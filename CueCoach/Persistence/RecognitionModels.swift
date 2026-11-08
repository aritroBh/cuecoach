import Foundation
import SQLite3
import SwiftData

// Recognition store (Recognition/Recognition.store). See docs/SCHEMA.md.
// Opt-in face/appearance embeddings only. Its own SwiftData store, in its own directory that is excluded from
// iCloud/Finder device backups and protected `.complete`, so embeddings never leave the phone in a backup.
// Rows point at a PlayerProfile by id (SwiftData relationships can't cross stores).

@Model
final class RecognitionData {
    @Attribute(.unique) var id: UUID
    var profileID: UUID
    @Attribute(.externalStorage) private var faceEmbeddingValue: Data?
    var faceEmbedding: Data? { get { faceEmbeddingValue } set { faceEmbeddingValue = newValue; updatedAt = .now } }
    @Attribute(.externalStorage) private var appearanceEmbeddingValue: Data?
    var appearanceEmbedding: Data? { get { appearanceEmbeddingValue } set { appearanceEmbeddingValue = newValue; updatedAt = .now } }
    private var optedInAtValue: Date
    var optedInAt: Date { get { optedInAtValue } set { optedInAtValue = newValue; updatedAt = .now } }
    private var versionValue: Int
    var version: Int { get { versionValue } set { versionValue = newValue; updatedAt = .now } }
    var updatedAt: Date

    init(id: UUID = UUID(), profileID: UUID, faceEmbedding: Data?, appearanceEmbedding: Data?, optedInAt: Date,
         version: Int, updatedAt: Date? = nil) {
        self.id = id
        self.profileID = profileID
        self.faceEmbeddingValue = faceEmbedding
        self.appearanceEmbeddingValue = appearanceEmbedding
        self.optedInAtValue = optedInAt
        self.versionValue = version
        self.updatedAt = updatedAt ?? optedInAt
    }

    convenience init(_ r: RecognitionRecord) {
        self.init(id: r.id, profileID: r.profileID, faceEmbedding: r.faceEmbedding,
                  appearanceEmbedding: r.appearanceEmbedding, optedInAt: r.optedInAt, version: r.version,
                  updatedAt: r.updatedAt)
    }

    var record: RecognitionRecord {
        RecognitionRecord(id: id, profileID: profileID, faceEmbedding: faceEmbedding,
                          appearanceEmbedding: appearanceEmbedding, optedInAt: optedInAt, version: version,
                          updatedAt: updatedAt)
    }
}

/// Value copy of a row: the migration's hand-off and the Undo snapshot. Never encoded, never written to disk.
struct RecognitionRecord: Sendable, Equatable {
    var id: UUID
    var profileID: UUID
    var faceEmbedding: Data?
    var appearanceEmbedding: Data?
    var optedInAt: Date
    var version: Int
    var updatedAt: Date
}

enum RecognitionError: Error, Equatable {
    /// The profile deleted its recognition data after this opt-in; a fresh opt-in is needed.
    case revoked
    /// No profile with that id on this phone.
    case unknownProfile
}

/// Anything holding embeddings derived from the store (identity galleries, matcher caches) registers here so
/// "Delete recognition data", guest purge and promotion reach it. Called on the main actor, synchronously.
@MainActor
protocol RecognitionGallery: AnyObject {
    func recognitionDidChange(_ change: RecognitionChange)
}

enum RecognitionChange: Equatable, Sendable {
    /// Every embedding is gone: drop all of them, including ones learned in this session.
    case purgedAll
    /// These profiles' embeddings are gone.
    case purged(Set<UUID>)
    /// Undo brought these profiles' rows back; reload them from the store.
    case restored(Set<UUID>)
}

/// File-level handling of the recognition store, usable off the main actor (the migration runs there).
enum RecognitionStoreFiles {
    static let directoryName = "Recognition"
    static let storeName = "Recognition"
    /// Present while a one-tap delete is inside its Undo window. Holds no data; on launch it means
    /// "finish the delete" (the app died before the window closed).
    static let pendingDeleteName = ".pending-delete"

    static func directory(in base: URL) -> URL { base.appendingPathComponent(directoryName, isDirectory: true) }
    static func storeURL(in base: URL) -> URL { directory(in: base).appendingPathComponent("\(storeName).store") }
    static func pendingDeleteURL(in base: URL) -> URL { directory(in: base).appendingPathComponent(pendingDeleteName) }

    static func container(in base: URL?, inMemory: Bool) throws -> ModelContainer {
        let schema = Schema(versionedSchema: RecognitionSchemaV1.self)
        let config: ModelConfiguration
        if inMemory || base == nil {
            config = ModelConfiguration(storeName, schema: schema, isStoredInMemoryOnly: true, allowsSave: true,
                                        groupContainer: .none, cloudKitDatabase: .none)
        } else {
            let base = base!
            try prepareDirectory(in: base)
            config = ModelConfiguration(storeName, schema: schema, url: storeURL(in: base), allowsSave: true,
                                        cloudKitDatabase: .none)
        }
        let container = try ModelContainer(for: schema, migrationPlan: RecognitionMigrationPlan.self,
                                           configurations: [config])
        if let base, !inMemory { try protect(in: base) }
        return container
    }

    /// Creates the directory already excluded and `.complete`, so the store's first byte is never backed up.
    /// Files created inside inherit the directory's protection class; exclusion covers the whole subtree.
    static func prepareDirectory(in base: URL) throws {
        let dir = directory(in: base)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.complete])
        try protect(in: base)
    }

    /// Marks the directory and every file under it excluded from backup, protection `.complete`.
    static func protect(in base: URL) throws {
        let dir = directory(in: base)
        var urls = [dir]
        if let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) {
            for case let url as URL in e { urls.append(url) }
        }
        for var url in urls {
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try url.setResourceValues(values)
            #if targetEnvironment(simulator)
            // The simulator has no data protection; the call is a no-op there.
            try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
            #else
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
            #endif
        }
    }

    /// Migration hand-off: upserts the rows into the recognition store in `base`.
    static func write(_ records: [RecognitionRecord], in base: URL) throws {
        let container = try self.container(in: base, inMemory: false)
        let ctx = ModelContext(container)
        let existing = Set(try ctx.fetch(FetchDescriptor<RecognitionData>()).map(\.id))
        for r in records where !existing.contains(r.id) { ctx.insert(RecognitionData(r)) }
        try ctx.save()
        try protect(in: base)
    }
}

/// After the V1 → V2 stage deleted the embeddings from Competitive.store, SQLite still holds their bytes in free
/// pages and the WAL, and the V1 external-blob folder still holds the big ones. A marker file (written by the stage
/// before it deletes anything) makes the scrub durable: every open retries it until it succeeds.
enum RecognitionMigration {
    enum Failure: Error { case noStoreURL, sqlite(String), checkpointBlocked, marker }

    static func pendingScrubURL(in base: URL) -> URL { base.appendingPathComponent(".Competitive.scrub-pending") }

    static func markScrubPending(in base: URL) throws {
        guard FileManager.default.createFile(atPath: pendingScrubURL(in: base).path, contents: nil) else {
            throw Failure.marker
        }
    }

    static func isScrubPending(in base: URL) -> Bool {
        FileManager.default.fileExists(atPath: pendingScrubURL(in: base).path)
    }

    /// Removes the V1 external-blob folder (no CompetitiveSchemaV2 attribute uses external storage, so every file
    /// there belonged to a V1 RecognitionData row), VACUUMs the database and truncates the WAL, checking that each
    /// checkpoint really completed. Only call with no other connection open. Clears the marker on success.
    static func scrub(_ storeURL: URL) throws {
        let base = storeURL.deletingLastPathComponent()
        let support = base
            .appendingPathComponent(".\(storeURL.deletingPathExtension().lastPathComponent)_SUPPORT/_EXTERNAL_DATA")
        if FileManager.default.fileExists(atPath: support.path) { try FileManager.default.removeItem(at: support) }
        var db: OpaquePointer?
        guard sqlite3_open_v2(storeURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            defer { sqlite3_close(db) }
            throw Failure.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 5_000)
        try checkpoint(db)
        guard sqlite3_exec(db, "VACUUM;", nil, nil, nil) == SQLITE_OK else {
            throw Failure.sqlite("VACUUM \(String(cString: sqlite3_errmsg(db)))")
        }
        try checkpoint(db)
        try FileManager.default.removeItem(at: pendingScrubURL(in: base))
    }

    /// `PRAGMA wal_checkpoint(TRUNCATE)` reports a blocked checkpoint in its result row (busy = 1), not in the
    /// return code, so read the row.
    private static func checkpoint(_ db: OpaquePointer?) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA wal_checkpoint(TRUNCATE);", -1, &stmt, nil) == SQLITE_OK else {
            throw Failure.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw Failure.sqlite(String(cString: sqlite3_errmsg(db))) }
        guard sqlite3_column_int(stmt, 0) == 0 else { throw Failure.checkpointBlocked }
    }
}

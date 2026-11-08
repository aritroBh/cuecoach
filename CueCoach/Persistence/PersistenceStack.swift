import Foundation
import SwiftData

/// Owns the three SwiftData containers, each in its own file:
/// - `Competitive.store`: profiles, games, stats. Backed up with the device.
/// - `Training.store`: drills. Separate schema, so training rows can never be counted as competitive stats.
/// - `Recognition/Recognition.store`: opt-in embeddings only. Excluded from device backup, protection `.complete`.
/// Local-only: no CloudKit (free Personal Team).
@MainActor
final class PersistenceStack {
    static let competitiveModels: [any PersistentModel.Type] = CompetitiveSchemaV2.models
    static let trainingModels: [any PersistentModel.Type] = TrainingSchemaV1.models
    static let recognitionModels: [any PersistentModel.Type] = RecognitionSchemaV1.models

    enum StoreKind: Sendable { case competitive, training, trainingCompensation }

    /// Test seam: called right before each store is saved during an import; throwing simulates a save failure.
    var beforeSave: ((StoreKind) throws -> Void)?

    let competitiveContainer: ModelContainer
    let trainingContainer: ModelContainer
    /// Replaced after "Delete recognition data": `deleteAllData()` destroys the store files and leaves the old
    /// container without a store, so a fresh (empty) one is opened in its place.
    var recognitionContainer: ModelContainer
    var competitiveContext: ModelContext { competitiveContainer.mainContext }
    var trainingContext: ModelContext { trainingContainer.mainContext }
    var recognitionContext: ModelContext { recognitionContainer.mainContext }

    /// nil when in memory.
    let directory: URL?
    var galleries: [WeakGallery] = []

    struct WeakGallery { weak var gallery: (any RecognitionGallery)? }

    static func recognitionDirectory(in base: URL) -> URL { RecognitionStoreFiles.directory(in: base) }

    /// - Parameters:
    ///   - inMemory: tests only; nothing touches disk.
    ///   - directory: where the stores live (default: Application Support).
    ///   - skipScrubForTesting: simulates a crash between the V1 → V2 migration and its scrub.
    init(inMemory: Bool = false, directory: URL? = nil, skipScrubForTesting: Bool = false) throws {
        let dir = directory ?? URL.applicationSupportDirectory
        self.directory = inMemory ? nil : dir
        if !inMemory { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }

        if !inMemory {
            // Open once just to run any pending migration, then let it close. The V1 → V2 stage deletes the
            // embeddings, but SQLite keeps their bytes in free pages and the WAL until a VACUUM.
            let url = dir.appendingPathComponent("Competitive.store")
            do { _ = try Self.container(name: "Competitive", schema: CompetitiveSchemaV2.self,
                                        plan: CompetitiveMigrationPlan.self, dir: dir, inMemory: false) }
            // Retried on every open until it succeeds; a failure (e.g. a blocked checkpoint) keeps the marker and
            // the app usable rather than locking the user out of their stats.
            if RecognitionMigration.isScrubPending(in: dir) {
                // Until the scrub succeeds the file may hold V1 template bytes: keep it out of device backups.
                try RecognitionMigration.setCompetitiveExcluded(true, storeURL: url)
                if !skipScrubForTesting, (try? RecognitionMigration.scrub(url)) != nil {
                    try RecognitionMigration.setCompetitiveExcluded(false, storeURL: url)   // stats back up again
                }
            }
        }
        competitiveContainer = try Self.container(name: "Competitive", schema: CompetitiveSchemaV2.self,
                                                  plan: CompetitiveMigrationPlan.self, dir: dir, inMemory: inMemory)
        trainingContainer = try Self.container(name: "Training", schema: TrainingSchemaV1.self,
                                               plan: TrainingMigrationPlan.self, dir: dir, inMemory: inMemory)
        recognitionContainer = try RecognitionStoreFiles.container(in: inMemory ? nil : dir, inMemory: inMemory)

        if !inMemory, FileManager.default.fileExists(atPath: RecognitionStoreFiles.pendingDeleteURL(in: dir).path) {
            try deleteMyRecognitionData()   // the app died inside an Undo window: finish the delete
        }
        try pruneOrphanRecognition()
    }

    private static func container(name: String, schema versioned: any VersionedSchema.Type,
                                  plan: any SchemaMigrationPlan.Type, dir: URL,
                                  inMemory: Bool) throws -> ModelContainer {
        let schema = Schema(versionedSchema: versioned)
        let config = inMemory
            ? ModelConfiguration(name, schema: schema, isStoredInMemoryOnly: true, allowsSave: true,
                                 groupContainer: .none, cloudKitDatabase: .none)
            : ModelConfiguration(name, schema: schema, url: dir.appendingPathComponent("\(name).store"),
                                 allowsSave: true, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, migrationPlan: plan, configurations: [config])
    }

    // MARK: Gallery registry

    func register(_ gallery: any RecognitionGallery) {
        galleries.removeAll { $0.gallery == nil }
        galleries.append(WeakGallery(gallery: gallery))
    }

    func notifyGalleries(_ change: RecognitionChange) {
        galleries.removeAll { $0.gallery == nil }
        for g in galleries { g.gallery?.recognitionDidChange(change) }
    }
}

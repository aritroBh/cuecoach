import Foundation
import SQLite3
import SwiftData
import Testing
@testable import CueCoach

/// Recognition embeddings live in their own SwiftData store (Recognition/Recognition.store) that is excluded
/// from iCloud/Finder device backups and file-protected `.complete`. Competitive stats still back up.
@MainActor
@Suite struct RecognitionStoreTests {
    /// A byte run that can't occur by accident, so raw-file scans can't false-positive.
    static let marker = Data((0..<48).map { UInt8(truncatingIfNeeded: 0xC3 &+ $0 &* 7) })
    /// Above SwiftData's external-storage threshold, so the external-blob path is exercised too.
    static let bigMarker = Data((0..<300_000).map { UInt8(truncatingIfNeeded: 0x5A &+ $0 &* 13) })

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("rec-\(UUID().uuidString)", isDirectory: true)
    }

    private func populated(_ stack: PersistenceStack) throws {
        _ = Fixture.populateCompetitive(stack.competitiveContext)
        try stack.competitiveContext.save()
        try Fixture.addOwnerRecognition(stack, face: Self.marker, appearance: Self.bigMarker)
    }

    // MARK: Backup exclusion + file protection

    @Test func recognitionStoreIsExcludedFromDeviceBackup() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stack = try PersistenceStack(directory: dir)
        try populated(stack)
        let recDir = PersistenceStack.recognitionDirectory(in: dir)
        #expect(recDir.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL)
        #expect(try recDir.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        let files = try FileManager.default.contentsOfDirectory(at: recDir, includingPropertiesForKeys: nil)
        #expect(files.contains { $0.lastPathComponent == "Recognition.store" })
        for f in files {
            #expect(try f.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true,
                    "\(f.lastPathComponent) is backed up")
        }
        // The simulator ignores data protection (setAttributes is a no-op there and files report a canned
        // default), so the class can only be checked on a device.
        #if !targetEnvironment(simulator)
        for url in [recDir] + files where !url.hasDirectoryPath {
            let p = try url.resourceValues(forKeys: [.fileProtectionKey]).fileProtection
            #expect(p == .complete, "\(url.lastPathComponent) protection \(String(describing: p))")
        }
        #endif
    }

    @Test func recognitionStoreStaysExcludedAfterDelete() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stack = try PersistenceStack(directory: dir)
        try populated(stack)
        try stack.deleteMyRecognitionData()
        try Fixture.addOwnerRecognition(stack, face: Data([1]), appearance: nil, optedInAt: .now.addingTimeInterval(5))
        let recDir = PersistenceStack.recognitionDirectory(in: dir)
        #expect(try recDir.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        for f in try FileManager.default.contentsOfDirectory(at: recDir, includingPropertiesForKeys: nil) {
            #expect(try f.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        }
    }

    @Test func competitiveAndTrainingStoresStillBackUp() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stack = try PersistenceStack(directory: dir)
        try populated(stack)
        for name in ["Competitive.store", "Training.store"] {
            let url = dir.appendingPathComponent(name)
            #expect(FileManager.default.fileExists(atPath: url.path))
            #expect(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == false)
        }
        #expect(try dir.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == false)
    }

    @Test func embeddingsNeverTouchCompetitiveFiles() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stack = try PersistenceStack(directory: dir)
        try populated(stack)
        #expect(try stack.recognition(for: Fixture.ownerID)?.faceEmbedding == Self.marker)
        #expect(!RawScan.contains(Self.marker, under: dir, excluding: PersistenceStack.recognitionDirectory(in: dir)))
        #expect(RawScan.contains(Self.marker, under: PersistenceStack.recognitionDirectory(in: dir)))
    }

    @Test func schemasAreSplitThreeWays() throws {
        let stack = try PersistenceStack(inMemory: true)
        let comp = Set(stack.competitiveContainer.schema.entities.map(\.name))
        #expect(!comp.contains("RecognitionData"))
        #expect(Set(stack.recognitionContainer.schema.entities.map(\.name)) == ["RecognitionData"])
        let profile = try #require(stack.competitiveContainer.schema.entities.first { $0.name == "PlayerProfile" })
        #expect(profile.relationships.isEmpty)
    }

    // MARK: Migration V1 → V2

    /// Builds a V1 (pre-split) Competitive.store with an owner and a guest that both have embeddings.
    private func makeV1Store(at dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let schema = Schema(versionedSchema: CompetitiveSchemaV1.self)
        let config = ModelConfiguration("Competitive", schema: schema,
                                        url: dir.appendingPathComponent("Competitive.store"),
                                        allowsSave: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [config])
        let ctx = ModelContext(container)
        let owner = CompetitiveSchemaV1.PlayerProfile(id: Fixture.ownerID, name: "Ari", isLocalOwner: true,
                                                      isSessionGuest: false, createdAt: Fixture.t0)
        owner.recognitionLink = CompetitiveSchemaV1.RecognitionData(
            faceEmbedding: Self.marker, appearanceEmbedding: Self.bigMarker, optedInAt: Fixture.t0, version: 3)
        let guest = CompetitiveSchemaV1.PlayerProfile(id: Fixture.guestID, name: "Sam", isLocalOwner: false,
                                                      isSessionGuest: true, createdAt: Fixture.t0)
        guest.recognitionLink = CompetitiveSchemaV1.RecognitionData(
            faceEmbedding: Data([9, 9]), appearanceEmbedding: nil, optedInAt: Fixture.t0, version: 1)
        ctx.insert(owner)
        ctx.insert(guest)
        ctx.insert(CompetitiveSchemaV2.Session(startedAt: Fixture.t0, ruleSet: .barEight, format: .oneVsOne,
                                               tableSize: .sevenFoot))   // the frozen shape V1 shipped
        try ctx.save()
    }

    @Test func migrationMovesRecognitionOutOfCompetitiveStore() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeV1Store(at: dir)
        #expect(RawScan.contains(Self.marker, under: dir))   // sanity: V1 really held it

        let stack = try PersistenceStack(directory: dir)

        // Competitive keeps its stats and loses the entity.
        #expect(try stack.competitiveContext.fetch(FetchDescriptor<PlayerProfile>()).count == 2)
        #expect(try Fixture.count(Session.self, stack.competitiveContext) == 1)
        #expect(!Set(stack.competitiveContainer.schema.entities.map(\.name)).contains("RecognitionData"))
        let tables = try RawScan.sqliteTables(dir.appendingPathComponent("Competitive.store"))
        #expect(!tables.contains("ZRECOGNITIONDATA"), "tables: \(tables)")
        #expect(tables.contains("ZPLAYERPROFILE"))

        // The rows moved, keyed by profile id.
        let owner = try #require(try stack.recognition(for: Fixture.ownerID))
        #expect(owner.faceEmbedding == Self.marker)
        #expect(owner.appearanceEmbedding == Self.bigMarker)
        #expect(owner.version == 3)
        #expect(try stack.recognition(for: Fixture.guestID)?.faceEmbedding == Data([9, 9]))

        // No embedding bytes are left behind in Competitive.store, its WAL, or its external-data folder.
        let rec = PersistenceStack.recognitionDirectory(in: dir)
        #expect(!RawScan.contains(Self.marker, under: dir, excluding: rec))
        #expect(!RawScan.contains(Self.bigMarker.prefix(4096), under: dir, excluding: rec))
    }

    /// Codex r1: the scrub must survive a crash between the migration and the VACUUM. The pending mark is a file
    /// written before the rows are deleted, so the next open still scrubs.
    @Test func scrubInterruptedAfterMigrationIsRetriedOnNextOpen() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeV1Store(at: dir)
        do { _ = try PersistenceStack(directory: dir, skipScrubForTesting: true) }   // "crash" before the scrub
        #expect(FileManager.default.fileExists(atPath: RecognitionMigration.pendingScrubURL(in: dir).path))
        // Codex r2: while residue may remain, Competitive.store and its sidecars stay out of device backups.
        let competitive = dir.appendingPathComponent("Competitive.store")
        #expect(try competitive.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        let stack = try PersistenceStack(directory: dir)
        #expect(!FileManager.default.fileExists(atPath: RecognitionMigration.pendingScrubURL(in: dir).path))
        let fresh = dir.appendingPathComponent("Competitive.store")   // URL caches resource values; read anew
        #expect(try fresh.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == false)
        let rec = PersistenceStack.recognitionDirectory(in: dir)
        #expect(!RawScan.contains(Self.marker, under: dir, excluding: rec))
        #expect(!RawScan.contains(Self.bigMarker.prefix(4096), under: dir, excluding: rec))
        #expect(try stack.recognition(for: Fixture.ownerID)?.faceEmbedding == Self.marker)
    }

    @Test func migratedStoreReopensWithoutMigratingAgain() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeV1Store(at: dir)
        do { _ = try PersistenceStack(directory: dir) }
        let again = try PersistenceStack(directory: dir)
        #expect(try Fixture.count(RecognitionData.self, again.recognitionContext) == 2)
        #expect(try Fixture.count(PlayerProfile.self, again.competitiveContext) == 2)
    }

    // MARK: One-tap delete

    @Test func deleteEmptiesTheRecognitionStore() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stack = try PersistenceStack(directory: dir)
        try populated(stack)
        stack.recognitionContext.insert(RecognitionData(profileID: Fixture.guestID, faceEmbedding: Data([7]),
                                                        appearanceEmbedding: nil, optedInAt: Fixture.t0, version: 1))
        try stack.recognitionContext.save()
        let gallery = FakeGallery()
        stack.register(gallery)

        try stack.deleteMyRecognitionData()

        #expect(try Fixture.count(RecognitionData.self, stack.recognitionContext) == 0)
        #expect(gallery.changes == [.purgedAll])
        #expect(try stack.competitiveContext.fetch(FetchDescriptor<PlayerProfile>()).first?.recognitionRevokedAt != nil)
        #expect(try Fixture.count(Session.self, stack.competitiveContext) == 1)   // stats untouched
        // Gone from disk too, not just unlinked: no residue in pages, WAL or external blobs.
        #expect(!RawScan.contains(Self.marker, under: dir))
        #expect(!RawScan.contains(Self.bigMarker.prefix(4096), under: dir))
        let reopened = try PersistenceStack(directory: dir)
        #expect(try Fixture.count(RecognitionData.self, reopened.recognitionContext) == 0)
    }

    @Test func stagedDeleteHidesDataUndoRestoresIt() throws {
        let stack = try PersistenceStack(inMemory: true)
        try populated(stack)
        let gallery = FakeGallery()
        stack.register(gallery)

        let undo = try stack.beginRecognitionDeletion()
        #expect(try stack.recognition(for: Fixture.ownerID) == nil)
        #expect(try Fixture.count(RecognitionData.self, stack.recognitionContext) == 0)

        try stack.undoRecognitionDeletion(undo)
        #expect(try stack.recognition(for: Fixture.ownerID)?.faceEmbedding == Self.marker)
        #expect(try stack.competitiveContext.fetch(FetchDescriptor<PlayerProfile>()).first?.recognitionRevokedAt == nil)
        #expect(gallery.changes.first == .purgedAll)
        if case .restored(let ids) = gallery.changes.last { #expect(ids == [Fixture.ownerID]) }
        else { Issue.record("gallery not told about the restore: \(gallery.changes)") }
    }

    @Test func stagedDeleteWritesNothingUntilCommitted() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stack = try PersistenceStack(directory: dir)
        try populated(stack)
        _ = try stack.beginRecognitionDeletion()
        // The on-disk store still has the row: staging is in memory only.
        let peek = try ModelContext(stack.recognitionContainer).fetchCount(FetchDescriptor<RecognitionData>())
        #expect(peek == 1)
        try stack.deleteMyRecognitionData()
        #expect(try ModelContext(stack.recognitionContainer).fetchCount(FetchDescriptor<RecognitionData>()) == 0)
    }

    /// If the app dies inside the Undo window, the next launch finishes the delete instead of reviving the data.
    @Test func pendingDeleteIsCommittedOnNextLaunch() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            let stack = try PersistenceStack(directory: dir)
            try populated(stack)
            _ = try stack.beginRecognitionDeletion()
        }   // "crash": never committed, never undone
        let next = try PersistenceStack(directory: dir)
        #expect(try Fixture.count(RecognitionData.self, next.recognitionContext) == 0)
        #expect(try next.competitiveContext.fetch(FetchDescriptor<PlayerProfile>()).first?.recognitionRevokedAt != nil)
        #expect(!RawScan.contains(Self.marker, under: dir))
    }

    @Test func undoneDeleteIsNotCommittedOnNextLaunch() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            let stack = try PersistenceStack(directory: dir)
            try populated(stack)
            try stack.undoRecognitionDeletion(stack.beginRecognitionDeletion())
        }
        let next = try PersistenceStack(directory: dir)
        #expect(try next.recognition(for: Fixture.ownerID)?.faceEmbedding == Self.marker)
    }

    /// Codex r2: the one tap clears every profile's rows, so every profile is fenced, not just the owner.
    @Test func deleteFencesEveryProfileItCleared() throws {
        let stack = try PersistenceStack(inMemory: true)
        try populated(stack)
        stack.competitiveContext.insert(PlayerProfile(id: Fixture.guestID, name: "Sam", avatarSymbol: "s",
                                                      avatarColor: "c", isSessionGuest: true))
        try stack.competitiveContext.save()
        try stack.storeRecognition(profileID: Fixture.guestID, faceEmbedding: Data([7]), appearanceEmbedding: nil,
                                   optedInAt: Fixture.t0, version: 1)
        try stack.deleteMyRecognitionData()
        #expect(throws: RecognitionError.revoked) {
            try stack.storeRecognition(profileID: Fixture.guestID, faceEmbedding: Data([7]), appearanceEmbedding: nil,
                                       optedInAt: Fixture.t0, version: 1)
        }
    }

    @Test func revokedOwnerCannotStoreAnOlderOptIn() throws {
        let stack = try PersistenceStack(inMemory: true)
        try populated(stack)
        try stack.deleteMyRecognitionData(now: Fixture.t0.addingTimeInterval(100))
        #expect(throws: RecognitionError.revoked) {
            try Fixture.addOwnerRecognition(stack, face: Data([1]), appearance: nil, optedInAt: Fixture.t0)
        }
        try Fixture.addOwnerRecognition(stack, face: Data([2]), appearance: nil,
                                        optedInAt: Fixture.t0.addingTimeInterval(200))
        #expect(try stack.recognition(for: Fixture.ownerID)?.faceEmbedding == Data([2]))
    }

    @Test func storingAgainReplacesTheProfilesRow() throws {
        let stack = try PersistenceStack(inMemory: true)
        try populated(stack)
        try Fixture.addOwnerRecognition(stack, face: Data([4]), appearance: nil)
        #expect(try Fixture.count(RecognitionData.self, stack.recognitionContext) == 1)
        #expect(try stack.recognition(for: Fixture.ownerID)?.faceEmbedding == Data([4]))
    }

    // MARK: Guests, orphans

    @Test func purgeSessionGuestsDropsTheirRecognition() throws {
        let stack = try PersistenceStack(inMemory: true)
        try populated(stack)
        stack.competitiveContext.insert(PlayerProfile(id: Fixture.guestID, name: "Sam", avatarSymbol: "s",
                                                      avatarColor: "c", isSessionGuest: true))
        try stack.competitiveContext.save()
        try stack.storeRecognition(profileID: Fixture.guestID, faceEmbedding: Data([7]), appearanceEmbedding: nil,
                                   optedInAt: Fixture.t0, version: 1)
        let gallery = FakeGallery()
        stack.register(gallery)
        try stack.purgeSessionGuests()
        #expect(try stack.recognition(for: Fixture.guestID) == nil)
        #expect(try stack.recognition(for: Fixture.ownerID) != nil)
        #expect(gallery.changes == [.purged([Fixture.guestID])])
    }

    @Test func recognitionWithoutAProfileIsPrunedOnOpen() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            let s = try PersistenceStack(directory: dir)
            try populated(s)
            s.recognitionContext.insert(RecognitionData(profileID: UUID(), faceEmbedding: Data([3]),
                                                        appearanceEmbedding: nil, optedInAt: Fixture.t0, version: 1))
            try s.recognitionContext.save()
        }
        let r = try PersistenceStack(directory: dir)
        #expect(try r.recognitionContext.fetch(FetchDescriptor<RecognitionData>()).map(\.profileID) == [Fixture.ownerID])
    }

    @Test func deletingAProfileDropsItsRecognition() throws {
        let stack = try PersistenceStack(inMemory: true)
        try populated(stack)
        let owner = try #require(stack.competitiveContext.fetch(FetchDescriptor<PlayerProfile>()).first)
        try stack.deleteProfile(owner)
        #expect(try Fixture.count(RecognitionData.self, stack.recognitionContext) == 0)
        #expect(try Fixture.count(PlayerProfile.self, stack.competitiveContext) == 0)
    }

    // MARK: Export

    @Test func exportNeverIncludesEmbeddings() throws {
        let stack = try PersistenceStack(inMemory: true)
        try populated(stack)
        let data = try stack.exportBackup()
        let json = String(decoding: data, as: UTF8.self)
        for needle in ["faceEmbedding", "appearanceEmbedding", "\"recognition\"", "includesRecognition",
                       Self.marker.base64EncodedString(), String(Self.bigMarker.base64EncodedString().prefix(64))] {
            #expect(!json.contains(needle), "export contains \(needle.prefix(20))")
        }
        #expect(data.range(of: Self.marker) == nil)
    }

    @Test func importIgnoresRecognitionInALegacyBackup() throws {
        let legacy = """
        {"version":1,"exportedAt":"2023-11-14T22:13:20.123Z","includesRecognition":true,
         "competitive":{"profiles":[{"id":"\(Fixture.ownerID.uuidString)","name":"Ari","avatarSymbol":"s",
           "avatarColor":"c","isLocalOwner":true,"createdAt":"2023-11-14T22:13:20.123Z",
           "updatedAt":"2023-11-14T22:13:20.123Z","skillModel":{"aimSigma":0.01,"speedSigma":0.05,"spinSigma":0.1,"samples":1},
           "recognition":{"id":"\(UUID().uuidString)","faceEmbedding":"AQID","optedInAt":"2023-11-14T22:13:20.123Z",
             "version":1,"updatedAt":"2023-11-14T22:13:20.123Z"}}],
           "sessions":[],"games":[],"shots":[],"archetypes":[],"highlights":[]},
         "training":{"profiles":[],"drillProgress":[],"attempts":[],"biases":[]}}
        """
        let fresh = try PersistenceStack(inMemory: true)
        try fresh.importBackup(Data(legacy.utf8))
        #expect(try Fixture.count(PlayerProfile.self, fresh.competitiveContext) == 1)
        #expect(try Fixture.count(RecognitionData.self, fresh.recognitionContext) == 0)
    }

    // MARK: Revocation flag travels in backups (the data never does)

    @Test func revocationIsExportedAndSurvivesRestore() throws {
        let stack = try PersistenceStack(inMemory: true)
        try populated(stack)
        let revokedAt = Fixture.t0.addingTimeInterval(500)
        try stack.deleteMyRecognitionData(now: revokedAt)
        let b = try BackupV1.decode(stack.exportBackup())
        let p = try #require(b.competitive.profiles.first { $0.id == Fixture.ownerID })
        #expect(p.recognitionRevokedAt.map(BackupV1.millis) == BackupV1.millis(revokedAt))

        let fresh = try PersistenceStack(inMemory: true)
        try fresh.importBackup(b.encoded())
        let restored = try #require(fresh.competitiveContext.fetch(FetchDescriptor<PlayerProfile>()).first)
        #expect(restored.recognitionRevokedAt.map(BackupV1.millis) == BackupV1.millis(revokedAt))
        #expect(throws: RecognitionError.revoked) {
            try Fixture.addOwnerRecognition(fresh, face: Data([1]), appearance: nil, optedInAt: Fixture.t0)
        }
    }

    @Test func importNeverMovesRevocationBackwards() throws {
        let stack = try PersistenceStack(inMemory: true)
        try populated(stack)
        let newer = Fixture.t0.addingTimeInterval(900)
        try stack.deleteMyRecognitionData(now: newer)
        var b = try BackupV1.decode(stack.exportBackup())
        b.competitive.profiles[0].recognitionRevokedAt = Fixture.t0.addingTimeInterval(1)
        b.competitive.profiles[0].updatedAt = .now.addingTimeInterval(60)
        try stack.importBackup(b.encoded())
        var none = b
        none.competitive.profiles[0].recognitionRevokedAt = nil
        none.competitive.profiles[0].updatedAt = .now.addingTimeInterval(120)
        try stack.importBackup(none.encoded())
        let owner = try #require(stack.competitiveContext.fetch(FetchDescriptor<PlayerProfile>()).first)
        #expect(owner.recognitionRevokedAt.map(BackupV1.millis) == BackupV1.millis(newer))
    }

    // MARK: Guest promotion (audit F8 regression)

    private func stackWithLiveGuest() throws -> PersistenceStack {
        let stack = try PersistenceStack(inMemory: true)
        try populated(stack)
        stack.competitiveContext.insert(PlayerProfile(id: Fixture.guestID, name: "Sam", avatarSymbol: "s",
                                                      avatarColor: "c", isSessionGuest: true, createdAt: Fixture.t0))
        try stack.competitiveContext.save()
        try stack.storeRecognition(profileID: Fixture.guestID, faceEmbedding: Data([7, 7]), appearanceEmbedding: nil,
                                   optedInAt: Fixture.t0, version: 1)
        return stack
    }

    private func backupSavingGuest() throws -> Data {
        var b = BackupV1(exportedAt: Fixture.t0, competitive: .init(), training: .init())
        b.competitive.profiles = [.init(id: Fixture.guestID, name: "Sam (saved)", avatarSymbol: "s", avatarColor: "c",
                                        isLocalOwner: false, createdAt: Fixture.t0, updatedAt: Fixture.t0,
                                        skillModel: .prior)]
        return try b.encoded()
    }

    @Test func promotingAGuestDropsItsSessionRecognition() throws {
        let stack = try stackWithLiveGuest()
        let gallery = FakeGallery()
        stack.register(gallery)
        try stack.importBackup(backupSavingGuest())
        let guest = try #require(stack.competitiveContext.fetch(FetchDescriptor<PlayerProfile>())
            .first { $0.id == Fixture.guestID })
        #expect(!guest.isSessionGuest)
        #expect(try stack.recognition(for: Fixture.guestID) == nil)
        #expect(try stack.recognition(for: Fixture.ownerID) != nil)
        #expect(gallery.changes == [.purged([Fixture.guestID])])
    }

    @Test func promotingAGuestWithConsentKeepsItsRecognition() throws {
        let stack = try stackWithLiveGuest()
        try stack.importBackup(backupSavingGuest(), keepingRecognitionOf: [Fixture.guestID])
        #expect(try stack.recognition(for: Fixture.guestID)?.faceEmbedding == Data([7, 7]))
    }

    @Test func directPromotionDropsRecognitionUnlessConsented() throws {
        let stack = try stackWithLiveGuest()
        try stack.promoteSessionGuest(Fixture.guestID, keepRecognition: false)
        #expect(try stack.recognition(for: Fixture.guestID) == nil)
        try stack.purgeSessionGuests()
        #expect(try stack.competitiveContext.fetch(FetchDescriptor<PlayerProfile>()).contains { $0.id == Fixture.guestID })

        let other = try stackWithLiveGuest()
        try other.promoteSessionGuest(Fixture.guestID, keepRecognition: true)
        #expect(try other.recognition(for: Fixture.guestID) != nil)
    }

    /// Codex r1: a delayed session capture can't sneak back after a non-consented promotion.
    @Test func promotionWithoutConsentFencesLateSessionCaptures() throws {
        let stack = try stackWithLiveGuest()
        try stack.promoteSessionGuest(Fixture.guestID, keepRecognition: false)
        #expect(throws: RecognitionError.revoked) {
            try stack.storeRecognition(profileID: Fixture.guestID, faceEmbedding: Data([1]), appearanceEmbedding: nil,
                                       optedInAt: Fixture.t0.addingTimeInterval(10), version: 1)
        }
        let viaImport = try stackWithLiveGuest()
        try viaImport.importBackup(backupSavingGuest())
        #expect(throws: RecognitionError.revoked) {
            try viaImport.storeRecognition(profileID: Fixture.guestID, faceEmbedding: Data([1]), appearanceEmbedding: nil,
                                           optedInAt: Fixture.t0.addingTimeInterval(10), version: 1)
        }
        // A fresh opt-in after promotion is still possible.
        try stack.storeRecognition(profileID: Fixture.guestID, faceEmbedding: Data([2]), appearanceEmbedding: nil,
                                   optedInAt: .now.addingTimeInterval(60), version: 1)
        #expect(try stack.recognition(for: Fixture.guestID)?.faceEmbedding == Data([2]))
    }

    /// Codex r1: a gallery can hold a session-only copy with no persisted row; promotion must still reach it.
    @Test func promotionNotifiesGalleriesEvenWithoutAStoredRow() throws {
        let stack = try PersistenceStack(inMemory: true)
        stack.competitiveContext.insert(PlayerProfile(id: Fixture.guestID, name: "Sam", avatarSymbol: "s",
                                                      avatarColor: "c", isSessionGuest: true))
        try stack.competitiveContext.save()
        let gallery = FakeGallery()
        stack.register(gallery)
        try stack.promoteSessionGuest(Fixture.guestID, keepRecognition: false)
        #expect(gallery.changes == [.purged([Fixture.guestID])])
        try stack.purgeSessionGuests()   // nothing left to purge: no notification for an empty set
        #expect(gallery.changes == [.purged([Fixture.guestID])])
    }

    @Test func failedImportDoesNotPromoteOrKeepGuestRecognition() throws {
        let stack = try stackWithLiveGuest()
        struct Boom: Error {}
        stack.beforeSave = { if $0 == .competitive { throw Boom() } }
        #expect(throws: Boom.self) { try stack.importBackup(backupSavingGuest()) }
        stack.beforeSave = nil
        let guest = try #require(stack.competitiveContext.fetch(FetchDescriptor<PlayerProfile>())
            .first { $0.id == Fixture.guestID })
        #expect(guest.isSessionGuest)   // still a guest: purge at session end will still remove it
    }
}

@MainActor
final class FakeGallery: RecognitionGallery {
    var changes: [RecognitionChange] = []
    func recognitionDidChange(_ change: RecognitionChange) { changes.append(change) }
}

/// Raw byte scans of store files, so "deleted" means gone from disk, not just from the object graph.
enum RawScan {
    static func contains(_ needle: Data, under dir: URL, excluding: URL? = nil) -> Bool {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey],
                                                     options: []) else { return false }
        let skip = excluding?.standardizedFileURL.path
        for case let url as URL in e {
            if let skip, url.standardizedFileURL.path.hasPrefix(skip) { continue }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let data = try? Data(contentsOf: url) else { continue }
            if data.range(of: needle) != nil { return true }
        }
        return false
    }

    static func sqliteTables(_ url: URL) throws -> Set<String> {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            throw CocoaError(.fileReadUnknown)
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type='table'", -1, &stmt, nil) == SQLITE_OK
        else { throw CocoaError(.fileReadUnknown) }
        defer { sqlite3_finalize(stmt) }
        var out: Set<String> = []
        while sqlite3_step(stmt) == SQLITE_ROW { out.insert(String(cString: sqlite3_column_text(stmt, 0))) }
        return out
    }
}

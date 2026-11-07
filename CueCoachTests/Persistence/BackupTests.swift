import Foundation
import SwiftData
import Testing
@testable import CueCoach

@MainActor
@Suite struct BackupTests {
    private func populated() throws -> PersistenceStack {
        let stack = try PersistenceStack(inMemory: true)
        _ = Fixture.populateCompetitive(stack.competitiveContext)
        _ = Fixture.populateTraining(stack.trainingContext)
        try stack.competitiveContext.save()
        try stack.trainingContext.save()
        return stack
    }

    private func decode(_ data: Data) throws -> BackupV1 { try BackupV1.decode(data) }

    @Test func exportWipeImportRoundTripsBothStores() throws {
        let original = try populated()
        let backup = try original.exportBackup(exportedAt: Fixture.t0)

        let fresh = try PersistenceStack(inMemory: true)   // wiped device
        try fresh.importBackup(backup)
        let again = try fresh.exportBackup(exportedAt: Fixture.t0)

        let a = try decode(backup), b = try decode(again)
        #expect(a == b)
        #expect(a.competitive.profiles.count == 1)
        #expect(a.competitive.sessions.count == 1)
        #expect(a.competitive.games.count == 1)
        #expect(a.competitive.shots.count == 2)
        #expect(a.competitive.archetypes.count == 1)
        #expect(a.competitive.highlights.count == 1)
        #expect(a.training.profiles.count == 1)
        #expect(a.training.drillProgress.count == 1)
        #expect(a.training.attempts.count == 3)
        #expect(a.training.biases.count == 1)
    }

    @Test func importRestoresRelationships() throws {
        let backup = try populated().exportBackup()
        let fresh = try PersistenceStack(inMemory: true)
        try fresh.importBackup(backup)
        let session = try #require(fresh.competitiveContext.fetch(FetchDescriptor<Session>()).first)
        #expect(session.games.first?.shots.count == 2)
        #expect(session.games.first?.highlights.count == 1)
        let owner = try #require(fresh.competitiveContext.fetch(FetchDescriptor<PlayerProfile>()).first)
        #expect(owner.recognition == nil)          // recognition data never travels in a backup (CX-4)
        let progress = try #require(fresh.trainingContext.fetch(FetchDescriptor<DrillProgress>()).first)
        #expect(progress.attempts.count == 3)
    }

    @Test func jsonIsVersionedSortedAndUsesISO8601Dates() throws {
        let data = try populated().exportBackup(exportedAt: Fixture.t0)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"version\":1"))
        #expect(json.contains("\"exportedAt\":\"2023-11-14T22:13:20.123Z\""))
        let top = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(top.keys) == ["version", "exportedAt", "competitive", "training", "includesRecognition"])
        // sortedKeys: top-level keys appear alphabetically
        let order = ["competitive", "exportedAt", "includesRecognition", "training", "version"]
            .compactMap { json.range(of: "\"\($0)\":")?.lowerBound }
        #expect(order == order.sorted())
    }

    @Test func datesAreStableAcrossRepeatedRoundTrips() throws {
        var data = try populated().exportBackup(exportedAt: Fixture.t0)
        let first = try decode(data)
        for _ in 0..<3 { data = try decode(data).encoded() }
        #expect(try decode(data) == first)
        #expect(String(decoding: data, as: UTF8.self).contains("\"exportedAt\":\"2023-11-14T22:13:20.123Z\""))
    }

    @Test func recognitionIsNeverExported() throws {
        // CX-4: face and clothing vectors never leave the device inside a backup file.
        let stack = try populated()
        let data = try stack.exportBackup()
        let b = try decode(data)
        #expect(b.includesRecognition == false)
        #expect(b.competitive.profiles.allSatisfy { $0.recognition == nil })
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.contains("faceEmbedding") && !json.contains("appearanceEmbedding"))
    }

    @Test func handEditedBackupCannotRestoreRecognition() throws {
        // CX-4: a file that claims to carry embeddings is still never written into the store.
        var b = try decode(populated().exportBackup())
        b.includesRecognition = true
        b.competitive.profiles[0].recognition = .init(id: UUID(), faceEmbedding: Data([9]), appearanceEmbedding: Data([9]),
                                                     optedInAt: Fixture.t0, version: 1, updatedAt: Fixture.t0)
        let fresh = try PersistenceStack(inMemory: true)
        try fresh.importBackup(b.encoded())
        #expect(try Fixture.count(PlayerProfile.self, fresh.competitiveContext) == 1)
        #expect(try Fixture.count(RecognitionData.self, fresh.competitiveContext) == 0)
    }

    @Test func importingBackupWithoutRecognitionKeepsLocalEmbeddings() throws {
        let stack = try populated()
        try stack.importBackup(stack.exportBackup())
        #expect(try Fixture.count(RecognitionData.self, stack.competitiveContext) == 1)
    }

    @Test func mergeConflictNewerUpdatedAtWins() throws {
        let stack = try populated()
        var b = try decode(stack.exportBackup())
        b.competitive.profiles[0].name = "Newer"
        b.competitive.profiles[0].updatedAt = Fixture.t0.addingTimeInterval(60)
        b.training.drillProgress[0].level = 4
        b.training.drillProgress[0].updatedAt = .distantPast           // older → ignored
        try stack.importBackup(b.encoded())

        let owner = try #require(stack.competitiveContext.fetch(FetchDescriptor<PlayerProfile>()).first)
        #expect(owner.name == "Newer")
        let p = try #require(stack.trainingContext.fetch(FetchDescriptor<DrillProgress>()).first)
        #expect(p.level == 2)
    }

    @Test func localEditNewerThanBackupIsKept() throws {
        let stack = try populated()
        let backup = try stack.exportBackup()
        let owner = try #require(stack.competitiveContext.fetch(FetchDescriptor<PlayerProfile>()).first)
        owner.name = "Local"
        owner.touch(Fixture.t0.addingTimeInterval(3600))
        try stack.competitiveContext.save()
        try stack.importBackup(backup)
        #expect(owner.name == "Local")
    }

    @Test func reImportIsIdempotent() throws {
        let stack = try populated()
        let backup = try stack.exportBackup(exportedAt: Fixture.t0)
        try stack.importBackup(backup)
        try stack.importBackup(backup)
        let after = try stack.exportBackup(exportedAt: Fixture.t0)
        #expect(try decode(after) == decode(backup))
        #expect(try Fixture.count(Shot.self, stack.competitiveContext) == 2)
        #expect(try Fixture.count(TrainingAttempt.self, stack.trainingContext) == 3)
    }

    @Test func importAddsRowsFromAnotherDevice() throws {
        let stack = try populated()
        var b = try decode(stack.exportBackup())
        var extra = b.training.attempts[0]
        extra.id = UUID()
        b.training.attempts.append(extra)
        try stack.importBackup(b.encoded())
        #expect(try Fixture.count(TrainingAttempt.self, stack.trainingContext) == 4)
        let p = try #require(stack.trainingContext.fetch(FetchDescriptor<DrillProgress>()).first)
        #expect(p.attempts.count == 4)
    }

    @Test func unsupportedVersionIsRejectedWithoutChanges() throws {
        let stack = try populated()
        var b = try decode(stack.exportBackup())
        b.version = 2
        b.competitive.profiles[0].name = "Hacked"
        b.competitive.profiles[0].updatedAt = .distantFuture
        #expect(throws: BackupError.unsupportedVersion(2)) { try stack.importBackup(b.encoded()) }
        let owner = try #require(stack.competitiveContext.fetch(FetchDescriptor<PlayerProfile>()).first)
        #expect(owner.name == "Ari")
    }

    @Test func importNeverCreatesSessionGuests() throws {
        let source = try populated()
        source.competitiveContext.insert(PlayerProfile(id: Fixture.guestID, name: "Sam", avatarSymbol: "star",
                                                       avatarColor: "red", isSessionGuest: true))
        try source.competitiveContext.save()
        let fresh = try PersistenceStack(inMemory: true)
        try fresh.importBackup(source.exportBackup())
        let all = try fresh.competitiveContext.fetch(FetchDescriptor<PlayerProfile>())
        #expect(all.map(\.id) == [Fixture.ownerID])
        #expect(all.allSatisfy { !$0.isSessionGuest })
    }
}

@MainActor
@Suite struct BackupOwnerTests {
    @Test func importingAnotherPhonesOwnerDoesNotCreateSecondLocalOwner() throws {
        let other = try PersistenceStack(inMemory: true)
        other.competitiveContext.insert(PlayerProfile(name: "Kim", avatarSymbol: "bolt", avatarColor: "blue",
                                                      isLocalOwner: true))
        try other.competitiveContext.save()

        let mine = try PersistenceStack(inMemory: true)
        mine.competitiveContext.insert(Fixture.owner())
        try mine.competitiveContext.save()
        try mine.importBackup(other.exportBackup())

        let owners = try mine.competitiveContext.fetch(FetchDescriptor<PlayerProfile>(predicate: #Predicate { $0.isLocalOwner }))
        #expect(owners.map(\.id) == [Fixture.ownerID])
        #expect(try Fixture.count(PlayerProfile.self, mine.competitiveContext) == 2)
    }
}

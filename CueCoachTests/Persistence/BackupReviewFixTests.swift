import Foundation
import SwiftData
import Testing
@testable import CueCoach

/// Regression tests for the supervisor review (atomicity, auto-stamping, orphans, owner flag, manifest).
@MainActor
@Suite struct BackupReviewFixTests {
    struct Injected: Error {}

    private func populated() throws -> PersistenceStack {
        let stack = try PersistenceStack(inMemory: true)
        _ = Fixture.populateCompetitive(stack.competitiveContext)
        _ = Fixture.populateTraining(stack.trainingContext)
        try stack.competitiveContext.save()
        try stack.trainingContext.save()
        return stack
    }

    /// Backup that changes both stores: newer owner name + one extra attempt.
    private func changingBackup(from stack: PersistenceStack) throws -> Data {
        var b = try BackupV1.decode(stack.exportBackup(includeRecognition: true))
        b.competitive.profiles[0].name = "Changed"
        b.competitive.profiles[0].updatedAt = .now.addingTimeInterval(60)
        var extra = b.training.attempts[0]
        extra.id = UUID()
        b.training.attempts.append(extra)
        return try b.encoded()
    }

    // 1. all-or-nothing
    @Test(arguments: [PersistenceStack.StoreKind.competitive, .training])
    func failedSaveLeavesBothStoresUnchanged(failing: PersistenceStack.StoreKind) throws {
        let stack = try populated()
        let before = try stack.exportBackup(includeRecognition: true, exportedAt: Fixture.t0)
        let backup = try changingBackup(from: stack)
        stack.beforeSave = { if $0 == failing { throw Injected() } }
        #expect(throws: Injected.self) { try stack.importBackup(backup) }
        stack.beforeSave = nil
        let after = try stack.exportBackup(includeRecognition: true, exportedAt: Fixture.t0)
        #expect(try BackupV1.decode(after) == BackupV1.decode(before))
        #expect(try Fixture.count(TrainingAttempt.self, stack.trainingContext) == 3)
        let reopened = try stack.competitiveContext.fetch(FetchDescriptor<PlayerProfile>())
        #expect(reopened.map(\.name) == ["Ari"])
    }

    // 2. updatedAt bumps on every field mutation, for every model
    @Test func mutatingAnyModelBumpsUpdatedAt() throws {
        let stack = try populated()
        let c = stack.competitiveContext, t = stack.trainingContext
        let old = Date.distantPast
        func check<M: PersistentModel>(_: M.Type, _ ctx: ModelContext, _ stamp: ReferenceWritableKeyPath<M, Date>,
                                       _ mutate: (M) -> Void) throws {
            let m = try #require(ctx.fetch(FetchDescriptor<M>()).first)
            m[keyPath: stamp] = old
            mutate(m)
            #expect(m[keyPath: stamp] > old, "\(M.self)")
        }
        try check(PlayerProfile.self, c, \.updatedAt) { $0.skillModel.samples += 1 }
        try check(RecognitionData.self, c, \.updatedAt) { $0.version += 1 }
        try check(Session.self, c, \.updatedAt) { $0.endedAt = .now }
        try check(Game.self, c, \.updatedAt) { $0.winnerTeam = 1 }
        try check(Shot.self, c, \.updatedAt) { $0.made = false }
        try check(ArchetypeSnapshot.self, c, \.updatedAt) { $0.tags = ["longGun"] }
        try check(Highlight.self, c, \.updatedAt) { $0.label = "Clutch" }
        try check(TrainingProfile.self, t, \.updatedAt) { $0.playerID = UUID() }
        try check(DrillProgress.self, t, \.updatedAt) { $0.recentResults.append(true) }
        try check(TrainingAttempt.self, t, \.updatedAt) { $0.made = false }
        try check(BiasRecord.self, t, \.updatedAt) { $0.resolvedAt = .now }
    }

    @Test func localEditsAfterExportSurviveImportOfOlderBackup() throws {
        let stack = try populated()
        let backup = try stack.exportBackup(includeRecognition: true)
        let c = stack.competitiveContext, t = stack.trainingContext
        try #require(c.fetch(FetchDescriptor<Highlight>()).first).label = "Clutch"
        try #require(c.fetch(FetchDescriptor<ArchetypeSnapshot>()).first).tags = ["longGun"]
        let newPlayer = UUID()
        try #require(t.fetch(FetchDescriptor<TrainingProfile>()).first).playerID = newPlayer
        for a in try t.fetch(FetchDescriptor<TrainingAttempt>()) { a.made = false }
        try c.save(); try t.save()

        try stack.importBackup(backup)

        #expect(try c.fetch(FetchDescriptor<Highlight>()).first?.label == "Clutch")
        #expect(try c.fetch(FetchDescriptor<ArchetypeSnapshot>()).first?.tags == ["longGun"])
        #expect(try t.fetch(FetchDescriptor<TrainingProfile>()).first?.playerID == newPlayer)
        #expect(try t.fetch(FetchDescriptor<TrainingAttempt>()).allSatisfy { !$0.made })
    }

    // 3. orphans
    @Test(arguments: ["game.session", "shot.game", "highlight.game", "attempt.progress"])
    func unknownParentRejectsWholeBackup(_ edge: String) throws {
        var b = try BackupV1.decode(populated().exportBackup())
        let bogus = UUID()
        switch edge {
        case "game.session": b.competitive.games[0].sessionID = bogus
        case "shot.game": b.competitive.shots[0].gameID = bogus
        case "highlight.game": b.competitive.highlights[0].gameID = bogus
        default: b.training.attempts[0].progressID = bogus
        }
        let fresh = try PersistenceStack(inMemory: true)
        #expect(throws: BackupError.self) { try fresh.importBackup(b.encoded()) }
        do { try fresh.importBackup(b.encoded()) } catch let e as BackupError {
            guard case .missingParent(_, _, let parent) = e else { Issue.record("wrong error \(e)"); return }
            #expect(parent == bogus)
        }
        #expect(try Fixture.count(Shot.self, fresh.competitiveContext) == 0)
        #expect(try Fixture.count(TrainingAttempt.self, fresh.trainingContext) == 0)
        #expect(try Fixture.count(PlayerProfile.self, fresh.competitiveContext) == 0)
    }

    @Test func parentPresentOnlyLocallyIsAccepted() throws {
        let stack = try populated()
        var b = try BackupV1.decode(stack.exportBackup())
        b.competitive.sessions = []
        b.training.drillProgress = []
        var extra = b.training.attempts[0]; extra.id = UUID()
        b.training.attempts.append(extra)
        try stack.importBackup(b.encoded())
        let p = try #require(stack.trainingContext.fetch(FetchDescriptor<DrillProgress>()).first)
        #expect(p.attempts.count == 4)
    }

    // 4. isLocalOwner is device-local
    @Test func importNeverChangesLocalOwnerFlag() throws {
        let stack = try populated()
        var b = try BackupV1.decode(stack.exportBackup())
        b.competitive.profiles[0].isLocalOwner = false
        b.competitive.profiles[0].name = "Renamed"
        b.competitive.profiles[0].updatedAt = .now.addingTimeInterval(60)
        b.competitive.profiles.append(.init(id: UUID(), name: "Kim", avatarSymbol: "bolt", avatarColor: "blue",
                                            isLocalOwner: true, createdAt: Fixture.t0, updatedAt: Fixture.t0,
                                            skillModel: .prior, recognition: nil))
        try stack.importBackup(b.encoded())

        let owners = try stack.competitiveContext.fetch(FetchDescriptor<PlayerProfile>(predicate: #Predicate { $0.isLocalOwner }))
        #expect(owners.map(\.id) == [Fixture.ownerID])
        #expect(owners.first?.name == "Renamed")
        try stack.deleteMyRecognitionData()
        #expect(try Fixture.count(RecognitionData.self, stack.competitiveContext) == 0)
    }

    @Test func freshPhoneRestoreKeepsOwner() throws {
        let fresh = try PersistenceStack(inMemory: true)
        try fresh.importBackup(populated().exportBackup(includeRecognition: true))
        let owners = try fresh.competitiveContext.fetch(FetchDescriptor<PlayerProfile>(predicate: #Predicate { $0.isLocalOwner }))
        #expect(owners.map(\.id) == [Fixture.ownerID])
        try fresh.deleteMyRecognitionData()
        #expect(try Fixture.count(RecognitionData.self, fresh.competitiveContext) == 0)
    }

    // 5. manifest governs recognition
    @Test func recognitionIgnoredWhenManifestSaysExcluded() throws {
        var b = try BackupV1.decode(populated().exportBackup(includeRecognition: true))
        b.includesRecognition = false
        let fresh = try PersistenceStack(inMemory: true)
        try fresh.importBackup(b.encoded())
        #expect(try Fixture.count(PlayerProfile.self, fresh.competitiveContext) == 1)
        #expect(try Fixture.count(RecognitionData.self, fresh.competitiveContext) == 0)
    }
}

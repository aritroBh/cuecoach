import Foundation
import SwiftData
import Testing
@testable import CueCoach

/// Supervisor round 2: non-destructive compensation, relationship edits bump updatedAt, versioned schemas.
@MainActor
@Suite struct ReviewRound2Tests {
    struct Injected: Error {}

    private func populated() throws -> PersistenceStack {
        let stack = try PersistenceStack(inMemory: true)
        _ = Fixture.populateCompetitive(stack.competitiveContext)
        _ = Fixture.populateTraining(stack.trainingContext)
        try stack.competitiveContext.save()
        try stack.trainingContext.save()
        return stack
    }

    private func trainingIDs(_ s: PersistenceStack) throws -> Set<UUID> {
        let t = s.trainingContext
        return Set(try t.fetch(FetchDescriptor<TrainingAttempt>()).map(\.id))
            .union(try t.fetch(FetchDescriptor<DrillProgress>()).map(\.id))
            .union(try t.fetch(FetchDescriptor<TrainingProfile>()).map(\.id))
            .union(try t.fetch(FetchDescriptor<BiasRecord>()).map(\.id))
    }

    /// Updates existing training rows (incl. re-parenting an attempt onto a NEW drill) and inserts new ones,
    /// plus a competitive change so the competitive save has work to fail on.
    private func heavyBackup(_ stack: PersistenceStack) throws -> Data {
        var b = try BackupV1.decode(stack.exportBackup())
        let later = Date.now.addingTimeInterval(120)
        let newDrill = UUID()
        b.training.drillProgress[0].level = 4
        b.training.drillProgress[0].updatedAt = later
        b.training.drillProgress.append(.init(id: newDrill, playerID: Fixture.ownerID, drill: "banks", level: 1,
                                              recentResults: [], levelHistory: [], updatedAt: later))
        b.training.attempts[0].made = false
        b.training.attempts[0].progressID = newDrill
        b.training.attempts[0].updatedAt = later
        var extra = b.training.attempts[1]; extra.id = UUID(); extra.updatedAt = later
        b.training.attempts.append(extra)
        b.training.profiles[0].playerID = UUID()
        b.training.profiles[0].updatedAt = later
        b.competitive.profiles[0].name = "Changed"
        b.competitive.profiles[0].updatedAt = later
        return try b.encoded()
    }

    // A. compensation restores exactly the pre-import training state, without deleting pre-existing rows
    @Test func competitiveFailureCompensatesTrainingExactly() throws {
        let stack = try populated()
        let before = try BackupV1.decode(stack.exportBackup(exportedAt: Fixture.t0))
        let backup = try heavyBackup(stack)
        stack.beforeSave = { if $0 == .competitive { throw Injected() } }
        #expect(throws: Injected.self) { try stack.importBackup(backup) }
        stack.beforeSave = nil
        let after = try BackupV1.decode(stack.exportBackup(exportedAt: Fixture.t0))
        #expect(after == before)
        let p = try #require(stack.trainingContext.fetch(FetchDescriptor<DrillProgress>()).first)
        #expect(p.attempts.count == 3)
    }

    @Test func failureDuringCompensationKeepsPreExistingRows() throws {
        let stack = try populated()
        let preIDs = try trainingIDs(stack)
        let backup = try heavyBackup(stack)
        stack.beforeSave = { kind in
            if kind == .competitive || kind == .trainingCompensation { throw Injected() }
        }
        #expect(throws: (any Error).self) { try stack.importBackup(backup) }
        stack.beforeSave = nil
        #expect(try trainingIDs(stack).isSuperset(of: preIDs))
        #expect(try Fixture.count(TrainingAttempt.self, stack.trainingContext) >= 3)
    }

    // B. relationship edits bump updatedAt
    @Test func relationshipEditsBumpUpdatedAt() throws {
        let stack = try populated()
        let c = stack.competitiveContext, t = stack.trainingContext
        let old = Date.distantPast
        func check<M: PersistentModel>(_ label: String, _ m: M, _ stamp: ReferenceWritableKeyPath<M, Date>,
                                       _ mutate: (M) -> Void) {
            m[keyPath: stamp] = old
            mutate(m)
            #expect(m[keyPath: stamp] > old, "\(label)")
        }
        let session2 = Session(startedAt: .now, ruleSet: .barEight, format: .oneVsOne, tableSize: .sevenFoot)
        c.insert(session2)
        let game = try #require(c.fetch(FetchDescriptor<Game>()).first)
        let game2 = Game(index: 1, ruleSet: .barEight, teams: [], startedAt: .now)
        c.insert(game2)
        let shot = try #require(c.fetch(FetchDescriptor<Shot>()).first)
        let highlight = try #require(c.fetch(FetchDescriptor<Highlight>()).first)
        let owner = try #require(c.fetch(FetchDescriptor<PlayerProfile>()).first)
        let rec = try #require(c.fetch(FetchDescriptor<RecognitionData>()).first)
        let attempt = try #require(t.fetch(FetchDescriptor<TrainingAttempt>()).first)
        let drill2 = DrillProgress(playerID: Fixture.ownerID, drill: "banks", level: 1)
        t.insert(drill2)

        check("Game.session", game, \.updatedAt) { $0.session = session2 }
        check("Shot.game", shot, \.updatedAt) { $0.game = game2 }
        check("Highlight.game", highlight, \.updatedAt) { $0.game = game2 }
        check("TrainingAttempt.progress", attempt, \.updatedAt) { $0.progress = drill2 }
        check("RecognitionData.profile", rec, \.updatedAt) { $0.profile = nil }
        check("PlayerProfile.recognition", owner, \.updatedAt) { $0.recognition = nil }
        check("Session.games", session2, \.updatedAt) { $0.games.append(game2) }
        check("Game.shots", game, \.updatedAt) { $0.shots.append(shot) }
        check("Game.highlights", game, \.updatedAt) { $0.highlights.append(highlight) }
        check("DrillProgress.attempts", drill2, \.updatedAt) { $0.attempts.append(attempt) }
    }

    @Test func localReparentAfterExportSurvivesOlderImport() throws {
        let stack = try populated()
        let backup = try stack.exportBackup()
        let c = stack.competitiveContext
        let game2 = Game(index: 1, ruleSet: .barEight, teams: [], startedAt: .now)
        c.insert(game2)
        let shot = try #require(c.fetch(FetchDescriptor<Shot>()).first)
        shot.game = game2
        try c.save()
        try stack.importBackup(backup)
        #expect(shot.game?.id == game2.id)
    }

    @Test func importDoesNotRestampProfileWhenLinkingRecognition() throws {
        let original = try populated()
        let data = try original.exportBackup(exportedAt: Fixture.t0)
        let fresh = try PersistenceStack(inMemory: true)
        try fresh.importBackup(data)
        #expect(try BackupV1.decode(fresh.exportBackup(exportedAt: Fixture.t0))
                == BackupV1.decode(data))
    }

    // Versioned schemas
    @Test func eachStoreHasAVersionedSchemaAndMigrationPlan() throws {
        #expect(CompetitiveSchemaV1.versionIdentifier == Schema.Version(1, 0, 0))
        #expect(TrainingSchemaV1.versionIdentifier == Schema.Version(1, 0, 0))
        #expect(Set(CompetitiveSchemaV1.models.map { "\($0)" }) == Set(PersistenceStack.competitiveModels.map { "\($0)" }))
        #expect(Set(TrainingSchemaV1.models.map { "\($0)" }) == Set(PersistenceStack.trainingModels.map { "\($0)" }))
        #expect(CompetitiveMigrationPlan.schemas.count == 1)
        #expect(TrainingMigrationPlan.schemas.count == 1)
        let stack = try PersistenceStack(inMemory: true)
        #expect(stack.competitiveContainer.schema.version == Schema.Version(1, 0, 0))
        #expect(stack.trainingContainer.schema.version == Schema.Version(1, 0, 0))
        #expect(stack.competitiveContainer.migrationPlan != nil)
        #expect(stack.trainingContainer.migrationPlan != nil)
    }
}

import Foundation
import SwiftData
import Testing
import Geometry
import Rules
import Engine
@testable import CueCoach

@MainActor
@Suite struct CompetitiveStoreTests {
    @Test func createAndFetchEveryCompetitiveModel() throws {
        let stack = try PersistenceStack(inMemory: true)
        let ctx = stack.competitiveContext
        _ = Fixture.populateCompetitive(ctx)
        try ctx.save()

        let profile = try #require(ctx.fetch(FetchDescriptor<PlayerProfile>()).first)
        #expect(profile.id == Fixture.ownerID)
        #expect(profile.isLocalOwner)
        #expect(profile.skillModel.samples == 12)
        try Fixture.addOwnerRecognition(stack)
        #expect(try stack.recognition(for: profile.id)?.faceEmbedding == Data([1, 2, 3]))

        let session = try #require(ctx.fetch(FetchDescriptor<Session>()).first)
        #expect(session.ruleSet == .wpaNine)
        #expect(session.format == .oneVsOne)
        #expect(session.tableSize == .eightFoot)
        #expect(session.voteTally[.wpaNine] == 2)
        #expect(session.games.count == 1)

        let game = try #require(session.games.first)
        #expect(game.teams.count == 2)
        #expect(game.winProbSeries == [0.5, 0.62])
        #expect(game.shots.count == 2)
        #expect(game.highlights.count == 1)

        let shot = try #require(game.shots.first { $0.index == 0 })
        #expect(shot.preState == Fixture.table())
        #expect(shot.pocketed == [.eight: .footLeft])
        #expect(shot.fouls == [.wrongBallFirst(BallID(2)!)])
        #expect(shot.features.kind == .bank)
        #expect(shot.executionRating == ExecutionRating(result: .made, position: .inZone))
        #expect(shot.calledPocket == .footLeft)
        #expect(shot.firstContact == .eight)
        #expect(shot.game?.id == game.id)

        let arch = try #require(ctx.fetch(FetchDescriptor<ArchetypeSnapshot>()).first)
        #expect(arch.vector["cut"] == 1.2)
        #expect(arch.proComp?.proID == "efren")
        #expect(try Fixture.count(Highlight.self, ctx) == 1)
    }

    @Test func deletingSessionCascadesToGamesShotsAndHighlights() throws {
        let stack = try PersistenceStack(inMemory: true)
        let ctx = stack.competitiveContext
        let session = Fixture.populateCompetitive(ctx)
        try ctx.save()
        ctx.delete(session)
        try ctx.save()
        #expect(try Fixture.count(Game.self, ctx) == 0)
        #expect(try Fixture.count(Shot.self, ctx) == 0)
        #expect(try Fixture.count(Highlight.self, ctx) == 0)
        #expect(try Fixture.count(PlayerProfile.self, ctx) == 1)
    }

    @Test func deletingProfileRemovesItsRecognitionData() throws {
        let stack = try PersistenceStack(inMemory: true)
        let ctx = stack.competitiveContext
        _ = Fixture.populateCompetitive(ctx)
        try ctx.save()
        try Fixture.addOwnerRecognition(stack)
        let profile = try #require(ctx.fetch(FetchDescriptor<PlayerProfile>()).first)
        try stack.deleteProfile(profile)
        #expect(try Fixture.count(RecognitionData.self, stack.recognitionContext) == 0)
    }
}

@MainActor
@Suite struct TrainingStoreTests {
    @Test func createAndFetchEveryTrainingModel() throws {
        let stack = try PersistenceStack(inMemory: true)
        let ctx = stack.trainingContext
        _ = Fixture.populateTraining(ctx)
        try ctx.save()

        let tp = try #require(ctx.fetch(FetchDescriptor<TrainingProfile>()).first)
        #expect(tp.playerID == Fixture.ownerID)
        let p = try #require(ctx.fetch(FetchDescriptor<DrillProgress>()).first)
        #expect(p.level == 2)
        #expect(p.recentResults == [true, false, true])
        #expect(p.levelHistory == [LevelChange(at: Fixture.t0, from: 1, to: 2)])
        #expect(p.attempts.count == 3)
        let a = try #require(p.attempts.first)
        #expect(a.setup == Fixture.table())
        #expect(a.features.signedCutError == -0.02)
        #expect(a.progress?.id == p.id)
        let b = try #require(ctx.fetch(FetchDescriptor<BiasRecord>()).first)
        #expect(b.axis == .cut)
        #expect(b.resolvedAt == nil)
    }

    @Test func drillLevelIsClampedToOneThroughFour() {
        #expect(DrillProgress(playerID: UUID(), drill: "x", level: 9).level == 4)
        #expect(DrillProgress(playerID: UUID(), drill: "x", level: 0).level == 1)
    }

    @Test func deletingDrillProgressCascadesToAttempts() throws {
        let stack = try PersistenceStack(inMemory: true)
        let ctx = stack.trainingContext
        let p = Fixture.populateTraining(ctx)
        try ctx.save()
        ctx.delete(p)
        try ctx.save()
        #expect(try Fixture.count(TrainingAttempt.self, ctx) == 0)
    }
}

@MainActor
@Suite struct PersistenceStackTests {
    @Test func onDiskStackUsesSeparateStoreFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let stack = try PersistenceStack(directory: dir)
        #expect(stack.competitiveContainer.configurations.first?.url.lastPathComponent == "Competitive.store")
        #expect(stack.trainingContainer.configurations.first?.url.lastPathComponent == "Training.store")
        _ = Fixture.populateCompetitive(stack.competitiveContext)
        _ = Fixture.populateTraining(stack.trainingContext)
        try stack.competitiveContext.save()
        try stack.trainingContext.save()
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Competitive.store").path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Training.store").path))
    }

    @Test func onDiskDataSurvivesReopen() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            let stack = try PersistenceStack(directory: dir)
            _ = Fixture.populateTraining(stack.trainingContext)
            try stack.trainingContext.save()
        }
        let reopened = try PersistenceStack(directory: dir)
        #expect(try Fixture.count(TrainingAttempt.self, reopened.trainingContext) == 3)
        #expect(try Fixture.count(Shot.self, reopened.competitiveContext) == 0)
    }
}

import Foundation
import SwiftData
import Geometry
import Training
import Testing
@testable import CueCoach

@MainActor
@Suite(.serialized) struct TrainingSessionControllerTests {
    @Test func setupGhostsTurnReadyWhenDetectedBallsMatchWithinTolerance() throws {
        let stack = try PersistenceStack(inMemory: true)
        let playerID = UUID()
        let controller = TrainingSessionController(drill: .straightIn, initialLevel: .full,
                                                   tableSize: .sevenFoot, playerID: playerID, stack: stack)
        #expect(controller.ghostTargets.count == 2)
        #expect(!controller.isSetupReady)

        // Place detected balls far away → still false.
        controller.updateDetectedBalls([Vec2(0.05, 0.05)])
        #expect(!controller.isSetupReady)

        // Place detected balls within tolerance of each ghost → ready!
        let slightlyShifted = controller.ghostTargets.map { $0 + Vec2(0.02, -0.01) }
        controller.updateDetectedBalls(slightlyShifted)
        #expect(controller.matchedGhosts == [true, true])
        #expect(controller.isSetupReady)
    }

    @Test func rollingMakesPromoteAssistLevelAndPersistStrictlyToTrainingStore() throws {
        let stack = try PersistenceStack(inMemory: true)
        let suiteName = "cc.test.training.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let playerID = UUID()
        let controller = TrainingSessionController(drill: .increasingCuts, initialLevel: .full,
                                                   tableSize: .sevenFoot, playerID: playerID,
                                                   stack: stack, defaults: defaults)
        // 8 makes + 2 misses in 10 attempts = 80 % → promotes from Level 1 (.full) to Level 2 (.objectLineOnly)!
        for i in 0..<10 {
            controller.recordAttempt(SettledTrainingShot(made: i < 8))
        }
        #expect(controller.level == .objectLineOnly)
        #expect(controller.lastLevelChange == .promoted(to: .objectLineOnly))
        #expect(defaults.integer(forKey: TrainingPickerModel.levelKey) == AssistLevel.objectLineOnly.rawValue)

        // Verify Training.store rows and strict Competitive.store isolation.
        let progressRows = try stack.trainingContext.fetch(FetchDescriptor<DrillProgress>())
        let attemptRows = try stack.trainingContext.fetch(FetchDescriptor<TrainingAttempt>())
        #expect(progressRows.count == 1)
        #expect(progressRows.first?.level == AssistLevel.objectLineOnly.rawValue)
        #expect(progressRows.first?.levelHistory.count == 1)
        #expect(attemptRows.count == 10)
        #expect(try stack.competitiveContext.fetch(FetchDescriptor<Game>()).isEmpty,
                "Training attempts must NEVER write to Competitive.store")
        #expect(try stack.competitiveContext.fetch(FetchDescriptor<Shot>()).isEmpty)
    }

    @Test func consistentSameSignErrorSurfacesNonNumericVisualFeedbackAndPersistsBiasRecord() throws {
        let stack = try PersistenceStack(inMemory: true)
        let playerID = UUID()
        let controller = TrainingSessionController(drill: .increasingCuts, initialLevel: .full,
                                                   tableSize: .sevenFoot, playerID: playerID, stack: stack)
        // Feed 12 consistent positive overcut errors (+0.12 rad ≈ 7°, well above 0.035 typicalNoise).
        for _ in 0..<12 {
            controller.recordAttempt(SettledTrainingShot(
                made: false,
                explicitErrors: [.cut: 0.12]))
        }
        let fb = try #require(controller.activeFeedback)
        #expect(fb.correction == .hitThicker)
        #expect(fb.label == "Hit thicker")
        #expect(!fb.label.contains(where: \.isNumber))

        let biases = try stack.trainingContext.fetch(FetchDescriptor<BiasRecord>())
        #expect(biases.count == 1)
        #expect(biases.first?.axis == .cut)
        #expect(biases.first?.sign == 1)
        #expect(biases.first?.resolvedAt == nil)

        // Dismissing clears activeFeedback and marks the BiasRecord resolved.
        controller.dismissFeedback()
        #expect(controller.activeFeedback == nil)
        #expect(try stack.trainingContext.fetch(FetchDescriptor<BiasRecord>()).first?.resolvedAt != nil)
    }
}

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
        let compGames = try stack.competitiveContext.fetch(FetchDescriptor<Game>())
        let compShots = try stack.competitiveContext.fetch(FetchDescriptor<Shot>())
        #expect(compGames.isEmpty, "Training attempts must NEVER write to Competitive.store")
        #expect(compShots.isEmpty)
    }

    @Test func consistentSameSignErrorSurfacesNonNumericVisualFeedbackAndPersistsBiasRecord() throws {
        let stack = try PersistenceStack(inMemory: true)
        let playerID = UUID()
        let controller = TrainingSessionController(drill: .increasingCuts, initialLevel: .full,
                                                   tableSize: .sevenFoot, playerID: playerID, stack: stack)
        // Feed 15 consistent positive overcut errors (+0.12 rad ≈ 7°, well above 0.035 typicalNoise; 15 × ln(1.5) ≈ 6.08 ≥ 5.5 CUSUM threshold).
        for _ in 0..<15 {
            controller.recordAttempt(SettledTrainingShot(
                made: false,
                explicitErrors: [.cut: 0.12]))
        }
        let fb = try #require(controller.activeFeedback)
        #expect(fb.correction == .hitThicker)
        #expect(fb.label == "Hit thicker")
        #expect(fb.label.allSatisfy { !$0.isNumber })

        let biases = try stack.trainingContext.fetch(FetchDescriptor<BiasRecord>())
        #expect(biases.count == 1)
        #expect(biases.first?.axis == .cut)
        #expect(biases.first?.sign == 1)
        #expect(biases.first?.resolvedAt == nil)

        // Dismissing clears activeFeedback and marks the BiasRecord resolved.
        controller.dismissFeedback()
        #expect(controller.activeFeedback == nil)
        let resolvedBiases = try stack.trainingContext.fetch(FetchDescriptor<BiasRecord>())
        #expect(resolvedBiases.first?.resolvedAt != nil)
    }

    @Test func nilPlayerIDResolvesStableFallbackPersistsAcrossReloadAndSyncsLiveModelMode() throws {
        let stack = try PersistenceStack(inMemory: true)
        let suiteName = "cc.test.training.fallback.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(TrainingSessionController.defaultPocket(for: .rail) == .footLeft)
        #expect(TrainingSessionController.defaultPocket(for: .sidePocket) == .sideLeft)

        let c1 = TrainingSessionController(drill: .rail, initialLevel: .full,
                                           tableSize: .sevenFoot, playerID: nil,
                                           stack: stack, defaults: defaults)
        let liveModel = LiveModel(mode: .training(level: c1.level.rawValue))
        #expect(liveModel.visibility.line2)
        #expect(liveModel.visibility.line1)

        for i in 0..<10 {
            c1.recordAttempt(SettledTrainingShot(made: i < 8))
        }
        #expect(c1.level == .objectLineOnly)
        liveModel.mode = .training(level: c1.level.rawValue)
        #expect(liveModel.visibility.line2)
        #expect(!liveModel.visibility.line1, "Level 2 hides cue-to-ghost path live in-session")

        // Reloading with `playerID: nil` right after promotion recovers the exact same fallback UUID and Level 2!
        let c2 = TrainingSessionController(drill: .rail, initialLevel: .full,
                                           tableSize: .sevenFoot, playerID: nil,
                                           stack: stack, defaults: defaults)
        #expect(c2.playerID == c1.playerID)
        #expect(c2.level == .objectLineOnly)

        // Subsequent consistent overcuts on the reloaded controller surface feedback and resolve BiasRecord on dismiss.
        for _ in 0..<15 {
            c2.recordAttempt(SettledTrainingShot(made: false, explicitErrors: [.cut: 0.12]))
        }
        #expect(c2.activeFeedback != nil)
        c2.dismissFeedback()
        let biases = try stack.trainingContext.fetch(FetchDescriptor<BiasRecord>())
        #expect(biases.first?.resolvedAt != nil)
    }

    @Test func madeShotsWithNaturalCueBallTangentDeflectionNeverTriggerFalseBias() throws {
        let stack = try PersistenceStack(inMemory: true)
        let controller = TrainingSessionController(drill: .increasingCuts, initialLevel: .full,
                                                   tableSize: .sevenFoot, playerID: UUID(), stack: stack)
        let one = BallID(1)!
        // Simulate 20 successful cut pots where the cue ball deflects ~65° along the tangent line after contact.
        for _ in 0..<20 {
            controller.recordAttempt(SettledTrainingShot(
                made: true,
                before: [.cue: Vec2(0.6, 0.55), one: Vec2(1.4, 0.35)],
                after: [.cue: Vec2(1.55, 0.85)],
                targetPocket: .footRight))
        }
        #expect(controller.activeFeedback == nil, "Natural cue-ball collision deflection on made pots is never flagged as bias")
        let biases = try stack.trainingContext.fetch(FetchDescriptor<BiasRecord>())
        #expect(biases.isEmpty)
    }

    @Test func positionPlaySameRadiusMissAndSpinControlOvershootSurfaceFeedback() throws {
        let stack = try PersistenceStack(inMemory: true)
        let one = BallID(1)!

        // 1. Position play: cue ball lands on the SAME-RADIUS circle around `cueBefore` as `positionZoneCenter`,
        //    but 0.55 m laterally away from the zone → error must NOT be zero!
        let posController = TrainingSessionController(drill: .positionPlay, initialLevel: .full,
                                                      tableSize: .sevenFoot, playerID: UUID(), stack: stack)
        let zone = try #require(posController.positionZoneCenter)
        let cueStart = Vec2(0.30, 0.30)
        let radius = cueStart.distance(to: zone)
        // Rotate `zone - cueStart` by 60° so `|sameRadiusMiss - cueStart| == |zone - cueStart|` while `|sameRadiusMiss - zone| == radius`!
        let d = zone - cueStart
        let cos60 = 0.5, sin60 = 0.8660254037844386
        let rotated = Vec2(d.x * cos60 - d.y * sin60, d.x * sin60 + d.y * cos60)
        let sameRadiusMiss = cueStart + rotated
        #expect(abs(sameRadiusMiss.distance(to: cueStart) - radius) < 1e-6)
        #expect(sameRadiusMiss.distance(to: zone) > 0.35)

        for _ in 0..<15 {
            posController.recordAttempt(SettledTrainingShot(
                made: true,
                before: [.cue: cueStart, one: Vec2(1.2, 0.65)],
                after: [.cue: sameRadiusMiss],
                targetPocket: .footRight))
        }
        #expect(posController.activeFeedback != nil, "Off-axis miss on same-radius circle around cueStart is detected")

        // 2. Spin control (no positionZone): consistent stop-shot overshoots past the ghost contact point surface feedback!
        let spinController = TrainingSessionController(drill: .spinControl, initialLevel: .full,
                                                       tableSize: .sevenFoot, playerID: UUID(), stack: stack)
        for _ in 0..<15 {
            spinController.recordAttempt(SettledTrainingShot(
                made: true,
                before: [.cue: Vec2(0.60, 0.50), one: Vec2(1.15, 0.50)],
                after: [.cue: Vec2(1.75, 0.50)],
                targetPocket: .footRight))
        }
        #expect(spinController.activeFeedback != nil, "Spin Control drill surfaces speed/distance feedback on consistent overshoot")

        // 3. Spin control excess draw (drawing backward behind the stop target) never falsely advises "More spin"!
        let drawController = TrainingSessionController(drill: .spinControl, initialLevel: .full,
                                                       tableSize: .sevenFoot, playerID: UUID(), stack: stack)
        for _ in 0..<15 {
            drawController.recordAttempt(SettledTrainingShot(
                made: true,
                before: [.cue: Vec2(0.60, 0.50), one: Vec2(1.15, 0.50)],
                after: [.cue: Vec2(0.25, 0.50)],
                targetPocket: .footRight))
        }
        #expect(drawController.activeFeedback != nil)
        #expect(drawController.activeFeedback?.correction != .moreSpin,
                "Drawing back behind the stop target must never advise More spin")
    }

    @Test("Banks drill never measures false side error against direct pocket from cushion departure")
    func bankDrillNeverMeasuresDirectPocketSideErrorFromCushionDeparture() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("TrainTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let stack = try PersistenceStack(directory: dir)
        let one = try #require(BallID(1))
        let bankController = TrainingSessionController(drill: .banks, initialLevel: .full,
                                                       tableSize: .sevenFoot, playerID: UUID(), stack: stack)
        for _ in 0..<15 {
            bankController.recordAttempt(SettledTrainingShot(
                made: false,
                before: [.cue: Vec2(0.80, 0.30), one: Vec2(1.05, 0.72)],
                after: [.cue: Vec2(0.95, 0.55), one: Vec2(1.10, 0.20)],
                targetPocket: .headRight,
                objectDepartureDir: Vec2(0.15, 0.99),
                objectHitRail: true))
        }
        #expect(bankController.activeFeedback == nil,
                "Cushion-directed bank departure must never be compared against direct un-mirrored pocket direction")
    }
}

import Foundation
import Geometry
import Testing
@testable import Training

/// Regression tests for the supervisor's review findings (round 1).
@Suite("Training review fixes")
struct ReviewFixTests {
    // MARK: MAJOR 1 — precise (dead-zone) attempts are evidence the habit is gone

    @Test func preciseAttemptsClearAnActiveBias() {
        var d = BiasDetector()
        for _ in 0..<40 { d.observe(.cut, error: 1) }
        #expect(!d.activeBiases().isEmpty)
        for _ in 0..<20 { d.observe(.cut, error: 0.1) }        // inside the dead zone: on target
        #expect(d.activeBiases().isEmpty)
    }
    @Test func preciseAttemptsAloneStillNeverFire() {
        var d = BiasDetector()
        for _ in 0..<500 { d.observe(.cut, error: 0.1) }
        #expect(d.activeBiases().isEmpty)
        #expect(d.statistic(.cut, .positive) == 0)
    }
    @Test func coachMovesOnAfterPlayerFixesHabitByHittingPrecisely() {
        // Supervisor probe: stale "Hit thicker" blocked a real speed bias forever.
        var c = FeedbackCoach(drill: .increasingCuts, config: .standard)
        for _ in 0..<40 { c.record([.cut: 1]) }
        #expect(c.current?.correction == .hitThicker)
        for _ in 0..<60 { c.record([.cut: 0.1, .speed: 2]) }
        #expect(c.current?.correction == .softer)
    }

    // MARK: MAJOR 2 — meanError never contradicts the reported direction

    @Test func meanErrorSignMatchesDirectionDespiteOpposingOutliers() {
        var d = BiasDetector()
        for _ in 0..<25 { d.observe(.cut, error: 0.3) }
        for _ in 0..<4 { d.observe(.cut, error: -10) }
        for b in d.activeBiases() {
            #expect((b.meanError > 0) == (b.key.direction == .positive), "\(b)")
            #expect(BiasStrength(meanError: b.meanError, deadZone: 0.25) == .slight)
        }
    }
    @Test func meanErrorSignMatchesDirectionUnderHeavyTails() {
        for s in 0..<300 {
            var rng = SplitMix64(seed: UInt64(s) &+ 9_000_000)
            var d = BiasDetector()
            for _ in 0..<80 {
                for a in BiasAxis.allCases { d.observe(a, error: rng.heavyTailed() + (a == .speed ? 1 : 0)) }
                for b in d.activeBiases() {
                    #expect((b.meanError > 0) == (b.key.direction == .positive), "seed \(s) \(b)")
                }
            }
        }
    }

    // MARK: MAJOR 3 — per-axis units and dead zones

    @Test func everyAxisDeclaresAUnitAndTypicalNoise() {
        for a in BiasAxis.allCases {
            #expect(!a.unit.isEmpty)
            #expect(a.typicalNoise > 0 && a.typicalNoise.isFinite)
        }
        #expect(BiasAxis.cut.unit == "rad")
        #expect(BiasAxis.cueBallDistance.unit == "m")
    }
    @Test func calibratedConfigsScaleTheDeadZonePerAxis() {
        let c = BiasDetector.Config.calibrated
        #expect(Set(c.keys) == Set(BiasAxis.allCases))
        for a in BiasAxis.allCases {
            #expect(abs(c[a]!.deadZone - BiasDetector.Config.standard.deadZone * a.typicalNoise) < 1e-12)
        }
    }
    @Test func detectorUsesEachAxisOwnDeadZone() {
        var cfg = BiasDetector.Config.calibrated
        cfg[.cut] = .standard.scaled(by: 0.01)       // tiny dead zone
        cfg[.speed] = .standard.scaled(by: 100)      // huge dead zone
        var d = BiasDetector(configs: cfg)
        for _ in 0..<40 { d.observe(.cut, error: 0.05); d.observe(.speed, error: 0.05) }
        #expect(d.activeBiases().map(\.key) == [BiasKey(axis: .cut, direction: .positive)])
        #expect(d.config(for: .speed).deadZone == 25)
    }
    @Test func coachFiresOnConsistentLongCueBallInMetres() {
        var c = FeedbackCoach(drill: .positionPlay)
        for _ in 0..<40 { c.record([.cueBallDistance: 0.20]) }
        #expect(c.current?.correction == .shorter)
    }
    @Test func coachFiresOnAFewDegreesOfOvercut() {
        var c = FeedbackCoach(drill: .increasingCuts)
        for _ in 0..<40 { c.record([.cut: 3 * Double.pi / 180]) }
        #expect(c.current?.correction == .hitThicker)
    }
    @Test func coachStrengthUsesTheAxisDeadZone() {
        var c = FeedbackCoach(drill: .positionPlay)
        for _ in 0..<40 { c.record([.cueBallDistance: 0.1]) }    // 1–2 dead zones of cue-ball distance
        #expect(c.current?.strength == .slight)
    }
    @Test func coachQuietOnUnbiasedNoiseInRealUnits() {
        var fired = 0, sessions = 0
        for drill in DrillID.allCases {
            for s in 0..<200 {
                var rng = SplitMix64(seed: UInt64(s) &+ 88_000)
                var c = FeedbackCoach(drill: drill); sessions += 1
                var any = false
                for _ in 0..<50 {
                    var obs: [BiasAxis: Double] = [:]
                    for a in BiasAxis.allCases { obs[a] = rng.gaussian() * a.typicalNoise }
                    c.record(obs)
                    if c.current != nil { any = true }
                }
                if any { fired += 1 }
            }
        }
        #expect(Double(fired) / Double(sessions) <= 0.03)
    }
    @Test func perAxisDetectorRoundTripsThroughCodable() throws {
        var d = BiasDetector(configs: BiasDetector.Config.calibrated)
        for _ in 0..<20 { d.observe(.cut, error: 0.1) }
        let back = try JSONDecoder().decode(BiasDetector.self, from: JSONEncoder().encode(d))
        #expect(back == d)
    }

    // MARK: MINOR — SetupMatcher contested ball goes to the nearer ghost, whatever the order

    @Test func contestedBallGoesToNearerGhostRegardlessOfOrder() {
        let a = Vec2(0, 0), b = Vec2(0.012, 0), ball = [Vec2(0.004, 0)]
        #expect(SetupMatcher.match(ghosts: [a, b], detected: ball, tolerance: 0.02) == [true, false])
        #expect(SetupMatcher.match(ghosts: [b, a], detected: ball, tolerance: 0.02) == [false, true])
    }

    // MARK: MINOR — Codable decoding validates like the initialisers

    @Test func levelPolicyDecodingRejectsInvalidSettings() {
        for json in [#"{"window":0,"promoteAt":0.8,"demoteAt":0.4}"#,
                     #"{"window":10,"promoteAt":0.2,"demoteAt":0.9}"#,
                     #"{"window":10,"promoteAt":1.5,"demoteAt":0.4}"#] {
            #expect(throws: DecodingError.self) { try JSONDecoder().decode(LevelPolicy.self, from: Data(json.utf8)) }
        }
        let ok = try? JSONDecoder().decode(LevelPolicy.self, from: JSONEncoder().encode(LevelPolicy.standard))
        #expect(ok == .standard)
    }
    @Test func biasConfigDecodingRejectsInvalidSettings() {
        for json in [#"{"deadZone":0.25,"alternativeP":0.5,"threshold":7,"cap":10.5,"minimumAttempts":8}"#,
                     #"{"deadZone":-1,"alternativeP":0.75,"threshold":7,"cap":10.5,"minimumAttempts":8}"#,
                     #"{"deadZone":0.25,"alternativeP":0.75,"threshold":7,"cap":3,"minimumAttempts":8}"#,
                     #"{"deadZone":0.25,"alternativeP":0.75,"threshold":7,"cap":10.5,"minimumAttempts":0}"#] {
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(BiasDetector.Config.self, from: Data(json.utf8))
            }
        }
        let ok = try? JSONDecoder().decode(BiasDetector.Config.self,
                                           from: JSONEncoder().encode(BiasDetector.Config.standard))
        #expect(ok == .standard)
    }
}

import Foundation
import Geometry
import simd
import Testing
@testable import CueCoach

struct CornerValidatorTests {
    let truth = SyntheticRig.frame(.eightFoot)
    var world: [SIMD3<Double>] { truth.corners.map { truth.world($0) } }

    @Test func goodCornersInAnyOrderPass() {
        let w = world
        guard case .ok(let fit)? = CornerValidator.check([w[2], w[0], w[3], w[1]]) else {
            Issue.record("expected ok"); return
        }
        #expect(fit.sizing.size == .eightFoot)
    }

    @Test func oneBadCornerIsNamedNotWiped() throws {
        for bad in 0..<4 {
            var w = world
            w[bad] += SIMD3(0.45, 0, -0.3)   // tapped a diamond instead of the pocket
            guard case .outlier(let i, let suggested)? = CornerValidator.check(w) else {
                Issue.record("corner \(bad): expected outlier"); continue
            }
            #expect(i == bad, "flagged \(i), bad was \(bad)")
            #expect(simd_distance(suggested, world[bad]) < 0.02)
        }
    }

    @Test func smallTapNoiseStillPasses() {
        var rng = SplitMix(seed: 9)
        let w = world.map { $0 + SIMD3(rng.gauss() * 0.015, 0, rng.gauss() * 0.015) }
        guard case .ok? = CornerValidator.check(w) else { Issue.record("noise should pass"); return }
    }

    @Test func tooSmallATableIsRejected() {
        let w = world.map { truth.world(Vec2(0, 0)) + ($0 - truth.world(Vec2(0, 0))) * 0.3 }
        guard case .outlier? = CornerValidator.check(w) else { Issue.record("tiny quad must not pass"); return }
    }
}

import Foundation
import Geometry
import simd
import Testing
@testable import CueCoach

/// Lock-plan step 2 (scratchpad reviews/lock-plan.md): adaptive fusion lock.
@Suite("AutoTableLocator — lock speed")
struct AutoTableLockSpeedTests {

    static func jittered(_ i: Int, _ d: Double) -> AutoTableMeasurement {
        // Centres on a circle of radius d around the truth: every frame's corners are d from the fused ones.
        let a = Double(i) * 2.399963
        return AutoTableMeasurement(center: SIMD3(d * cos(a), 0.79, d * sin(a)), axis: SIMD3(1, 0, 0), up: SIMD3(0, 1, 0),
                                    measuredLength: TableSize.nineFoot.playingLength,
                                    measuredWidth: TableSize.nineFoot.playingLength / 2, snapped: .nineFoot,
                                    cameraPosition: SIMD3(0, 2, -3))
    }

    static func framesToLock(spread d: Double, max n: Int = 40) -> Int? {
        var f = AutoTableFusion()
        for i in 0..<n {
            f.add(jittered(i, d))
            if f.locked { return i + 1 }
        }
        return nil
    }

    // MARK: Step 2: adaptive fusion lock

    @Test func tightAgreementLocksAfterSixFrames() {
        #expect(Self.framesToLock(spread: 0.004) == 6)
    }

    @Test func looserAgreementNeedsFifteenFrames() {
        let n = Self.framesToLock(spread: 0.015)
        #expect(n == 15, "locked after \(String(describing: n)) frames")
    }

    @Test func spreadAboveTwoCentimetresNeverLocks() {
        #expect(Self.framesToLock(spread: 0.026) == nil)
    }

    @Test func syntheticSceneLocksInUnderTenFrames() throws {
        let run = autoRun(AutoSyntheticScene(), elevation: 40, frames: 12)
        let at = try #require(run.lockedAtFrame)
        #expect(at < 10, "locked at frame \(at)")
        #expect(AutoTestMetrics.maxCornerError(try #require(run.estimate.pose).corners, AutoSyntheticScene().trueCorners) < 0.01)
    }
}

import Foundation
import Geometry
import simd
import Testing
@testable import CueCoach

@MainActor
struct CalibrationEditorTests {
    let truth = SyntheticRig.frame(.sevenFoot)
    var world: [SIMD3<Double>] { truth.corners.map { truth.world($0) } }

    @Test func badFourthTapKeepsCornersAndFlagsOne() {
        let e = CalibrationEditor()
        let w = world
        e.add(w[0]); e.add(w[1]); e.add(w[2])
        e.add(w[3] + SIMD3(0.5, 0, 0.4))
        #expect(e.confirm(viewer: nil) == nil)
        #expect(e.corners.count == 4)
        #expect(e.outlier == 3)
        // Re-tap replaces only the flagged corner.
        e.add(w[3])
        #expect(e.outlier == nil && e.corners.count == 4)
        #expect(e.confirm(viewer: nil) != nil)
    }

    @Test func dragFixesOutlier() {
        let e = CalibrationEditor()
        var w = world
        w[1] += SIMD3(0, 0, 0.6)
        e.setProposal(w)
        #expect(e.confirm(viewer: nil) == nil)
        let bad = e.outlier!
        e.move(bad, to: world[bad])
        #expect(e.outlier == nil)
        #expect(e.confirm(viewer: nil) != nil)
    }

    @Test func undoAndReset() {
        let e = CalibrationEditor()
        e.add(world[0]); e.add(world[1])
        e.undo()
        #expect(e.corners.count == 1)
        e.reset()
        #expect(e.corners.isEmpty && !e.isComplete)
        for c in world { e.add(c) }
        #expect(!e.add(world[0]))  // no fifth corner
    }
}

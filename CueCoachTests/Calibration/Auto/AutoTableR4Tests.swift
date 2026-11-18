import Foundation
import Geometry
import simd
import Testing
@testable import CueCoach

/// Round 4: a steep, close view where the table never fits in the frame (VirtualTable elev-45/60, static camera).
/// Both long rails and both side pockets are seen; the corners are not.
@Suite("AutoTableLocator — round 4")
struct AutoTableR4Tests {
    static func closeCamera(_ scene: AutoSyntheticScene, elevation: Double, closer: Double) -> simd_double4x4 {
        var m = scene.camera(elevationDeg: elevation)
        let back = SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z)
        m.columns.3 -= SIMD4(back * closer, 0)
        // Phone held in portrait (rolled 90°): the table's length runs along the short image axis, as in the
        // VirtualTable elev-45/60 sessions, so its ends leave the frame first.
        let x = m.columns.0, y = m.columns.1
        m.columns.0 = y; m.columns.1 = -x
        return m
    }

    static func inFrame(_ scene: AutoSyntheticScene, _ m: simd_double4x4, _ p: SIMD3<Double>) -> Bool {
        guard let q = scene.project(p, cameraToWorld: m) else { return false }
        return q.x >= 0 && q.y >= 0 && q.x < Double(scene.width) && q.y < Double(scene.height)
    }

    /// Fraction of a long rail (y = 0 or W) inside the frame.
    static func railVisible(_ scene: AutoSyntheticScene, _ m: simd_double4x4, y: Double) -> Double {
        let L = scene.spec.length
        return Double((0...100).filter { inFrame(scene, m, scene.world(L * Double($0) / 100, y, 0)) }.count) / 101
    }

    static func steepView(_ scene: AutoSyntheticScene) -> (simd_double4x4, Double)? {
        let W = scene.spec.width, L = scene.spec.length
        for elevation in [55.0, 65, 75] { for closer in stride(from: 0.4, through: 3.0, by: 0.1) {
            let m = closeCamera(scene, elevation: elevation, closer: closer)
            let v0 = railVisible(scene, m, y: 0), v1 = railVisible(scene, m, y: W)
            let corners = [scene.world(0, 0, 0), scene.world(L, 0, 0), scene.world(0, W, 0), scene.world(L, W, 0)]
            let sides = [scene.world(L / 2, -0.04, 0.03), scene.world(L / 2, W + 0.04, 0.03)]
            // No corner in frame (the corner fit can't apply), both side pockets in.
            if corners.allSatisfy({ !inFrame(scene, m, $0) }), sides.allSatisfy({ inFrame(scene, m, $0) }),
               min(v0, v1) >= 0.62, max(v0, v1) <= 0.85 { return (m, min(v0, v1)) }
        } }
        return nil
    }

    static func run(_ scene: AutoSyntheticScene, _ cam: simd_double4x4, frames: Int) -> AutoRun {
        var rng = AutoTestRNG(seed: 9)
        let locator = ClassicalAutoTableLocator()
        var all: [AutoTableEstimate] = []
        var lockedAt: Int?
        for i in 0..<frames {
            let actual = AutoSyntheticScene.perturb(cam, rng: &rng, rotDeg: 0.2, trans: 0.005)
            let reported = AutoSyntheticScene.perturb(actual, rng: &rng, rotDeg: 0.02, trans: 0.001)
            let e = locator.process(scene.frame(cameraToWorld: actual, reported: reported, seed: UInt64(900 + i)))
            if lockedAt == nil, e.state == .locked { lockedAt = i }
            all.append(e)
        }
        return AutoRun(estimate: all.last!, lockedAtFrame: lockedAt, perFrame: all)
    }

    @Test(arguments: [TableSize.sevenFoot, .nineFoot])
    func steepViewWithoutCornersLocksFromRailsAndSidePockets(size: TableSize) throws {
        var scene = AutoSyntheticScene()
        scene.size = size
        scene.balls = []
        let (cam, vis) = try #require(Self.steepView(scene))
        if let dir = ProcessInfo.processInfo.environment["VQA_OUT"] {
            let im = scene.render(cameraToWorld: cam)
            if let cg = VTImageIO.cgImage(rgb: im.rgb, width: im.width, height: im.height) {
                VTHarness.writePNG(cg, to: URL(fileURLWithPath: dir).appendingPathComponent("steep-\(size).png"))
            }
        }
        let run = Self.run(scene, cam, frames: 16)
        print("[autocal] steep \(size) (\(Int(vis * 100)) % of the length in view): \(run.estimate.state), rejections \(Set(run.perFrame.compactMap(\.frame.rejection)))")
        let pose = try #require(run.estimate.pose)
        #expect(run.estimate.state == .locked)
        #expect(run.perFrame.contains { $0.frame.partialAnchor == "sidePockets" }, "the side-pocket fit never ran")
        #expect(!run.perFrame.contains { $0.frame.partialAnchor == "corner" })
        #expect(pose.snappedSize == size)
        // The visible-length estimate the second-look rule uses is honest: close to the truth, never above it.
        let W = scene.spec.width
        let truth = max(Self.railVisible(scene, cam, y: 0), Self.railVisible(scene, cam, y: W))
        let fractions = run.perFrame.compactMap(\.frame.visibleLengthFraction)
        #expect(!fractions.isEmpty)
        for v in fractions {
            #expect(v <= truth + 0.03, "visible \(v) > true \(truth)")
            #expect(v >= truth - 0.08, "visible \(v) ≪ true \(truth)")
        }
        #expect(AutoTestMetrics.maxCornerError(pose.corners, scene.trueCorners) < 0.02)
    }

    /// The second-look rule at its boundary: one static view of a partial fit locks at ≥ 60 % of the length
    /// seen and never below it (the steep-view fit feeds fusion exactly these measurements).
    @Test(arguments: [(0.58, false), (0.62, true)])
    func staticPartialViewLocksOnlyFromSixtyPercent(visible: Double, locks: Bool) {
        var f = AutoTableFusion()
        for i in 0..<30 {
            var m = AutoTableMeasurement(center: SIMD3(0.001 * Double(i % 3), 0.79, 0), axis: SIMD3(1, 0, 0), up: SIMD3(0, 1, 0),
                                         measuredLength: TableSize.nineFoot.playingLength,
                                         measuredWidth: TableSize.nineFoot.playingLength / 2, snapped: .nineFoot,
                                         cameraPosition: SIMD3(0, 2.2, -0.6))
            m.visibleLengthFraction = visible
            f.add(m)
        }
        #expect(f.locked == locks, "visible \(visible)")
    }
}

/// Dark marks that are not pockets must not anchor the table along its length (Codex r4).
struct AutoTableFakeSidePocketTests {
    @Test func darkBallsOnTheClothBesideBothRailsAreNotSidePockets() throws {
        var scene = AutoSyntheticScene()
        let L = scene.spec.length, W = scene.spec.width
        // Two black discs on the cloth hugging both cushions, 60 cm off the true middle (aligned across).
        scene.balls = []
        scene.occluders = [(L / 2 + 0.55, L / 2 + 0.66, 0.0, 0.05, 0.0, 0.004), (L / 2 + 0.55, L / 2 + 0.66, W - 0.05, W, 0.0, 0.004)]
        let (cam, _) = try #require(AutoTableR4Tests.steepView(scene))
        let run = AutoTableR4Tests.run(scene, cam, frames: 16)
        if let pose = run.estimate.pose, run.estimate.state == .locked {
            #expect(AutoTestMetrics.maxCornerError(pose.corners, scene.trueCorners) < 0.05, "locked on a fake pocket")
        }
    }
}

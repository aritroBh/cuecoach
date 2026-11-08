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
            // At least the two near corners out of frame (no rail corner to fit), both side pockets in.
            if corners.filter({ !inFrame(scene, m, $0) }).count >= 2, sides.allSatisfy({ inFrame(scene, m, $0) }),
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
        #expect(pose.snappedSize == size)
        // The visible-length estimate the second-look rule uses is honest: close to the truth, never above it.
        let W = scene.spec.width
        let truth = max(Self.railVisible(scene, cam, y: 0), Self.railVisible(scene, cam, y: W))
        for v in run.perFrame.compactMap(\.frame.visibleLengthFraction) {
            #expect(v <= truth + 0.03, "visible \(v) > true \(truth)")
            #expect(v >= truth - 0.08, "visible \(v) ≪ true \(truth)")
        }
        #expect(AutoTestMetrics.maxCornerError(pose.corners, scene.trueCorners) < 0.02)
    }

    @Test func steepViewWithMostOfTheLengthHiddenDoesNotLock() throws {
        // Same fit, but < 60 % of the length in view and a static camera: the second-look rule holds it back.
        let scene = AutoSyntheticScene()
        var cam: simd_double4x4?
        for elevation in [65.0, 75, 85, 89] { for closer in stride(from: 0.3, through: 3.5, by: 0.05) where cam == nil {
            let m = Self.closeCamera(scene, elevation: elevation, closer: closer)
            let W = scene.spec.width, L = scene.spec.length
            if max(Self.railVisible(scene, m, y: 0), Self.railVisible(scene, m, y: W)) < 0.55,
               Self.inFrame(scene, m, scene.world(L / 2, -0.04, 0.03)), Self.inFrame(scene, m, scene.world(L / 2, W + 0.04, 0.03)) {
                cam = m
            }
        } }
        let c = try #require(cam)
        let run = Self.run(scene, c, frames: 16)
        #expect(run.estimate.state != .locked)
    }
}

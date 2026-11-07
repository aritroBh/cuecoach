import Foundation
import Geometry
import simd
import Testing
@testable import CueCoach

/// Lock-plan steps 4–6 (scratchpad reviews/lock-plan.md): partial and far views, neutral cloth and dim
/// light, plausible geometry instead of preset matching.
@Suite("AutoTableLocator — coverage")
struct AutoTableCoverageTests {

    // MARK: Step 4: partial and far views

    /// The default long-side camera slid toward the foot end by `shift` m (along the table axis) and
    /// pulled in by `closer` m, so part of the table leaves the frame.
    static func shiftedCamera(_ scene: AutoSyntheticScene, elevation: Double = 40, shift: Double, closer: Double = 0,
                              azimuth: Double = 90) -> simd_double4x4 {
        var m = scene.camera(elevationDeg: elevation, azimuthDeg: azimuth)
        let ex = SIMD3(scene.tableToWorld.columns.0.x, scene.tableToWorld.columns.0.y, scene.tableToWorld.columns.0.z)
        let back = SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z)
        m.columns.3 += SIMD4(ex * shift - back * closer, 0)
        return m
    }

    static func visibleFraction(_ scene: AutoSyntheticScene, _ m: simd_double4x4, worst: Bool = false) -> Double {
        // The better-seen long rail (the far one usually covers more of the length in perspective).
        let L = scene.spec.length, W = scene.spec.width
        return [0, W].map { y -> Double in
            var seen = 0
            for k in 0...100 {
                let x = L * Double(k) / 100
                if let q = scene.project(scene.world(x, y, 0), cameraToWorld: m),
                   q.x >= 0, q.y >= 0, q.x < Double(scene.width), q.y < Double(scene.height) { seen += 1 }
            }
            return Double(seen) / 101
        }.sorted()[worst ? 0 : 1]
    }

    static func runFixed(_ scene: AutoSyntheticScene, cameras: [simd_double4x4], frames: Int,
                         locator: ClassicalAutoTableLocator = ClassicalAutoTableLocator()) -> AutoRun {
        var rng = AutoTestRNG(seed: 5)
        var all: [AutoTableEstimate] = []
        var lockedAt: Int?
        for i in 0..<frames {
            let base = cameras[i * cameras.count / frames]
            let actual = AutoSyntheticScene.perturb(base, rng: &rng, rotDeg: 0.3, trans: 0.01)
            let reported = AutoSyntheticScene.perturb(actual, rng: &rng, rotDeg: 0.03, trans: 0.002)
            let e = locator.process(scene.frame(cameraToWorld: actual, reported: reported, seed: UInt64(700 + i)))
            if lockedAt == nil, e.state == .locked { lockedAt = i }
            all.append(e)
        }
        return AutoRun(estimate: all.last!, lockedAtFrame: lockedAt, perFrame: all)
    }

    @Test func partialViewWithMostOfTheLengthLocksAccurately() throws {
        let scene = AutoSyntheticScene()
        let cam = Self.shiftedCamera(scene, shift: 0.55, closer: 0.4)
        let vis = Self.visibleFraction(scene, cam), near = Self.visibleFraction(scene, cam, worst: true)
        #expect(vis > 0.6 && near < 0.97, "visible \(vis), near rail \(near)")
        let run = Self.runFixed(scene, cameras: [cam], frames: 16)
        print("[autocal] partial rejections: \(run.perFrame.map { $0.frame.rejection ?? "ok" })")
        let pose = try #require(run.estimate.pose)
        let err = AutoTestMetrics.maxCornerError(pose.corners, scene.trueCorners)
        print("[autocal] partial view \(Int(vis * 100)) % visible: state \(run.estimate.state), err \(err * 1000) mm")
        #expect(run.estimate.state == .locked)
        #expect(err < 0.02)
    }

    @Test func partialViewOfUnderSixtyPercentNeedsASecondViewAngle() throws {
        let scene = AutoSyntheticScene()
        let shift = stride(from: 1.0, through: 1.8, by: 0.1).first { Self.visibleFraction(scene, Self.shiftedCamera(scene, shift: $0, closer: 0.9)) < 0.55 } ?? 1.8
        let a = Self.shiftedCamera(scene, shift: shift, closer: 0.9)
        let vis = Self.visibleFraction(scene, a)
        #expect(vis < 0.6, "visible \(vis)")
        let one = Self.runFixed(scene, cameras: [a], frames: 16)
        #expect(one.estimate.state != .locked)
        // Walk around the corner: a second azimuth 30° away.
        let b = Self.shiftedCamera(scene, shift: shift, closer: 0.9, azimuth: 60)
        let two = Self.runFixed(scene, cameras: [a, b], frames: 20)
        if two.estimate.state == .locked {
            let err = AutoTestMetrics.maxCornerError(try #require(two.estimate.pose).corners, scene.trueCorners)
            #expect(err < 0.03)
        }
    }

    @Test func farViewAtThreeMetresLocks() throws {
        let scene = AutoSyntheticScene()
        let cam = Self.shiftedCamera(scene, elevation: 30, shift: 0, closer: -1.5)
        let run = Self.runFixed(scene, cameras: [cam], frames: 14)
        let pose = try #require(run.estimate.pose)
        let err = AutoTestMetrics.maxCornerError(pose.corners, scene.trueCorners)
        print("[autocal] far view: state \(run.estimate.state), err \(err * 1000) mm, rejection \(String(describing: run.estimate.frame.rejection))")
        #expect(run.estimate.state == .locked)
        #expect(err < 0.02)
    }

    @Test func grazingViewIsNotMeasured() {
        // Below ~12° a 1 cm plane error moves the lifted rails ≥ 5 cm along the rays (the virtual-table
        // matrix's 3 m sessions at 8–11° locked a 9 ft table as 8 ft). Not measured, so never locked.
        let scene = AutoSyntheticScene()
        let run = autoRun(scene, elevation: 9, frames: 12)
        #expect(run.estimate.state != .locked)
        #expect(run.perFrame.contains { $0.frame.rejection == "view too shallow" })
    }

    // MARK: Step 5: neutral cloth, dim light

    @Test func greyClothLocksInsideTheDepthGate() throws {
        var scene = AutoSyntheticScene()
        scene.feltColor = (118, 118, 116)
        let run = autoRun(scene, elevation: 40, frames: 14)
        let pose = try #require(run.estimate.pose)
        #expect(run.estimate.state == .locked)
        #expect(AutoTestMetrics.maxCornerError(pose.corners, scene.trueCorners) < 0.01)
    }

    @Test func greyClothWithoutDepthIsNotGuessed() {
        var scene = AutoSyntheticScene()
        scene.feltColor = (118, 118, 116)
        scene.floorColor = (118, 118, 116)
        let run = autoRun(scene, elevation: 40, frames: 10, withDepth: false)
        #expect(run.estimate.state != .locked)
    }

    @Test func dimRoomLocks() throws {
        var scene = AutoSyntheticScene()
        scene.lightScale = 0.35
        scene.noiseSigma = 3
        let run = autoRun(scene, elevation: 40, frames: 14)
        let pose = try #require(run.estimate.pose)
        print("[autocal] dim room: state \(run.estimate.state), rejection \(String(describing: run.estimate.frame.rejection))")
        #expect(run.estimate.state == .locked)
        #expect(AutoTestMetrics.maxCornerError(pose.corners, scene.trueCorners) < 0.01)
    }

    // MARK: Step 6: plausible geometry, not preset matching

    @Test func offPresetTableLocksWithItsMeasuredSize() throws {
        var scene = AutoSyntheticScene()
        scene.lengthOverride = 1.80  // 6 ft bar box: 9 % short of 7 ft, no preset within 6 %
        let run = autoRun(scene, elevation: 40, frames: 18)
        let pose = try #require(run.estimate.pose)
        #expect(run.estimate.state == .locked)
        #expect(pose.snappedSize == nil)
        #expect(abs(pose.spec.length - 1.80) < 0.01)
        #expect(AutoTestMetrics.maxCornerError(pose.corners, scene.trueCorners) < 0.01)
    }

    @Test func plausibleAspectIsOneSixToTwoFive() {
        // Geometry vet: a rectangle with aspect 1.3 is rejected by the plausibility gate.
        #expect(!ClassicalAutoTableLocator.plausibleAspect(1.3))
        #expect(ClassicalAutoTableLocator.plausibleAspect(1.6))
        #expect(ClassicalAutoTableLocator.plausibleAspect(2.4))
        #expect(!ClassicalAutoTableLocator.plausibleAspect(2.6))
    }
}

import Foundation
import Geometry
import simd
import Testing
@testable import CueCoach

/// Regression tests for the AutoTableLocator review findings (one section per finding).
@Suite("AutoTableLocator — review fixes")
struct AutoTableLocatorReviewTests {

    // MARK: Helpers

    static func measurement(x: Double = 0, z: Double = 0, length: Double = TableSize.nineFoot.playingLength,
                            snapped: TableSize? = .nineFoot) -> AutoTableMeasurement {
        AutoTableMeasurement(center: SIMD3(x, 0.79, z), axis: SIMD3(1, 0, 0), up: SIMD3(0, 1, 0),
                             measuredLength: length, measuredWidth: length / 2, snapped: snapped,
                             cameraPosition: SIMD3(0, 2, -3))
    }

    static func lockedFusion() -> AutoTableFusion {
        var f = AutoTableFusion()
        for _ in 0..<20 { f.add(measurement()) }
        return f
    }

    // MARK: 1. Physical-quad check must reject when no 4-group combination passes

    @Test func coarseLinesRejectsWhenNoCandidateQuadIsAccepted() {
        // A pentagon boundary: 5 hull side groups, none of which the vetting closure accepts.
        var pts: [AutoP2] = []
        let verts = (0..<5).map { k -> AutoP2 in
            let a = Double(k) / 5 * 2 * .pi
            return AutoP2(480 + 250 * cos(a), 360 + 250 * sin(a))
        }
        for k in 0..<5 {
            let a = verts[k], b = verts[(k + 1) % 5]
            for t in 0..<60 { pts.append(a + (b - a) * (Double(t) / 60)) }
        }
        var rng = AutoRandom()
        let lines = AutoRailDetector.coarseLines(boundary: pts, stride: 2, rng: &rng, accept: { _ in false })
        #expect(lines == nil)
    }

    // MARK: 2. Size changes while locked must never move corners silently

    @Test func sizeVoteFlipWhileLockedBumpsGeneration() throws {
        var f = Self.lockedFusion()
        #expect(f.locked)
        var gen = f.generation
        var len = try #require(f.fused).spec.length
        // Rail occlusion: the fits stop snapping and measure ~2.50 m.
        for _ in 0..<30 {
            f.add(Self.measurement(length: 2.50, snapped: nil))
            let now = try #require(f.fused).spec.length
            if f.generation == gen { #expect(abs(now - len) < 1e-9, "size changed \(len) → \(now) with no new generation") }
            gen = f.generation; len = now
        }
        #expect(abs(len - 2.50) < 0.002)
        #expect(f.generation >= 2)
    }

    @Test func sizeWaverNearTheVoteThresholdIsHeldWhileLocked() throws {
        var f = Self.lockedFusion()
        let len0 = try #require(f.fused).spec.length
        for i in 0..<40 {
            f.add(i % 2 == 0 ? Self.measurement() : Self.measurement(length: 2.533, snapped: nil))
            #expect(abs(try #require(f.fused).spec.length - len0) < 1e-9)
        }
        #expect(f.generation == 1)
        #expect(f.locked)
    }

    // MARK: 3. Test honesty: profile mismatch, depth-only plane, correlated drift

    @Test func railProfileMismatchStaysWithinOneCentimetre() throws {
        // The real table's felt/wood boundary is 7 mm higher and its cushion 4 mm wider than the model assumes.
        var scene = AutoSyntheticScene()
        scene.profile.railTopHeight = 0.052
        scene.profile.cushionWidth = 0.055
        let run = autoRun(scene, elevation: 40, frames: 24)
        let pose = try #require(run.estimate.pose)
        let err = AutoTestMetrics.maxCornerError(pose.corners, scene.trueCorners)
        print("[autocal] rail profile mismatch (+7 mm height, +4 mm cushion): max corner error \(err * 1000) mm")
        #expect(run.estimate.state == .locked)
        // LiDAR measures the rail-cap height, so the profile error does not shift the table (was 8.7 mm).
        #expect(err < 0.003)
    }

    @Test func depthOnlyPlaneWithoutARKitHint() throws {
        let scene = AutoSyntheticScene()
        let run = autoRun(scene, elevation: 40, frames: 24, withPlane: false)
        let pose = try #require(run.estimate.pose)
        let err = AutoTestMetrics.maxCornerError(pose.corners, scene.trueCorners)
        print("[autocal] no plane hint (LiDAR-only plane): max corner error \(err * 1000) mm")
        #expect(run.estimate.state == .locked)
        #expect(err < 0.01)
    }

    @Test func correlatedTrackingDriftIsFollowed() throws {
        var scene = AutoSyntheticScene()
        let drift = SIMD3<Double>(0.0003, 0, 0.0002)  // 0.36 mm/frame, ~8.6 mm over the run
        let frames = 24
        let run = autoRun(scene, elevation: 40, frames: frames, driftMetresPerFrame: drift)
        let pose = try #require(run.estimate.pose)
        // In the drifted world the table sits at truth + drift × last frame index.
        scene.tableCenterXZ += SIMD2(drift.x, drift.z) * Double(frames - 1)
        let err = AutoTestMetrics.maxCornerError(pose.corners, scene.trueCorners)
        print("[autocal] correlated drift 0.36 mm/frame: max corner error vs current world \(err * 1000) mm")
        #expect(err < 0.01)
    }

    // MARK: 4. Keypoint-only path must not claim perfect reprojection

    struct OffsetKeypoints: TableKeypointProvider {
        var scene: AutoSyntheticScene
        var camera: simd_double4x4
        var offsets: [SIMD2<Double>]
        func keypoints(in image: AutoRGBImage, intrinsics: AutoIntrinsics) -> [AutoTableKeypoint] {
            scene.trueCorners.enumerated().compactMap { i, p in
                let q = scene.project(p + SIMD3(0, scene.profile.noseHeight, 0), cameraToWorld: camera)
                return q.map { AutoTableKeypoint(kind: .cornerPocket, pixel: $0 + offsets[i], confidence: 0.9) }
            }
        }
    }

    static func greyScene() -> AutoSyntheticScene {
        var scene = AutoSyntheticScene()
        scene.feltColor = (120, 120, 120)
        scene.floorColor = (120, 120, 120)
        return scene
    }

    @Test func keypointOnlyConfidenceReflectsKeypointResiduals() throws {
        let scene = Self.greyScene()
        let cam = scene.camera(elevationDeg: 45)
        let off = [SIMD2(7.0, 0), SIMD2(0, -7.0), SIMD2(7.0, 5), SIMD2(-6.0, 6)]
        let locator = ClassicalAutoTableLocator(keypoints: OffsetKeypoints(scene: scene, camera: cam, offsets: off))
        var last: AutoTableEstimate?
        for i in 0..<20 { last = locator.process(scene.frame(cameraToWorld: cam, seed: UInt64(i))) }
        let e = try #require(last)
        #expect(e.frame.path == .keypointsOnly)
        print("[autocal] keypoint-only, offset keypoints: frame rms \(e.frame.reprojectionRMS) px, conf \(e.confidence)")
        #expect(e.frame.reprojectionRMS > 1)
        #expect(e.frame.reprojectionRMS.isFinite)
        #expect(e.frame.pocketScores.count >= 4)
        #expect(e.confidence < 0.8)
    }

    @Test func keypointOnlyExactKeypointsHaveSmallResidual() throws {
        let scene = Self.greyScene()
        let cam = scene.camera(elevationDeg: 45)
        let locator = ClassicalAutoTableLocator(keypoints: OffsetKeypoints(scene: scene, camera: cam,
                                                                           offsets: Array(repeating: .zero, count: 4)))
        var last: AutoTableEstimate?
        for i in 0..<20 { last = locator.process(scene.frame(cameraToWorld: cam, seed: UInt64(i))) }
        let e = try #require(last)
        #expect(e.frame.path == .keypointsOnly)
        #expect(e.frame.reprojectionRMS < 0.5)
        #expect(e.fusedReprojectionRMS != nil)
    }

    // MARK: 5. "Cloth touches frame" must be able to fire

    @Test func openingKeepsComponentPixelsOnTheImageBorder() {
        let w = 20, h = 16
        let m = AutoMask(width: w, height: h, stride: 1, bits: [UInt8](repeating: 1, count: w * h))
        let (comp, _) = AutoClothSegmenter.largestComponent(AutoClothSegmenter.open(m))
        #expect(AutoClothSegmenter.boundary(comp).borderTouches == 2 * (w + h) - 4)
    }

    @Test func tableRunningOffTheFrameIsRejected() throws {
        let scene = AutoSyntheticScene()
        // Pulled in so the table runs past the frame edges: the cloth itself reaches the border.
        let cam = scene.camera(elevationDeg: 50, margin: -400)
        let e = ClassicalAutoTableLocator().process(scene.frame(cameraToWorld: cam, seed: 3))
        print("[autocal] table off frame: rejection \(e.frame.rejection ?? "none")")
        #expect(e.frame.rejection == "cloth touches frame")
    }

    // MARK: 6. LiDAR cloth level must be plausible and well covered

    @Test func lidarIgnoresAnOccluderFillingTheBed() throws {
        var scene = AutoSyntheticScene()
        let L = scene.spec.length, W = scene.spec.width
        // Seen by LiDAR only: someone leaning over most of the bed, 10 cm above the cloth.
        scene.depthOccluders = [(0.15, L - 0.15, 0.08, W - 0.08, 0.0, 0.10)]
        let run = autoRun(scene, elevation: 40, frames: 12)
        for e in run.perFrame {
            if let h = e.frame.lidarClothHeight { #expect(abs(h - scene.clothHeight) < 0.03, "cloth level \(h)") }
        }
        let pose = try #require(run.estimate.pose)
        #expect(AutoTestMetrics.maxCornerError(pose.corners, scene.trueCorners) < 0.025)
    }

    // MARK: 7. Tracking state, duplicates, inconsistent re-lock

    @Test func limitedTrackingFramesAreSkipped() throws {
        let scene = AutoSyntheticScene()
        let locator = ClassicalAutoTableLocator()
        let first = autoRun(scene, elevation: 40, frames: 20, locator: locator)
        #expect(first.estimate.state == .locked)
        let pose0 = try #require(first.estimate.pose)
        let cam = scene.camera(elevationDeg: 40)
        // Relocalizing: 15 frames whose reported pose is far off and keeps jumping.
        for i in 0..<15 {
            var bad = cam; bad.columns.3 += SIMD4(0.3 + 0.05 * Double(i), 0, -0.2, 0)
            let e = locator.process(scene.frame(cameraToWorld: cam, reported: bad, seed: UInt64(700 + i), tracking: .limited))
            #expect(e.frame.rejection == "tracking")
        }
        let after = try #require(locator.latest)
        #expect(after.state == .locked)
        #expect(after.generation == first.estimate.generation)
        #expect(AutoTestMetrics.maxCornerError(try #require(after.pose).corners, pose0.corners) < 1e-9)
    }

    @Test func duplicateFramesDoNotCountTowardLock() {
        let scene = AutoSyntheticScene()
        let locator = ClassicalAutoTableLocator()
        let f = scene.frame(cameraToWorld: scene.camera(elevationDeg: 40), seed: 5)
        var last: AutoTableEstimate?
        for _ in 0..<30 { last = locator.process(f) }
        #expect(last?.state != .locked)
        #expect(last?.frame.rejection == "duplicate frame")
    }

    @Test func inconsistentDisagreementDoesNotRelock() throws {
        var f = Self.lockedFusion()
        #expect(f.locked)
        for i in 0..<14 { f.add(Self.measurement(x: i % 2 == 0 ? 0.12 : -0.12)) }
        #expect(f.locked)
        #expect(f.generation == 1)
        #expect(abs(try #require(f.fused).center.x) < 0.005)
    }

    @Test func consistentDisagreementStillRelocks() throws {
        var f = Self.lockedFusion()
        for _ in 0..<30 { f.add(Self.measurement(x: 0.08)) }
        #expect(f.locked)
        #expect(f.generation == 2)
        #expect(abs(try #require(f.fused).center.x - 0.08) < 0.002)
    }

    // MARK: 8. Intrinsics scaling keeps the integer-pixel-centre convention

    @Test func scaledIntrinsicsMapPixelCentresConsistently() {
        let k = AutoIntrinsics(fx: 1450, fy: 1450, cx: 959.5, cy: 719.5, width: 1920, height: 1440)
        let s = k.scaled(toWidth: 960, height: 720)
        #expect(abs(s.cx - 479.5) < 1e-12)
        #expect(abs(s.cy - 359.5) < 1e-12)
        #expect(abs(s.fx - 725) < 1e-12)
    }

    // MARK: 9. Readers must not wait for a whole frame's detection

    final class SlowKeypoints: TableKeypointProvider, @unchecked Sendable {
        let entered = DispatchSemaphore(value: 0)
        func keypoints(in image: AutoRGBImage, intrinsics: AutoIntrinsics) -> [AutoTableKeypoint] {
            entered.signal()
            Thread.sleep(forTimeInterval: 0.4)
            return []
        }
    }

    @Test func latestAndFlipDoNotBlockDuringDetection() {
        let scene = AutoSyntheticScene()
        let slow = SlowKeypoints()
        let locator = ClassicalAutoTableLocator(keypoints: slow)
        let frame = scene.frame(cameraToWorld: scene.camera(elevationDeg: 40), seed: 2)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { _ = locator.process(frame); done.signal() }
        slow.entered.wait()
        let t0 = Date()
        _ = locator.latest
        locator.flipHeadFoot()
        let dt = Date().timeIntervalSince(t0)
        done.wait()
        #expect(dt < 0.1, "reader blocked \(dt) s")
    }
}

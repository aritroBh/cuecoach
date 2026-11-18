import Foundation
import Geometry
import simd
import Testing
@testable import CueCoach

/// Regression tests for the round-2 re-verification findings and the tablekp keypoint contract.
@Suite("AutoTableLocator — round 2")
struct AutoTableLocatorRound2Tests {

    // MARK: 1. reset() vs an in-flight detection; concurrent process() calls

    final class ArmedSlow: TableKeypointProvider, @unchecked Sendable {
        let entered = DispatchSemaphore(value: 0)
        var armed = false
        func keypoints(in image: AutoRGBImage, intrinsics: AutoIntrinsics) -> [AutoTableKeypoint] {
            if armed { entered.signal(); Thread.sleep(forTimeInterval: 0.4) }
            return []
        }
    }

    @Test func resetDuringAnInFlightDetectionLeavesFreshState() throws {
        let scene = AutoSyntheticScene()
        let slow = ArmedSlow()
        let locator = ClassicalAutoTableLocator(keypoints: slow)
        let first = autoRun(scene, elevation: 40, frames: 20, locator: locator)
        #expect(first.estimate.state == .locked)
        slow.armed = true
        let frame = scene.frame(cameraToWorld: scene.camera(elevationDeg: 40), seed: 900)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { _ = locator.process(frame); done.signal() }
        slow.entered.wait()
        locator.reset()
        done.wait()
        #expect(locator.latest == nil, "pre-reset frame was written into the reset locator")
        #expect(locator.debugWorkCounts.clothLevels == 0)
        // The next frame starts from scratch: one frame cannot be locked.
        slow.armed = false
        let next = locator.process(scene.frame(cameraToWorld: scene.camera(elevationDeg: 40), seed: 901))
        #expect(next.state != .locked)
        #expect(next.generation == 0)
    }

    @Test func concurrentProcessCallsLoseNoDetectorUpdates() async {
        let scene = AutoSyntheticScene()
        let cam = scene.camera(elevationDeg: 40)
        let frames = (0..<6).map { scene.frame(cameraToWorld: cam, seed: UInt64(300 + $0)) }
        let sequential = ClassicalAutoTableLocator()
        for f in frames { _ = sequential.process(f) }
        let concurrent = ClassicalAutoTableLocator()
        await withTaskGroup(of: Void.self) { g in
            for f in frames { g.addTask { _ = concurrent.process(f) } }
        }
        #expect(sequential.debugWorkCounts.clothLevels == frames.count)
        #expect(concurrent.debugWorkCounts.clothLevels == sequential.debugWorkCounts.clothLevels)
        #expect(concurrent.debugWorkCounts.railHeights == sequential.debugWorkCounts.railHeights)
    }

    // MARK: 2. Held size needs hysteresis near the 6 % snap edge

    static func m(_ len: Double, _ snapped: TableSize?) -> AutoTableMeasurement {
        AutoTableMeasurement(center: SIMD3(0, 0.79, 0), axis: SIMD3(1, 0, 0), up: SIMD3(0, 1, 0),
                             measuredLength: len, measuredWidth: len / 2, snapped: snapped,
                             cameraPosition: SIMD3(0, 2, -3))
    }

    @Test(arguments: [UInt64(42), 7, 1234, 99, 2026])
    func snapEdgeTableDoesNotFlapWhileLocked(seed: UInt64) {
        // A ~2.39 m table sits at the 6 % snap boundary of 9 ft: ~60 % of frames snap, the rest do not.
        var f = AutoTableFusion()
        var rng = AutoTestRNG(seed: seed)
        var lens: [Double] = []
        var firstLockGen: Int?
        for _ in 0..<300 {
            let snap = rng.uniform() < 0.6
            f.add(Self.m(snap ? 2.392 : 2.386, snap ? .nineFoot : nil))
            if f.locked, let p = f.fused {
                if firstLockGen == nil { firstLockGen = f.generation }
                lens.append(p.spec.length)
            }
        }
        var flips = 0
        for i in 1..<lens.count where abs(lens[i] - lens[i - 1]) > 0.01 { flips += 1 }
        #expect(firstLockGen != nil)
        #expect(flips <= 1, "seed \(seed): size flapped \(flips) times while locked")
        #expect(f.generation - (firstLockGen ?? 0) <= 1, "seed \(seed): generation \(f.generation)")
    }

    @Test func aHeldPresetWithSupportSurvivesACompetingPreset() throws {
        var f = AutoTableFusion()
        for _ in 0..<20 { f.add(Self.m(TableSize.nineFoot.playingLength, .nineFoot)) }
        #expect(f.locked)
        // Split support: ~50 % 8 ft vs ~47 % 9 ft — 9 ft keeps more than share − band, so it is held.
        for i in 0..<60 { f.add(i % 2 == 0 ? Self.m(TableSize.eightFoot.playingLength, .eightFoot) : Self.m(TableSize.nineFoot.playingLength, .nineFoot)) }
        #expect(try #require(f.fused).snappedSize == .nineFoot)
        #expect(f.generation == 1)
    }

    @Test func aGenuineSizeChangeIsStillAdoptedOnce() throws {
        var f = AutoTableFusion()
        for _ in 0..<20 { f.add(Self.m(TableSize.nineFoot.playingLength, .nineFoot)) }
        #expect(f.locked)
        for _ in 0..<40 { f.add(Self.m(TableSize.eightFoot.playingLength, .eightFoot)) }
        #expect(abs(try #require(f.fused).spec.length - TableSize.eightFoot.playingLength) < 1e-9)
        #expect(f.generation == 2)
    }

    // MARK: 3. LiDAR rail-cap height on device-like (smoothed, sparse-confidence) depth

    static func realistic(_ scene: AutoSyntheticScene) -> AutoSyntheticScene {
        var s = scene
        s.realisticDepth = AutoSyntheticScene.RealisticDepth()
        return s
    }

    @Test func realisticDepthHasMixedConfidenceAndRailHoles() {
        let scene = Self.realistic(AutoSyntheticScene())
        let d = scene.depth(cameraToWorld: scene.camera(elevationDeg: 40))
        let c = d.confidence ?? []
        let n = Double(c.count)
        let high = Double(c.filter { $0 == 2 }.count) / n, none = Double(c.filter { $0 == 0 }.count) / n
        print("[autocal] realistic depth confidence: high \(high), none \(none)")
        #expect(high > 0.25 && high < 0.95)
        #expect(none > 0.01)
    }

    @Test func smoothedDepthDoesNotBiasTheRailHeightBeyondTheDefault() throws {
        // Real table = the profile default. Measured LiDAR rail height must not make things worse than
        // simply trusting the default.
        let scene = Self.realistic(AutoSyntheticScene())
        let measuring = ClassicalAutoTableLocator()
        let measured = autoRun(scene, elevation: 40, frames: 24, locator: measuring)
        // The LiDAR path must actually accept measurements on device-like depth, not silently fall back.
        #expect(measuring.debugWorkCounts.railHeights > 0)
        var cfg = ClassicalAutoTableLocator.Config()
        cfg.measureRailTopHeight = false
        let plain = autoRun(scene, elevation: 40, frames: 24, locator: ClassicalAutoTableLocator(config: cfg))
        let pm = try #require(measured.estimate.pose), pp = try #require(plain.estimate.pose)
        let em = AutoTestMetrics.maxCornerError(pm.corners, scene.trueCorners)
        let ep = AutoTestMetrics.maxCornerError(pp.corners, scene.trueCorners)
        let h = try #require(measured.estimate.frame.railTopHeight)
        print("[autocal] realistic depth: rail height used \(h * 1000) mm, err measured \(em * 1000) mm vs default \(ep * 1000) mm")
        #expect(measured.estimate.state == .locked)
        #expect(abs(h - AutoTableProfile().railTopHeight) <= 0.008)
        #expect(em <= ep + 0.001)
        #expect(em < 0.01)
    }

    @Test func implausibleLidarRailHeightFallsBackToTheDefault() throws {
        // A rail 15 mm higher than the profile (or a depth artefact saying so) is outside the trusted
        // 8 mm band: the default is kept, not the measurement.
        var scene = AutoSyntheticScene()
        scene.profile.railTopHeight = 0.060
        let run = autoRun(scene, elevation: 40, frames: 12)
        let h = try #require(run.estimate.frame.railTopHeight)
        #expect(abs(h - AutoTableProfile().railTopHeight) < 1e-9)
    }

    @Test func realisticDepthWithAProfileMismatchIsNoWorseThanTheDefault() throws {
        var scene = Self.realistic(AutoSyntheticScene())
        scene.profile.railTopHeight = 0.052
        let measuring = ClassicalAutoTableLocator()
        let measured = autoRun(scene, elevation: 40, frames: 24, locator: measuring)
        // +7 mm sits next to the 8 mm trust limit: smoothed depth may push a measurement past it, and then the
        // default is used — never worse than the default (asserted below). The accept path itself is asserted
        // on the default-profile table above.
        var cfg = ClassicalAutoTableLocator.Config()
        cfg.measureRailTopHeight = false
        let plain = autoRun(scene, elevation: 40, frames: 24, locator: ClassicalAutoTableLocator(config: cfg))
        let em = AutoTestMetrics.maxCornerError(try #require(measured.estimate.pose).corners, scene.trueCorners)
        let ep = AutoTestMetrics.maxCornerError(try #require(plain.estimate.pose).corners, scene.trueCorners)
        print("[autocal] realistic depth, +7 mm rail: err measured \(em * 1000) mm vs default \(ep * 1000) mm")
        #expect(em <= ep + 0.001)
        #expect(em < 0.01)
    }

    // MARK: 4. tablekp keypoint contract

    @Test func keypointKindsFollowTheTablekpOrder() throws {
        // tools/tablekp/generate_dataset.py KEYPOINT_NAMES, verbatim.
        let names = ["corner_mouth_0", "corner_mouth_1", "corner_mouth_2", "corner_mouth_3",
                     "side_mouth_0", "side_mouth_1",
                     "nose_corner_0", "nose_corner_1", "nose_corner_2", "nose_corner_3"]
        #expect(AutoTableKeypointModel.keypointNames == names)
        let kinds = try #require(AutoTableKeypointModel.kinds(names: names))
        #expect(kinds == [.cornerMouth, .cornerMouth, .cornerMouth, .cornerMouth, .sideMouth, .sideMouth,
                          .noseCorner, .noseCorner, .noseCorner, .noseCorner])
        #expect(AutoTableKeypointModel.kinds(names: names + ["diamond_0"]) == nil)
        // flip_idx [1, 0, 3, 2, 4, 5, 7, 6, 9, 8] keeps every index inside its kind group.
        let flip = [1, 0, 3, 2, 4, 5, 7, 6, 9, 8]
        for (i, j) in flip.enumerated() { #expect(kinds[i] == kinds[j]) }
    }

    @Test func letterboxRoundTripsAndMatchesUltralytics() {
        let lb = AutoTableKeypointModel.Letterbox(imageWidth: 960, imageHeight: 720)
        #expect(abs(lb.scale - 640.0 / 960) < 1e-12)
        #expect(lb.padX == 0)
        #expect(abs(lb.padY - 80) < 1e-12)
        let p = SIMD2(123.4, 567.8)
        #expect(simd_distance(lb.toImage(lb.toModel(p)), p) < 1e-9)
    }

    /// The model's ten outputs for a scene, in model-input pixels (what Core ML returns), from ground truth.
    /// tablekp labels a flat table texture whose rectangle is the nose lines and warps it with one homography,
    /// so every label lies in a single plane; here that plane is the real nose plane (cloth + noseHeight),
    /// which is exactly the plane the locator lifts all three kinds onto.
    static func modelRows(_ scene: AutoSyntheticScene, camera: simd_double4x4, lb: AutoTableKeypointModel.Letterbox,
                          conf: Double = 0.9) -> [SIMD3<Double>] {
        let L = scene.spec.length, W = scene.spec.width, m = AutoTableProfile().cornerMouthInset
        let h = scene.profile.noseHeight
        let mouths = [(m, m), (L - m, m), (L - m, W - m), (m, W - m)]
        let sides = [(L / 2, 0.0), (L / 2, W)]
        let noses = [(0.0, 0.0), (L, 0), (L, W), (0, W)]
        return (mouths + sides + noses).map { x, y in
            let q = scene.project(scene.world(x, y, h), cameraToWorld: camera)!
            let mq = lb.toModel(q)
            return SIMD3(mq.x, mq.y, conf)
        }
    }

    struct ModelKeypoints: TableKeypointProvider {
        var rows: [SIMD3<Double>]
        var letterbox: AutoTableKeypointModel.Letterbox
        func keypoints(in image: AutoRGBImage, intrinsics: AutoIntrinsics) -> [AutoTableKeypoint] {
            AutoTableKeypointModel.keypoints(rows: rows, letterbox: letterbox)
        }
    }

    @Test func adapterOutputLocatesTheTableAndFitsItsOwnModel() throws {
        let scene = AutoTableLocatorReviewTests.greyScene()  // keypoints only
        let cam = scene.camera(elevationDeg: 45)
        let lb = AutoTableKeypointModel.Letterbox(imageWidth: Double(scene.width), imageHeight: Double(scene.height))
        let rows = Self.modelRows(scene, camera: cam, lb: lb)
        let kps = AutoTableKeypointModel.keypoints(rows: rows, letterbox: lb)
        #expect(kps.count == 10)
        #expect(AutoTableKeypointModel.keypoints(rows: Array(rows.prefix(9)), letterbox: lb).isEmpty)
        var low = rows; low[0].z = 0.1
        #expect(AutoTableKeypointModel.keypoints(rows: low, letterbox: lb).count == 9)

        let locator = ClassicalAutoTableLocator(keypoints: ModelKeypoints(rows: rows, letterbox: lb))
        var last: AutoTableEstimate?
        for i in 0..<20 { last = locator.process(scene.frame(cameraToWorld: cam, seed: UInt64(i), withDepth: false, planeBias: 0)) }
        let e = try #require(last)
        let pose = try #require(e.pose)
        #expect(e.frame.path == .keypointsOnly)
        #expect(AutoTestMetrics.maxCornerError(pose.corners, scene.trueCorners) < 0.01)
        // All ten keypoints (mouths and sides included) agree with the fused pose to sub-pixel.
        let rms = ClassicalAutoTableLocator.keypointRMS(kps, pose: pose, camera: AutoCamera(intrinsics: scene.intrinsics, cameraToWorld: cam),
                                                        profile: AutoTableProfile())
        #expect(rms < 1.0, "keypoint rms \(rms) px")
    }

    struct ScaledKeypoints: TableKeypointProvider {
        var inner: ModelKeypoints
        var spread: Double
        func keypoints(in image: AutoRGBImage, intrinsics: AutoIntrinsics) -> [AutoTableKeypoint] {
            let k = inner.keypoints(in: image, intrinsics: intrinsics)
            let c = k.map(\.pixel).reduce(.zero, +) / Double(max(1, k.count))
            return k.map { var q = $0; q.pixel = c + (q.pixel - c) * SIMD2(spread, 1); return q }
        }
    }

    @Test func keypointOnlyFramesPassTheSameSafetyGates() {
        let scene = AutoTableLocatorReviewTests.greyScene()
        let lb = AutoTableKeypointModel.Letterbox(imageWidth: Double(scene.width), imageHeight: Double(scene.height))
        // Grazing view: exact keypoints, but 9° over the table.
        let flat = scene.camera(elevationDeg: 9)
        let grazing = ClassicalAutoTableLocator(keypoints: ModelKeypoints(rows: Self.modelRows(scene, camera: flat, lb: lb), letterbox: lb))
        var last: AutoTableEstimate?
        for i in 0..<12 { last = grazing.process(scene.frame(cameraToWorld: flat, seed: UInt64(i), withDepth: false, planeBias: 0)) }
        #expect(last?.state != .locked)
        #expect(last?.frame.rejection == "view too shallow")
        // Keypoints stretched sideways: no longer a 2:1 table and/or not explained by any fit.
        let cam = scene.camera(elevationDeg: 45)
        let bad = ScaledKeypoints(inner: ModelKeypoints(rows: Self.modelRows(scene, camera: cam, lb: lb), letterbox: lb), spread: 1.6)
        let locator = ClassicalAutoTableLocator(keypoints: bad)
        for i in 0..<12 { last = locator.process(scene.frame(cameraToWorld: cam, seed: UInt64(i), withDepth: false, planeBias: 0)) }
        #expect(last?.state != .locked)
        #expect(last?.pose == nil)
    }

    @Test func offFrameKeypointsAreNotAWholeTable() {
        // A provider that extrapolates confident nose corners outside the image must not single-view lock.
        let scene = AutoTableLocatorReviewTests.greyScene()
        let cam = scene.camera(elevationDeg: 50, margin: -150)
        let lb = AutoTableKeypointModel.Letterbox(imageWidth: Double(scene.width), imageHeight: Double(scene.height))
        let rows = Self.modelRows(scene, camera: cam, lb: lb)
        let locator = ClassicalAutoTableLocator(keypoints: ModelKeypoints(rows: rows, letterbox: lb))
        var last: AutoTableEstimate?
        for i in 0..<12 { last = locator.process(scene.frame(cameraToWorld: cam, seed: UInt64(i), withDepth: false, planeBias: 0)) }
        #expect(last?.state != .locked)
        #expect(last?.frame.rejection == "keypoint off frame")
    }

    @Test func cornerMouthKeypointsRefineAnEdgeFit() throws {
        let scene = AutoSyntheticScene()
        let cam = scene.camera(elevationDeg: 40)
        let lb = AutoTableKeypointModel.Letterbox(imageWidth: Double(scene.width), imageHeight: Double(scene.height))
        let rows = Self.modelRows(scene, camera: cam, lb: lb)
        let locator = ClassicalAutoTableLocator(keypoints: ModelKeypoints(rows: rows, letterbox: lb))
        var last: AutoTableEstimate?
        for i in 0..<16 { last = locator.process(scene.frame(cameraToWorld: cam, seed: UInt64(40 + i))) }
        let e = try #require(last)
        #expect(e.frame.keypointsUsed == 10)
        #expect(AutoTestMetrics.maxCornerError(try #require(e.pose).corners, scene.trueCorners) < 0.01)
    }
}

import Foundation
import Geometry
import simd
import Testing
@testable import CueCoach

/// Runs `frames` frames of a scene through a fresh locator with handheld motion + tracking noise.
struct AutoRun {
    var estimate: AutoTableEstimate
    var lockedAtFrame: Int?
    var perFrame: [AutoTableEstimate]
}

func autoRun(_ scene: AutoSyntheticScene, elevation: Double, azimuth: Double = 90, frames: Int = 24,
             handheldDeg: Double = 0.4, handheldMetres: Double = 0.02,
             trackingDeg: Double = 0.03, trackingMetres: Double = 0.002,
             withDepth: Bool = true, withPlane: Bool = true, planeBias: Double = 0.012, seed: UInt64 = 11,
             driftMetresPerFrame: SIMD3<Double> = .zero,
             locator: ClassicalAutoTableLocator = ClassicalAutoTableLocator()) -> AutoRun {
    var rng = AutoTestRNG(seed: seed)
    let base = scene.camera(elevationDeg: elevation, azimuthDeg: azimuth)
    var est: AutoTableEstimate?
    var lockedAt: Int?
    var all: [AutoTableEstimate] = []
    for i in 0..<frames {
        let actual = AutoSyntheticScene.perturb(base, rng: &rng, rotDeg: handheldDeg, trans: handheldMetres)
        var reported = AutoSyntheticScene.perturb(actual, rng: &rng, rotDeg: trackingDeg, trans: trackingMetres)
        // Correlated ARKit drift: the reported camera walks steadily away from the true one.
        reported.columns.3 += SIMD4(driftMetresPerFrame * Double(i), 0)
        let f = scene.frame(cameraToWorld: actual, reported: reported, seed: seed &+ UInt64(i), withDepth: withDepth,
                            withPlane: withPlane, planeBias: planeBias, timestamp: Double(seed &+ UInt64(i)) / 30)
        let e = locator.process(f)
        all.append(e)
        if lockedAt == nil, e.state == .locked { lockedAt = i }
        est = e
    }
    return AutoRun(estimate: est!, lockedAtFrame: lockedAt, perFrame: all)
}

@Suite("AutoTableLocator — synthetic scenes")
struct AutoTableLocatorTests {

    // MARK: Accuracy + lock

    @Test func locksAndIsAccurateOnNineFootFromLongSide() throws {
        let scene = AutoSyntheticScene()
        let run = autoRun(scene, elevation: 40)
        let pose = try #require(run.estimate.pose)
        #expect(run.estimate.state == .locked)
        #expect(run.lockedAtFrame != nil && run.lockedAtFrame! <= 20)
        #expect(pose.snappedSize == .nineFoot)
        let err = AutoTestMetrics.maxCornerError(pose.corners, scene.trueCorners)
        print("[autocal] 9ft 40°: max corner error \(err * 1000) mm, reproj \(run.estimate.frame.reprojectionRMS) px, conf \(run.estimate.confidence)")
        #expect(err < 0.01)
        #expect(err < 0.005 * AutoTestMetrics.diagonal(scene.spec))
        #expect(run.estimate.frame.reprojectionRMS < 1.0)
        #expect(run.estimate.confidence > 0.6)
    }

    @Test(arguments: [TableSize.sevenFoot, .eightFoot, .nineFoot])
    func snapsEverySize(_ size: TableSize) throws {
        var scene = AutoSyntheticScene()
        scene.size = size
        let run = autoRun(scene, elevation: 45, frames: 20)
        let pose = try #require(run.estimate.pose)
        #expect(pose.snappedSize == size)
        #expect(abs(pose.spec.length - size.playingLength) < 1e-9)
        #expect(abs(pose.measuredLength - size.playingLength) < 0.03)
        let err = AutoTestMetrics.maxCornerError(pose.corners, scene.trueCorners)
        print("[autocal] \(size) 45°: max corner error \(err * 1000) mm")
        #expect(err < 0.01)
    }

    @Test(arguments: [20.0, 60.0])
    func handlesShallowAndSteepCameras(_ elevation: Double) throws {
        let scene = AutoSyntheticScene()
        let run = autoRun(scene, elevation: elevation, frames: 28)
        let pose = try #require(run.estimate.pose)
        #expect(run.estimate.state == .locked)
        #expect(pose.snappedSize == .nineFoot)
        let err = AutoTestMetrics.maxCornerError(pose.corners, scene.trueCorners)
        print("[autocal] 9ft \(elevation)°: max corner error \(err * 1000) mm, spread \(run.estimate.cornerSpread * 1000) mm")
        #expect(err < 0.01)
        #expect(err < 0.005 * AutoTestMetrics.diagonal(scene.spec))
    }

    @Test func fromTheHeadEndToo() throws {
        let scene = AutoSyntheticScene()
        let run = autoRun(scene, elevation: 35, azimuth: 180)
        let pose = try #require(run.estimate.pose)
        let err = AutoTestMetrics.maxCornerError(pose.corners, scene.trueCorners)
        print("[autocal] 9ft end view 35°: max corner error \(err * 1000) mm")
        #expect(err < 0.01)
    }

    // MARK: Robustness

    @Test func oneCornerOccluded() throws {
        var scene = AutoSyntheticScene()
        let L = scene.spec.length
        // A person standing over the foot-left corner.
        scene.occluders = [(L - 0.15, L + 0.5, -0.5, 0.2, 0, 0.9)]
        let run = autoRun(scene, elevation: 40)
        let pose = try #require(run.estimate.pose)
        let err = AutoTestMetrics.maxCornerError(pose.corners, scene.trueCorners)
        print("[autocal] corner occluded: max corner error \(err * 1000) mm")
        #expect(run.estimate.state == .locked)
        #expect(err < 0.01)
    }

    @Test func personAcrossARail() throws {
        var scene = AutoSyntheticScene()
        // Leaning across the far long rail into the table.
        scene.occluders = [(0.9, 1.35, scene.spec.width - 0.35, scene.spec.width + 0.6, 0.0, 0.7),
                           (1.5, 1.52, 0.3, scene.spec.width + 0.4, 0.05, 0.08)]  // + a cue lying across
        let run = autoRun(scene, elevation: 40)
        let pose = try #require(run.estimate.pose)
        let err = AutoTestMetrics.maxCornerError(pose.corners, scene.trueCorners)
        print("[autocal] person across rail: max corner error \(err * 1000) mm")
        #expect(run.estimate.state == .locked)
        #expect(err < 0.01)
    }

    @Test func strongGlareOverTheRail() throws {
        var scene = AutoSyntheticScene()
        scene.glare = [(Vec2(0.8, 0.15), 0.35, 1.0), (Vec2(1.9, 1.1), 0.3, 1.0)]
        let run = autoRun(scene, elevation: 40)
        let pose = try #require(run.estimate.pose)
        let err = AutoTestMetrics.maxCornerError(pose.corners, scene.trueCorners)
        print("[autocal] strong glare: max corner error \(err * 1000) mm")
        #expect(err < 0.01)
    }

    @Test func blueClothAndNoLiDAR() throws {
        var scene = AutoSyntheticScene()
        scene.feltColor = (30, 70, 150)
        scene.size = .eightFoot
        // Exact ARKit plane: < 1 cm.
        let exact = autoRun(scene, elevation: 45, withDepth: false, planeBias: 0)
        let pose = try #require(exact.estimate.pose)
        #expect(pose.snappedSize == .eightFoot)
        let err = AutoTestMetrics.maxCornerError(pose.corners, scene.trueCorners)
        // ARKit plane 12 mm off and no LiDAR to correct it: the lift shifts every corner along the view rays.
        let biased = autoRun(scene, elevation: 45, withDepth: false, planeBias: 0.012)
        let errB = AutoTestMetrics.maxCornerError(try #require(biased.estimate.pose).corners, scene.trueCorners)
        print("[autocal] blue cloth, no LiDAR: exact plane \(err * 1000) mm, plane 12 mm off \(errB * 1000) mm")
        #expect(err < 0.01)
        #expect(errB < 0.025)
    }

    @Test func lidarRefinesABiasedPlane() throws {
        let scene = AutoSyntheticScene()
        let run = autoRun(scene, elevation: 40, frames: 6)
        let h = try #require(run.estimate.frame.lidarClothHeight)
        #expect(abs(h - scene.clothHeight) < 0.004)
    }

    @Test func noTableNoLock() {
        var scene = AutoSyntheticScene()
        scene.tableCenterXZ = SIMD2(40, 40)  // table far outside the view
        let locator = ClassicalAutoTableLocator()
        let cam = AutoSyntheticScene().camera(elevationDeg: 40)
        for i in 0..<8 {
            let e = locator.process(scene.frame(cameraToWorld: cam, seed: UInt64(i)))
            #expect(e.state == .searching)
            #expect(e.pose == nil)
        }
    }

    // MARK: Orientation, drift, re-lock

    @Test func headIsTheShortRailNearerTheCameraAndFlips() throws {
        let scene = AutoSyntheticScene()
        let locator = ClassicalAutoTableLocator()
        // Camera off the head end (azimuth 180 = −x side, beyond the head rail).
        let run = autoRun(scene, elevation: 40, azimuth: 160, locator: locator)
        let pose = try #require(run.estimate.pose)
        let truth = scene.trueCorners
        // Head-left corner must be the true head-left corner (x = 0), not the foot end.
        #expect(simd_distance(pose.corners[0], truth[0]) < 0.02)
        locator.flipHeadFoot()
        let flipped = try #require(locator.latest?.pose)
        #expect(simd_distance(flipped.corners[0], truth[2]) < 0.02)
        #expect(locator.latest?.generation == run.estimate.generation)
    }

    @Test func relocksWhenTheTableMoves() throws {
        var scene = AutoSyntheticScene()
        let locator = ClassicalAutoTableLocator()
        let first = autoRun(scene, elevation: 40, frames: 20, locator: locator)
        #expect(first.estimate.state == .locked)
        let gen = first.estimate.generation
        // Tracking re-anchors: the whole table appears 8 cm away.
        scene.tableCenterXZ += SIMD2(0.08, 0.0)
        let second = autoRun(scene, elevation: 40, frames: 40, seed: 99, locator: locator)
        let pose = try #require(second.estimate.pose)
        #expect(second.estimate.state == .locked)
        #expect(second.estimate.generation > gen)
        let err = AutoTestMetrics.maxCornerError(pose.corners, scene.trueCorners)
        print("[autocal] re-lock after 8 cm shift: max corner error \(err * 1000) mm")
        #expect(err < 0.01)
    }

    @Test func survivesASingleGarbageFrame() throws {
        let scene = AutoSyntheticScene()
        let locator = ClassicalAutoTableLocator()
        let first = autoRun(scene, elevation: 40, frames: 20, locator: locator)
        let gen = first.estimate.generation
        // Wildly wrong pose for one frame (tracking glitch).
        let cam = scene.camera(elevationDeg: 40)
        var bad = cam; bad.columns.3 += SIMD4(0.5, 0, 0.3, 0)
        _ = locator.process(scene.frame(cameraToWorld: cam, reported: bad, seed: 500))
        let after = autoRun(scene, elevation: 40, frames: 3, seed: 501, locator: locator)
        #expect(after.estimate.state == .locked)
        #expect(after.estimate.generation == gen)
    }

    // MARK: Keypoint plug-in

    struct OracleKeypoints: TableKeypointProvider {
        var scene: AutoSyntheticScene
        var camera: simd_double4x4
        func keypoints(in image: AutoRGBImage, intrinsics: AutoIntrinsics) -> [AutoTableKeypoint] {
            scene.trueCorners.compactMap { p in
                let q = scene.project(p + SIMD3(0, scene.profile.noseHeight, 0), cameraToWorld: camera)
                return q.map { AutoTableKeypoint(kind: .noseCorner, pixel: $0, confidence: 0.9) }
            }
        }
    }

    @Test func keypointProviderAloneCanLocateTheTable() throws {
        var scene = AutoSyntheticScene()
        scene.feltColor = (120, 120, 120)  // grey cloth: segmentation has nothing to grab
        scene.floorColor = (120, 120, 120)
        let cam = scene.camera(elevationDeg: 45)
        let locator = ClassicalAutoTableLocator(keypoints: OracleKeypoints(scene: scene, camera: cam))
        var last: AutoTableEstimate?
        for i in 0..<20 { last = locator.process(scene.frame(cameraToWorld: cam, seed: UInt64(i), withDepth: false, planeBias: 0)) }
        let e = try #require(last)
        let pose = try #require(e.pose)
        #expect(e.frame.keypointsUsed >= 4)
        #expect(AutoTestMetrics.maxCornerError(pose.corners, scene.trueCorners) < 0.01)
    }

    // MARK: Pocket evidence

    @Test func pocketEvidenceSeesAllSixPockets() throws {
        let scene = AutoSyntheticScene()
        let run = autoRun(scene, elevation: 50, frames: 4)
        let scores = run.estimate.frame.pocketScores
        #expect(scores.count == 6)
        for p in Pocket.allCases { #expect((scores[p] ?? 0) > 0.5, "pocket \(p) score \(scores[p] ?? -1)") }
    }

    // MARK: Perf

    @Test func perFrameTimeAtHalfResolution() throws {
        let scene = AutoSyntheticScene()
        let cam = scene.camera(elevationDeg: 40)
        let frames = (0..<20).map { scene.frame(cameraToWorld: cam, seed: UInt64($0)) }
        func timed(_ l: ClassicalAutoTableLocator, _ f: AutoTableFrame) -> (Double, AutoFrameDiagnostics.Path) {
            let t0 = Date()
            let e = l.process(f)
            return (Date().timeIntervalSince(t0), e.frame.path)
        }
        // Full search: a fresh locator every frame (no prior).
        var full: [Double] = []
        for f in frames.prefix(6) {
            let (dt, path) = timed(ClassicalAutoTableLocator(), f)
            #expect(path == .full)
            full.append(dt)
        }
        // Tracked: one locator, frames after the first.
        let locator = ClassicalAutoTableLocator()
        var tracked: [Double] = []
        for f in frames {
            let (dt, path) = timed(locator, f)
            if path == .tracked { tracked.append(dt) }
        }
        func med(_ a: [Double]) -> Double { a.isEmpty ? .nan : a.sorted()[a.count / 2] }
        print("[autocal] perf 960×720: full-search median \(med(full) * 1000) ms, tracked median \(med(tracked) * 1000) ms (n=\(tracked.count))")
        #expect(tracked.count >= 18)
        #if DEBUG
        // Unoptimised (-Onone) test build: regression guard only. The < 8 ms target is asserted in the
        // optimised run: xcodebuild test -configuration Release ENABLE_TESTABILITY=YES …
        #expect(med(full) < 0.4)
        #expect(med(tracked) < 0.1)
        #else
        #expect(med(full) < 0.008)
        #expect(med(tracked) < 0.008)
        #endif
    }
}

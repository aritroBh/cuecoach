import Foundation
import Geometry
import simd
import Testing
@testable import CueCoach

/// Lock plan steps 1, 2, 3, 7 (capture side). Auto's own accuracy is covered by Calibration/Auto tests and the
/// VirtualTable matrix gate.
struct LockPlanTests {
    @Test func autoRejectionsMapToUserReasons() {
        #expect(LockFailure.from(autoRejection: "cloth touches frame") == .partialTable)
        #expect(LockFailure.from(autoRejection: "cloth too small") == .tooFar)
        #expect(LockFailure.from(autoRejection: "too small") == .tooFar)
        #expect(LockFailure.from(autoRejection: "no plane") == .noPlane)
        #expect(LockFailure.from(autoRejection: "no cloth colour") == .noFelt)
        for r in ["no rails", "parallel rails", "reprojection", "no quad", "edge refine", "fit", "not a rectangle"] {
            #expect(LockFailure.from(autoRejection: r) == .badShape)
        }
    }

    /// Step 2: FrameTap locates at ~15 Hz; the busy flag is still the load bound.
    @Test func locatingGateRunsAt15HzAndRespectsBusy() {
        var g = LocatingGate()
        var admitted: [Int] = []
        for i in 0..<120 where g.offer(timestamp: 100 + Double(i) / 60, busy: false) { admitted.append(i) }
        let gaps = Set(zip(admitted.dropFirst(), admitted).map { $0 - $1 })
        #expect(gaps == [4])   // 60 fps / 4 = 15 Hz
        var b = LocatingGate()
        let first = b.offer(timestamp: 0, busy: false)
        let whileBusy = b.offer(timestamp: 1, busy: true)
        #expect(first && !whileBusy)
    }

    /// Step 3: no extent test — an infinite plane at the anchor's height; the floor is never the table.
    @Test func smallEarlyAnchorStillGivesTheTablePlane() throws {
        let cam = SyntheticRig.camera()
        let tiny = LocatorPlane(center: SIMD3(0.9, 0.75, -0.9), extent: SIMD2(0.1, 0.1), isTable: false)
        let p = try #require(LocatorMath.plane(for: Vec2(960, 540), camera: cam, planes: [tiny]))
        #expect(abs(p.point.y - 0.75) < 1e-9)
    }

    @Test func floorIsRejectedEvenAsTheOnlyPlane() {
        let cam = SyntheticRig.camera()   // ~1.95 m above the floor
        let floor = LocatorPlane(center: SIMD3(0, 0, 0), extent: SIMD2(8, 8), isTable: false)
        #expect(LocatorMath.plane(for: Vec2(960, 540), camera: cam, planes: [floor]) == nil)
    }

    @Test func lidarLevelFarBelowTheCameraIsTheFloor() {
        var scene = SyntheticTableScene.demo()
        let cloth = scene.renderDepth()
        #expect(!LocatorMath.depthLevelIsFloor(cloth, camera: scene.camera))
        // Same camera looking at the floor 2 m below.
        scene.camera = CameraModel.lookAt(eye: SIMD3(3, 2.0, 3), target: SIMD3(3.5, 0, 2), intrinsics: scene.camera.intrinsics)
        var floorScene = scene
        floorScene.balls = []
        let floorDepth = DepthMap(width: 64, height: 48, depth: (0..<(64 * 48)).map { i in
            let x = i % 64, y = i / 64
            let k = scene.camera.intrinsics.scaled(toWidth: 64, height: 48)
            var cam = scene.camera; cam.intrinsics = k
            let r = cam.ray(through: Vec2(Double(x) + 0.5, Double(y) + 0.5))
            guard let hit = Plane3(point: .zero, normal: SIMD3(0, 1, 0)).intersect(origin: r.origin, direction: r.direction) else { return 0 }
            return Float(-(cam.worldToCamera * SIMD4(hit, 1)).z)
        }, confidence: nil)
        #expect(LocatorMath.depthLevelIsFloor(floorDepth, camera: scene.camera))
    }

    /// Step 7: fallback after ~4 s unlocked, or the same failure for 2.5 s — with or without a plane.
    @Test func fallbackPolicy() {
        #expect(!FallbackPolicy.offer(unlockedFor: 2, sameFailureFor: 1))
        #expect(FallbackPolicy.offer(unlockedFor: 4.2, sameFailureFor: 0))
        #expect(FallbackPolicy.offer(unlockedFor: 3, sameFailureFor: 2.6))
        #expect(!FallbackPolicy.offer(unlockedFor: nil, sameFailureFor: nil))
    }

    @Test func failureTimerTracksTheSameReason() {
        var t = FailureTimer()
        t.note(.tooFar, at: 0)
        t.note(.tooFar, at: 2)
        #expect(t.sameFor(at: 2) == 2)
        t.note(.noFelt, at: 2.5)
        #expect(t.sameFor(at: 3) == 0.5)
        t.note(nil, at: 4)
        #expect(t.sameFor(at: 5) == nil)
    }

    /// Step 7: drags snap to a nearby candidate corner (rails/pockets from the locator) within the radius.
    @Test func dragSnapsToNearbyCandidate() {
        let targets = [CGPoint(x: 100, y: 100), CGPoint(x: 400, y: 120)]
        #expect(DragSnap.snap(CGPoint(x: 112, y: 95), to: targets, radius: 36) == CGPoint(x: 100, y: 100))
        #expect(DragSnap.snap(CGPoint(x: 200, y: 200), to: targets, radius: 36) == nil)
    }

    /// Step 1: the adapter locks on a synthetic table with LiDAR depth and returns Auto's exact pose.
    @Test func adapterLocksOnSyntheticTableWithDepth() async throws {
        let scene = SyntheticTableScene.demo()
        let cg = try #require(scene.render())
        let img = try #require(PixelImage(cgImage: cg))
        let depth = scene.renderDepth(width: 256, height: 144)
        let s = scene.frame.spec
        let plane = LocatorPlane(center: scene.frame.world(Vec2(s.length / 2, s.width / 2)), extent: SIMD2(1, 0.6), isTable: true)
        let loc = AutoTableLocating()
        var last: TableEstimate?
        var i = 0
        while i < 60 && last?.locked != true {
            last = await loc.ingest(LocatorFrame(image: img, camera: scene.camera, planes: [plane], timestamp: Double(i) / 15,
                                                 depth: depth))
            i += 1
        }
        let e = try #require(last)
        #expect(e.locked, "failure \(String(describing: e.failure)) after \(i) frames")
        let truth = scene.frame.corners.map { scene.frame.world($0) }
        for c in e.corners { #expect(truth.map { simd_distance($0, c) }.min()! < 0.05) }
        #expect(e.frame != nil)
    }

    @Test func adapterExpiresHistoryAfterAGap() async throws {
        let scene = SyntheticTableScene.demo()
        let cg = try #require(scene.render())
        let img = try #require(PixelImage(cgImage: cg))
        let depth = scene.renderDepth(width: 256, height: 144)
        let loc = AutoTableLocating()
        for i in 0..<3 { _ = await loc.ingest(LocatorFrame(image: img, camera: scene.camera, planes: [], timestamp: Double(i) / 15, depth: depth)) }
        let afterGap = await loc.ingest(LocatorFrame(image: img, camera: scene.camera, planes: [], timestamp: 5, depth: depth))
        #expect(afterGap?.locked != true)
    }
}

import Foundation
import Geometry
import simd
import Testing
@testable import CueCoach

/// Synthetic scene shared by calibration/perception tests: a 7 ft table on the world plane y = 0.75
/// (ARKit world: y up), viewed from behind the head end, elevated.
enum SyntheticRig {
    static let k = CameraIntrinsics(fx: 1500, fy: 1500, cx: 960, cy: 540, width: 1920, height: 1080)
    static let tableHeight = 0.75

    /// Table frame: head at world z = +L/2 (near the camera), foot at z = −L/2; x across.
    static func frame(_ size: TableSize = .sevenFoot) -> TableFrame {
        let spec = TableSpec(size: size)
        // table x (length) → world −z, table y (width) → world −x... keep right-handed with up = +y:
        let xAxis = SIMD3<Double>(0, 0, -1), up = SIMD3<Double>(0, 1, 0)
        let yAxis = simd_cross(up, xAxis)
        let origin = SIMD3<Double>(0, tableHeight, 0) - xAxis * (spec.length / 2) - yAxis * (spec.width / 2)
        return TableFrame(tableToWorld: simd_double4x4(columns: (SIMD4(xAxis, 0), SIMD4(yAxis, 0), SIMD4(up, 0),
                                                                 SIMD4(origin, 1))), spec: spec)
    }

    static func camera(eye: SIMD3<Double> = SIMD3(0.15, 1.95, 2.1)) -> CameraModel {
        CameraModel.lookAt(eye: eye, target: SIMD3(0, tableHeight, -0.1), intrinsics: k)
    }
}

struct HomographyTests {
    @Test func exactFourPointRecovery() throws {
        let truth = Homography(rowMajor: [1.2, 0.1, 30, -0.05, 0.9, 12, 0.0004, 0.0002, 1])
        let src = [Vec2(0, 0), Vec2(100, 0), Vec2(100, 60), Vec2(0, 60)]
        let dst = src.compactMap { truth.apply($0) }
        let h = try #require(Homography.estimate(from: src, to: dst))
        for p in [Vec2(50, 30), Vec2(10, 55), Vec2(-20, 80)] {
            let a = try #require(h.apply(p)), b = try #require(truth.apply(p))
            #expect(a.distance(to: b) < 1e-6)
        }
    }

    @Test func leastSquaresWithNoise() throws {
        let cam = SyntheticRig.camera(), frame = SyntheticRig.frame()
        let truth = frame.homography(camera: cam, height: 0)
        var rng = SplitMix(seed: 7)
        var src: [Vec2] = [], dst: [Vec2] = []
        for i in 0..<30 {
            let p = Vec2(Double(i % 6) / 5 * frame.spec.length, Double(i / 6) / 4 * frame.spec.width)
            src.append(p)
            dst.append(truth.apply(p)! + Vec2(rng.gauss() * 0.5, rng.gauss() * 0.5))
        }
        let h = try #require(Homography.estimate(from: src, to: dst))
        #expect(h.rmsError(from: src, to: dst) < 1.0)
        let mid = Vec2(frame.spec.length / 2, frame.spec.width / 2)
        #expect(h.apply(mid)!.distance(to: truth.apply(mid)!) < 1.0)
    }

    @Test func degenerateInputIsRejected() {
        let line = [Vec2(0, 0), Vec2(1, 1), Vec2(2, 2), Vec2(3, 3)]
        #expect(Homography.estimate(from: line, to: line) == nil)
        #expect(Homography.estimate(from: [Vec2(0, 0)], to: [Vec2(0, 0)]) == nil)
    }

    @Test func inverseRoundTrips() throws {
        let h = SyntheticRig.frame().homography(camera: SyntheticRig.camera(), height: 0)
        let p = Vec2(0.7, 0.3)
        let img = try #require(h.apply(p))
        let back = try #require(h.inverse.apply(img))
        #expect(back.distance(to: p) < 1e-9)
    }
}

struct CameraModelTests {
    @Test func projectAndRayAreInverse() throws {
        let cam = SyntheticRig.camera()
        let plane = SyntheticRig.frame().plane
        let w = SIMD3<Double>(0.2, SyntheticRig.tableHeight, -0.4)
        let px = try #require(cam.project(w))
        #expect(px.x > 0 && px.x < 1920 && px.y > 0 && px.y < 1080)
        let hit = try #require(cam.intersect(pixel: px, with: plane))
        #expect(simd_distance(hit, w) < 1e-9)
    }

    @Test func pointsBehindCameraDoNotProject() {
        let cam = SyntheticRig.camera()
        let behind = cam.position + simd_normalize(cam.position - SIMD3(0, 0.75, -0.1)) * 2
        #expect(cam.project(behind) == nil)
    }

    @Test func poseHomographyMatchesProjection() throws {
        let cam = SyntheticRig.camera(), frame = SyntheticRig.frame()
        let h = frame.homography(camera: cam, height: TableSpec.ballRadius)
        let p = Vec2(1.3, 0.21)
        let a = try #require(h.apply(p))
        let b = try #require(cam.project(frame.world(p, height: TableSpec.ballRadius)))
        #expect(a.distance(to: b) < 1e-6)
    }

    @Test func farTableCornersAreSmallerThanNear() {
        let geo = FrameGeometry(frame: SyntheticRig.frame(), camera: SyntheticRig.camera())
        let s = geo.spec
        let near = geo.ball.maxScale(at: Vec2(0.1, s.width / 2))
        let far = geo.ball.maxScale(at: Vec2(s.length - 0.1, s.width / 2))
        #expect(near > far * 1.3)
    }
}

struct PlaneOffsetTests {
    /// SPEC §5.1: cloth homography misplaces ball centres; the ball-plane homography recovers them.
    @Test func ballPlaneFromImageOnlyCalibration() throws {
        let cam = SyntheticRig.camera(), frame = SyntheticRig.frame()
        let spec = frame.spec
        let cornersPx = frame.corners.map { frame.homography(camera: cam, height: 0).apply($0)! }
        let geo = try #require(ImageCalibration.geometry(imageCorners: cornersPx.shuffledDeterministic(),
                                                          spec: spec, intrinsics: SyntheticRig.k))
        for p in [Vec2(1.5, 0.3), Vec2(0.4, 0.8), Vec2(1.9, 0.9)] {
            let ballPx = try #require(cam.project(frame.world(p, height: TableSpec.ballRadius)))
            let viaBall = try #require(geo.ballInverse.apply(ballPx))
            let viaCloth = try #require(geo.clothInverse.apply(ballPx))
            // Up to the rectangle's symmetries (image-only calibration can't tell head from foot or left from right).
            let sym = [p, Vec2(spec.length - p.x, spec.width - p.y), Vec2(spec.length - p.x, p.y), Vec2(p.x, spec.width - p.y)]
            let errBall = sym.map { viaBall.distance(to: $0) }.min()!
            let errCloth = sym.map { viaCloth.distance(to: $0) }.min()!
            #expect(errBall < 0.004, "ball-plane error \(errBall)")
            #expect(errCloth > 0.01, "cloth plane should be biased, got \(errCloth)")
        }
    }

    @Test func cornerOrderingPutsSidePocketsOnLongRails() throws {
        let cam = SyntheticRig.camera(eye: SIMD3(1.6, 1.8, 1.4)), frame = SyntheticRig.frame(.nineFoot)
        let cloth = frame.homography(camera: cam, height: 0)
        let px = frame.corners.map { cloth.apply($0)! }
        let geo = try #require(ImageCalibration.geometry(imageCorners: [px[2], px[0], px[3], px[1]],
                                                          spec: frame.spec, intrinsics: SyntheticRig.k))
        let side = try #require(geo.cloth.apply(Vec2(frame.spec.length / 2, 0)))
        let truthSides = [Pocket.sideLeft, .sideRight].map { cloth.apply(frame.spec.pocketCenter($0))! }
        #expect(truthSides.map { $0.distance(to: side) }.min()! < 2)
    }

    @Test func cornerOrderingToleratesNoisyTaps() throws {
        let cam = SyntheticRig.camera(), frame = SyntheticRig.frame()
        let cloth = frame.homography(camera: cam, height: 0)
        var rng = SplitMix(seed: 3)
        let px = frame.corners.map { cloth.apply($0)! + Vec2(rng.gauss() * 4, rng.gauss() * 4) }
        let geo = try #require(ImageCalibration.geometry(imageCorners: px, spec: frame.spec,
                                                          intrinsics: SyntheticRig.k))
        let side = try #require(geo.cloth.apply(Vec2(frame.spec.length / 2, 0)))
        let truthSides = [Pocket.sideLeft, .sideRight].map { cloth.apply(frame.spec.pocketCenter($0))! }
        #expect(truthSides.map { $0.distance(to: side) }.min()! < 15)
    }
}

struct TableFitTests {
    @Test func fitsFrameFromShuffledWorldCorners() throws {
        let truth = SyntheticRig.frame(.eightFoot)
        let world = truth.corners.map { truth.world($0) }
        let fit = try #require(TableFitter.fit(corners: [world[3], world[1], world[0], world[2]],
                                               viewer: SyntheticRig.camera().position))
        #expect(fit.sizing.size == .eightFoot)
        #expect(abs(fit.measuredLength - truth.spec.length) < 1e-6)
        #expect(fit.residual < 1e-6)
        // Head is the end nearest the camera.
        let head = fit.frame.world(Vec2(0, truth.spec.width / 2))
        #expect(simd_distance(head, truth.world(Vec2(0, truth.spec.width / 2))) < 1e-6)
        // Right-handed with z = up.
        let up = fit.frame.tableToWorld.columns.2
        #expect(abs(up.y - 1) < 1e-9)
    }

    @Test func measurementSnapsToPresets() {
        #expect(TableSizing.snap(length: 2.03, width: 1.01).size == .sevenFoot)
        #expect(TableSizing.snap(length: 2.36, width: 1.15).size == .eightFoot)
        #expect(TableSizing.snap(length: 2.52, width: 1.28).size == .nineFoot)
        #expect(TableSizing.snap(length: 2.52, width: 1.28).confident)
        // A 76" bar box still snaps to 7 ft, within tolerance.
        let bar = TableSizing.snap(length: 76 * 0.0254, width: 38 * 0.0254)
        #expect(bar.size == .sevenFoot && bar.confident)
        #expect(!TableSizing.snap(length: 3.4, width: 1.7).confident)
    }

    @Test func noisyCornersStillSnap() throws {
        let truth = SyntheticRig.frame(.nineFoot)
        var rng = SplitMix(seed: 11)
        let world = truth.corners.map { truth.world($0) + SIMD3(rng.gauss() * 0.02, 0, rng.gauss() * 0.02) }
        let fit = try #require(TableFitter.fit(corners: world))
        #expect(fit.sizing.size == .nineFoot)
    }

    @Test func insetRemovesCushionWidth() {
        let truth = SyntheticRig.frame()
        let outer = [Vec2(-0.05, -0.05), Vec2(-0.05, truth.spec.width + 0.05),
                     Vec2(truth.spec.length + 0.05, truth.spec.width + 0.05), Vec2(truth.spec.length + 0.05, -0.05)]
            .map { truth.world($0) }
        let inner = TableFitter.insetQuad(outer, by: 0.05)
        for (a, b) in zip(inner, truth.corners.map { truth.world($0) }) { #expect(simd_distance(a, b) < 1e-6) }
    }

    @Test func lidarPlaneFitRejectsBallsAndNoise() throws {
        var rng = SplitMix(seed: 5)
        var pts: [SIMD3<Double>] = []
        for i in 0..<400 {
            let x = Double(i % 20) / 20 - 0.5, z = Double(i / 20) / 20 - 0.5
            var y = 0.78 + rng.gauss() * 0.004
            if i % 9 == 0 { y += 0.05 }  // balls, a hand
            pts.append(SIMD3(x, y, z))
        }
        let plane = try #require(PlaneFit.fit(pts))
        #expect(abs(plane.point.y - 0.78) < 0.003)
        #expect(plane.normal.y > 0.999)
    }
}

/// Deterministic RNG for tests.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func uniform() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func gauss() -> Double {
        let u = max(1e-12, uniform()), v = uniform()
        return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
    }
}

extension Array {
    func shuffledDeterministic() -> [Element] {
        guard count == 4 else { return self }
        return [self[2], self[0], self[3], self[1]]
    }
}

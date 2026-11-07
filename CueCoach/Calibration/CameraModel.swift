import Foundation
import Geometry
import simd

/// Pinhole intrinsics in pixels of a specific image resolution.
struct CameraIntrinsics: Hashable, Codable, Sendable {
    var fx: Double, fy: Double, cx: Double, cy: Double
    var width: Double, height: Double

    /// From a horizontal field of view across the image's long side (AVFoundation `videoFieldOfView`).
    static func fromFieldOfView(degrees: Double, width: Double, height: Double) -> CameraIntrinsics {
        let f = (max(width, height) / 2) / tan(degrees * .pi / 360)
        return CameraIntrinsics(fx: f, fy: f, cx: width / 2, cy: height / 2, width: width, height: height)
    }

    /// Same camera at a different resolution (e.g. high-res still vs streaming frame).
    func scaled(toWidth w: Double, height h: Double) -> CameraIntrinsics {
        let sx = w / width, sy = h / height
        return CameraIntrinsics(fx: fx * sx, fy: fy * sy, cx: cx * sx, cy: cy * sy, width: w, height: h)
    }
}

/// Infinite plane in world space.
struct Plane3: Hashable, Sendable {
    var point: SIMD3<Double>
    var normal: SIMD3<Double>  // unit, pointing "up" (toward the camera side)

    func intersect(origin: SIMD3<Double>, direction: SIMD3<Double>) -> SIMD3<Double>? {
        let denom = simd_dot(normal, direction)
        guard abs(denom) > 1e-9 else { return nil }
        let t = simd_dot(normal, point - origin) / denom
        guard t > 0 else { return nil }
        return origin + direction * t
    }
}

/// Camera with ARKit conventions: camera space x right, y up, z backward (looks down −z),
/// relative to the image's native (sensor/landscape) orientation; pixel v grows downward.
struct CameraModel: Sendable {
    var intrinsics: CameraIntrinsics
    var cameraToWorld: simd_double4x4

    var worldToCamera: simd_double4x4 { cameraToWorld.inverse }
    var position: SIMD3<Double> { SIMD3(cameraToWorld.columns.3.x, cameraToWorld.columns.3.y, cameraToWorld.columns.3.z) }

    /// Pixel of a world point; nil if behind the camera.
    func project(_ p: SIMD3<Double>) -> Vec2? {
        let c = worldToCamera * SIMD4(p, 1)
        guard c.z < -1e-6 else { return nil }
        let k = intrinsics
        return Vec2(k.fx * c.x / -c.z + k.cx, k.fy * -c.y / -c.z + k.cy)
    }

    /// World-space ray through a pixel.
    func ray(through px: Vec2) -> (origin: SIMD3<Double>, direction: SIMD3<Double>) {
        let k = intrinsics
        let dc = SIMD4((px.x - k.cx) / k.fx, -(px.y - k.cy) / k.fy, -1, 0)
        let dw = cameraToWorld * dc
        return (position, simd_normalize(SIMD3(dw.x, dw.y, dw.z)))
    }

    func intersect(pixel: Vec2, with plane: Plane3) -> SIMD3<Double>? {
        let r = ray(through: pixel)
        return plane.intersect(origin: r.origin, direction: r.direction)
    }

    /// A camera at `eye` looking at `target`, world up +y (ARKit world is gravity-aligned, y up).
    static func lookAt(eye: SIMD3<Double>, target: SIMD3<Double>, up: SIMD3<Double> = SIMD3(0, 1, 0),
                       intrinsics: CameraIntrinsics) -> CameraModel {
        let back = simd_normalize(eye - target)          // camera +z
        let right = simd_normalize(simd_cross(up, back)) // camera +x
        let camUp = simd_cross(back, right)              // camera +y
        let m = simd_double4x4(columns: (SIMD4(right, 0), SIMD4(camUp, 0), SIMD4(back, 0), SIMD4(eye, 1)))
        return CameraModel(intrinsics: intrinsics, cameraToWorld: m)
    }
}

/// The calibrated table: a rigid frame in world space. Table coords (Geometry): x along the length
/// (head x = 0 → foot x = length), y across, z up from the cloth. Units metres.
struct TableFrame: Sendable {
    var tableToWorld: simd_double4x4
    var spec: TableSpec

    func world(_ p: Vec2, height: Double = 0) -> SIMD3<Double> {
        let w = tableToWorld * SIMD4(p.x, p.y, height, 1)
        return SIMD3(w.x, w.y, w.z)
    }

    func table(_ w: SIMD3<Double>) -> (point: Vec2, height: Double) {
        let t = tableToWorld.inverse * SIMD4(w, 1)
        return (Vec2(t.x, t.y), t.z)
    }

    var plane: Plane3 {
        Plane3(point: world(.zero), normal: simd_normalize(SIMD3(tableToWorld.columns.2.x, tableToWorld.columns.2.y,
                                                                tableToWorld.columns.2.z)))
    }

    /// Cloth corners in Geometry pocket order: headLeft, headRight, footRight, footLeft.
    var corners: [Vec2] { [Vec2(0, 0), Vec2(0, spec.width), Vec2(spec.length, spec.width), Vec2(spec.length, 0)] }

    /// table plane at height `h` → image homography for this camera.
    func homography(camera: CameraModel, height h: Double) -> Homography {
        let k = camera.intrinsics
        let kk = simd_double3x3(rows: [SIMD3(k.fx, 0, k.cx), SIMD3(0, k.fy, k.cy), SIMD3(0, 0, 1)])
        let tc = camera.worldToCamera * tableToWorld
        // ARKit camera → CV camera (y down, z forward).
        func cv(_ v: SIMD4<Double>) -> SIMD3<Double> { SIMD3(v.x, -v.y, -v.z) }
        let c1 = cv(tc.columns.0), c2 = cv(tc.columns.1)
        let c3 = cv(tc.columns.3) + cv(tc.columns.2) * h
        return Homography(kk * simd_double3x3(columns: (c1, c2, c3)))
    }
}

/// Per-frame table↔image mapping used by perception and the 2D overlay.
struct FrameGeometry: Sendable {
    /// Table (cloth plane, z = 0) → image pixels.
    var cloth: Homography
    /// Table (ball-centre plane, z = R) → image pixels. SPEC §5.1 plane offset.
    var ball: Homography
    var spec: TableSpec

    var clothInverse: Homography { cloth.inverse }
    var ballInverse: Homography { ball.inverse }

    init(cloth: Homography, ball: Homography, spec: TableSpec) {
        self.cloth = cloth; self.ball = ball; self.spec = spec
    }

    init(frame: TableFrame, camera: CameraModel) {
        self.init(cloth: frame.homography(camera: camera, height: 0),
                  ball: frame.homography(camera: camera, height: TableSpec.ballRadius), spec: frame.spec)
    }
}

extension simd_float4x4 {
    var toDouble: simd_double4x4 {
        func c(_ v: SIMD4<Float>) -> SIMD4<Double> { SIMD4(Double(v.x), Double(v.y), Double(v.z), Double(v.w)) }
        return simd_double4x4(columns: (c(columns.0), c(columns.1), c(columns.2), c(columns.3)))
    }
}

extension simd_double4x4 {
    var toFloat: simd_float4x4 {
        func c(_ v: SIMD4<Double>) -> SIMD4<Float> { SIMD4(Float(v.x), Float(v.y), Float(v.z), Float(v.w)) }
        return simd_float4x4(columns: (c(columns.0), c(columns.1), c(columns.2), c(columns.3)))
    }
}

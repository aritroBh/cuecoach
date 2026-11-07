import CoreGraphics
import Foundation
import Geometry
import simd

/// Renders a perspective photo-like pool table with CoreGraphics. Used by unit tests and by the
/// simulator replay (`-cuecoach.replay synthetic`), since the simulator has no camera or ARKit.
struct SyntheticTableScene: Sendable {
    struct Ball: Sendable {
        var position: Vec2
        var color: (UInt8, UInt8, UInt8)
        var stripe: Bool = false
    }

    static let cushionWidth = 0.05
    static let felt: (UInt8, UInt8, UInt8) = (24, 112, 74)
    static let cushionFelt: (UInt8, UInt8, UInt8) = (20, 100, 66)

    /// A cue stick lying over the cloth at ball-centre height: tip point, direction toward the ball, length.
    struct Stick: Sendable { var tip: Vec2; var direction: Vec2; var length: Double = 1.0 }

    var frame: TableFrame
    var camera: CameraModel
    var balls: [Ball]
    var stick: Stick? = nil

    var plane: Plane3 { frame.plane }

    /// Default demo: 7 ft table on a y = 0.76 m top, camera behind the head end, a few balls.
    static func demo() -> SyntheticTableScene {
        let spec = TableSpec(size: .sevenFoot)
        let up = SIMD3<Double>(0, 1, 0), xAxis = SIMD3<Double>(0, 0, -1)
        let yAxis = simd_cross(up, xAxis)
        let origin = SIMD3<Double>(0, 0.76, 0) - xAxis * (spec.length / 2) - yAxis * (spec.width / 2)
        let frame = TableFrame(tableToWorld: simd_double4x4(columns: (SIMD4(xAxis, 0), SIMD4(yAxis, 0), SIMD4(up, 0),
                                                                      SIMD4(origin, 1))), spec: spec)
        let k = CameraIntrinsics(fx: 1500, fy: 1500, cx: 960, cy: 540, width: 1920, height: 1080)
        let cam = CameraModel.lookAt(eye: SIMD3(0.1, 2.15, 2.45), target: SIMD3(0, 0.76, -0.25), intrinsics: k)
        let L = spec.length, W = spec.width
        let balls: [Ball] = [
            Ball(position: Vec2(0.45, W * 0.45), color: (240, 240, 236)),               // cue
            Ball(position: Vec2(L * 0.62, W * 0.40), color: (200, 32, 30)),             // 3 red
            Ball(position: Vec2(L * 0.75, W * 0.70), color: (18, 18, 20)),              // 8
            Ball(position: Vec2(L * 0.50, W * 0.80), color: (236, 200, 30), stripe: true), // 9
            Ball(position: Vec2(L * 0.85, W * 0.25), color: (30, 60, 190)),             // 2 blue
            Ball(position: Vec2(L * 0.30, W * 0.20), color: (240, 120, 20)),            // 5 orange
        ]
        return SyntheticTableScene(frame: frame, camera: cam, balls: balls)
    }

    /// Ground-truth image point of a ball centre.
    func imagePoint(_ b: Ball) -> Vec2? { camera.project(frame.world(b.position, height: TableSpec.ballRadius)) }

    /// Synthetic LiDAR: ray-cast the cloth plane and ball spheres at a low resolution (like ARKit's 256×192).
    func renderDepth(width: Int = 256, height: Int = 144, noise: Double = 0, seed: UInt64 = 1) -> DepthMap {
        let k = camera.intrinsics.scaled(toWidth: Double(width), height: Double(height))
        var cam = camera
        cam.intrinsics = k
        let plane = frame.plane
        let R = TableSpec.ballRadius
        let centres = balls.map { frame.world($0.position, height: R) }
        var state = seed
        func gauss() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let u = max(1e-12, Double(state >> 11) / Double(1 << 53))
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let v = Double(state >> 11) / Double(1 << 53)
            return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
        }
        var out = [Float](repeating: 0, count: width * height)
        let w2c = camera.worldToCamera
        for y in 0..<height {
            for x in 0..<width {
                let ray = cam.ray(through: Vec2(Double(x) + 0.5, Double(y) + 0.5))
                var best = plane.intersect(origin: ray.origin, direction: ray.direction)
                var bestT = best.map { simd_distance($0, ray.origin) } ?? .infinity
                for c in centres {
                    let f = ray.origin - c
                    let b = simd_dot(f, ray.direction), cc = simd_dot(f, f) - R * R
                    let disc = b * b - cc
                    guard disc >= 0 else { continue }
                    let t = -b - disc.squareRoot()
                    if t > 0 && t < bestT { bestT = t; best = ray.origin + ray.direction * t }
                }
                guard let p = best else { continue }
                let pc = w2c * SIMD4(p, 1)
                out[y * width + x] = Float(-pc.z + noise * gauss())
            }
        }
        return DepthMap(width: width, height: height, depth: out, confidence: nil)
    }

    func render() -> CGImage? {
        let W = Int(camera.intrinsics.width), H = Int(camera.intrinsics.height)
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        // Image coordinates: origin top-left, y down.
        ctx.translateBy(x: 0, y: CGFloat(H)); ctx.scaleBy(x: 1, y: -1)
        func color(_ c: (UInt8, UInt8, UInt8)) -> CGColor {
            CGColor(srgbRed: CGFloat(c.0) / 255, green: CGFloat(c.1) / 255, blue: CGFloat(c.2) / 255, alpha: 1)
        }
        ctx.setFillColor(color((44, 40, 38))); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        let s = frame.spec
        func poly(_ pts: [Vec2], height: Double = 0) -> CGPath? {
            let img = pts.compactMap { camera.project(frame.world($0, height: height)) }
            guard img.count == pts.count else { return nil }
            let p = CGMutablePath()
            p.addLines(between: img.map { CGPoint(x: $0.x, y: $0.y) }); p.closeSubpath()
            return p
        }
        func rect(_ m: Double) -> [Vec2] {
            [Vec2(-m, -m), Vec2(-m, s.width + m), Vec2(s.length + m, s.width + m), Vec2(s.length + m, -m)]
        }
        func fill(_ path: CGPath?, _ c: (UInt8, UInt8, UInt8)) {
            guard let path else { return }
            ctx.addPath(path); ctx.setFillColor(color(c)); ctx.fillPath()
        }
        fill(poly(rect(0.16)), (78, 48, 30))                   // wooden rail
        fill(poly(rect(Self.cushionWidth)), Self.cushionFelt)  // cushion tops
        fill(poly(rect(0)), Self.felt)                         // playing surface
        // Pockets: dark discs at the corners and the side midpoints, slightly outside the nose line.
        for p in s.pockets {
            let c = s.pocketCenter(p)
            let out = Vec2(c.x == 0 ? -0.025 : (c.x == s.length ? 0.025 : 0), c.y == 0 ? -0.025 : 0.025)
            let r = (p.isSide ? s.sideMouth : s.cornerMouth) / 2
            let ring = (0..<24).map { c + out + Vec2(cos(Double($0) * .pi / 12), sin(Double($0) * .pi / 12)) * r }
            fill(poly(ring), (8, 8, 8))
        }
        // Soft ball shadows, then balls.
        let geo = FrameGeometry(frame: frame, camera: camera)
        for b in balls {
            let shadow = (0..<20).map { b.position + Vec2(0.006, 0.004) +
                Vec2(cos(Double($0) * .pi / 10), sin(Double($0) * .pi / 10)) * TableSpec.ballRadius * 0.9 }
            fill(poly(shadow), (14, 64, 42))
        }
        for b in balls {
            guard let c = imagePoint(b) else { continue }
            let r = TableSpec.ballRadius * geo.ball.maxScale(at: b.position)
            let disc = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
            ctx.saveGState()
            ctx.addEllipse(in: disc); ctx.clip()
            if b.stripe {
                ctx.setFillColor(color((238, 238, 232))); ctx.fill(disc)
                ctx.setFillColor(color(b.color)); ctx.fill(CGRect(x: c.x - r, y: c.y - r * 0.5, width: 2 * r, height: r))
            } else {
                ctx.setFillColor(color(b.color)); ctx.fill(disc)
            }
            // Specular highlight.
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.85))
            ctx.fillEllipse(in: CGRect(x: c.x - r * 0.45, y: c.y - r * 0.6, width: r * 0.3, height: r * 0.3))
            ctx.restoreGState()
        }
        if let st = stick {
            // Tapered maple shaft: 13 mm at the tip to 30 mm at the butt, a bit above the ball plane.
            let u = st.direction.normalized, n = u.perpendicular
            let butt = st.tip - u * st.length
            let quad = [st.tip + n * 0.0065, st.tip - n * 0.0065, butt - n * 0.015, butt + n * 0.015]
            fill(poly(quad, height: TableSpec.ballRadius * 1.4), (214, 184, 140))
        }
        return ctx.makeImage()
    }
}

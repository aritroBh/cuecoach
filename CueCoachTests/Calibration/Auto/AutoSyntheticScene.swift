import CoreGraphics
import Foundation
import Geometry
import simd
@testable import CueCoach

/// Deterministic RNG for reproducible scenes.
struct AutoTestRNG {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        return z ^ (z >> 31)
    }
    mutating func uniform() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func uniform(_ a: Double, _ b: Double) -> Double { a + (b - a) * uniform() }
    mutating func gauss() -> Double {
        let u1 = max(uniform(), 1e-12), u2 = uniform()
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}

/// A perspective-rendered pool table with rails, cushions, pockets, diamonds, balls, glare, occluders and
/// noise, plus synthetic LiDAR depth, with exact ground truth. Rendered with CoreGraphics by projecting
/// 3D polygons (straight edges stay straight under a pinhole camera).
///
/// Honesty note: these scenes are simulation regression targets, not evidence of field accuracy. The camera
/// is an ideal pinhole (no distortion, blur, rolling shutter or ISP), depth is pixel-aligned at full
/// confidence, and tracking noise is mostly independent per frame. Tests that break the detector's own
/// assumptions on purpose: `railProfileMismatchStaysWithinOneCentimetre` (rail profile ≠ `AutoTableProfile`),
/// `depthOnlyPlaneWithoutARKitHint` (no plane hint) and `correlatedTrackingDriftIsFollowed` (correlated drift).
/// Field accuracy must be measured on device against a tape-measured table.
struct AutoSyntheticScene {
    // Table placement (world, ARKit y-up).
    var size: TableSize = .nineFoot
    var clothHeight: Double = 0.79
    var tableCenterXZ = SIMD2<Double>(0.2, -0.1)
    var tableYaw: Double = 0.35
    var profile = AutoTableProfile()
    var railWoodWidth: Double = 0.13

    // Image.
    var width = 960
    var height = 720
    /// Half of ARKit's ~1450 px focal length at 1920×1440.
    var focal: Double = 725

    // Disturbances.
    var noiseSigma: Double = 5
    var glare: [(center: Vec2, radius: Double, alpha: Double)] = [(Vec2(1.4, 0.5), 0.25, 0.75)]
    /// Occluder boxes in table coords: (x0, x1, y0, y1, z0, z1).
    var occluders: [(Double, Double, Double, Double, Double, Double)] = []
    /// Boxes seen only by LiDAR (table coords, top face only): an arm/body over the bed the colour pass ignores.
    var depthOccluders: [(Double, Double, Double, Double, Double, Double)] = []
    var balls: [Vec2] = [Vec2(0.6, 0.6), Vec2(1.9, 0.3), Vec2(1.95, 0.35), Vec2(2.0, 0.6), Vec2(1.2, 1.0)]
    var feltColor: (Double, Double, Double) = (28, 112, 64)
    var floorColor: (Double, Double, Double) = (96, 84, 72)

    var spec: TableSpec { TableSpec(size: size) }

    /// True table → world (head-left nose corner origin, TableFrame convention).
    var tableToWorld: simd_double4x4 {
        let L = spec.length, W = spec.width
        let ex = SIMD3(cos(tableYaw), 0, sin(tableYaw))
        let ez = SIMD3<Double>(0, 1, 0)
        let ey = simd_cross(ez, ex)
        let c = SIMD3(tableCenterXZ.x, clothHeight, tableCenterXZ.y)
        let o = c - ex * (L / 2) - ey * (W / 2)
        return simd_double4x4(columns: (SIMD4(ex, 0), SIMD4(ey, 0), SIMD4(ez, 0), SIMD4(o, 1)))
    }

    func world(_ x: Double, _ y: Double, _ z: Double) -> SIMD3<Double> {
        let w = tableToWorld * SIMD4(x, y, z, 1)
        return SIMD3(w.x, w.y, w.z)
    }

    /// Nose corners at cloth height, in AutoTablePose.corners order.
    var trueCorners: [SIMD3<Double>] {
        let L = spec.length, W = spec.width
        return [world(0, 0, 0), world(0, W, 0), world(L, W, 0), world(L, 0, 0)]
    }

    var intrinsics: AutoIntrinsics {
        AutoIntrinsics(fx: focal, fy: focal, cx: Double(width) / 2 - 0.5, cy: Double(height) / 2 - 0.5,
                       width: Double(width), height: Double(height))
    }

    // MARK: Camera

    /// Camera at `elevation` (degrees above horizontal) and `azimuth` (degrees; 90 = long side, y < 0),
    /// pulled back until the whole table + rails fit inside the frame with a margin.
    func camera(elevationDeg: Double, azimuthDeg: Double = 90, margin: Double = 40) -> simd_double4x4 {
        let center = world(spec.length / 2, spec.width / 2, 0)
        // Direction in table frame → world.
        let az = azimuthDeg * .pi / 180, el = elevationDeg * .pi / 180
        let exT = SIMD3(tableToWorld.columns.0.x, tableToWorld.columns.0.y, tableToWorld.columns.0.z)
        let eyT = SIMD3(tableToWorld.columns.1.x, tableToWorld.columns.1.y, tableToWorld.columns.1.z)
        let horiz = exT * cos(az) - eyT * sin(az)
        let dir = horiz * cos(el) + SIMD3(0, 1, 0) * sin(el)
        var d = 1.5
        while d < 12 {
            let m = Self.lookAt(eye: center + dir * d, target: center)
            if outerRailCorners.allSatisfy({ p in
                guard let q = project(p, cameraToWorld: m) else { return false }
                return q.x > margin && q.x < Double(width) - margin && q.y > margin && q.y < Double(height) - margin
            }) { return m }
            d += 0.05
        }
        return Self.lookAt(eye: center + dir * d, target: center)
    }

    var outerRailCorners: [SIMD3<Double>] {
        let o = profile.cushionWidth + railWoodWidth, L = spec.length, W = spec.width, h = profile.railTopHeight
        return [world(-o, -o, h), world(-o, W + o, h), world(L + o, W + o, h), world(L + o, -o, h)]
    }

    static func lookAt(eye: SIMD3<Double>, target: SIMD3<Double>) -> simd_double4x4 {
        let back = simd_normalize(eye - target)
        let right = simd_normalize(simd_cross(SIMD3(0, 1, 0), back))
        let up = simd_cross(back, right)
        return simd_double4x4(columns: (SIMD4(right, 0), SIMD4(up, 0), SIMD4(back, 0), SIMD4(eye, 1)))
    }

    /// Small rigid perturbation (handheld motion / tracking error).
    static func perturb(_ m: simd_double4x4, rng: inout AutoTestRNG, rotDeg: Double, trans: Double) -> simd_double4x4 {
        let axis = simd_normalize(SIMD3(rng.gauss(), rng.gauss(), rng.gauss()))
        let ang = rng.gauss() * rotDeg * .pi / 180
        let q = simd_quatd(angle: ang, axis: axis)
        let r = simd_double3x3(q)
        var out = m
        let c0 = r * SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z)
        let c1 = r * SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z)
        let c2 = r * SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z)
        out.columns.0 = SIMD4(c0, 0); out.columns.1 = SIMD4(c1, 0); out.columns.2 = SIMD4(c2, 0)
        out.columns.3 = m.columns.3 + SIMD4(rng.gauss() * trans, rng.gauss() * trans, rng.gauss() * trans, 0)
        return out
    }

    func project(_ p: SIMD3<Double>, cameraToWorld m: simd_double4x4) -> SIMD2<Double>? {
        let c = m.inverse * SIMD4(p, 1)
        guard c.z < -1e-3 else { return nil }
        let k = intrinsics
        return SIMD2(k.fx * c.x / -c.z + k.cx, k.fy * -c.y / -c.z + k.cy)
    }

    // MARK: Rendering

    func render(cameraToWorld m: simd_double4x4, seed: UInt64 = 1) -> AutoRGBImage {
        let w = width, h = height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        rgba.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            // y-down pixel space, pixel centres at integers (CG centre = +0.5).
            ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
            ctx.translateBy(x: 0.5, y: 0.5)
            ctx.setShouldAntialias(true)
            draw(ctx, m)
        }
        var rng = AutoTestRNG(seed: seed)
        // Gaussian noise from a shuffled table (fast in unoptimised test builds).
        let table: [Int16] = (0..<8192).map { _ in Int16((rng.gauss() * noiseSigma).rounded()) }
        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        var k = Int(rng.next() % 8192)
        let jump = Int(rng.next() % 4000) * 2 + 1
        rgba.withUnsafeBufferPointer { src in
            rgb.withUnsafeMutableBufferPointer { dst in
                for i in 0..<(w * h) {
                    for c in 0..<3 {
                        k = (k &+ jump) & 8191
                        let v = Int(src[i * 4 + c]) + Int(table[k])
                        dst[i * 3 + c] = UInt8(max(0, min(255, v)))
                    }
                }
            }
        }
        return AutoRGBImage(width: w, height: h, rgb: rgb)
    }

    private func color(_ c: (Double, Double, Double), _ k: Double = 1, alpha: Double = 1) -> CGColor {
        CGColor(srgbRed: min(1, c.0 * k / 255), green: min(1, c.1 * k / 255), blue: min(1, c.2 * k / 255), alpha: alpha)
    }

    private func fillPoly(_ ctx: CGContext, _ pts: [SIMD3<Double>], _ m: simd_double4x4, _ col: CGColor) {
        let q = pts.compactMap { project($0, cameraToWorld: m) }
        guard q.count == pts.count, q.count >= 3 else { return }
        ctx.beginPath()
        ctx.move(to: CGPoint(x: q[0].x, y: q[0].y))
        for p in q.dropFirst() { ctx.addLine(to: CGPoint(x: p.x, y: p.y)) }
        ctx.closePath()
        ctx.setFillColor(col)
        ctx.fillPath()
    }

    private func disc(_ cx: Double, _ cy: Double, _ z: Double, _ r: Double, n: Int = 36) -> [SIMD3<Double>] {
        (0..<n).map { i in
            let a = Double(i) / Double(n) * 2 * .pi
            return world(cx + r * cos(a), cy + r * sin(a), z)
        }
    }

    private func faceVisible(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>, inwardTo inside: SIMD3<Double>,
                             _ m: simd_double4x4) -> Bool {
        var n = simd_cross(b - a, c - a)
        let mid = (a + b + c) / 3
        if simd_dot(n, inside - mid) > 0 { n = -n }  // outward
        let eye = SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        return simd_dot(n, eye - mid) > 0
    }

    private func draw(_ ctx: CGContext, _ m: simd_double4x4) {
        let L = spec.length, W = spec.width
        let c = profile.cushionWidth, rw = railWoodWidth
        let hr = profile.railTopHeight, hn = profile.noseHeight
        let o = c + rw
        // Floor with a few tile seams (straight distractor edges).
        ctx.setFillColor(color(floorColor))
        ctx.fill(CGRect(x: -1, y: -1, width: width + 2, height: height + 2))
        for i in -6...6 {
            let x = Double(i) * 0.6
            fillPoly(ctx, [world(x, -6, -clothHeight), world(x + 0.02, -6, -clothHeight),
                           world(x + 0.02, 8, -clothHeight), world(x, 8, -clothHeight)], m, color(floorColor, 0.8))
        }
        let center = world(L / 2, W / 2, -0.1)
        // Apron / body: vertical outer faces.
        let base = -0.22
        let outer: [(Double, Double)] = [(-o, -o), (-o, W + o), (L + o, W + o), (L + o, -o)]
        for i in 0..<4 {
            let p = outer[i], q = outer[(i + 1) % 4]
            let quad = [world(p.0, p.1, base), world(q.0, q.1, base), world(q.0, q.1, hr), world(p.0, p.1, hr)]
            if faceVisible(quad[0], quad[1], quad[2], inwardTo: center, m) {
                fillPoly(ctx, quad, m, color((70, 40, 24)))
            }
        }
        // Bed first: everything else on the table top is above it and may cover it.
        fillPoly(ctx, [world(0, 0, 0), world(0, W, 0), world(L, W, 0), world(L, 0, 0)], m, color(feltColor))
        // Soft lamp falloff on the bed.
        for (k, s) in [(1.06, 0.8), (1.1, 0.55), (1.13, 0.3)] {
            fillPoly(ctx, [world(L / 2 - L * s / 2, W / 2 - W * s / 2, 0), world(L / 2 - L * s / 2, W / 2 + W * s / 2, 0),
                           world(L / 2 + L * s / 2, W / 2 + W * s / 2, 0), world(L / 2 + L * s / 2, W / 2 - W * s / 2, 0)],
                     m, color(feltColor, k, alpha: 0.5))
        }
        let feltOut: [(Double, Double)] = [(-c, -c), (-c, W + c), (L + c, W + c), (L + c, -c)]
        // Cushion faces (vertical, at the nose) and cushion tops (nose → felt boundary).
        let nose: [(Double, Double)] = [(0, 0), (0, W), (L, W), (L, 0)]
        let bedCenter = world(L / 2, W / 2, hn / 2)
        for i in 0..<4 {
            let p = nose[i], q = nose[(i + 1) % 4]
            let face = [world(p.0, p.1, 0), world(q.0, q.1, 0), world(q.0, q.1, hn), world(p.0, p.1, hn)]
            // Visible from the bed side: outward normal of the face as seen from inside points to the bed centre.
            var nrm = simd_cross(face[1] - face[0], face[3] - face[0])
            let mid = (face[0] + face[2]) / 2
            if simd_dot(nrm, bedCenter - mid) < 0 { nrm = -nrm }
            let eye = SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
            if simd_dot(nrm, eye - mid) > 0 { fillPoly(ctx, face, m, color(feltColor, 0.72)) }
        }
        for i in 0..<4 {
            let p = nose[i], q = nose[(i + 1) % 4], po = feltOut[i], qo = feltOut[(i + 1) % 4]
            fillPoly(ctx, [world(p.0, p.1, hn), world(q.0, q.1, hn), world(qo.0, qo.1, hr), world(po.0, po.1, hr)],
                     m, color(feltColor, 0.9))
        }
        // Rail caps (wood) between the felt boundary (offset c) and the outer edge.
        for i in 0..<4 {
            let p = outer[i], q = outer[(i + 1) % 4], pi = feltOut[i], qi = feltOut[(i + 1) % 4]
            fillPoly(ctx, [world(p.0, p.1, hr), world(q.0, q.1, hr), world(qi.0, qi.1, hr), world(pi.0, pi.1, hr)],
                     m, color((128, 76, 42)))
        }
        // Pockets: dark holes cut into cushion + rail.
        let dark = color((12, 12, 12))
        let cr = spec.cornerMouth / 2 + 0.002, sr = spec.sideMouth / 2 + 0.002
        let off = 0.028
        for (x, y, dx, dy) in [(0.0, 0.0, -1.0, -1.0), (0, W, -1, 1), (L, W, 1, 1), (L, 0, 1, -1)] {
            fillPoly(ctx, disc(x + dx * off, y + dy * off, hn, cr), m, dark)
        }
        fillPoly(ctx, disc(L / 2, -0.035, hn, sr), m, dark)
        fillPoly(ctx, disc(L / 2, W + 0.035, hn, sr), m, dark)
        // Diamonds.
        let white = color((235, 235, 225))
        for k in 1..<8 where k != 4 {
            let x = L * Double(k) / 8
            fillPoly(ctx, disc(x, -c - rw / 2, hr + 0.001, 0.008, n: 10), m, white)
            fillPoly(ctx, disc(x, W + c + rw / 2, hr + 0.001, 0.008, n: 10), m, white)
        }
        for k in 1..<4 {
            let y = W * Double(k) / 4
            fillPoly(ctx, disc(-c - rw / 2, y, hr + 0.001, 0.008, n: 10), m, white)
            fillPoly(ctx, disc(L + c + rw / 2, y, hr + 0.001, 0.008, n: 10), m, white)
        }
        // Balls (approximate silhouettes).
        let ballColors: [(Double, Double, Double)] = [(240, 240, 230), (230, 190, 20), (30, 40, 170), (200, 30, 30), (20, 20, 20)]
        for (i, b) in balls.enumerated() {
            fillPoly(ctx, disc(b.x, b.y, TableSpec.ballRadius, TableSpec.ballRadius, n: 20), m,
                     color(ballColors[i % ballColors.count]))
        }
        // Glare (layered translucent white discs on the cloth).
        for g in glare {
            for k in 1...5 {
                let r = g.radius * Double(6 - k) / 5
                fillPoly(ctx, disc(g.center.x, g.center.y, 0.001, r, n: 40), m,
                         color((255, 255, 250), alpha: min(1, g.alpha / 5 * 1.6)))
            }
        }
        // Occluders (people, cues): projected convex hull of each box.
        for b in occluders {
            let v = [world(b.0, b.2, b.4), world(b.1, b.2, b.4), world(b.1, b.3, b.4), world(b.0, b.3, b.4),
                     world(b.0, b.2, b.5), world(b.1, b.2, b.5), world(b.1, b.3, b.5), world(b.0, b.3, b.5)]
            let q = v.compactMap { project($0, cameraToWorld: m) }
            guard q.count == 8 else { continue }
            let hull = Self.hull(q)
            ctx.beginPath()
            ctx.move(to: CGPoint(x: hull[0].x, y: hull[0].y))
            for p in hull.dropFirst() { ctx.addLine(to: CGPoint(x: p.x, y: p.y)) }
            ctx.closePath()
            ctx.setFillColor(color((40, 48, 70)))
            ctx.fillPath()
        }
    }

    static func hull(_ pts: [SIMD2<Double>]) -> [SIMD2<Double>] {
        let p = pts.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        func cross(_ o: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var lo: [SIMD2<Double>] = [], up: [SIMD2<Double>] = []
        for q in p { while lo.count >= 2 && cross(lo[lo.count - 2], lo[lo.count - 1], q) <= 0 { lo.removeLast() }; lo.append(q) }
        for q in p.reversed() { while up.count >= 2 && cross(up[up.count - 2], up[up.count - 1], q) <= 0 { up.removeLast() }; up.append(q) }
        return Array(lo.dropLast() + up.dropLast())
    }

    // MARK: LiDAR

    /// 256×192 depth, noisy, ray-cast against the table top (bed/rails at their heights) and the floor.
    func depth(cameraToWorld m: simd_double4x4, seed: UInt64 = 7, sigma: Double = 0.005, occludersInDepth: Bool = true) -> AutoDepthMap {
        let dw = 256, dh = 192
        let inv = tableToWorld.inverse
        let eye = SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        var rng = AutoTestRNG(seed: seed)
        var out = [Float](repeating: 0, count: dw * dh)
        let o = profile.cushionWidth + railWoodWidth, L = spec.length, W = spec.width
        for v in 0..<dh {
            for u in 0..<dw {
                // Depth pixel centre → colour-image pixel (integer-centre convention), colour intrinsics.
                let ik = intrinsics
                let iu = (Double(u) + 0.5) * Double(width) / Double(dw) - 0.5
                let iv = (Double(v) + 0.5) * Double(height) / Double(dh) - 0.5
                let dc = SIMD4((iu - ik.cx) / ik.fx, -(iv - ik.cy) / ik.fy, -1, 0)
                let dwv = m * dc
                let dir = SIMD3(dwv.x, dwv.y, dwv.z)
                var best = Double.infinity
                // Table top planes in table coords.
                for (z, inside) in [(0.0, { (x: Double, y: Double) in x >= 0 && x <= L && y >= 0 && y <= W }),
                                    (profile.railTopHeight, { (x: Double, y: Double) in
                                        x >= -o && x <= L + o && y >= -o && y <= W + o && !(x > 0 && x < L && y > 0 && y < W) })] {
                    let pw = world(0, 0, z)
                    let t = (pw.y - eye.y) / dir.y
                    if t > 0 {
                        let hit = eye + dir * t
                        let tc = inv * SIMD4(hit, 1)
                        if inside(tc.x, tc.y) { best = min(best, t) }
                    }
                }
                if occludersInDepth {
                    for b in occluders + depthOccluders {
                        // Coarse: hit the box's top face only.
                        let pw = world(0, 0, b.5)
                        let t = (pw.y - eye.y) / dir.y
                        if t > 0 {
                            let tc = inv * SIMD4(eye + dir * t, 1)
                            if tc.x >= b.0 && tc.x <= b.1 && tc.y >= b.2 && tc.y <= b.3 { best = min(best, t) }
                        }
                    }
                }
                if !best.isFinite {
                    let t = (0 - eye.y) / dir.y  // floor at world y = 0
                    best = t > 0 ? t : 10
                }
                // Depth along the view axis: t · (dir · forward), dc has z = −1 → depth = t.
                out[v * dw + u] = Float(best + rng.gauss() * sigma)
            }
        }
        return AutoDepthMap(width: dw, height: dh, depth: out, confidence: [UInt8](repeating: 2, count: dw * dh))
    }

    /// `timestamp` defaults to seed / 30 s so loops over seeds give distinct frames.
    func frame(cameraToWorld m: simd_double4x4, reported: simd_double4x4? = nil, seed: UInt64 = 1,
               withDepth: Bool = true, withPlane: Bool = true, planeBias: Double = 0.012, timestamp: Double? = nil,
               tracking: AutoTrackingState = .normal) -> AutoTableFrame {
        let c = world(spec.length / 2, spec.width / 2, 0)
        return AutoTableFrame(image: render(cameraToWorld: m, seed: seed), intrinsics: intrinsics,
                              cameraToWorld: reported ?? m,
                              depth: withDepth ? depth(cameraToWorld: m, seed: seed &+ 99) : nil,
                              plane: withPlane ? AutoPlaneHint(point: c + SIMD3(0.3, planeBias, -0.2)) : nil,
                              timestamp: timestamp ?? Double(seed) / 30, tracking: tracking)
    }
}

enum AutoTestMetrics {
    /// Max corner error (m), allowing the 180° symmetry of the rectangle (head/foot resolved separately).
    static func maxCornerError(_ est: [SIMD3<Double>], _ truth: [SIMD3<Double>]) -> Double {
        let a = (0..<4).map { simd_distance(est[$0], truth[$0]) }.max()!
        let b = (0..<4).map { simd_distance(est[($0 + 2) % 4], truth[$0]) }.max()!
        return min(a, b)
    }

    static func diagonal(_ spec: TableSpec) -> Double { (spec.length * spec.length + spec.width * spec.width).squareRoot() }
}

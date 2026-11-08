import Foundation
import Geometry
import simd

/// The table plane (cloth) with an in-plane 2D basis.
struct AutoTablePlane: Sendable {
    /// A point on the cloth.
    var origin: SIMD3<Double>
    var normal: SIMD3<Double>
    var e1: SIMD3<Double>
    var e2: SIMD3<Double>

    init(origin: SIMD3<Double>, normal: SIMD3<Double>) {
        self.origin = origin
        let n = simd_normalize(normal)
        self.normal = n
        var a = SIMD3<Double>(1, 0, 0) - n * n.x
        if simd_length(a) < 0.3 { a = SIMD3<Double>(0, 0, 1) - n * n.z }
        e1 = simd_normalize(a)
        e2 = simd_cross(n, e1)
    }

    func to2D(_ p: SIMD3<Double>) -> AutoP2 { let d = p - origin; return AutoP2(simd_dot(d, e1), simd_dot(d, e2)) }
    func to3D(_ p: AutoP2, height: Double = 0) -> SIMD3<Double> { origin + e1 * p.x + e2 * p.y + normal * height }

    func lift(_ px: AutoP2, camera: AutoCamera, height: Double) -> AutoP2? {
        camera.lift(px, point: origin + normal * height, normal: normal).map(to2D)
    }
}

/// Rectangle on the cloth plane: centre, major-axis angle θ (in the plane's e1/e2 basis), nose half-sizes.
struct AutoRect: Sendable {
    var center: AutoP2
    var theta: Double
    var a: Double  // half nose length (along the major axis)
    var b: Double  // half nose width

    var u: AutoP2 { AutoP2(cos(theta), sin(theta)) }
    var v: AutoP2 { AutoP2(-sin(theta), cos(theta)) }

    /// Outward normal of side k (0: +u short rail, 1: +v long rail, 2: −u, 3: −v).
    func normal(_ k: Int) -> AutoP2 { let t = theta + Double(k) * .pi / 2; return AutoP2(cos(t), sin(t)) }
    func extent(_ k: Int) -> Double { k % 2 == 0 ? a : b }
    func point(_ sx: Double, _ sy: Double) -> AutoP2 { center + u * (sx * a) + v * (sy * b) }

    /// Outer corners grown by `grow` (m), consecutive.
    func corners(grow: Double = 0) -> [AutoP2] {
        let A = a + grow, B = b + grow
        return [center + u * A + v * B, center - u * A + v * B, center - u * A - v * B, center + u * A - v * B]
    }
}

/// Least-squares rectangle fit to lifted rail edge points (each carrying its side and outward offset)
/// and optional keypoints, with Huber weights. Modes: free size, fixed 2:1 aspect, or fixed preset.
enum AutoRectFitter {
    struct EdgeSample { var p: AutoP2; var side: Int; var offset: Double }
    struct PointSample { var p: AutoP2; var sx: Double; var sy: Double; var grow: Double; var weight: Double }
    enum Mode { case free, aspect, fixed(a: Double, b: Double) }

    static func fit(_ init0: AutoRect, edges: [EdgeSample], points: [PointSample] = [], mode: Mode,
                    huber: Double = 0.01, iterations: Int = 12) -> (rect: AutoRect, rms: Double)? {
        var r = init0
        if case .fixed(let a, let b) = mode { r.a = a; r.b = b }
        if case .aspect = mode { r.b = r.a / 2 }
        let np: Int
        switch mode { case .free: np = 5; case .aspect: np = 4; case .fixed: np = 3 }
        guard edges.count + points.count * 2 >= np + 2 else { return nil }
        var rms = Double.infinity
        for _ in 0..<iterations {
            var H = [Double](repeating: 0, count: np * np), g = [Double](repeating: 0, count: np)
            var sse = 0.0, wsum = 0.0
            func add(_ J: [Double], _ res: Double, _ w0: Double) {
                let ar = abs(res)
                let w = w0 * (ar <= huber ? 1 : huber / ar)
                for i in 0..<np {
                    g[i] += w * J[i] * res
                    for j in 0..<np { H[i * np + j] += w * J[i] * J[j] }
                }
                sse += w0 * res * res; wsum += w0
            }
            for e in edges {
                let n = r.normal(e.side)
                let d = e.p - r.center
                let res = simd_dot(d, n) - r.extent(e.side) - e.offset
                let dn = AutoP2(-n.y, n.x)
                var J = [-n.x, -n.y, simd_dot(d, dn)]
                switch mode {
                case .free: J += e.side % 2 == 0 ? [-1, 0] : [0, -1]
                case .aspect: J.append(e.side % 2 == 0 ? -1 : -0.5)
                case .fixed: break
                }
                add(J, res, 1)
            }
            for p in points {
                let lx = p.sx * (r.a + p.grow), ly = p.sy * (r.b + p.grow)
                let m = r.center + r.u * lx + r.v * ly
                let res = p.p - m
                // ∂m/∂θ = v·lx − u·ly
                let dth = r.v * lx - r.u * ly
                for c in 0..<2 {
                    var J = [c == 0 ? -1.0 : 0, c == 1 ? -1.0 : 0, -dth[c]]
                    switch mode {
                    case .free: J += [-(r.u * p.sx)[c], -(r.v * p.sy)[c]]
                    case .aspect: J.append(-(r.u * p.sx)[c] - 0.5 * (r.v * p.sy)[c])
                    case .fixed: break
                    }
                    add(J, res[c], p.weight)
                }
            }
            rms = wsum > 0 ? (sse / wsum).squareRoot() : .infinity
            for i in 0..<np { H[i * np + i] += 1e-9 }
            guard let dx = AutoLinear.solve(H, g.map { -$0 }, n: np) else { return nil }
            r.center += AutoP2(dx[0], dx[1])
            r.theta += dx[2]
            switch mode {
            case .free: r.a += dx[3]; r.b += dx[4]
            case .aspect: r.a += dx[3]; r.b = r.a / 2
            case .fixed: break
            }
            guard r.a > 0.3, r.b > 0.15, r.a < 4, r.b < 2 else { return nil }
            if abs(dx[0]) + abs(dx[1]) < 1e-6 && abs(dx[2]) < 1e-7 { break }
        }
        return (r, rms)
    }

    /// D12 sizing: nearest preset by (L + 2W)/2; relative error ≤ 6 % snaps, else the measurement is used.
    static func snap(length: Double, width: Double) -> (size: TableSize, relativeError: Double) {
        let est = (length + 2 * width) / 2
        let best = TableSize.allCases.min { abs($0.playingLength - est) < abs($1.playingLength - est) }!
        return (best, abs(best.playingLength - est) / best.playingLength)
    }
}

/// LiDAR refinement of the cloth height: median height of depth samples that land inside the bed.
enum AutoPlaneRefiner {
    /// Returns nil unless ≥ `minCoverage` of the trusted bed samples agree (within ±3 cm) on one level,
    /// so a body or arm over much of the bed cannot set the cloth height.
    static func clothOffset(depth: AutoDepthMap, camera: AutoCamera, imageWidth: Int, imageHeight: Int,
                            bed: [AutoP2], plane: AutoTablePlane, minCoverage: Double = 0.6) -> (offset: Double, samples: Int)? {
        guard bed.count >= 3 else { return nil }
        let sx = Double(imageWidth) / Double(depth.width), sy = Double(imageHeight) / Double(depth.height)
        var minX = Double.infinity, maxX = -Double.infinity, minY = Double.infinity, maxY = -Double.infinity
        for p in bed { minX = min(minX, p.x); maxX = max(maxX, p.x); minY = min(minY, p.y); maxY = max(maxY, p.y) }
        var hs: [Double] = []
        hs.reserveCapacity(2048)
        let x0 = max(0, Int(minX / sx)), x1 = min(depth.width - 1, Int(maxX / sx) + 1)
        let y0 = max(0, Int(minY / sy)), y1 = min(depth.height - 1, Int(maxY / sy) + 1)
        guard x1 > x0, y1 > y0 else { return nil }
        let st = max(1, Int((Double((x1 - x0) * (y1 - y0)) / 2500).squareRoot()))
        for v in Swift.stride(from: y0, through: y1, by: st) {
            for u in Swift.stride(from: x0, through: x1, by: st) {
                let i = v * depth.width + u
                if let c = depth.confidence, c[i] < 2 { continue }
                let z = Double(depth.depth[i])
                guard z > 0.1, z < 8 else { continue }
                // Depth pixel centre → image pixel (integer-centre convention).
                let px = AutoP2((Double(u) + 0.5) * sx - 0.5, (Double(v) + 0.5) * sy - 0.5)
                guard AutoPolygon.contains(bed, px) else { continue }
                let w = camera.unproject(px, depth: z)
                hs.append(simd_dot(w - plane.origin, plane.normal))
            }
        }
        guard hs.count >= 30 else { return nil }
        let m0 = autoMedian(hs)
        let near = hs.filter { abs($0 - m0) < 0.03 }
        guard near.count >= 20, Double(near.count) >= minCoverage * Double(hs.count) else { return nil }
        return (autoMedian(near), near.count)
    }

    /// LiDAR height of the rail caps above the cloth plane: depth samples in a band 2.5–9 cm outside the
    /// outer felt boundary (`feltCorners`, plane 2D, consecutive), away from the pockets. Real tables differ
    /// from the default profile by 5–10 mm here, and that error shifts every lifted rail edge along the
    /// view rays; LiDAR's cloth level cannot correct it, this can. nil when the band is not clearly seen.
    static func railTopHeight(depth: AutoDepthMap, camera: AutoCamera, imageWidth: Int, imageHeight: Int,
                              plane: AutoTablePlane, feltCorners q: [AutoP2]) -> (height: Double, samples: Int)? {
        guard q.count == 4 else { return nil }
        let c = (q[0] + q[1] + q[2] + q[3]) / 4
        let d = (q[1] - q[0]) + (q[2] - q[3])
        guard simd_length(d) > 1e-6 else { return nil }
        let u = simd_normalize(d), v = AutoP2(-u.y, u.x)
        let a = q.map { abs(simd_dot($0 - c, u)) }.reduce(0, +) / 4
        let b = q.map { abs(simd_dot($0 - c, v)) }.reduce(0, +) / 4
        let sx = Double(imageWidth) / Double(depth.width), sy = Double(imageHeight) / Double(depth.height)
        var hs: [Double] = []
        hs.reserveCapacity(1024)
        for vv in Swift.stride(from: 0, to: depth.height, by: 2) {
            for uu in Swift.stride(from: 0, to: depth.width, by: 2) {
                let i = vv * depth.width + uu
                if let cf = depth.confidence, cf[i] < 2 { continue }
                let z = Double(depth.depth[i])
                guard z > 0.1, z < 8 else { continue }
                let w = camera.unproject(AutoP2((Double(uu) + 0.5) * sx - 0.5, (Double(vv) + 0.5) * sy - 0.5), depth: z)
                let h = simd_dot(w - plane.origin, plane.normal)
                guard h > 0.01, h < 0.12 else { continue }
                let p = plane.to2D(w) - c
                let du = abs(simd_dot(p, u)) - a, dv = abs(simd_dot(p, v)) - b
                let onLong = dv > 0.025 && dv < 0.09 && du < -0.12
                let onShort = du > 0.025 && du < 0.09 && dv < -0.12
                if onLong || onShort { hs.append(h) }
            }
        }
        guard hs.count >= 40 else { return nil }
        let m0 = autoMedian(hs)
        let near = hs.filter { abs($0 - m0) < 0.01 }
        guard Double(near.count) >= 0.6 * Double(hs.count) else { return nil }
        return (autoMedian(near), near.count)
    }

    /// Depth gate on the depth grid: 1 = within `tolerance` of the plane (or untrusted), 0 = clearly off it.
    /// `trustUnknown`: no-confidence samples pass (segmentation veto) or fail (learning the cloth model).
    static func gate(depth: AutoDepthMap, camera: AutoCamera, imageWidth: Int, imageHeight: Int,
                     plane: AutoTablePlane, tolerance: Double = 0.12, grow: Int = 0, trustUnknown: Bool = true) -> [UInt8] {
        let sx = Double(imageWidth) / Double(depth.width), sy = Double(imageHeight) / Double(depth.height)
        var g = [UInt8](repeating: 1, count: depth.width * depth.height)
        for v in 0..<depth.height {
            for u in 0..<depth.width {
                let i = v * depth.width + u
                if let c = depth.confidence, c[i] < 1 { if !trustUnknown { g[i] = 0 }; continue }
                let z = Double(depth.depth[i])
                guard z > 0.05 else { if !trustUnknown { g[i] = 0 }; continue }
                let px = AutoP2((Double(u) + 0.5) * sx - 0.5, (Double(v) + 0.5) * sy - 0.5)
                let h = simd_dot(camera.unproject(px, depth: z) - plane.origin, plane.normal)
                if abs(h) > tolerance { g[i] = 0 }
            }
        }
        // Depth is coarse and blurs at the rail edge: grow the "on plane" region by `grow` depth pixels
        // so the colour boundary, not the depth boundary, decides the cloth edge.
        let w = depth.width, hh = depth.height
        for _ in 0..<grow {
            var o = g
            for v in 0..<hh {
                for u in 0..<w where g[v * w + u] == 0 {
                    if (u > 0 && g[v * w + u - 1] != 0) || (u < w - 1 && g[v * w + u + 1] != 0)
                        || (v > 0 && g[(v - 1) * w + u] != 0) || (v < hh - 1 && g[(v + 1) * w + u] != 0) { o[v * w + u] = 1 }
                }
            }
            g = o
        }
        return g
    }
}

/// Darkness evidence for pocket holes, sampled in the image around a world point.
enum AutoPocketEvidence {
    static func score(_ img: AutoRGBImage, camera: AutoCamera, center: SIMD3<Double>, e1: SIMD3<Double>,
                      e2: SIMD3<Double>, radius: Double, darkBelow: Float) -> Double? {
        var dark = 0, n = 0
        for ring in 0...2 {
            let r = radius * Double(ring) / 2
            let count = ring == 0 ? 1 : 8 * ring
            for k in 0..<count {
                let a = Double(k) / Double(count) * 2 * .pi
                guard let q = camera.project(center + e1 * (r * cos(a)) + e2 * (r * sin(a))) else { continue }
                let x = Int(q.x.rounded()), y = Int(q.y.rounded())
                guard x >= 0, y >= 0, x < img.width, y < img.height else { continue }
                let o = (y * img.width + x) * 3
                let i = (Float(img.rgb[o]) + Float(img.rgb[o + 1]) + Float(img.rgb[o + 2])) / 3
                n += 1
                if i < darkBelow { dark += 1 }
            }
        }
        return n >= 8 ? Double(dark) / Double(n) : nil
    }
}

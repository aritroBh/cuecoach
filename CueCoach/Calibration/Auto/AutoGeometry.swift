import Foundation
import simd

typealias AutoP2 = SIMD2<Double>

/// Pinhole camera, ARKit conventions (see AutoTableTypes.swift).
struct AutoCamera: Sendable {
    let k: AutoIntrinsics
    let cameraToWorld: simd_double4x4
    let worldToCamera: simd_double4x4

    init(intrinsics: AutoIntrinsics, cameraToWorld: simd_double4x4) {
        k = intrinsics; self.cameraToWorld = cameraToWorld; worldToCamera = cameraToWorld.inverse
    }

    var position: SIMD3<Double> { SIMD3(cameraToWorld.columns.3.x, cameraToWorld.columns.3.y, cameraToWorld.columns.3.z) }

    func project(_ p: SIMD3<Double>) -> AutoP2? {
        let c = worldToCamera * SIMD4(p, 1)
        guard c.z < -1e-4 else { return nil }
        return AutoP2(k.fx * c.x / -c.z + k.cx, k.fy * -c.y / -c.z + k.cy)
    }

    /// Unnormalised world direction through a pixel (camera-space z component = −1).
    func direction(_ px: AutoP2) -> SIMD3<Double> {
        let d = cameraToWorld * SIMD4((px.x - k.cx) / k.fx, -(px.y - k.cy) / k.fy, -1, 0)
        return SIMD3(d.x, d.y, d.z)
    }

    /// World point of a pixel at depth `z` (metres along the view axis).
    func unproject(_ px: AutoP2, depth z: Double) -> SIMD3<Double> { position + direction(px) * z }

    /// Ray ∩ horizontal plane through `point` with normal `n`.
    func lift(_ px: AutoP2, point: SIMD3<Double>, normal n: SIMD3<Double>) -> SIMD3<Double>? {
        let d = direction(px)
        let den = simd_dot(n, d)
        guard abs(den) > 1e-9 else { return nil }
        let t = simd_dot(n, point - position) / den
        guard t > 0 else { return nil }
        return position + d * t
    }
}

/// Image line n·p + c = 0 with |n| = 1.
struct AutoLine: Sendable {
    var n: AutoP2
    var c: Double

    init(n: AutoP2, c: Double) { self.n = n; self.c = c }
    init?(through a: AutoP2, _ b: AutoP2) {
        let d = b - a
        let l = simd_length(d)
        guard l > 1e-9 else { return nil }
        n = AutoP2(-d.y, d.x) / l
        c = -simd_dot(n, a)
    }

    @inline(__always) func distance(_ p: AutoP2) -> Double { simd_dot(n, p) + c }
    var direction: AutoP2 { AutoP2(n.y, -n.x) }
    var abc: SIMD3<Double> { SIMD3(n.x, n.y, c) }

    func intersect(_ o: AutoLine) -> AutoP2? {
        let det = n.x * o.n.y - n.y * o.n.x
        guard abs(det) > 1e-9 else { return nil }
        return AutoP2((-c * o.n.y + o.c * n.y) / det, (-o.c * n.x + c * o.n.x) / det)
    }

    /// Total-least-squares fit.
    static func fit(_ pts: [AutoP2]) -> AutoLine? {
        guard pts.count >= 2 else { return nil }
        var m = AutoP2.zero
        for p in pts { m += p }
        m /= Double(pts.count)
        var sxx = 0.0, sxy = 0.0, syy = 0.0
        for p in pts { let d = p - m; sxx += d.x * d.x; sxy += d.x * d.y; syy += d.y * d.y }
        let theta = 0.5 * atan2(2 * sxy, sxx - syy)
        let dir = AutoP2(cos(theta), sin(theta))
        let n = AutoP2(-dir.y, dir.x)
        return AutoLine(n: n, c: -simd_dot(n, m))
    }
}

/// Deterministic xorshift for RANSAC (repeatable frames → repeatable results).
struct AutoRandom {
    var s: UInt64
    init(_ seed: UInt64 = 0x9E3779B97F4A7C15) { s = seed | 1 }
    mutating func next(_ n: Int) -> Int {
        s ^= s << 13; s ^= s >> 7; s ^= s << 17
        return Int(s % UInt64(max(1, n)))
    }
}

enum AutoRansac {
    /// Robust line: 2-point RANSAC, then TLS on inliers, then a tightened TLS pass.
    /// Returns the line, inlier indices and the inlier RMS.
    static func line(_ pts: [AutoP2], tolerance: Double, iterations: Int = 80, rng: inout AutoRandom)
        -> (line: AutoLine, inliers: [Int], rms: Double)? {
        let n = pts.count
        guard n >= 4 else { return nil }
        var bestCount = 0
        var best: AutoLine?
        for _ in 0..<iterations {
            let i = rng.next(n), j = rng.next(n)
            guard i != j, let l = AutoLine(through: pts[i], pts[j]) else { continue }
            var cnt = 0
            for p in pts where abs(l.distance(p)) < tolerance { cnt += 1 }
            if cnt > bestCount { bestCount = cnt; best = l }
        }
        guard var l = best else { return nil }
        var inl: [Int] = []
        for pass in 0..<3 {
            let tol: Double
            if pass == 0 { tol = tolerance } else {
                let r = rms(pts, inl, l)
                tol = min(tolerance, max(tolerance * 0.35, 2.5 * r))
            }
            inl = (0..<n).filter { abs(l.distance(pts[$0])) < tol }
            guard inl.count >= 3, let f = AutoLine.fit(inl.map { pts[$0] }) else { return nil }
            l = f
        }
        return (l, inl, rms(pts, inl, l))
    }

    static func rms(_ pts: [AutoP2], _ idx: [Int], _ l: AutoLine) -> Double {
        guard !idx.isEmpty else { return .infinity }
        var s = 0.0
        for i in idx { let d = l.distance(pts[i]); s += d * d }
        return (s / Double(idx.count)).squareRoot()
    }
}

enum AutoPolygon {
    /// Andrew's monotone chain.
    static func convexHull(_ pts: [AutoP2]) -> [AutoP2] {
        let p = pts.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        guard p.count >= 3 else { return p }
        @inline(__always) func cross(_ o: AutoP2, _ a: AutoP2, _ b: AutoP2) -> Double {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var lo: [AutoP2] = [], up: [AutoP2] = []
        lo.reserveCapacity(64); up.reserveCapacity(64)
        for q in p {
            while lo.count >= 2 && cross(lo[lo.count - 2], lo[lo.count - 1], q) <= 0 { lo.removeLast() }
            lo.append(q)
        }
        for q in p.reversed() {
            while up.count >= 2 && cross(up[up.count - 2], up[up.count - 1], q) <= 0 { up.removeLast() }
            up.append(q)
        }
        return Array(lo.dropLast() + up.dropLast())
    }

    /// Groups consecutive hull edges of similar direction; the 4 longest groups are the rails
    /// (short groups are the corners cut by pockets). Returns the 4 groups' end points in hull order.
    static func fourSides(_ hull: [AutoP2], angleTol: Double = 9 * .pi / 180) -> [(AutoP2, AutoP2)]? {
        sideGroups(hull, angleTol: angleTol, maxGroups: 4)
    }

    /// The `maxGroups` longest direction groups of the hull, in hull order.
    static func sideGroups(_ hull: [AutoP2], angleTol: Double = 9 * .pi / 180, maxGroups: Int) -> [(AutoP2, AutoP2)]? {
        let n = hull.count
        guard n >= 4 else { return nil }
        func ang(_ i: Int) -> Double { let d = hull[(i + 1) % n] - hull[i]; return atan2(d.y, d.x) }
        func diff(_ a: Double, _ b: Double) -> Double {
            let d = abs(a - b).truncatingRemainder(dividingBy: 2 * .pi)
            return min(d, 2 * .pi - d)
        }
        // Start at the edge with the largest turn before it, so no group wraps around.
        let start = (0..<n).max { diff(ang($0), ang(($0 + n - 1) % n)) < diff(ang($1), ang(($1 + n - 1) % n)) }!
        struct G { var a: AutoP2; var b: AutoP2; var len: Double }
        var groups: [G] = []
        for s in 0..<n {
            let i = (start + s) % n
            let a = hull[i], b = hull[(i + 1) % n]
            let len = simd_length(b - a)
            guard len > 0 else { continue }
            if var g = groups.last {
                let gd = g.b - g.a
                if diff(atan2(gd.y, gd.x), atan2(b.y - a.y, b.x - a.x)) < angleTol {
                    g.b = b; g.len += len
                    groups[groups.count - 1] = g
                    continue
                }
            }
            groups.append(G(a: a, b: b, len: len))
        }
        guard groups.count >= 4 else { return nil }
        let keep = groups.indices.sorted { groups[$0].len > groups[$1].len }.prefix(maxGroups).sorted()
        return keep.map { (groups[$0].a, groups[$0].b) }
    }

    static func contains(_ poly: [AutoP2], _ p: AutoP2) -> Bool {
        var inside = false
        var j = poly.count - 1
        for i in 0..<poly.count {
            let a = poly[i], b = poly[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }

    static func area(_ poly: [AutoP2]) -> Double {
        var s = 0.0
        for i in 0..<poly.count { let a = poly[i], b = poly[(i + 1) % poly.count]; s += a.x * b.y - a.y * b.x }
        return abs(s) / 2
    }
}

/// Small dense linear solver (Gaussian elimination, partial pivoting). `a` is row-major n×n.
enum AutoLinear {
    static func solve(_ a: [Double], _ b: [Double], n: Int) -> [Double]? {
        var m = a, r = b
        for col in 0..<n {
            var piv = col
            for row in (col + 1)..<n where abs(m[row * n + col]) > abs(m[piv * n + col]) { piv = row }
            guard abs(m[piv * n + col]) > 1e-12 else { return nil }
            if piv != col {
                for k in 0..<n { m.swapAt(col * n + k, piv * n + k) }
                r.swapAt(col, piv)
            }
            for row in (col + 1)..<n {
                let f = m[row * n + col] / m[col * n + col]
                if f == 0 { continue }
                for k in col..<n { m[row * n + k] -= f * m[col * n + k] }
                r[row] -= f * r[col]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for row in stride(from: n - 1, through: 0, by: -1) {
            var s = r[row]
            for k in (row + 1)..<n { s -= m[row * n + k] * x[k] }
            x[row] = s / m[row * n + row]
        }
        return x
    }
}

@inline(__always) func autoWrapPi(_ a: Double) -> Double {
    var x = a.truncatingRemainder(dividingBy: 2 * .pi)
    if x > .pi { x -= 2 * .pi } else if x <= -.pi { x += 2 * .pi }
    return x
}

/// Angle difference modulo π, in (−π/2, π/2].
@inline(__always) func autoWrapHalfPi(_ a: Double) -> Double {
    var x = a.truncatingRemainder(dividingBy: .pi)
    if x > .pi / 2 { x -= .pi } else if x <= -.pi / 2 { x += .pi }
    return x
}

func autoMedian(_ v: [Double]) -> Double {
    guard !v.isEmpty else { return .nan }
    let s = v.sorted()
    return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
}

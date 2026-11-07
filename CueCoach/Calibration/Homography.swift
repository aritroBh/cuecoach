import Foundation
import Geometry
import simd

/// Plane-to-plane projective map (3×3, row-major in `m`). Used image↔table.
struct Homography: Hashable, Codable, Sendable {
    /// Row-major 3×3.
    var m: [Double]

    init(rowMajor m: [Double]) {
        precondition(m.count == 9)
        self.m = m
    }

    init(_ s: simd_double3x3) {
        // simd is column-major: s[col][row]
        m = [s[0][0], s[1][0], s[2][0],
             s[0][1], s[1][1], s[2][1],
             s[0][2], s[1][2], s[2][2]]
    }

    static let identity = Homography(rowMajor: [1, 0, 0, 0, 1, 0, 0, 0, 1])

    var simd: simd_double3x3 {
        simd_double3x3(rows: [SIMD3(m[0], m[1], m[2]), SIMD3(m[3], m[4], m[5]), SIMD3(m[6], m[7], m[8])])
    }

    var inverse: Homography { Homography(simd.inverse) }

    static func * (a: Homography, b: Homography) -> Homography { Homography(a.simd * b.simd) }

    /// Maps a point; nil when it lands at (or behind) the line at infinity.
    func apply(_ p: Vec2) -> Vec2? {
        let w = m[6] * p.x + m[7] * p.y + m[8]
        guard abs(w) > 1e-12 else { return nil }
        return Vec2((m[0] * p.x + m[1] * p.y + m[2]) / w, (m[3] * p.x + m[4] * p.y + m[5]) / w)
    }

    /// Homogeneous w of the mapped point (sign tells which side of the camera for pose-built homographies).
    func w(_ p: Vec2) -> Double { m[6] * p.x + m[7] * p.y + m[8] }

    /// Largest singular value of the local Jacobian at `p` (output units per input unit).
    func maxScale(at p: Vec2, step: Double = 1e-3) -> Double {
        guard let o = apply(p), let ax = apply(Vec2(p.x + step, p.y)), let ay = apply(Vec2(p.x, p.y + step))
        else { return 0 }
        let a = (ax.x - o.x) / step, c = (ax.y - o.y) / step
        let b = (ay.x - o.x) / step, d = (ay.y - o.y) / step
        // σmax of [[a b][c d]]
        let s1 = a * a + b * b + c * c + d * d
        let det = a * d - b * c
        let disc = max(0, s1 * s1 - 4 * det * det)
        return ((s1 + disc.squareRoot()) / 2).squareRoot()
    }

    /// Direct Linear Transform with Hartley normalisation; least squares for > 4 points.
    /// Returns nil for degenerate input (fewer than 4 points, collinear points).
    static func estimate(from src: [Vec2], to dst: [Vec2]) -> Homography? {
        guard src.count == dst.count, src.count >= 4 else { return nil }
        guard let ts = normalizer(src), let td = normalizer(dst) else { return nil }
        let s = src.compactMap { ts.apply($0) }, d = dst.compactMap { td.apply($0) }
        // Normal equations AᵀA h = Aᵀb with h33 = 1.
        var ata = [Double](repeating: 0, count: 64)
        var atb = [Double](repeating: 0, count: 8)
        func add(_ row: [Double], _ rhs: Double) {
            for i in 0..<8 {
                atb[i] += row[i] * rhs
                for j in 0..<8 { ata[i * 8 + j] += row[i] * row[j] }
            }
        }
        for (p, q) in zip(s, d) {
            add([p.x, p.y, 1, 0, 0, 0, -q.x * p.x, -q.x * p.y], q.x)
            add([0, 0, 0, p.x, p.y, 1, -q.y * p.x, -q.y * p.y], q.y)
        }
        guard let h = LinearSolve.solve(ata, atb, n: 8) else { return nil }
        let hn = Homography(rowMajor: h + [1])
        let full = td.inverse * hn * ts
        guard full.m.allSatisfy(\.isFinite), abs(full.simd.determinant) > 1e-15 else { return nil }
        return full.normalized
    }

    /// Scale so that h33 = 1 (or the largest entry = 1 if h33 ≈ 0).
    var normalized: Homography {
        let k = abs(m[8]) > 1e-12 ? m[8] : (m.map(abs).max() ?? 1)
        return Homography(rowMajor: m.map { $0 / k })
    }

    /// RMS distance between mapped `src` and `dst`.
    func rmsError(from src: [Vec2], to dst: [Vec2]) -> Double {
        guard !src.isEmpty else { return 0 }
        var sum = 0.0
        for (p, q) in zip(src, dst) {
            guard let r = apply(p) else { return .infinity }
            sum += (r - q).lengthSquared
        }
        return (sum / Double(src.count)).squareRoot()
    }

    private static func normalizer(_ pts: [Vec2]) -> Homography? {
        let n = Double(pts.count)
        let c = pts.reduce(Vec2.zero, +) / n
        let meanDist = pts.reduce(0) { $0 + $1.distance(to: c) } / n
        guard meanDist > 1e-12 else { return nil }
        let k = 2.0.squareRoot() / meanDist
        return Homography(rowMajor: [k, 0, -k * c.x, 0, k, -k * c.y, 0, 0, 1])
    }
}

enum LinearSolve {
    /// Gaussian elimination with partial pivoting. `a` is row-major n×n.
    static func solve(_ a: [Double], _ b: [Double], n: Int) -> [Double]? {
        var a = a, b = b
        for col in 0..<n {
            var piv = col
            for r in (col + 1)..<max(col + 1, n) where abs(a[r * n + col]) > abs(a[piv * n + col]) { piv = r }
            guard abs(a[piv * n + col]) > 1e-14 else { return nil }
            if piv != col {
                for j in 0..<n { a.swapAt(col * n + j, piv * n + j) }
                b.swapAt(col, piv)
            }
            for r in 0..<n where r != col {
                let f = a[r * n + col] / a[col * n + col]
                if f == 0 { continue }
                for j in col..<n { a[r * n + j] -= f * a[col * n + j] }
                b[r] -= f * b[col]
            }
        }
        return (0..<n).map { b[$0] / a[$0 * n + $0] }
    }
}

import Foundation
import Geometry
import simd

/// Checks 4 placed corners form a plausible pool table; if not, names the corner that doesn't fit
/// so the UI can highlight just that one (no wipe).
enum CornerValidator {
    enum Check {
        case ok(TableFitter.Fit)
        /// Index into the input array of the corner to fix, and where a rectangle through the other 3 puts it.
        case outlier(index: Int, suggested: SIMD3<Double>)
    }

    static let lengthRange = 1.4...3.3      // m (bar box … 9 ft + slack)
    static let aspectRange = 1.6...2.5

    static func check(_ corners: [SIMD3<Double>], up: SIMD3<Double> = SIMD3(0, 1, 0),
                      viewer: SIMD3<Double>? = nil, size: TableSize? = nil) -> Check? {
        guard corners.count == 4 else { return nil }
        let n = simd_normalize(up)
        let c = corners.reduce(SIMD3<Double>(), +) / 4
        var e1 = corners[0] - c; e1 -= n * simd_dot(e1, n)
        guard simd_length(e1) > 1e-6 else { return .outlier(index: 0, suggested: corners[0]) }
        e1 = simd_normalize(e1)
        let e2 = simd_cross(n, e1)
        func p2(_ p: SIMD3<Double>) -> Vec2 { Vec2(simd_dot(p - c, e1), simd_dot(p - c, e2)) }
        let ring = corners.indices.sorted { p2(corners[$0]).angle < p2(corners[$1]).angle }
        let flat = ring.map { p2(corners[$0]) }

        // Score each corner by how well the OTHER three make a table-shaped right angle.
        func tripleScore(excluding i: Int) -> (score: Double, predicted: Vec2) {
            let a = flat[(i + 1) % 4], b = flat[(i + 2) % 4], cc = flat[(i + 3) % 4]
            let ab = a - b, cb = cc - b
            let la = ab.length, lc = cb.length
            guard la > 1e-6, lc > 1e-6 else { return (.infinity, a) }
            let cosB = abs(ab.dot(cb) / (la * lc))
            let ratio = max(la, lc) / min(la, lc)
            return (cosB + abs(log(ratio / 2)), a + cc - b)
        }
        let scores = (0..<4).map { tripleScore(excluding: $0) }
        let worst = (0..<4).min { scores[$0].score < scores[$1].score }!  // best triple excludes the outlier

        if let fit = TableFitter.fit(corners: corners, up: up, viewer: viewer, size: size) {
            let aspect = fit.measuredLength / max(1e-6, fit.measuredWidth)
            let closure = flat[worst].distance(to: scores[worst].predicted)
            if lengthRange.contains(fit.measuredLength), aspectRange.contains(aspect),
               closure < max(0.08, 0.06 * fit.measuredLength), allAnglesSquare(flat) {
                return .ok(fit)
            }
        }
        let p = scores[worst].predicted
        let suggested = c + e1 * p.x + e2 * p.y
        return .outlier(index: ring[worst], suggested: suggested)
    }

    private static func allAnglesSquare(_ q: [Vec2]) -> Bool {
        for i in 0..<4 {
            let a = q[(i + 3) % 4] - q[i], b = q[(i + 1) % 4] - q[i]
            guard a.length > 0, b.length > 0 else { return false }
            if abs(a.dot(b) / (a.length * b.length)) > cos(70 * .pi / 180) { return false }
        }
        return true
    }
}

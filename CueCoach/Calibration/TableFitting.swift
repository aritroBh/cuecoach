import Foundation
import Geometry
import simd

/// Table size from measurement (D12): snap to the nearest preset; report how far off the best preset is.
enum TableSizing {
    struct Result: Equatable, Sendable {
        var size: TableSize
        /// Relative error vs the chosen preset (0.03 = 3 %).
        var relativeError: Double
        /// True when the measurement is close enough to trust the preselection.
        var confident: Bool { relativeError <= 0.06 }
    }

    /// Length and width in metres (playing surface). Width counts as 2× (tables are 2:1).
    /// D50: no size was picked here, so only 7/8/9 ft are candidates (callers with a picked size use it directly).
    static func snap(length: Double, width: Double) -> Result {
        let est = (length + 2 * width) / 2
        let best = TableSize.autoSnapCandidates(prior: nil).min { abs($0.playingLength - est) < abs($1.playingLength - est) }!
        return Result(size: best, relativeError: abs(best.playingLength - est) / best.playingLength)
    }
}

/// Fits the table frame to 4 cloth-corner points in world space.
enum TableFitter {
    struct Fit: Sendable {
        var frame: TableFrame
        var measuredLength: Double
        var measuredWidth: Double
        var sizing: TableSizing.Result
        /// RMS distance from the input corners to the fitted rectangle's corners (m).
        var residual: Double
    }

    /// - Parameters:
    ///   - corners: 4 points in any order (each roughly a corner pocket).
    ///   - up: world up (ARKit: +y).
    ///   - viewer: camera position; the short side nearest it becomes the head (x = 0).
    ///   - size: force a preset; nil = snap the measurement.
    static func fit(corners: [SIMD3<Double>], up: SIMD3<Double> = SIMD3(0, 1, 0),
                    viewer: SIMD3<Double>? = nil, size: TableSize? = nil) -> Fit? {
        guard corners.count == 4 else { return nil }
        let n = simd_normalize(up)
        let c = corners.reduce(SIMD3<Double>(), +) / 4
        // In-plane basis.
        var e1 = corners[0] - c; e1 -= n * simd_dot(e1, n)
        guard simd_length(e1) > 1e-6 else { return nil }
        e1 = simd_normalize(e1)
        let e2 = simd_cross(n, e1)
        func p2(_ p: SIMD3<Double>) -> Vec2 { Vec2(simd_dot(p - c, e1), simd_dot(p - c, e2)) }
        let sorted = corners.sorted { p2($0).angle < p2($1).angle }  // CCW around up
        // Edges i→i+1. Long edges are 0-1 & 2-3, or 1-2 & 3-0.
        let len = (0..<4).map { simd_distance(sorted[$0], sorted[($0 + 1) % 4]) }
        let firstLong = len[0] + len[2] >= len[1] + len[3]
        let measuredL = firstLong ? (len[0] + len[2]) / 2 : (len[1] + len[3]) / 2
        let measuredW = firstLong ? (len[1] + len[3]) / 2 : (len[0] + len[2]) / 2
        guard measuredW > 0.2, measuredL > 0.3 else { return nil }
        // Long axis direction: average of the two long edges (made parallel).
        // Opposite long edges taken in the same direction.
        let a = firstLong ? sorted[1] - sorted[0] : sorted[2] - sorted[1]
        let b = firstLong ? sorted[2] - sorted[3] : sorted[3] - sorted[0]
        var axis = simd_normalize(a) + simd_normalize(b)
        axis -= n * simd_dot(axis, n)
        guard simd_length(axis) > 1e-6 else { return nil }
        var xAxis = simd_normalize(axis)
        // Head = end nearer the viewer → +x points away from the viewer.
        if let v = viewer, simd_dot(v - c, xAxis) > 0 { xAxis = -xAxis }
        let yAxis = simd_cross(n, xAxis)
        let sizing = TableSizing.snap(length: measuredL, width: measuredW)
        let spec = TableSpec(size: size ?? sizing.size)
        let origin = c - xAxis * (spec.length / 2) - yAxis * (spec.width / 2)
        let m = simd_double4x4(columns: (SIMD4(xAxis, 0), SIMD4(yAxis, 0), SIMD4(n, 0), SIMD4(origin, 1)))
        let frame = TableFrame(tableToWorld: m, spec: spec)
        // Residual: each input to its nearest fitted corner.
        let fitted = frame.corners.map { frame.world($0) }
        let res = (corners.reduce(0.0) { acc, p in acc + (fitted.map { simd_distance_squared($0, p) }.min() ?? 0) } / 4)
            .squareRoot()
        return Fit(frame: frame, measuredLength: measuredL, measuredWidth: measuredW, sizing: sizing, residual: res)
    }

    /// Felt boundary (outer, includes cushion tops) → playing-surface corners, inset by `cushion` metres
    /// along both in-plane diagonals' edge normals.
    static func insetQuad(_ q: [SIMD3<Double>], by cushion: Double, up: SIMD3<Double> = SIMD3(0, 1, 0)) -> [SIMD3<Double>] {
        guard q.count == 4 else { return q }
        let c = q.reduce(SIMD3<Double>(), +) / 4
        let n = simd_normalize(up)
        return (0..<4).map { i in
            let p = q[i], prev = q[(i + 3) % 4], next = q[(i + 1) % 4]
            func inward(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> SIMD3<Double> {
                var nn = simd_normalize(simd_cross(n, b - a))
                if simd_dot(nn, c - a) < 0 { nn = -nn }
                return nn
            }
            let n1 = inward(prev, p), n2 = inward(p, next)
            // Move so the point is `cushion` inside both edges: p + α n1 + β n2 solved for symmetric case.
            let cosT = simd_dot(n1, n2)
            let k = cushion / max(1e-3, 1 + cosT)
            return p + (n1 + n2) * k
        }
    }
}

/// Least-squares plane through 3D points with outlier trimming (LiDAR depth → table top).
enum PlaneFit {
    static func fit(_ pts: [SIMD3<Double>], up: SIMD3<Double> = SIMD3(0, 1, 0),
                    iterations: Int = 3, trim: Double = 0.02) -> Plane3? {
        var use = pts
        var plane: Plane3?
        for _ in 0..<iterations {
            guard use.count >= 3, let p = fitOnce(use, up: up) else { break }
            plane = p
            let kept = pts.filter { abs(simd_dot($0 - p.point, p.normal)) <= trim }
            if kept.count < 3 || kept.count == use.count { use = kept.count >= 3 ? kept : use; break }
            use = kept
        }
        if let p = plane, use.count >= 3 { return fitOnce(use, up: up) ?? p }
        return plane
    }

    /// Smallest-eigenvector of the covariance via inverse power iteration.
    private static func fitOnce(_ pts: [SIMD3<Double>], up: SIMD3<Double>) -> Plane3? {
        let c = pts.reduce(SIMD3<Double>(), +) / Double(pts.count)
        var cov = simd_double3x3()
        for p in pts {
            let d = p - c
            cov += simd_double3x3(columns: (d * d.x, d * d.y, d * d.z))
        }
        let shifted = cov + simd_double3x3(diagonal: SIMD3(repeating: 1e-12))
        guard abs(shifted.determinant) > 1e-30 else { return Plane3(point: c, normal: simd_normalize(up)) }
        let inv = shifted.inverse
        var v = simd_normalize(up)
        for _ in 0..<50 { v = simd_normalize(inv * v) }
        if simd_dot(v, up) < 0 { v = -v }
        return Plane3(point: c, normal: v)
    }
}

/// 2D-only calibration (no camera pose: replayed video, stills). Image corners + approximate intrinsics.
enum ImageCalibration {
    /// Orders 4 image points (any order) to table corners headLeft, headRight, footRight, footLeft by picking
    /// the assignment whose homography decomposes into the most rigid rotation under `k`.
    static func orderCorners(_ pts: [Vec2], spec: TableSpec, intrinsics k: CameraIntrinsics) -> [Vec2]? {
        guard pts.count == 4 else { return nil }
        let c = pts.reduce(Vec2.zero, +) / 4
        let ring = pts.sorted { ($0 - c).angle < ($1 - c).angle }
        let candidates: [[Vec2]] = (0..<4).flatMap { s -> [[Vec2]] in
            let fwd = (0..<4).map { ring[(s + $0) % 4] }
            let rev = (0..<4).map { ring[(s + 4 - $0) % 4] }
            return [fwd, rev]
        }
        let table = TableFrame(tableToWorld: matrix_identity_double4x4, spec: spec).corners
        var best: (cost: Double, pts: [Vec2])?
        for cand in candidates {
            guard let h = Homography.estimate(from: table, to: cand) else { continue }
            let cost = rigidityCost(h, k)
            if best == nil || cost < best!.cost { best = (cost, cand) }
        }
        return best?.pts
    }

    static func rigidityCost(_ h: Homography, _ k: CameraIntrinsics) -> Double {
        let kinv = simd_double3x3(rows: [SIMD3(k.fx, 0, k.cx), SIMD3(0, k.fy, k.cy), SIMD3(0, 0, 1)]).inverse
        let mm = kinv * h.simd
        let m1 = mm.columns.0, m2 = mm.columns.1
        let n1 = simd_length(m1), n2 = simd_length(m2)
        guard n1 > 0, n2 > 0 else { return .infinity }
        return abs(log(n1 / n2)) + abs(simd_dot(m1, m2) / (n1 * n2))
    }

    /// SPEC §5.1: ball centres sit one radius above the cloth. Decompose the cloth homography (table→image)
    /// into a pose with `k` and build the ball-plane homography.
    static func ballPlane(cloth h: Homography, intrinsics k: CameraIntrinsics,
                          height: Double = TableSpec.ballRadius) -> Homography? {
        let kk = simd_double3x3(rows: [SIMD3(k.fx, 0, k.cx), SIMD3(0, k.fy, k.cy), SIMD3(0, 0, 1)])
        let mm = kk.inverse * h.simd
        var m1 = mm.columns.0, m2 = mm.columns.1, m3 = mm.columns.2
        var lambda = 2 / (simd_length(m1) + simd_length(m2))
        guard lambda.isFinite else { return nil }
        if (m3 * lambda).z < 0 { lambda = -lambda }  // table in front of the camera
        m1 *= lambda; m2 *= lambda; m3 *= lambda
        // Orthonormalise r1, r2 symmetrically.
        let cc = simd_normalize(m1 + m2), dd = simd_normalize(m1 - m2)
        let r1 = (cc + dd) / 2.0.squareRoot(), r2 = (cc - dd) / 2.0.squareRoot()
        var r3 = simd_cross(r1, r2)
        // r3 must point toward the camera (CV camera at origin; camera centre in table frame has +z).
        if -simd_dot(r3, m3) < 0 { r3 = -r3 }
        let t = m3 + r3 * height
        return Homography(kk * simd_double3x3(columns: (r1, r2, t))).normalized
    }

    /// Full 2D calibration from 4 tapped image points.
    static func geometry(imageCorners: [Vec2], spec: TableSpec, intrinsics: CameraIntrinsics) -> FrameGeometry? {
        guard let ordered = orderCorners(imageCorners, spec: spec, intrinsics: intrinsics) else { return nil }
        let table = TableFrame(tableToWorld: matrix_identity_double4x4, spec: spec).corners
        guard let cloth = Homography.estimate(from: table, to: ordered),
              let ball = ballPlane(cloth: cloth, intrinsics: intrinsics) else { return nil }
        return FrameGeometry(cloth: cloth, ball: ball, spec: spec)
    }
}

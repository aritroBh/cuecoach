import Foundation
import Geometry
import simd

/// A horizontal surface ARKit reports (world, y-up).
struct LocatorPlane: Sendable, Equatable {
    var center: SIMD3<Double>
    var extent: SIMD2<Double>     // x, z size in metres
    var isTable: Bool             // ARKit plane classification == .table
}

/// Input to a table locator: one frame plus the AR context.
struct LocatorFrame: Sendable {
    var image: PixelImage
    var camera: CameraModel
    var planes: [LocatorPlane]
    var timestamp: Double
}

/// Current belief about where the table is.
struct TableEstimate: Sendable, Equatable {
    /// Playing-surface corners in world space (any order).
    var corners: [SIMD3<Double>]
    /// 0…1; the ghost table fades in as this grows.
    var confidence: Double
    /// True once stable enough to lock without a tap.
    var locked: Bool
    var size: TableSize?
}

/// Seam between the live screen and table finding. `AutoTableLocator` (Calibration/Auto, separate worker)
/// and a Core ML keypoint locator plug in here; `FeltQuadLocator` is the interim implementation.
protocol TableLocating: Sendable {
    func ingest(_ frame: LocatorFrame) async -> TableEstimate?
    func reset() async
}

enum LocatorMath {
    /// Table plane for a felt quad: the plane under the quad centre (classified table first, then the
    /// highest horizontal plane below the camera that the centre ray hits inside its extent).
    static func plane(for centre: Vec2, camera: CameraModel, planes: [LocatorPlane]) -> Plane3? {
        let ray = camera.ray(through: centre)
        let below = planes.filter { $0.center.y < camera.position.y - 0.2 }
        let hits: [(LocatorPlane, SIMD3<Double>)] = below.compactMap { p in
            let pl = Plane3(point: p.center, normal: SIMD3(0, 1, 0))
            guard let h = pl.intersect(origin: ray.origin, direction: ray.direction) else { return nil }
            let inside = abs(h.x - p.center.x) <= p.extent.x / 2 + 0.3 && abs(h.z - p.center.z) <= p.extent.y / 2 + 0.3
            return inside ? (p, h) : nil
        }
        let pick = hits.first { $0.0.isTable } ?? hits.max { $0.0.center.y < $1.0.center.y }
        return pick.map { Plane3(point: $0.0.center, normal: SIMD3(0, 1, 0)) }
    }

    /// Match `new` corners to `ref` corners (nearest-first, one-to-one); returns `new` reordered like `ref`.
    static func align(_ new: [SIMD3<Double>], to ref: [SIMD3<Double>]) -> [SIMD3<Double>] {
        guard new.count == 4, ref.count == 4 else { return new }
        var pairs: [(Int, Int, Double)] = []
        for i in 0..<4 { for j in 0..<4 { pairs.append((i, j, simd_distance(ref[i], new[j]))) } }
        pairs.sort { $0.2 < $1.2 }
        var out = ref, usedI = Set<Int>(), usedJ = Set<Int>()
        for (i, j, _) in pairs where !usedI.contains(i) && !usedJ.contains(j) {
            out[i] = new[j]; usedI.insert(i); usedJ.insert(j)
        }
        return out
    }
}

/// Interim locator: felt-quad proposal per sampled frame, raycast to the table plane, fused over frames.
/// Confidence grows with consistent agreement; locks when the last `lockCount` samples agree within `tolerance`
/// and the shape validates as a table.
actor FeltQuadLocator: TableLocating {
    var lockCount = 6
    var tolerance = 0.035
    var minInterval = 0.2
    private var history: [[SIMD3<Double>]] = []
    private var lastT = -Double.infinity
    private var locked: TableEstimate?

    func reset() { history = []; lastT = -.infinity; locked = nil }

    func ingest(_ f: LocatorFrame) -> TableEstimate? {
        if let locked { return locked }
        guard f.timestamp - lastT >= minInterval else { return current() }
        lastT = f.timestamp
        guard let quad = FeltQuadProposer.propose(f.image) else { return current() }
        let centre = quad.reduce(Vec2.zero, +) / 4
        guard let plane = LocatorMath.plane(for: centre, camera: f.camera, planes: f.planes) else { return current() }
        let outer = quad.compactMap { f.camera.intersect(pixel: $0, with: plane) }
        guard outer.count == 4 else { return current() }
        var inner = TableFitter.insetQuad(outer, by: SyntheticTableScene.cushionWidth)
        if let ref = history.last { inner = LocatorMath.align(inner, to: ref) }
        history.append(inner)
        if history.count > 12 { history.removeFirst() }
        guard var est = current() else { return nil }
        if est.confidence >= 1, case .ok(let fit)? = CornerValidator.check(est.corners, viewer: f.camera.position) {
            est.locked = true
            est.size = fit.sizing.size
            locked = est
        }
        return est
    }

    /// Median corners of the recent agreeing run; confidence = agreeing run length / lockCount.
    private func current() -> TableEstimate? {
        guard let last = history.last else { return nil }
        var run = 0
        for h in history.reversed() {
            if zip(h, last).allSatisfy({ simd_distance($0, $1) < tolerance * 2 }) { run += 1 } else { break }
        }
        let recent = Array(history.suffix(run))
        let med = (0..<4).map { i -> SIMD3<Double> in
            func m(_ k: KeyPath<SIMD3<Double>, Double>) -> Double {
                let v = recent.map { $0[i][keyPath: k] }.sorted()
                return v[v.count / 2]
            }
            return SIMD3(m(\.x), m(\.y), m(\.z))
        }
        let spread = recent.map { h in zip(h, med).map { simd_distance($0, $1) }.max() ?? 0 }.max() ?? 0
        let agreeing = spread < tolerance ? run : max(1, run / 2)
        return TableEstimate(corners: med, confidence: min(1, Double(agreeing) / Double(lockCount)), locked: false,
                             size: TableFitter.fit(corners: med)?.sizing.size)
    }
}

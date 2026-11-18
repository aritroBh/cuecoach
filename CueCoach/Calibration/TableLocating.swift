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
    /// LiDAR scene depth aligned with the image (provisional plane + cloth gate); nil without LiDAR.
    var depth: DepthMap? = nil
    /// ARKit tracking is `.normal`.
    var trackingNormal: Bool = true
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
    /// Why it hasn't locked (nil once locked or while converging normally).
    var failure: LockFailure? = nil
    /// The locator's exact table pose when locked (install this, don't re-fit the corners).
    var frame: TableFrame? = nil
    /// Bumps on every new lock / re-lock / held-size change; rebuild the overlay when it changes.
    var generation: Int = 0
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
        // Each anchor is an infinite horizontal plane at its height (early anchors are small, and their extents
        // are rotated — no extent test). Never the floor: a phone over a pool table is < 1.4 m above the cloth.
        let lowest = planes.map(\.center.y).min()
        let candidates = planes.filter { p in
            let below = camera.position.y - p.center.y
            guard below > 0.2, below < floorDrop else { return false }
            if let floor = lowest, p.center.y - floor > 0.4 { return (0.55...1.1).contains(p.center.y - floor) }
            return true
        }
        let ray = camera.ray(through: centre)
        let hits = candidates.filter {
            Plane3(point: $0.center, normal: SIMD3(0, 1, 0)).intersect(origin: ray.origin, direction: ray.direction) != nil
        }
        let pick = hits.first { $0.isTable } ?? hits.max { $0.center.y < $1.center.y }
        return pick.map { Plane3(point: $0.center, normal: SIMD3(0, 1, 0)) }
    }

    /// A surface more than this far below the camera is the floor, not a pool table (lock plan step 3).
    static let floorDrop = 1.4

    /// No ARKit anchor yet: is the dominant LiDAR level under the image centre the floor?
    static func depthLevelIsFloor(_ d: DepthMap, camera: CameraModel) -> Bool {
        let k = camera.intrinsics.scaled(toWidth: Double(d.width), height: Double(d.height))
        var ys: [Double] = []
        for v in stride(from: d.height / 3, to: 2 * d.height / 3, by: 2) {
            for u in stride(from: d.width / 3, to: 2 * d.width / 3, by: 2) {
                let z = Double(d.value(u, v))
                guard z.isFinite, z > 0.1 else { continue }
                let pc = SIMD4((Double(u) + 0.5 - k.cx) / k.fx * z, -(Double(v) + 0.5 - k.cy) / k.fy * z, -z, 1)
                ys.append((camera.cameraToWorld * pc).y)
            }
        }
        guard ys.count > 10 else { return false }
        ys.sort()
        return camera.position.y - ys[ys.count / 2] > floorDrop
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
    /// No own throttle (FrameTap's gate + busy flag bound the load).
    var minInterval = 0.0
    /// Forget history after a timestamp gap or a run of failures (codex-7).
    var expireAfterGap = 1.0
    var expireAfterFailures = 5
    private var failures = 0
    private var history: [[SIMD3<Double>]] = []
    private var lastT = -Double.infinity
    private var locked: TableEstimate?

    func reset() { history = []; lastT = -.infinity; locked = nil; failures = 0 }

    func ingest(_ f: LocatorFrame) -> TableEstimate? {
        if let locked { return locked }
        guard f.timestamp - lastT >= minInterval else { return current() }
        if lastT.isFinite && f.timestamp - lastT > expireAfterGap { history = []; failures = 0 }
        lastT = f.timestamp
        func failing(_ why: LockFailure) -> TableEstimate {
            failures += 1
            if failures >= expireAfterFailures { history = []; failures = 0 }
            var e = current() ?? TableEstimate(corners: [], confidence: 0, locked: false, size: nil)
            e.failure = why
            return e
        }
        let analysis = FeltQuadProposer.analyze(f.image)
        guard let quad = analysis.quad else { return failing(analysis.failure ?? .noFelt) }
        let centre = quad.reduce(Vec2.zero, +) / 4
        guard !f.planes.isEmpty else { return failing(.noPlane) }
        guard let plane = LocatorMath.plane(for: centre, camera: f.camera, planes: f.planes) else { return failing(.noPlane) }
        // The felt boundary is the rail cap (AutoTableProfile): intersect at rail-top height, inset the cushion
        // width there, then drop back to the cloth (lock plan step 1, sim-F1 / codex-5).
        let profile = AutoTableProfile()
        let railTop = Plane3(point: plane.point + plane.normal * profile.railTopHeight, normal: plane.normal)
        let outer = quad.compactMap { f.camera.intersect(pixel: $0, with: railTop) }
        guard outer.count == 4 else { return failing(.badShape) }
        failures = 0
        var inner = TableFitter.insetQuad(outer, by: profile.cushionWidth).map { $0 - plane.normal * profile.railTopHeight }
        if let ref = history.last { inner = LocatorMath.align(inner, to: ref) }
        history.append(inner)
        if history.count > 12 { history.removeFirst() }
        guard var est = current() else { return nil }
        let check = CornerValidator.check(est.corners, viewer: f.camera.position)
        if est.confidence >= 1, case .ok(let fit)? = check, fit.sizing.confident, fit.residual < 0.05 {
            est.locked = true
            est.size = fit.sizing.size
            est.failure = nil
            locked = est
        } else if case .outlier? = check {
            est.failure = .badShape
        } else if est.confidence < 0.5 && history.count >= 3 {
            est.failure = .unstable
        }
        return est
    }

    /// Median corners of the recent agreeing run; confidence = agreeing run length / lockCount.
    private func current() -> TableEstimate? {
        guard let last = history.last, last.count == 4 else { return nil }
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

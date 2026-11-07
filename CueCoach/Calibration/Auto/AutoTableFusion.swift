import Foundation
import Geometry
import simd

/// One frame's table measurement in world space.
struct AutoTableMeasurement: Sendable {
    /// Playing-surface centre at cloth height.
    var center: SIMD3<Double>
    /// Unit major axis (either sign — a rectangle is symmetric under 180°).
    var axis: SIMD3<Double>
    var up: SIMD3<Double>
    /// Free-fit nose-to-nose size.
    var measuredLength: Double
    var measuredWidth: Double
    var snapped: TableSize?
    var cameraPosition: SIMD3<Double>
}

struct AutoFusionConfig: Sendable {
    var window = 30
    /// Frames that must agree before locking.
    var lockFrames = 15
    /// Robust spread of per-frame corners that allows a lock (m).
    var lockCornerSpread = 0.01
    /// A frame whose corners are this far from the fused ones disagrees (m).
    var disagreeDistance = 0.04
    /// This many consecutive disagreeing frames = the table (or tracking) changed → re-lock.
    /// They must also agree with each other (spread < `disagreeDistance`), else the oldest is dropped.
    var relockFrames = 10
    /// While locked the table size is held; only a size change larger than this is adopted, and it
    /// bumps `generation` (m, playing length).
    var sizeChangeTolerance = 0.015
}

/// Multi-frame fusion in world coordinates: robust (median → Huber) pose over a sliding window,
/// lock on stability, keep validating, re-lock when consistent disagreement appears.
struct AutoTableFusion: Sendable {
    var config = AutoFusionConfig()
    private(set) var window: [AutoTableMeasurement] = []
    private var disagreeing: [AutoTableMeasurement] = []
    private(set) var locked = false
    private(set) var generation = 0
    /// World direction head → foot chosen at lock (nil before the first lock).
    private var headToFoot: SIMD3<Double>?
    private var flipPending = false
    private(set) var fused: AutoTablePose?
    private(set) var spread: Double = .infinity
    private var deviations: [Double] = []
    /// Size held since lock (spec, snapped preset).
    private var heldSize: (spec: TableSpec, snapped: TableSize?)?

    mutating func reset() { self = AutoTableFusion(config: config) }

    mutating func flip() {
        if let h = headToFoot { headToFoot = -h } else { flipPending.toggle() }
        if let f = fused, let p = Self.pose(center: f.center, axis: f.xAxis, up: f.up, spec: f.spec,
                                           snapped: f.snappedSize, measured: (f.measuredLength, f.measuredWidth),
                                           headToFoot: -f.xAxis) {
            fused = p
        }
    }

    /// Adds a measurement (or a miss) and updates the fused pose. Returns whether the frame agreed.
    @discardableResult
    mutating func add(_ m: AutoTableMeasurement?) -> Bool {
        guard let m else { return false }
        if let f = fused, window.count >= 5 {
            let dev = Self.deviation(m, from: f)
            if dev > config.disagreeDistance {
                disagreeing.append(m)
                if disagreeing.count >= config.relockFrames {
                    if Self.selfConsistent(disagreeing, spec: f.spec, tolerance: config.disagreeDistance) {
                        // Consistent new evidence: start over from it (keep the head choice by direction).
                        window = disagreeing
                        disagreeing = []
                        locked = false
                        deviations = []
                        heldSize = nil
                        recompute(camera: m.cameraPosition)
                    } else {
                        // Scattered glitches, not a moved table: keep the lock, age out the oldest.
                        disagreeing.removeFirst()
                    }
                }
                return false
            }
            disagreeing.removeAll()
            deviations.append(dev)
        }
        window.append(m)
        if window.count > config.window { window.removeFirst(window.count - config.window) }
        if deviations.count > config.window { deviations.removeFirst(deviations.count - config.window) }
        recompute(camera: m.cameraPosition)
        return true
    }

    var progress: Double {
        guard fused != nil else { return 0 }
        let n = min(1, Double(window.count) / Double(config.lockFrames))
        let s = spread.isFinite ? min(1, config.lockCornerSpread / max(spread, 1e-6)) : 0
        return min(0.99, 0.6 * n + 0.4 * s)
    }

    // MARK: Internals

    private mutating func recompute(camera: SIMD3<Double>) {
        guard !window.isEmpty else { fused = nil; return }
        let up = simd_normalize(window.last!.up)
        func yaw(_ a: SIMD3<Double>) -> Double { atan2(a.z, a.x) }
        let ref = fused.map { yaw($0.xAxis) } ?? yaw(window.last!.axis)
        let angles = window.map { ref + autoWrapHalfPi(yaw($0.axis) - ref) }
        var cx = autoMedian(window.map(\.center.x)), cy = autoMedian(window.map(\.center.y))
        var cz = autoMedian(window.map(\.center.z))
        var th = autoMedian(angles)
        // Huber refinement (δ = 1 cm / 0.3°).
        for _ in 0..<3 {
            var sw = 0.0, sx = 0.0, sy = 0.0, sz = 0.0, swt = 0.0, st = 0.0
            for (i, m) in window.enumerated() {
                let r = simd_distance(m.center, SIMD3(cx, cy, cz))
                let w = r <= 0.01 ? 1 : 0.01 / r
                sw += w; sx += w * m.center.x; sy += w * m.center.y; sz += w * m.center.z
                let ra = abs(angles[i] - th)
                let wt = ra <= 0.005 ? 1 : 0.005 / ra
                swt += wt; st += wt * angles[i]
            }
            cx = sx / sw; cy = sy / sw; cz = sz / sw; th = st / swt
        }
        // Size: majority preset, else the median measurement at 2:1.
        var votes: [TableSize: Int] = [:]
        for m in window { if let s = m.snapped { votes[s, default: 0] += 1 } }
        var spec: TableSpec
        var snapped: TableSize?
        let mL = autoMedian(window.map(\.measuredLength)), mW = autoMedian(window.map(\.measuredWidth))
        if let (s, n) = votes.max(by: { $0.value < $1.value }), Double(n) >= 0.6 * Double(window.count) {
            spec = TableSpec(size: s); snapped = s
        } else {
            let (s, _) = AutoRectFitter.snap(length: mL, width: mW)
            spec = TableSpec(size: s)
            let len = (mL + 2 * mW) / 2
            spec.length = len; spec.width = len / 2
        }
        // Locked: hold the size so corners never move without a new generation.
        if locked, let held = heldSize {
            if abs(spec.length - held.spec.length) > config.sizeChangeTolerance {
                heldSize = (spec, snapped)
                generation += 1
            } else {
                spec = held.spec; snapped = held.snapped
            }
        }
        var axis = SIMD3(cos(th), 0, sin(th))
        axis -= up * simd_dot(axis, up)
        axis = simd_normalize(axis)
        let center = SIMD3(cx, cy, cz)
        // Head/foot: kept by direction once locked; before that, head = short rail nearer the camera.
        var h2f = headToFoot ?? (simd_dot(camera - center, axis) > 0 ? -axis : axis)
        if headToFoot == nil && flipPending { h2f = -h2f }
        guard let pose = Self.pose(center: center, axis: axis, up: up, spec: spec, snapped: snapped,
                                   measured: (mL, mW), headToFoot: h2f) else { return }
        fused = pose
        // Spread over the most recent frames.
        let recent = window.suffix(config.lockFrames)
        let devs = recent.map { Self.deviation($0, from: pose) }
        spread = recent.count >= 3 ? autoMedian(devs) : .infinity
        if !locked, window.count >= config.lockFrames, spread < config.lockCornerSpread,
           Double(devs.filter { $0 < 1.5 * config.lockCornerSpread }.count) >= 0.8 * Double(devs.count) {
            locked = true
            generation += 1
            heldSize = (spec, snapped)
            if headToFoot == nil { headToFoot = h2f; flipPending = false }
        }
        if let h = headToFoot, abs(simd_dot(h, pose.xAxis)) < 0.7 {
            // Re-locked onto a table turned by ~90°: re-derive head from the camera.
            headToFoot = simd_dot(camera - center, axis) > 0 ? -axis : axis
        }
    }

    static func pose(center: SIMD3<Double>, axis: SIMD3<Double>, up: SIMD3<Double>, spec: TableSpec,
                     snapped: TableSize?, measured: (Double, Double), headToFoot: SIMD3<Double>) -> AutoTablePose? {
        var x = simd_dot(axis, headToFoot) >= 0 ? axis : -axis
        x -= up * simd_dot(x, up)
        guard simd_length(x) > 1e-6 else { return nil }
        x = simd_normalize(x)
        let y = simd_cross(up, x)
        let o = center - x * (spec.length / 2) - y * (spec.width / 2)
        let m = simd_double4x4(columns: (SIMD4(x, 0), SIMD4(y, 0), SIMD4(up, 0), SIMD4(o, 1)))
        return AutoTablePose(tableToWorld: m, spec: spec, snappedSize: snapped,
                             measuredLength: measured.0, measuredWidth: measured.1)
    }

    /// Do the measurements agree with each other: ≥ 80 % within `tolerance` of their own median pose?
    static func selfConsistent(_ ms: [AutoTableMeasurement], spec: TableSpec, tolerance: Double) -> Bool {
        guard let first = ms.first else { return false }
        let c = SIMD3(autoMedian(ms.map(\.center.x)), autoMedian(ms.map(\.center.y)), autoMedian(ms.map(\.center.z)))
        let ref = ms.min { simd_distance($0.center, c) < simd_distance($1.center, c) } ?? first
        guard let p = pose(center: c, axis: ref.axis, up: ref.up, spec: spec, snapped: nil,
                           measured: (ref.measuredLength, ref.measuredWidth), headToFoot: ref.axis) else { return false }
        let ok = ms.filter { deviation($0, from: p) < tolerance }.count
        return Double(ok) >= 0.8 * Double(ms.count)
    }

    /// Max corner distance between a measurement (at the fused size) and the fused pose, mod 180°.
    static func deviation(_ m: AutoTableMeasurement, from f: AutoTablePose) -> Double {
        let up = f.up
        var x = m.axis - up * simd_dot(m.axis, up)
        x = simd_normalize(x)
        if simd_dot(x, f.xAxis) < 0 { x = -x }
        let y = simd_cross(up, x)
        let L = f.spec.length / 2, W = f.spec.width / 2
        let mc = [m.center - x * L - y * W, m.center - x * L + y * W, m.center + x * L + y * W, m.center + x * L - y * W]
        let fc = f.corners
        return (0..<4).map { simd_distance(mc[$0], fc[$0]) }.max()!
    }
}

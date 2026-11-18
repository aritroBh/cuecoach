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
    /// Fraction of the playing length actually seen (1 = whole table; < 1 = partial fit completed by 2:1 + preset).
    var visibleLengthFraction: Double = 1
    /// false = the size is a guess, not a measurement: a corner-anchored partial fit chose the preset by how well its
    /// outline fills the cloth mask (a cloth the colour of its rails fills a preset one size up: felt-tan seed 10), or a
    /// three-rail fit whose one measured axis fits two presets.
    /// Such a frame casts no size vote, cannot back a lock's size, and is pose evidence only under its own preset.
    var sizeMeasured = true
}

struct AutoFusionConfig: Sendable {
    var window = 30
    /// Adaptive lock: this few frames suffice when their robust corner spread is ≤ `lockCornerSpread`…
    var fastLockFrames = 6
    /// …otherwise this many frames with spread ≤ `slowLockCornerSpread`. Never above that.
    var lockFrames = 15
    /// Robust spread of per-frame corners that allows a fast lock (m).
    var lockCornerSpread = 0.01
    /// A size decision needs at least this many size votes in the window (one fit is not a size).
    var minSizeVotes = 3
    /// Robust spread that allows a lock after `lockFrames` frames (m).
    var slowLockCornerSpread = 0.02
    /// A frame whose corners are this far from the fused ones disagrees (m).
    var disagreeDistance = 0.04
    /// This many consecutive disagreeing frames = the table (or tracking) changed → re-lock.
    /// They must also agree with each other (spread < `disagreeDistance`), else the oldest is dropped.
    var relockFrames = 10
    /// While locked the table size is held; only a size change larger than this is adopted, and it
    /// bumps `generation` (m, playing length).
    var sizeChangeTolerance = 0.015
    /// Preset vote share that snaps the size (D12 majority).
    var snapVoteShare = 0.6
    /// Hysteresis band around `snapVoteShare` while locked: a held preset is dropped only below
    /// share − band, a held measured size switches to a preset only above share + band.
    var snapVoteBand = 0.15
    /// While locked, a different size must be the candidate this many consecutive frames before adoption.
    var sizeAdoptFrames = 10
    /// A partial-view window locks only if some frame saw this much of the length…
    var partialLockVisibleFraction = 0.6
    /// …or its view directions (camera around the table centre) span at least this angle (rad).
    var partialLockViewSpread = 15 * Double.pi / 180
    /// D36 (C): the size chosen in game setup or Settings (nil = none). A measured frame within `priorSnap` of it
    /// votes for it; it never stands in for a measurement (guessed frames stay guesses).
    var prior: TableSize?
    var priorSnap = 0.06
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
    /// The window holds ≥ `minSizeVotes` size votes (`votesOnSize`). A lock needs them: with guessed or
    /// between-preset sizes only, fusion converges but waits (fail closed, never a guessed size).
    private(set) var sizeBacked = false
    /// The size decision is a preset, or an off-preset size outside the presets' range (a bar box, a 10 ft). An
    /// unsnapped size between the smallest and largest preset means the frames disagree (no preset majority, or
    /// fits between two presets: dist-2.0m seed 3 fused 7 ft fits with long tracked fits to 2.19 m): never lock it.
    private(set) var sizeDecided = false
    /// Both: the size can be locked.
    var sizeSettled: Bool { sizeBacked && sizeDecided }
    /// D36: unsettled although the window holds enough measured frames, and their size lies between the presets:
    /// the whole table is in view, the problem is its size (the hint says so instead of "step back").
    private(set) var sizeBetweenPresets = false
    static let presetSpan: ClosedRange<Double> = {
        let l = TableSize.allCases.map(\.playingLength)
        return l.min()!...l.max()!
    }()
    private var deviations: [Double] = []
    /// Size held since lock (spec, snapped preset).
    private var heldSize: (spec: TableSpec, snapped: TableSize?)?
    /// Candidate size that differs from the held one, and for how many consecutive frames.
    private var pendingSize: (spec: TableSpec, snapped: TableSize?, frames: Int)?

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
                        pendingSize = nil
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
        let n = min(1, Double(window.count) / Double(config.fastLockFrames))
        let s = spread.isFinite ? min(1, config.lockCornerSpread / max(spread, 1e-6)) : 0
        return min(0.99, 0.6 * n + 0.4 * s)
    }

    // MARK: Internals

    private mutating func recompute(camera: SIMD3<Double>) {
        guard !window.isEmpty else { fused = nil; return }
        // Size: majority preset, else the median measurement at 2:1. While locked the vote threshold has
        // a hysteresis band around the held choice, so a table near the 6 % snap edge does not flap.
        // Only frames that measured the size vote on it (a guessed size is never size evidence).
        let sizing = window.filter(votesOnSize)
        sizeBacked = sizing.count >= config.minSizeVotes
        let voters = sizeBacked ? sizing : window
        var votes: [TableSize: Int] = [:]
        for m in voters { if let s = snap(m) { votes[s, default: 0] += 1 } }
        var spec: TableSpec
        var snapped: TableSize?
        let mL = autoMedian(voters.map(\.measuredLength)), mW = autoMedian(voters.map(\.measuredWidth))
        let n = Double(voters.count), top = votes.max(by: { $0.value < $1.value })
        var preset: TableSize?
        if locked, let held = heldSize {
            // A held preset stays while it keeps ≥ share − band of the votes (whoever else leads); any other
            // preset, or a preset after a measured size, needs ≥ share + band.
            if let hp = held.snapped, Double(votes[hp] ?? 0) >= (config.snapVoteShare - config.snapVoteBand) * n {
                preset = hp
            } else if let (s, c) = top, Double(c) >= (config.snapVoteShare + config.snapVoteBand) * n {
                preset = s
            }
        } else if let (s, c) = top, Double(c) >= config.snapVoteShare * n {
            preset = s
        }
        if let s = preset {
            spec = TableSpec(size: s); snapped = s
        } else {
            let (s, _) = AutoRectFitter.snap(length: mL, width: mW, prior: config.prior)
            spec = TableSpec(size: s)
            let len = (mL + 2 * mW) / 2
            spec.length = len; spec.width = len / 2
        }
        sizeDecided = snapped != nil || !Self.presetSpan.contains(spec.length)
        let measuredFrames = window.filter(\.sizeMeasured)
        sizeBetweenPresets = !sizeSettled && measuredFrames.count >= config.minSizeVotes
            && Self.presetSpan.contains(autoMedian(measuredFrames.map(Self.estimate)))
        // Locked: hold the size so corners never move without a new generation. A different size is
        // adopted only after it has been the (self-consistent) candidate for `sizeAdoptFrames` frames.
        if locked, let held = heldSize {
            if !sizeSettled {
                // Nothing in the window measured a size, or it sits between presets: hold the locked one.
                pendingSize = nil
                spec = held.spec; snapped = held.snapped
            } else if abs(spec.length - held.spec.length) > config.sizeChangeTolerance {
                if let p = pendingSize, p.snapped == snapped,
                   abs(p.spec.length - spec.length) <= config.sizeChangeTolerance {
                    pendingSize = (spec, snapped, p.frames + 1)
                } else {
                    pendingSize = (spec, snapped, 1)
                }
                if let p = pendingSize, p.frames >= config.sizeAdoptFrames {
                    heldSize = (spec, snapped)
                    pendingSize = nil
                    generation += 1
                } else {
                    spec = held.spec; snapped = held.snapped
                }
            } else {
                pendingSize = nil
                spec = held.spec; snapped = held.snapped
            }
        }
        // The pose's measured size (what the adapter's ambiguity check reads) comes from the votes for the chosen
        // preset, not from frames that abstained (Grok 4.7: a 7 ft lock read 2.19 m and stopped being published).
        // Locked with no such vote in the window, the last measured size stays.
        // While locked, fewer than `minSizeVotes` size votes never move it (Grok 4.7 r2: one borderline 8 ft snap at
        // 2.21 m among abstainers became the measured size, the adapter stopped trusting the lock, and it stuck).
        var measured = (mL, mW)
        if let s = snapped {
            let mine = voters.filter { snap($0) == s && votesOnSize($0) }
            if locked, !sizeBacked, let f = fused { measured = (f.measuredLength, f.measuredWidth) }
            else if !mine.isEmpty { measured = (autoMedian(mine.map(\.measuredLength)), autoMedian(mine.map(\.measuredWidth))) }
            else if locked, let f = fused { measured = (f.measuredLength, f.measuredWidth) }
        }
        // Pose from the frames consistent with that size: a guessed frame (see `sizeMeasured`) was centred for its own
        // preset, so for any other size it is no pose evidence (bar-rive-combo seed 5: 7 ft guesses centred a 9 ft pose
        // 25 cm off).
        func consistent(_ m: AutoTableMeasurement) -> Bool { m.sizeMeasured || m.snapped == snapped }
        let posing = window.contains(where: consistent) ? window.filter(consistent) : window
        let up = simd_normalize(posing.last!.up)
        func yaw(_ a: SIMD3<Double>) -> Double { atan2(a.z, a.x) }
        let ref = fused.map { yaw($0.xAxis) } ?? yaw(posing.last!.axis)
        let angles = posing.map { ref + autoWrapHalfPi(yaw($0.axis) - ref) }
        var cx = autoMedian(posing.map(\.center.x)), cy = autoMedian(posing.map(\.center.y))
        var cz = autoMedian(posing.map(\.center.z))
        var th = autoMedian(angles)
        // Huber refinement (δ = 1 cm / 0.3°).
        for _ in 0..<3 {
            var sw = 0.0, sx = 0.0, sy = 0.0, sz = 0.0, swt = 0.0, st = 0.0
            for (i, m) in posing.enumerated() {
                let r = simd_distance(m.center, SIMD3(cx, cy, cz))
                let w = r <= 0.01 ? 1 : 0.01 / r
                sw += w; sx += w * m.center.x; sy += w * m.center.y; sz += w * m.center.z
                let ra = abs(angles[i] - th)
                let wt = ra <= 0.005 ? 1 : 0.005 / ra
                swt += wt; st += wt * angles[i]
            }
            cx = sx / sw; cy = sy / sw; cz = sz / sw; th = st / swt
        }
        var axis = SIMD3(cos(th), 0, sin(th))
        axis -= up * simd_dot(axis, up)
        axis = simd_normalize(axis)
        let center = SIMD3(cx, cy, cz)
        // Head/foot: kept by direction once locked; before that, head = short rail nearer the camera.
        var h2f = headToFoot ?? (simd_dot(camera - center, axis) > 0 ? -axis : axis)
        if headToFoot == nil && flipPending { h2f = -h2f }
        guard let pose = Self.pose(center: center, axis: axis, up: up, spec: spec, snapped: snapped,
                                   measured: measured, headToFoot: h2f) else { return }
        fused = pose
        // Spread over the most recent frames.
        let recent = window.suffix(config.lockFrames)
        func dev(_ m: AutoTableMeasurement) -> Double { consistent(m) ? Self.deviation(m, from: pose) : .infinity }
        let devs = recent.map(dev)
        spread = recent.count >= 3 ? autoMedian(devs) : .infinity
        func agrees(frames: Int, spread limit: Double) -> Bool {
            guard window.count >= frames else { return false }
            let d = window.suffix(frames).map(dev)
            return autoMedian(d) <= limit && Double(d.filter { $0 < 1.5 * limit }.count) >= 0.8 * Double(d.count)
                && Self.partialViewsAgree(window, center: center, up: up, config: config)
        }
        if !locked, sizeSettled, agrees(frames: config.fastLockFrames, spread: config.lockCornerSpread)
            || agrees(frames: config.lockFrames, spread: config.slowLockCornerSpread) {
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

    /// A frame votes on the size if it measured it (`sizeMeasured`) and the measurement names one: an unsnapped fit
    /// between the smallest and largest preset sits between two neighbours (as far from one as from the other) and
    /// abstains, though it is still pose evidence (cross-vendor review, Grok 4.7: dist-2.0m seed 3 tracked fits).
    /// D36 (C): a measured frame within `priorSnap` of the chosen size votes for it.
    func votesOnSize(_ m: AutoTableMeasurement) -> Bool {
        m.sizeMeasured && (snap(m) != nil || !Self.presetSpan.contains(Self.estimate(m)))
    }

    /// The preset a frame votes for: the chosen size if it measured within `priorSnap` of it, else its own snap.
    func snap(_ m: AutoTableMeasurement) -> TableSize? {
        if let p = config.prior, m.sizeMeasured,
           abs(Self.estimate(m) - p.playingLength) / p.playingLength <= config.priorSnap { return p }
        return m.snapped
    }

    /// D12 size estimate of one frame, (L + 2W)/2.
    static func estimate(_ m: AutoTableMeasurement) -> Double { (m.measuredLength + 2 * m.measuredWidth) / 2 }

    /// A partial-view lock needs ≥ 60 % of the length seen in some frame, or ≥ 2 distinct view angles.
    static func partialViewsAgree(_ ms: [AutoTableMeasurement], center: SIMD3<Double>, up: SIMD3<Double>,
                                  config: AutoFusionConfig) -> Bool {
        guard ms.contains(where: { $0.visibleLengthFraction < 1 }) else { return true }
        if ms.contains(where: { $0.visibleLengthFraction >= config.partialLockVisibleFraction }) { return true }
        let dirs: [SIMD3<Double>] = ms.compactMap { m in
            var d = m.cameraPosition - center
            d -= up * simd_dot(d, up)
            return simd_length(d) > 0.1 ? simd_normalize(d) : nil
        }
        for i in dirs.indices { for j in dirs.indices where j > i {
            if acos(max(-1, min(1, simd_dot(dirs[i], dirs[j])))) >= config.partialLockViewSpread { return true }
        } }
        return false
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

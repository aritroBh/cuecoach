import Foundation
import Geometry

struct TrackedBall: Sendable, Equatable, Identifiable {
    var id: Int
    /// Filter position (predicted while the ball is not seen).
    var position: Vec2
    /// Filter velocity; exactly zero while the ball is still (zero-velocity rest model).
    var velocity: Vec2
    var kind: BallKind
    var tentativeNumber: Int?
    var confirmed: Bool
    /// A detection was associated with this track on this update (false while coasting).
    var measured: Bool = true
    /// Last associated measurement (never a prediction); nil = same as `position`.
    var lastMeasured: Vec2? = nil
    /// Start of the current unbroken run of measurements. A track re-born after an occlusion (even one that
    /// inherited an old id) starts a new run, so it carries no motion evidence from before the gap.
    var measuredSince: Double = -.infinity
    /// Share of the class votes held by `kind` (1 = every detection agreed).
    var kindShare: Double = 1
    /// Share of the number votes held by `tentativeNumber` (1 = every numbered detection agreed; 0 = no number).
    var numberShare: Double = 1
    var speed: Double { velocity.length }
    var measuredPosition: Vec2 { lastMeasured ?? position }
}

protocol BallTracker: Sendable {
    mutating func update(_ detections: [BallDetection], at t: Double) -> [TrackedBall]
    var isAtRest: Bool { get }
    mutating func reset()
}

/// Constant-velocity Kalman filter for one axis: state (position, velocity), white-noise acceleration.
struct CVKalman1D: Sendable, Equatable {
    var p: Double
    var v: Double
    /// Covariance [[pp, pv], [pv, vv]].
    var pp: Double, pv: Double, vv: Double

    init(position: Double, positionVar: Double, velocityVar: Double) {
        p = position; v = 0; pp = positionVar; pv = 0; vv = velocityVar
    }

    mutating func predict(dt: Double, q: Double) {
        p += v * dt
        let dt2 = dt * dt, dt3 = dt2 * dt
        let npp = pp + 2 * dt * pv + dt2 * vv + q * dt3 / 3
        let npv = pv + dt * vv + q * dt2 / 2
        let nvv = vv + q * dt
        pp = npp; pv = npv; vv = nvv
    }

    /// Innovation and its variance for a position measurement with variance r.
    func innovation(_ z: Double, r: Double) -> (y: Double, s: Double) { (z - p, pp + r) }

    mutating func update(_ z: Double, r: Double) {
        let (y, s) = innovation(z, r: r)
        let kp = pp / s, kv = pv / s
        p += kp * y
        v += kv * y
        let npp = (1 - kp) * pp
        let npv = (1 - kp) * pv
        let nvv = vv - kv * pv
        pp = npp; pv = npv; vv = nvv
    }

    /// Re-seed the state (a model switch: launch, collision); covariance widened so the filter re-learns fast.
    mutating func reseed(p: Double, v: Double, positionVar: Double, velocityVar: Double) {
        self.p = p; self.v = v; pp = positionVar; pv = 0; vv = velocityVar
    }
}

/// Per-ball Kalman tracker in table coordinates (SPEC §5.3) with Hungarian assignment on Mahalanobis distance;
/// majority-vote class; table-wide at-rest detection.
///
/// Motion models: constant velocity while rolling; zero velocity while still (rest jitter never reads as speed);
/// a launch model for a still ball that jumps (stroke onset at break speed); a contact model for touching balls
/// (velocity exchange along the line of centres, so a head-on hit does not swap ids). Tracks that die are kept
/// in a short graveyard so a ball that comes back after an occlusion inherits its id by colour and position.
struct KalmanBallTracker: BallTracker {
    struct Params: Sendable {
        var measurementSigma = 0.004   // m (detector jitter on the table)
        var accelNoise = 6.0           // (m/s²)² spectral density while rolling: friction + collisions
        var restAccelNoise = 0.05      // (m/s²)² while still
        var gateChi2 = 13.8            // 2 dof, 99.9 %
        var minGate = 0.03             // m: never gate tighter than this
        var maxMisses = 12
        var confirmHits = 3
        /// m/s: a ball whose fitted speed is below this (or below 3 standard errors of it) is still.
        var restSpeed = 0.05
        var restFrames = 15
        /// Measurements in the still test's regression window; at least `minStillSamples` are needed.
        var stillWindow = 15
        var minStillSamples = 5
        /// m/s: the noise-adaptive still threshold never exceeds this (a short window is noisy).
        var maxStillSpeed = 0.12
        /// A track whose residual scatter is above this while it goes nowhere is a flicker (reflection, a hand on
        /// the rail), not a ball: it does not hold the table out of rest.
        var jitterSigma = 0.009
        /// Fraction of the last 16 frames a track must have been measured in to count for at-rest.
        var minHitRatio = 0.7
        /// m/s: fastest launch a still ball may make between two frames and keep its track.
        var maxLaunchSpeed = 6.0
        /// Graveyard: how long a dead track's id can be inherited, and how fast it may have moved meanwhile.
        var graveyardSeconds = 10.0
        var graveyardSpeed = 2.5
        var graveyardCap = 32
        /// m: never inherit an id from farther away than this (a far birth is another ball or a false positive).
        var graveyardMaxReach = 1.0
        /// Misses that break the measurement run (`measuredSince` restarts after a longer gap).
        var continuityMisses = 3
        /// Added to the squared Mahalanobis cost when a detection's class disagrees with the track's.
        var classMismatchCost = 9.0
        /// m/s along the line of centres before a contact (velocity exchange) is hypothesised.
        var minClosingSpeed = 0.25
        /// m: a still ball measured this far from its rest point has started moving.
        var onsetJump = 0.02
    }

    private struct Track {
        var id: Int
        var x: CVKalman1D
        var y: CVKalman1D
        var hits: Int
        var misses: Int
        var votes: [BallKind: Double]
        var numberVotes: [Int: Double]
        var recent: [(p: Vec2, t: Double)] = []
        var lastMeasured: Vec2
        var measuredSince: Double
        var hitBits: UInt16 = 1
        var age = 1
        var still = false
        var lowQuality = false
        /// Per-axis measurement scatter from the still test's fit (m).
        var sigma = 0.0
        /// Mean of the recent measurements (the rest point while still).
        var centre: Vec2 = .zero
        var pos: Vec2 { Vec2(x.p, y.p) }
        var vel: Vec2 { Vec2(x.v, y.v) }
        var kind: BallKind { votes.max { $0.value < $1.value }?.key ?? .unknown }
    }

    private struct Dead {
        var id: Int
        var pos: Vec2
        var t: Double
        var votes: [BallKind: Double]
        var numberVotes: [Int: Double]
        var kind: BallKind { votes.max { $0.value < $1.value }?.key ?? .unknown }
    }

    /// Prediction under one motion model, kept so the winning model can re-seed the filter.
    private struct Hypothesis { var pos: Vec2; var vel: Vec2; var extraVar: Double; var reseed: Bool }

    var params = Params()
    private var tracks: [Track] = []
    private var graveyard: [Dead] = []
    private var nextID = 1
    private var lastT: Double?
    private(set) var stillFrames = 0

    init(params: Params = Params()) { self.params = params }

    var isAtRest: Bool { stillFrames >= params.restFrames }

    mutating func reset() { tracks = []; graveyard = []; lastT = nil; stillFrames = 0 }

    mutating func update(_ raw: [BallDetection], at t: Double) -> [TrackedBall] {
        let detections = raw.filter { $0.tablePoint.x.isFinite && $0.tablePoint.y.isFinite }
        let dt = lastT.map { max(1e-3, min(0.5, t - $0)) } ?? (1.0 / 30)
        lastT = t
        let r = params.measurementSigma * params.measurementSigma
        let R = TableSpec.ballRadius

        // Contact model: balls touching (or about to) may exchange velocity along the line of centres.
        var hyps: [[Hypothesis]] = tracks.map { _ in [] }
        for i in tracks.indices {
            for j in tracks.indices where j > i {
                let pi = tracks[i].pos, pj = tracks[j].pos
                let vi = tracks[i].still ? .zero : tracks[i].vel, vj = tracks[j].still ? .zero : tracks[j].vel
                // Time of contact inside this frame: |d + w τ| = 2R, τ ∈ [0, dt] (0 when already touching).
                let d = pj - pi, w = vj - vi
                guard d.length < 2 * R + w.length * dt + 0.01, d.length > 1e-6 else { continue }
                var tau = 0.0
                if d.length > 2 * R {
                    let a = w.dot(w), b = 2 * d.dot(w), c = d.dot(d) - 4 * R * R
                    let disc = b * b - 4 * a * c
                    guard a > 1e-9, disc >= 0 else { continue }
                    tau = (-b - disc.squareRoot()) / (2 * a)
                    guard tau >= 0, tau <= dt else { continue }
                }
                let ci = pi + vi * tau, cj = pj + vj * tau
                let n = (cj - ci).normalized
                let closing = (vi - vj).dot(n)
                // A real hit: a confirmed ball closing fast (filter noise on touching balls at rest is not one).
                guard closing > params.minClosingSpeed, tracks[i].hits >= params.confirmHits,
                      tracks[j].hits >= params.confirmHits else { continue }
                let vi2 = vi - n * closing, vj2 = vj + n * closing
                let rest = dt - tau
                hyps[i].append(Hypothesis(pos: ci + vi2 * rest, vel: vi2, extraVar: 0.006 * 0.006, reseed: true))
                hyps[j].append(Hypothesis(pos: cj + vj2 * rest, vel: vj2, extraVar: 0.006 * 0.006, reseed: true))
            }
        }

        // A hypothesis that puts a ball inside another one is impossible (a frozen rack passes the hit on).
        for i in hyps.indices where !hyps[i].isEmpty {
            hyps[i].removeAll { h in tracks.indices.contains { j in j != i && tracks[j].still && tracks[j].pos.distance(to: h.pos) < 1.6 * R } }
        }
        for i in tracks.indices {
            tracks[i].age += 1
            let q = tracks[i].still ? params.restAccelNoise : params.accelNoise
            tracks[i].x.predict(dt: dt, q: q)
            tracks[i].y.predict(dt: dt, q: q)
        }

        // Pass 1: Hungarian on squared Mahalanobis distance, best motion model per pair; outside every gate = no.
        var bestHyp: [[Int]] = []   // -1 = constant velocity
        let cost: [[Double]] = tracks.indices.map { ti in
            let tr = tracks[ti]
            let trKind = tr.kind
            var row: [Double] = [], hrow: [Int] = []
            for det in detections {
                // A detection of another class (cue vs solid…) is a worse match, not an impossible one: the
                // colour classifier flickers. This keeps a coasting object track off the cue ball rolling by.
                let classCost = tr.hits >= params.confirmHits && !Self.compatible(trKind, det.kind) ? params.classMismatchCost : 0
                let ix = tr.x.innovation(det.tablePoint.x, r: r), iy = tr.y.innovation(det.tablePoint.y, r: r)
                var best = ix.y * ix.y / ix.s + iy.y * iy.y / iy.s
                var inGate = best <= params.gateChi2 || tr.pos.distance(to: det.tablePoint) < params.minGate
                var bh = -1
                for (k, h) in hyps[ti].enumerated() {
                    let dx = det.tablePoint.x - h.pos.x, dy = det.tablePoint.y - h.pos.y
                    let m2 = dx * dx / (ix.s + h.extraVar) + dy * dy / (iy.s + h.extraVar)
                    if m2 < best { best = m2; bh = k }
                    if m2 <= params.gateChi2 { inGate = true }
                }
                row.append(inGate ? best + classCost : 1e6)
                hrow.append(bh)
            }
            bestHyp.append(hrow)
            return row
        }
        var pairs = tracks.isEmpty || detections.isEmpty ? [] : Assignment.solve(cost, gate: 1e5)
        var usedT = Set(pairs.map(\.0)), usedD = Set(pairs.map(\.1))

        // Pass 2: motion onset. A track measured last frame that lost its gate re-associates with a nearby
        // unclaimed detection of the same class (a stroke launching a still ball at break speed, a bounce).
        var launched = Set<Int>()
        let freeT = tracks.indices.filter { !usedT.contains($0) && tracks[$0].misses == 0 && tracks[$0].hits >= params.confirmHits }
        let freeD = detections.indices.filter { !usedD.contains($0) }
        if !freeT.isEmpty && !freeD.isEmpty {
            let c2: [[Double]] = freeT.map { ti in
                let tr = tracks[ti]
                return freeD.map { di in
                    let det = detections[di]
                    guard Self.compatible(tr.kind, det.kind) else { return 1e6 }
                    // Still: a launch from the last measurement. Moving: an abrupt turn (cushion, kiss) within
                    // one frame's travel of the prediction or of the last measurement.
                    let slow = tr.still || tr.vel.length < 0.5
                    let reach = slow ? params.maxLaunchSpeed * dt : tr.vel.length * dt + params.minGate
                    let fromLast = tr.lastMeasured.distance(to: det.tablePoint)
                    let d = slow ? fromLast : min(fromLast, tr.pos.distance(to: det.tablePoint))
                    // Same class but a different number guess: allowed (numbers flicker), but dearer.
                    let num = tr.numberVotes.max { $0.value < $1.value }?.key
                    let penalty = num != nil && det.tentativeNumber != nil && num != det.tentativeNumber ? 0.06 : 0
                    return d <= reach ? d + penalty : 1e6
                }
            }
            for (a, b) in Assignment.solve(c2, gate: 1e5) {
                let ti = freeT[a], di = freeD[b]
                pairs.append((ti, di)); usedT.insert(ti); usedD.insert(di); launched.insert(ti)
            }
        }

        // Frame shift (relocalization, a small AR pose jump): several still balls jump by the same vector in
        // one frame. That is the table frame moving, not balls: re-anchor them and break their measurement run
        // so nothing reads it as a launch or a shot.
        let shifted = isFrameShift(pairs, detections)
        for (ti, di) in pairs {
            let det = detections[di]
            let z = det.tablePoint
            if shifted && tracks[ti].still && tracks[ti].hits >= params.confirmHits {
                tracks[ti].x.reseed(p: z.x, v: 0, positionVar: r, velocityVar: 1e-3)
                tracks[ti].y.reseed(p: z.y, v: 0, positionVar: r, velocityVar: 1e-3)
                tracks[ti].recent = []
                tracks[ti].measuredSince = t
                launched.remove(ti)
                tracks[ti].hits += 1; tracks[ti].misses = 0
                tracks[ti].lastMeasured = z
                tracks[ti].hitBits = (tracks[ti].hitBits << 1) | 1
                tracks[ti].recent.append((z, t))
                tracks[ti].votes[det.kind, default: 0] += det.confidence
                if let n = det.tentativeNumber { tracks[ti].numberVotes[n, default: 0] += det.confidence }
                continue
            }
            // A still ball whose measurement jumped (inside the min gate) is launching too: follow it at once.
            if tracks[ti].still && tracks[ti].centre.distance(to: z) > max(params.onsetJump, 5 * tracks[ti].sigma) { launched.insert(ti) }
            if launched.contains(ti) {
                let v = (z - (tracks[ti].still ? tracks[ti].centre : tracks[ti].lastMeasured)) / dt
                tracks[ti].x.reseed(p: z.x, v: v.x, positionVar: r, velocityVar: 1.0)
                tracks[ti].y.reseed(p: z.y, v: v.y, positionVar: r, velocityVar: 1.0)
                tracks[ti].recent = []
                tracks[ti].still = false
            } else {
                let h = bestHyp[ti][di]
                if h >= 0 {
                    let hy = hyps[ti][h]
                    let before = tracks[ti].still ? Vec2.zero : tracks[ti].vel
                    tracks[ti].x.reseed(p: hy.pos.x, v: hy.vel.x, positionVar: tracks[ti].x.pp + hy.extraVar, velocityVar: 0.5)
                    tracks[ti].y.reseed(p: hy.pos.y, v: hy.vel.y, positionVar: tracks[ti].y.pp + hy.extraVar, velocityVar: 0.5)
                    // A new motion regime: rest samples from before the hit don't count.
                    if (hy.vel - before).length > 0.2 { tracks[ti].recent = [] }
                    tracks[ti].still = false
                }
                tracks[ti].x.update(z.x, r: r)
                tracks[ti].y.update(z.y, r: r)
            }
            if tracks[ti].misses > params.continuityMisses { tracks[ti].measuredSince = t }
            tracks[ti].hits += 1; tracks[ti].misses = 0
            tracks[ti].lastMeasured = z
            tracks[ti].hitBits = (tracks[ti].hitBits << 1) | 1
            tracks[ti].recent.append((z, t))
            if tracks[ti].recent.count > params.stillWindow { tracks[ti].recent.removeFirst() }
            tracks[ti].votes[det.kind, default: 0] += det.confidence
            if let n = det.tentativeNumber { tracks[ti].numberVotes[n, default: 0] += det.confidence }
        }
        for i in tracks.indices where !usedT.contains(i) {
            tracks[i].misses += 1
            tracks[i].hitBits <<= 1
            // A coasting ball is not extrapolated far: it was most likely stopped, pocketed or hidden.
            if tracks[i].misses >= 2 {
                tracks[i].x.v *= 0.6; tracks[i].y.v *= 0.6
            }
        }
        // Dead tracks: confirmed ones go to the graveyard so their id can come back.
        let dying = tracks.filter { $0.misses > params.maxMisses || ($0.hits < params.confirmHits && $0.misses > 2) }
        for d in dying where d.hits >= params.confirmHits {
            graveyard.append(Dead(id: d.id, pos: d.lastMeasured, t: t, votes: d.votes, numberVotes: d.numberVotes))
        }
        tracks.removeAll { $0.misses > params.maxMisses || ($0.hits < params.confirmHits && $0.misses > 2) }
        graveyard.removeAll { t - $0.t > params.graveyardSeconds }
        if graveyard.count > params.graveyardCap { graveyard.removeFirst(graveyard.count - params.graveyardCap) }

        // Births: inherit a dead id by class and position (Hungarian on distance, reach grows with the gap).
        let births = detections.indices.filter { !usedD.contains($0) }
        var inherited: [Int: Dead] = [:]
        if !births.isEmpty && !graveyard.isEmpty {
            let c3: [[Double]] = births.map { di in
                let det = detections[di]
                return graveyard.map { g in
                    guard det.kind != .unknown, g.kind == det.kind else { return 1e6 }
                    if let n = det.tentativeNumber, let gn = g.numberVotes.max(by: { $0.value < $1.value })?.key, n != gn { return 1e6 }
                    let reach = min(params.graveyardMaxReach, 0.04 + params.graveyardSpeed * max(0, t - g.t))
                    let d = g.pos.distance(to: det.tablePoint)
                    return d <= reach ? d : 1e6
                }
            }
            var takenG = Set<Int>()
            for (a, b) in Assignment.solve(c3, gate: 1e5) { inherited[births[a]] = graveyard[b]; takenG.insert(b) }
            graveyard = graveyard.enumerated().filter { !takenG.contains($0.offset) }.map(\.element)
        }
        for di in births {
            let det = detections[di]
            let old = inherited[di]
            var votes = old?.votes ?? [:]
            votes[det.kind, default: 0] += det.confidence
            var nv = old?.numberVotes ?? [:]
            if let n = det.tentativeNumber { nv[n, default: 0] += det.confidence }
            let id = old?.id ?? nextID
            if old == nil { nextID += 1 }
            tracks.append(Track(id: id,
                                x: CVKalman1D(position: det.tablePoint.x, positionVar: r, velocityVar: 0.25),
                                y: CVKalman1D(position: det.tablePoint.y, positionVar: r, velocityVar: 0.25),
                                hits: 1, misses: 0, votes: votes, numberVotes: nv,
                                recent: [(det.tablePoint, t)], lastMeasured: det.tablePoint, measuredSince: t))
        }

        // Still test + zero-velocity rest model.
        for i in tracks.indices {
            let (still, low, sigma, centre) = stillness(tracks[i])
            tracks[i].centre = centre
            tracks[i].still = still
            tracks[i].lowQuality = low
            tracks[i].sigma = sigma
            if still {
                tracks[i].x.v = 0; tracks[i].y.v = 0
                tracks[i].x.pv = 0; tracks[i].y.pv = 0
                tracks[i].x.vv = min(tracks[i].x.vv, 1e-3); tracks[i].y.vv = min(tracks[i].y.vv, 1e-3)
            }
        }
        let out = snapshot()
        // At rest: every confirmed, good-quality track is still. Flickering or jittering junk is ignored.
        // A flicker (seen in < 70 % of recent frames) counts only on frames it is actually seen, so a real ball
        // coming out from behind an arm or a pocket's dead zone still holds the table out of rest.
        let counted = tracks.filter { tr in
            tr.hits >= params.confirmHits && !tr.lowQuality
                && (tr.misses == 0 || Double(tr.hitBits.nonzeroBitCount) / Double(min(16, tr.age)) >= params.minHitRatio)
        }
        if !counted.isEmpty && counted.allSatisfy(\.still) {
            stillFrames += 1
        } else {
            stillFrames = 0
        }
        return out
    }

    /// ≥ 2 still confirmed balls (and ≥ 60 % of those matched) jumped this frame by one common vector (±1.5 cm).
    private func isFrameShift(_ pairs: [(Int, Int)], _ detections: [BallDetection]) -> Bool {
        let still = pairs.filter { tracks[$0.0].still && tracks[$0.0].hits >= params.confirmHits }
        let jumps: [Vec2] = still.compactMap { ti, di in
            let tr = tracks[ti]
            let d = detections[di].tablePoint - tr.centre
            return d.length > max(params.onsetJump, 5 * tr.sigma) ? d : nil
        }
        guard jumps.count >= 2, Double(jumps.count) >= 0.6 * Double(still.count) else { return false }
        func med(_ xs: [Double]) -> Double { let s = xs.sorted(); return s[s.count / 2] }
        let m = Vec2(med(jumps.map(\.x)), med(jumps.map(\.y)))
        return jumps.allSatisfy { ($0 - m).length < 0.015 }
    }

    static func compatible(_ a: BallKind, _ b: BallKind) -> Bool { a == b || a == .unknown || b == .unknown }

    /// Least-squares velocity over the recent measurements. Still = slower than `restSpeed`, or not
    /// significantly moving given the track's own scatter (3 standard errors). Low quality = large scatter
    /// going nowhere.
    private func stillness(_ tr: Track) -> (still: Bool, lowQuality: Bool, sigma: Double, centre: Vec2) {
        let n = tr.recent.count
        guard n >= params.minStillSamples else { return (false, false, tr.sigma, tr.lastMeasured) }
        let tm = tr.recent.reduce(0.0) { $0 + $1.t } / Double(n)
        let pm = tr.recent.reduce(Vec2.zero) { $0 + $1.p } / Double(n)
        var stt = 0.0, sx = 0.0, sy = 0.0
        for s in tr.recent { let dtt = s.t - tm; stt += dtt * dtt; sx += dtt * (s.p.x - pm.x); sy += dtt * (s.p.y - pm.y) }
        guard stt > 1e-9 else { return (false, false, tr.sigma, pm) }
        let v = Vec2(sx / stt, sy / stt)
        var res = 0.0
        for s in tr.recent {
            let f = pm + v * (s.t - tm)
            res += s.p.distance(to: f) * s.p.distance(to: f)
        }
        let sigma = (res / Double(2 * max(1, n - 2))).squareRoot()   // per axis
        let se = sigma / stt.squareRoot()
        // Motion onset: the newest measurement left the window's mean by far more than its scatter.
        let last = tr.recent[n - 1]
        let jumped = last.p.distance(to: pm + v * (last.t - tm)) > max(params.onsetJump, 5 * sigma)
        let still = !jumped && v.length < max(params.restSpeed, min(params.maxStillSpeed, 3 * se))
        // Jitter = scatter that goes nowhere: the first and last thirds of the window sit on top of each other.
        // (A decelerating or turning ball also fits a line badly, but it travels.)
        let k = max(1, n / 3)
        let head = tr.recent.prefix(k).reduce(Vec2.zero) { $0 + $1.p } / Double(k)
        let tail = tr.recent.suffix(k).reduce(Vec2.zero) { $0 + $1.p } / Double(k)
        let low = sigma > params.jitterSigma && v.length < 0.2 && head.distance(to: tail) < 2 * sigma
        return (still, low, sigma, pm)
    }

    private func snapshot() -> [TrackedBall] {
        tracks.map { tr in
            let kind = tr.kind
            let num = tr.numberVotes.max { $0.value < $1.value }?.key
            let total = tr.votes.values.reduce(0, +)
            return TrackedBall(id: tr.id, position: tr.pos, velocity: tr.still ? .zero : tr.vel, kind: kind,
                               tentativeNumber: num, confirmed: tr.hits >= params.confirmHits,
                               measured: tr.misses == 0, lastMeasured: tr.lastMeasured,
                               measuredSince: tr.measuredSince,
                               kindShare: total > 0 ? (tr.votes[kind] ?? 0) / total : 0,
                               numberShare: num.map { n in (tr.numberVotes[n] ?? 0) / max(1e-9, tr.numberVotes.values.reduce(0, +)) } ?? 0)
        }
    }
}

import Foundation
import Geometry

struct TrackedBall: Sendable, Equatable, Identifiable {
    var id: Int
    var position: Vec2
    var velocity: Vec2
    var kind: BallKind
    var tentativeNumber: Int?
    var confirmed: Bool
    var speed: Double { velocity.length }
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
}

/// Per-ball constant-velocity Kalman tracker in table coordinates (SPEC §5.3) with Hungarian assignment
/// on Mahalanobis distance; majority-vote class; table-wide at-rest detection.
struct KalmanBallTracker: BallTracker {
    struct Params: Sendable {
        var measurementSigma = 0.004   // m (detector jitter on the table)
        var accelNoise = 6.0           // (m/s²)² spectral density: rolling + collisions
        var gateChi2 = 13.8            // 2 dof, 99.9 %
        var minGate = 0.03             // m: never gate tighter than this
        var maxMisses = 12
        var confirmHits = 3
        var restSpeed = 0.05           // m/s (unused by the window test; kept for callers)
        var restFrames = 15
        /// A ball is still when the RMS spread of its last `stillWindow` measurements is below `stillRadius`.
        var stillWindow = 8
        var stillRadius = 0.008
    }

    private struct Track {
        var id: Int
        var x: CVKalman1D
        var y: CVKalman1D
        var hits: Int
        var misses: Int
        var votes: [BallKind: Double]
        var numberVotes: [Int: Double]
        var recent: [Vec2] = []
        var pos: Vec2 { Vec2(x.p, y.p) }
        var vel: Vec2 { Vec2(x.v, y.v) }
    }

    var params = Params()
    private var tracks: [Track] = []
    private var nextID = 1
    private var lastT: Double?
    private(set) var stillFrames = 0

    init(params: Params = Params()) { self.params = params }

    var isAtRest: Bool { stillFrames >= params.restFrames }

    mutating func reset() { tracks = []; lastT = nil; stillFrames = 0 }

    mutating func update(_ detections: [BallDetection], at t: Double) -> [TrackedBall] {
        let dt = lastT.map { max(1e-3, min(0.5, t - $0)) } ?? (1.0 / 30)
        lastT = t
        let r = params.measurementSigma * params.measurementSigma
        for i in tracks.indices {
            tracks[i].x.predict(dt: dt, q: params.accelNoise)
            tracks[i].y.predict(dt: dt, q: params.accelNoise)
        }
        // Hungarian on squared Mahalanobis distance; outside the gate = not assignable.
        let cost: [[Double]] = tracks.map { tr in
            detections.map { det in
                let ix = tr.x.innovation(det.tablePoint.x, r: r), iy = tr.y.innovation(det.tablePoint.y, r: r)
                let m2 = ix.y * ix.y / ix.s + iy.y * iy.y / iy.s
                let inGate = m2 <= params.gateChi2 || tr.pos.distance(to: det.tablePoint) < params.minGate
                return inGate ? m2 : 1e6
            }
        }
        let pairs = tracks.isEmpty || detections.isEmpty ? [] : Assignment.solve(cost, gate: 1e5)
        var usedT = Set<Int>(), usedD = Set<Int>()
        for (ti, di) in pairs {
            usedT.insert(ti); usedD.insert(di)
            let det = detections[di]
            tracks[ti].x.update(det.tablePoint.x, r: r)
            tracks[ti].y.update(det.tablePoint.y, r: r)
            tracks[ti].hits += 1; tracks[ti].misses = 0
            tracks[ti].recent.append(det.tablePoint)
            if tracks[ti].recent.count > params.stillWindow { tracks[ti].recent.removeFirst() }
            tracks[ti].votes[det.kind, default: 0] += det.confidence
            if let n = det.tentativeNumber { tracks[ti].numberVotes[n, default: 0] += det.confidence }
        }
        for i in tracks.indices where !usedT.contains(i) {
            tracks[i].misses += 1
        }
        tracks.removeAll { $0.misses > params.maxMisses || ($0.hits < params.confirmHits && $0.misses > 2) }
        for (di, det) in detections.enumerated() where !usedD.contains(di) {
            tracks.append(Track(id: nextID,
                                x: CVKalman1D(position: det.tablePoint.x, positionVar: r, velocityVar: 0.25),
                                y: CVKalman1D(position: det.tablePoint.y, positionVar: r, velocityVar: 0.25),
                                hits: 1, misses: 0, votes: [det.kind: det.confidence],
                                numberVotes: det.tentativeNumber.map { [$0: det.confidence] } ?? [:],
                                recent: [det.tablePoint]))
            nextID += 1
        }
        let out = snapshot()
        let confirmedTracks = tracks.filter { $0.hits >= params.confirmHits }
        if !confirmedTracks.isEmpty && confirmedTracks.allSatisfy({ isStill($0) }) {
            stillFrames += 1
        } else {
            stillFrames = 0
        }
        return out
    }

    private func isStill(_ tr: Track) -> Bool {
        guard tr.recent.count >= min(params.stillWindow, 5) else { return false }
        let mean = tr.recent.reduce(Vec2.zero, +) / Double(tr.recent.count)
        let ms = tr.recent.reduce(0.0) { $0 + $1.distance(to: mean) * $1.distance(to: mean) } / Double(tr.recent.count)
        return ms.squareRoot() < params.stillRadius   // RMS spread: robust to single-frame jitter
    }

    private func snapshot() -> [TrackedBall] {
        tracks.map { tr in
            let kind = tr.votes.max { $0.value < $1.value }?.key ?? .unknown
            let num = tr.numberVotes.max { $0.value < $1.value }?.key
            return TrackedBall(id: tr.id, position: tr.pos, velocity: tr.vel, kind: kind, tentativeNumber: num,
                               confirmed: tr.hits >= params.confirmHits)
        }
    }
}

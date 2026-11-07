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

/// v0 tracker in table coordinates: greedy nearest-neighbour association, alpha-beta
/// (constant-velocity) smoothing, majority-vote class, table-wide at-rest detection.
/// A Kalman tracker (SPEC §5.3) replaces it later.
struct SimpleBallTracker: BallTracker {
    struct Params: Sendable {
        var alpha = 0.55
        var beta = 0.12
        var baseGate = 0.07           // m
        var maxMisses = 12
        var confirmHits = 3
        var restSpeed = 0.05          // m/s
        var restFrames = 15
    }

    private struct Track {
        var id: Int
        var pos: Vec2
        var vel: Vec2
        var hits: Int
        var misses: Int
        var votes: [BallKind: Double]
        var numberVotes: [Int: Double]
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
        // Predict.
        for i in tracks.indices { tracks[i].pos += tracks[i].vel * dt }
        // Optimal (Hungarian) association on predicted positions, gated per track by its speed.
        // Normalised cost = distance / gate, so 1 is the gate for every track.
        let cost: [[Double]] = tracks.map { tr in
            let gate = params.baseGate + 2 * tr.vel.length * dt
            return detections.map { det in
                let d = tr.pos.distance(to: det.tablePoint) / gate
                return d <= 1 ? d : 1e6
            }
        }
        let pairs = tracks.isEmpty || detections.isEmpty ? [] : Assignment.solve(cost, gate: 1)
        var usedT = Set<Int>(), usedD = Set<Int>()
        for (ti, di) in pairs {
            usedT.insert(ti); usedD.insert(di)
            let det = detections[di]
            var tr = tracks[ti]
            let r = det.tablePoint - tr.pos
            tr.pos += r * params.alpha
            tr.vel += r * (params.beta / dt)
            tr.hits += 1; tr.misses = 0
            tr.votes[det.kind, default: 0] += det.confidence
            if let n = det.tentativeNumber { tr.numberVotes[n, default: 0] += det.confidence }
            tracks[ti] = tr
        }
        for i in tracks.indices where !usedT.contains(i) {
            tracks[i].misses += 1
            tracks[i].vel = tracks[i].vel * 0.7
        }
        tracks.removeAll { $0.misses > params.maxMisses || ($0.hits < params.confirmHits && $0.misses > 2) }
        for (di, det) in detections.enumerated() where !usedD.contains(di) {
            tracks.append(Track(id: nextID, pos: det.tablePoint, vel: .zero, hits: 1, misses: 0,
                                votes: [det.kind: det.confidence],
                                numberVotes: det.tentativeNumber.map { [$0: det.confidence] } ?? [:]))
            nextID += 1
        }
        let out = snapshot()
        let confirmed = out.filter(\.confirmed)
        if !confirmed.isEmpty && confirmed.allSatisfy({ $0.speed < params.restSpeed }) {
            stillFrames += 1
        } else {
            stillFrames = 0
        }
        return out
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

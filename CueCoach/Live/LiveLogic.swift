import Foundation
import Geometry
import Rules

/// Screen state, shown with icon + colour only.
enum LiveStatus: Equatable, Sendable {
    case searching      // sweep the phone; no table plane yet
    case placing        // plane found; corners being placed/adjusted
    case confirming     // 4 corners placed, waiting for ✓
    case calibrated     // tracking the table
    case trackingLost   // AR tracking limited: dim overlay, pulse recalibrate
    case phoneMoved     // a bump: pulse recalibrate briefly
    case relocking      // after relocalization: overlay dimmed, no perception, until the table locks again

    static func derive(planeFound: Bool, corners: Int, calibrated: Bool, trackingOK: Bool, bumped: Bool,
                       relocking: Bool = false) -> LiveStatus {
        if calibrated {
            if !trackingOK { return .trackingLost }
            if relocking { return .relocking }
            if bumped { return .phoneMoved }
            return .calibrated
        }
        if corners >= 4 { return .confirming }
        if !planeFound && corners == 0 { return .searching }
        return .placing
    }

    var showsRecalibratePulse: Bool { self == .trackingLost || self == .phoneMoved || self == .relocking }
    /// World-anchored guidance and perception results are only trusted in this state.
    var trustsTable: Bool { self == .calibrated || self == .phoneMoved }
}

/// Phone bump detector from CoreMotion user acceleration (g) and rotation rate (rad/s).
struct BumpDetector: Sendable {
    var accelThreshold = 0.35
    var rotationThreshold = 1.6
    var holdSeconds = 2.0
    private(set) var lastBump: Double?

    /// Returns true while within `holdSeconds` of the last bump.
    mutating func update(userAcceleration: Double, rotationRate: Double, at t: Double) -> Bool {
        if userAcceleration > accelThreshold || rotationRate > rotationThreshold { lastBump = t }
        guard let b = lastBump else { return false }
        return t - b < holdSeconds
    }
}

/// Ring colour per ball (MASTER: legal green, illegal red, cue white).
enum TargetMark: Equatable, Sendable { case cue, legal, illegal, unknown }

enum TargetLegality {
    /// Bar-8 open table until the Rules wiring lands (game flow).
    static func defaultGame() -> (RulesEngine, GameState) {
        let engine = RulesEngine(ruleSet: .barEight)
        var g = engine.newGame()
        g.phase = .open
        g.ballInHand = .none
        return (engine, g)
    }

    static func mark(kind: BallKind, number: Int?, legal: Set<BallID>) -> TargetMark {
        if kind == .cue || number == 0 { return .cue }
        if let n = number, let id = BallID(n) { return legal.contains(id) ? .legal : .illegal }
        switch kind {
        case .eight: return legal.contains(.eight) ? .legal : .illegal
        case .solid: return legal.contains { $0.group == .solids } ? .legal : .illegal
        case .stripe: return legal.contains { $0.group == .stripes } ? .legal : .illegal
        default: return .unknown
        }
    }
}

/// Drops stale perception results: frames are numbered when dispatched; an epoch bumps whenever
/// tracking state changes or the table is (re)locked, so results from before it are discarded.
struct FrameOrdering: Sendable {
    private(set) var lastApplied = -1
    mutating func accept(seq: Int, epoch: Int, currentEpoch: Int) -> Bool {
        guard epoch == currentEpoch, seq > lastApplied else { return false }
        lastApplied = seq
        return true
    }
}

/// Turns sampled paths into drawable segments (bounded counts for entity pools).
enum OverlayPath {
    /// Simplify `pts` into at most `max` straight segments (keeps corners such as cushion bounces).
    static func segments(_ pts: [Vec2], max: Int, tolerance: Double = 0.004) -> [(Vec2, Vec2)] {
        guard pts.count >= 2 else { return [] }
        var keep = douglasPeucker(pts, tolerance)
        var tol = tolerance
        while keep.count - 1 > max && tol < 0.2 { tol *= 2; keep = douglasPeucker(pts, tol) }
        return zip(keep, keep.dropFirst()).map { ($0, $1) }
    }

    /// Dash pattern walked along the polyline, starting `skip` metres in.
    static func dashes(_ pts: [Vec2], dash: Double, gap: Double, skip: Double, max: Int) -> [(Vec2, Vec2)] {
        guard pts.count >= 2 else { return [] }
        var out: [(Vec2, Vec2)] = []
        var along = 0.0, next = skip
        var drawing = false
        var start = pts[0]
        for (a, b) in zip(pts, pts.dropFirst()) {
            let len = a.distance(to: b)
            guard len > 1e-9 else { continue }
            let u = (b - a) / len
            var t = 0.0
            while along + (len - t) >= next {
                let step = next - along
                t += step; along = next
                let p = a + u * t
                if drawing { out.append((start, p)); if out.count >= max { return out }; next += gap }
                else { start = p; next += dash }
                drawing.toggle()
            }
            along += len - t
        }
        if drawing, let last = pts.last, start.distance(to: last) > 0.005, out.count < max { out.append((start, last)) }
        return out
    }

    static func douglasPeucker(_ p: [Vec2], _ eps: Double) -> [Vec2] {
        guard p.count > 2 else { return p }
        let a = p[0], b = p[p.count - 1], ab = b - a, l = ab.length
        var idx = 0, dmax = 0.0
        for i in 1..<(p.count - 1) {
            let d = l > 1e-12 ? abs(ab.cross(p[i] - a)) / l : p[i].distance(to: a)
            if d > dmax { dmax = d; idx = i }
        }
        guard dmax > eps else { return [a, b] }
        let left = douglasPeucker(Array(p[0...idx]), eps), right = douglasPeucker(Array(p[idx...]), eps)
        return left.dropLast() + right
    }
}

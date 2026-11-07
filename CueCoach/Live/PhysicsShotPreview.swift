import Foundation
import Geometry
import Physics

/// Simulated outcome of a suggested shot, drawn as Lines 2 and 3 (SPEC §5.6).
struct ShotPreview: Sendable, Equatable {
    enum Outcome: Sendable, Equatable { case make, miss, scratch }
    /// Cue-ball launch direction (unit; throw-compensated so the object ball really reaches the pocket).
    var direction: Vec2
    var spin: SpinSuggestion
    var power: Int
    /// Line 2: the object ball's simulated path (with throw).
    var objectPath: [Vec2]
    /// Line 3: the cue ball's simulated path after contact (follow / draw / stun, cushions included).
    var cuePath: [Vec2]
    /// Where the cue ball touches the object ball (ghost-ball centre).
    var contact: Vec2?
    var outcome: Outcome
}

/// Swappable shot preview (Physics now; Engine later).
protocol ShotPreviewing: Sendable {
    /// `balls`: every ball on the table by id (cue = 0). Returns nil when the shot can't be previewed.
    func preview(cue: Vec2, object: BallID, pocket: Pocket, balls: [BallID: Vec2], spec: TableSpec) -> ShotPreview?
}

/// CueCore `Simulator` based preview: searches spin × power for the first clean make, refining the aim so
/// the simulated object ball (with cut/spin throw) heads into the pocket.
struct PhysicsShotPreview: ShotPreviewing {
    var simulator = Simulator()
    /// Cue-ball launch speeds for the 5 power steps (m/s): soft … firm.
    static let speeds: [Double] = [0.9, 1.4, 2.0, 2.8, 3.8]
    static let spins: [SpinSuggestion] = [.stun, .follow, .draw]
    var sampleDT = 0.02
    var refineIterations = 3

    func preview(cue: Vec2, object: BallID, pocket: Pocket, balls: [BallID: Vec2], spec: TableSpec) -> ShotPreview? {
        guard let obj = balls[object] else { return nil }
        let target = AimPlanner.aimPoint(pocket, spec: spec)
        let state = TableState(spec: spec, balls: balls.mapValues { BallState(position: $0) })
        var fallback: ShotPreview?
        for spin in Self.spins {
            // Throw changes little with speed: refine once per spin at a medium pace, reuse for every power.
            let dir = refinedDirection(cue: cue, object: object, obj: obj, target: target, state: state,
                                       speed: Self.speeds[2], spin: spin)
            for (i, speed) in Self.speeds.enumerated() {
                let p = run(state: state, object: object, pocket: pocket, direction: dir, speed: speed, spin: spin,
                            power: i + 1)
                if p.outcome == .make { return p }
                if fallback == nil { fallback = p }
            }
        }
        return fallback
    }

    /// Start from the ghost-ball line and rotate the cue direction until the simulated object path points
    /// at the pocket (secant on the heading error) — this is where real throw is compensated.
    func refinedDirection(cue: Vec2, object: BallID, obj: Vec2, target: Vec2, state: TableState,
                          speed: Double, spin: SpinSuggestion) -> Vec2 {
        let want = (target - obj).normalized
        var dir = (AimPlanner.ghostBall(object: obj, pocket: target) - cue).normalized
        func headingError(_ d: Vec2) -> Double? {
            let tr = simulator.simulate(state, stroke: Stroke(direction: d, speed: speed, tipOffset: spin.tip))
            let path = tr.path(of: object, sampleDT: sampleDT)
            guard path.count >= 2 else { return nil }
            // Early heading of the object ball (first ~10 cm) vs the pocket line.
            let p = path.first { $0.distance(to: obj) > 0.1 } ?? path[path.count - 1]
            guard p.distance(to: obj) > 1e-4 else { return nil }
            return atan2(want.cross((p - obj).normalized), want.dot((p - obj).normalized))
        }
        guard var e0 = headingError(dir) else { return dir }
        var step = -e0 * 0.5
        for _ in 0..<refineIterations where abs(e0) > 0.002 {
            let next = dir.rotated(by: step)
            guard let e1 = headingError(next) else { break }
            let de = e1 - e0
            let newStep = abs(de) > 1e-6 ? -e1 * step / de : step
            dir = next; e0 = e1
            step = max(-0.05, min(0.05, newStep))
        }
        return dir
    }

    func run(state: TableState, object: BallID, pocket: Pocket, direction: Vec2, speed: Double,
             spin: SpinSuggestion, power: Int) -> ShotPreview {
        let tr = simulator.simulate(state, stroke: Stroke(direction: direction, speed: speed, tipOffset: spin.tip))
        var firstHit: (t: Double, other: BallID)?
        var objectPocket: Pocket?
        var scratch = false
        for e in tr.events {
            switch e.event {
            case let .ballBall(a, b) where firstHit == nil && (a == .cue || b == .cue):
                firstHit = (e.time, a == .cue ? b : a)
            case let .pocket(id, p):
                if id == object { objectPocket = p }
                if id == .cue { scratch = true }
            case .offTable(.cue):
                scratch = true
            default: break
            }
        }
        let cueFull = tr.path(of: .cue, sampleDT: sampleDT)
        // Line 3 starts at contact: drop the approach samples.
        var contact: Vec2?
        var after = cueFull
        if let h = firstHit {
            let c = tr.state(at: h.t).balls[.cue]?.position
            contact = c
            let k = Int((h.t / sampleDT).rounded(.down)) + 1
            after = (c.map { [$0] } ?? []) + Array(cueFull.dropFirst(min(cueFull.count, k)))
        }
        let outcome: ShotPreview.Outcome = scratch ? .scratch
            : (firstHit?.other == object && objectPocket == pocket ? .make : .miss)
        return ShotPreview(direction: direction, spin: spin, power: power,
                           objectPath: tr.path(of: object, sampleDT: sampleDT), cuePath: after, contact: contact,
                           outcome: outcome)
    }
}

/// Small LRU-ish cache keyed by a quantized table layout + target (balls are still while aiming).
struct PreviewCache: Sendable {
    private var store: [String: ShotPreview?] = [:]
    private var order: [String] = []
    var capacity = 32

    static func key(cue: Vec2, object: BallID, pocket: Pocket, balls: [BallID: Vec2], quantum: Double = 0.005) -> String {
        func q(_ v: Vec2) -> String { "\(Int((v.x / quantum).rounded())),\(Int((v.y / quantum).rounded()))" }
        let layout = balls.keys.sorted().map { "\($0.number):\(q(balls[$0]!))" }.joined(separator: ";")
        return "\(q(cue))|\(object.number)|\(pocket.rawValue)|\(layout)"
    }

    func get(_ k: String) -> ShotPreview?? { store[k] }

    mutating func put(_ k: String, _ v: ShotPreview?) {
        if store[k] == nil { order.append(k) }
        store[k] = v
        while order.count > capacity { store[order.removeFirst()] = nil }
    }
}

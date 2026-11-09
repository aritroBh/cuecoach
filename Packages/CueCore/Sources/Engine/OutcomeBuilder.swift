import Geometry
import Physics
import Rules

/// The single `ShotTrace` → `ShotOutcome` builder (engine.md R9). The simulator never drives a ball off the
/// table, so `offTable` comes from the caller (tracking) and is empty for simulated samples.
enum OutcomeBuilder {
    static func nearestPocket(to q: Vec2, spec: TableSpec) -> Pocket {
        Pocket.allCases.min { spec.pocketCenter($0).distance(to: q) < spec.pocketCenter($1).distance(to: q) }!
    }

    /// Did the cue ball's centre go below the head string before `time`? Reads the trace at every event
    /// (cushions included) and on a fine grid between them, so a rail-first path out and back is seen.
    static func cueCrossedHeadString(_ trace: ShotTrace, before time: Double, step: Double = 0.005) -> Bool {
        let line = trace.initial.spec.headStringX
        func below(_ t: Double) -> Bool { (trace.state(at: t).balls[.cue]?.position.x ?? 0) > line }
        if trace.events.contains(where: { $0.time <= time && below($0.time) }) { return true }
        var t = 0.0
        while t < time {
            if below(t) { return true }
            t += step
        }
        return below(time)
    }

    static func outcome(from trace: ShotTrace, game g: GameState, candidate c: Candidate?,
                        offTable: Set<BallID> = []) -> ShotOutcome {
        var firstContact: BallID?
        var firstContactTime = Double.infinity
        var pocketed: [BallID: Pocket] = [:]
        var order: [BallID] = []
        var railAfter = false
        var railedObjects = Set<BallID>()
        for e in trace.events {
            switch e.event {
            case let .ballBall(a, b):
                if firstContact == nil, a.isCue || b.isCue {
                    firstContact = a.isCue ? b : a
                    firstContactTime = e.time
                }
            case let .cushion(ball, _):
                if e.time >= firstContactTime { railAfter = true }
                if !ball.isCue { railedObjects.insert(ball) }
            case let .pocket(ball, _):
                // Physics' pocket labels disagree with Geometry's (head/foot swapped); trust the capture position.
                if pocketed[ball] == nil, let b = trace.final.balls[ball] {
                    pocketed[ball] = nearestPocket(to: b.position, spec: trace.initial.spec)
                    order.append(ball)
                }
            default: break
            }
        }
        let isBreak = g.phase == .breakShot
        let spec = trace.initial.spec
        var out = ShotOutcome(isBreak: isBreak, firstContact: firstContact, noContact: firstContact == nil,
                              pocketed: pocketed, pocketOrder: order,
                              anyRailAfterContact: firstContact == nil ? false : railAfter)
        out.offTable = offTable
        for id in offTable where out.pocketed[id] != nil {
            out.pocketed[id] = nil; out.pocketOrder.removeAll { $0 == id }
        }
        if isBreak {
            out.objectBallsToRailOnBreak = railedObjects.count
            let past = trace.final.balls.filter { id, b in
                !id.isCue && (b.motion == .pocketed || b.position.x < spec.headStringX)
            }.count
            out.objectBallsPastHeadStringOrPocketedOnBreak = past
        }
        if g.ballInHand == .behindHeadString, let cue = trace.initial.balls[.cue] {
            out.cueBallStartedAboveHeadString = cue.position.x < spec.headStringX
            // WPA 3.11: legal if the first ball hit is on/below the head string, or the cue ball crossed it first.
            if let f = firstContact, let fb = trace.initial.balls[f] {
                out.cueBallCrossedHeadStringFirst = fb.position.x >= spec.headStringX
                    || cueCrossedHeadString(trace, before: firstContactTime)
            }
        }
        if let c {
            if c.intendsPot { out.calledBall = c.objectBall; out.calledPocket = c.pocket }
            if c.kind == .safety || (c.kind != .pushOut && !c.intendsPot && c.kind != .breakShot) {
                out.calledSafety = true
            }
            out.isPushOut = c.kind == .pushOut
        }
        return out
    }
}

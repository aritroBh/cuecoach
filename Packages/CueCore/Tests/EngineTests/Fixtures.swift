import Geometry
import Physics
import Rules
@testable import Engine

// Hand-built positions for Engine tests. 7 ft table: length ≈ 2.032 m (x, head at x = 0), width ≈ 1.016 m (y).
enum Fx {
    static let spec = TableSpec(size: .sevenFoot)
    static let R = TableSpec.ballRadius
    static func b(_ n: Int) -> BallID { BallID(n)! }

    static func table(cue: Vec2?, _ objects: [Int: Vec2]) -> TableState {
        var balls: [BallID: BallState] = [:]
        if let cue { balls[.cue] = BallState(position: cue) }
        for (n, p) in objects { balls[b(n)] = BallState(position: p) }
        return TableState(spec: spec, balls: balls)
    }

    /// A 9-ball game in normal play with the given balls on the table, team 0 to shoot.
    static func nineBall(_ onTable: [Int], shooter: Int = 0, bih: BallInHand = .none,
                         phase: Phase = .inPlay, fouls: [Int: Int] = [:]) -> GameState {
        GameState(ruleSet: .wpaNine, teams: 2, shooter: shooter, breaker: 0, groups: nil, ballInHand: bih,
                  consecutiveFouls: fouls, phase: phase, onTable: Set(onTable.map(b)))
    }

    /// Bar 8-ball; `groups` nil = open table.
    static func eightBall(_ onTable: [Int], shooter: Int = 0, groups: [Int: BallGroup]? = [0: .solids, 1: .stripes],
                          bih: BallInHand = .none, ruleSet: RuleSetID = .barEight) -> GameState {
        GameState(ruleSet: ruleSet, teams: 2, shooter: shooter, breaker: 0, groups: groups, ballInHand: bih,
                  consecutiveFouls: [:], phase: groups == nil ? .open : .inPlay, onTable: Set(onTable.map(b)))
    }

    /// Footright pocket is (L, W). A ball on the diagonal line to it: straight-in shot.
    static var footRight: Vec2 { spec.pocketCenter(.footRight) }
    static var footLeft: Vec2 { spec.pocketCenter(.footLeft) }

    /// Short straight-in: CB and 1 on a line to the foot-right corner.
    static func straightIn() -> (TableState, GameState) {
        let p = footRight
        let dir = Vec2(-1, -1).normalized
        let ob = p + dir * 0.35
        let cue = p + dir * 0.75
        return (table(cue: cue, [1: ob, 5: Vec2(0.4, 0.2), 7: Vec2(0.3, 0.8)]), nineBall([1, 5, 7]))
    }

    /// Mid-game 8-ball, 9 object balls + cue = 10 balls (the perf position).
    static func midGame10() -> (TableState, GameState) {
        let s = table(cue: Vec2(0.62, 0.48), [
            1: Vec2(1.25, 0.30), 3: Vec2(1.55, 0.72), 4: Vec2(0.95, 0.80), 6: Vec2(1.75, 0.22),
            8: Vec2(1.05, 0.52), 10: Vec2(0.35, 0.20), 12: Vec2(1.88, 0.86), 13: Vec2(0.72, 0.28),
            15: Vec2(1.42, 0.46),
        ])
        return (s, eightBall([1, 3, 4, 6, 8, 10, 12, 13, 15]))
    }
}

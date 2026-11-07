import Geometry
@testable import Rules

func b(_ n: Int) -> BallID { BallID(n)! }
func balls(_ ns: [Int]) -> Set<BallID> { Set(ns.map(b)) }
func balls(_ r: ClosedRange<Int>) -> Set<BallID> { Set(r.map(b)) }

/// Compact ShotOutcome builder for tests. Unspecified observations stay `nil` ("not observed").
func shot(first: Int? = nil,
          pocket: [Int: Pocket] = [:],
          order: [Int] = [],
          off: [Int] = [],
          rail: Bool? = true,
          noContact: Bool = false,
          toRail: Int? = nil,
          past: Int? = nil,
          calledBall: Int? = nil,
          calledPocket: Pocket? = nil,
          safety: Bool = false,
          startedAbove: Bool? = nil,
          crossedFirst: Bool? = nil,
          isBreak: Bool = false,
          pushOut: Bool = false) -> ShotOutcome {
    var p: [BallID: Pocket] = [:]
    for (k, v) in pocket { p[b(k)] = v }
    return ShotOutcome(isBreak: isBreak,
                       firstContact: first.map(b),
                       noContact: noContact,
                       pocketed: p,
                       pocketOrder: order.map(b),
                       offTable: Set(off.map(b)),
                       anyRailAfterContact: rail,
                       objectBallsToRailOnBreak: toRail,
                       objectBallsPastHeadStringOrPocketedOnBreak: past,
                       calledBall: calledBall.map(b),
                       calledPocket: calledPocket,
                       calledSafety: safety,
                       cueBallStartedAboveHeadString: startedAbove,
                       cueBallCrossedHeadStringFirst: crossedFirst,
                       isPushOut: pushOut)
}

/// A break outcome (no first-contact requirement unless given).
func brk(first: Int? = 1, pocket: [Int: Pocket] = [:], off: [Int] = [], toRail: Int? = 4, past: Int? = 3,
         noContact: Bool = false, startedAbove: Bool? = nil) -> ShotOutcome {
    shot(first: first, pocket: pocket, off: off, rail: nil, noContact: noContact, toRail: toRail, past: past,
         startedAbove: startedAbove, isBreak: true)
}

extension GameState {
    /// Test helper: a mid-game state.
    func with(shooter: Int? = nil, groups: [Int: BallGroup]?? = nil, onTable: Set<BallID>? = nil,
              phase: Phase? = nil, ballInHand: BallInHand? = nil, fouls: [Int: Int]? = nil) -> GameState {
        var g = self
        if let shooter { g.shooter = shooter }
        if let groups { g.groups = groups }
        if let onTable { g.onTable = onTable }
        if let phase { g.phase = phase }
        if let ballInHand { g.ballInHand = ballInHand }
        if let fouls { g.consecutiveFouls = fouls }
        return g
    }
}

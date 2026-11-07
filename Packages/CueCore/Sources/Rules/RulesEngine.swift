import Geometry

/// Pure, deterministic rules state machine for bar 8-ball (docs/RULES.md), WPA 8-ball and WPA 9-ball
/// (WPA Rules of Play eff. 2026-10-21, Playing Regulations eff. 2026-10-21).
public struct RulesEngine: Hashable, Codable, Sendable {
    public let ruleSet: RuleSetID
    public let teams: Int
    /// 9-ball three-ball break rule (WPA 5.3(c), Reg 16). House rule D13: ON by default.
    public let threeBallRule: Bool

    public init(ruleSet: RuleSetID, teams: Int = 2, threeBallRule: Bool = true) {
        precondition(teams >= 2, "need at least two teams")
        self.ruleSet = ruleSet
        self.teams = teams
        self.threeBallRule = threeBallRule
    }

    var rack: Set<BallID> {
        ruleSet == .wpaNine ? Set(BallID.allObjectBalls.prefix(9)) : Set(BallID.allObjectBalls)
    }

    func next(_ team: Int) -> Int { (team + 1) % teams }

    /// A fresh rack. The cue ball starts in hand above the head string (WPA 4.3(a), 5.3(a); RULES.md B6).
    public func newGame(breaker: Int = 0) -> GameState {
        GameState(ruleSet: ruleSet, teams: teams, shooter: breaker, breaker: breaker, groups: nil,
                  ballInHand: .behindHeadString, consecutiveFouls: [:], phase: .breakShot, onTable: rack)
    }

    /// Balls the shooter may legally contact first (drives the red ring).
    public func legalTargets(_ g: GameState) -> Set<BallID> {
        let objects = g.onTable.filter { !$0.isCue }
        switch g.phase {
        case .awaitingOption, .over: return []
        case .breakShot:
            // WPA 4.3(b): no particular ball on an 8-ball break. 9-ball: lowest first (WPA 5.7 / 3.2).
            if ruleSet == .wpaNine { return objects.min().map { [$0] } ?? [] }
            return objects
        case .pushOutAvailable, .open, .inPlay:
            break
        }
        if ruleSet == .wpaNine {
            // WPA 5.7 / 3.2: lowest-numbered ball on the table.
            return objects.min().map { [$0] } ?? []
        }
        guard let groups = g.groups, let mine = groups[g.shooter] else {
            // Open table: any ball except the 8 (WPA 4.4; RULES.md B17).
            let nonEight = objects.subtracting([.eight])
            if ruleSet == .wpaEight {
                // WPA 4.4: if a group is completely pocketed, the shooter may claim it and play the 8.
                let solidsLeft = nonEight.contains { $0.group == .solids }
                let stripesLeft = nonEight.contains { $0.group == .stripes }
                if (!solidsLeft || !stripesLeft) && objects.contains(.eight) { return objects }
            }
            return nonEight
        }
        let own = objects.filter { $0.group == mine }
        // WPA 4.6 / RULES.md B13: once the group is cleared, the 8 is the target.
        return own.isEmpty ? objects.intersection([.eight]) : own
    }

    /// Whether a shot at `target` must be called.
    public func requiresCall(_ g: GameState, target: BallID) -> Bool {
        if g.phase == .breakShot { return false } // WPA 4.3(b); RULES.md B4
        switch ruleSet {
        case .barEight: return target == .eight   // RULES.md B1: only the 8's pocket is called
        case .wpaEight: return true               // WPA 4.6: every shot except the break
        case .wpaNine: return false               // WPA 5: no calling
        }
    }

    /// The next rack after `g` is over. Bar: winner breaks (RULES.md B25). WPA: breaks alternate (WPA 1.3, 4.1, 5.1).
    public func nextGame(after g: GameState) -> GameState {
        guard let w = g.winner else { return g }
        switch ruleSet {
        case .barEight: return newGame(breaker: w)                 // RULES.md B25
        case .wpaEight, .wpaNine: return newGame(breaker: next(g.breaker)) // WPA 1.3
        }
    }

    /// Stalemate: the original breaker of the rack breaks again (WPA 4.11, 5.9; RULES.md B24).
    public func stalemate(_ g: GameState) -> GameState { newGame(breaker: g.breaker) }

    public func apply(_ o: ShotOutcome, to g: GameState) -> RuleResult {
        switch g.phase {
        case .awaitingOption, .over:
            return RuleResult(nextState: g) // nothing to apply until the option is chosen / rack restarts
        case .breakShot:
            switch ruleSet {
            case .barEight: return barBreak(o, g)
            case .wpaEight: return wpaEightBreak(o, g)
            case .wpaNine: return nineBreak(o, g)
            }
        case .pushOutAvailable, .open, .inPlay:
            switch ruleSet {
            case .barEight: return barShot(o, g)
            case .wpaEight: return wpaEightShot(o, g)
            case .wpaNine: return nineShot(o, g)
            }
        }
    }

    public func choose(_ option: PlayerOption, in g: GameState) -> RuleResult {
        RuleResult(nextState: g)
    }
}

// MARK: - Shared helpers

extension RulesEngine {
    /// Object balls pocketed on the shot (cue excluded).
    func objectsPocketed(_ o: ShotOutcome) -> Set<BallID> { Set(o.pocketed.keys.filter { !$0.isCue }) }

    /// WPA 3.1 (RULES.md B7): cue ball pocketed or driven off the table.
    func cueBallFouls(_ o: ShotOutcome) -> [Foul] {
        var f: [Foul] = []
        if o.pocketed[.cue] != nil { f.append(.scratch) }
        if o.offTable.contains(.cue) { f.append(.cueBallOffTable) }
        return f
    }

    /// WPA 3.10 / 3.11 (RULES.md B6): only when the cue ball is in hand above the head string.
    func headStringFouls(_ o: ShotOutcome, _ g: GameState, isBreak: Bool) -> [Foul] {
        guard g.ballInHand == .behindHeadString else { return [] }
        var f: [Foul] = []
        if o.cueBallStartedAboveHeadString == false { f.append(.badCueBallPlacement) }          // WPA 3.10
        if !isBreak && o.cueBallCrossedHeadStringFirst == false { f.append(.badPlayFromAboveHeadString) } // WPA 3.11
        return f
    }

    /// WPA 3.2 wrong ball first / no contact, and WPA 3.3 no rail after contact (2.7: a pocketed or
    /// off-table ball counts as driven to a rail). `nil` observations never foul (Reg 25).
    func contactFouls(_ o: ShotOutcome, legal: Set<BallID>, checkFirstBall: Bool = true,
                      checkRail: Bool = true) -> [Foul] {
        if o.noContact && o.firstContact == nil {
            return [.noContact] // WPA 3.3 ("the cue-ball must contact an object-ball")
        }
        var f: [Foul] = []
        if checkFirstBall, let first = o.firstContact, !legal.contains(first) {
            f.append(.wrongBallFirst(first)) // WPA 3.2
        }
        let somethingReachedRail = !o.pocketed.isEmpty || !o.offTable.isEmpty // WPA 2.7
        if checkRail && o.anyRailAfterContact == false && !somethingReachedRail {
            f.append(.noRailAfterContact) // WPA 3.3
        }
        return f
    }

    /// Fresh rack with the same teams, `breaker` to break; keeps `g.breaker` (the rack's original breaker).
    func reRacked(_ g: GameState, breakingTeam: Int) -> GameState {
        var n = newGame(breaker: breakingTeam)
        n.breaker = g.breaker
        return n
    }

    func over(_ g: GameState, winner: Int, _ reason: GameEndReason, fouls: [Foul]) -> RuleResult {
        var n = g
        n.phase = .over(winner: winner)
        n.ballInHand = .none
        return RuleResult(fouls: fouls, nextState: n, turnPasses: false, winner: winner, endReason: reason)
    }

    /// Bookkeeping for WPA 3.13: a foul adds one for the shooter, a legal shot clears it.
    func countFouls(_ n: inout GameState, shooter: Int, fouled: Bool) {
        n.consecutiveFouls[shooter] = fouled ? n.consecutiveFouls[shooter, default: 0] + 1 : 0
    }

    /// The group decided by a legal pocketing on an open table: first ball in `pocketOrder` when known,
    /// else the single group pocketed; `nil` if mixed with unknown order.
    func decidingGroup(_ pocketed: Set<BallID>, order: [BallID]) -> BallGroup? {
        let candidates = pocketed.filter { $0.group != nil }
        if let first = order.first(where: { candidates.contains($0) }) { return first.group }
        let groups = Set(candidates.compactMap(\.group))
        return groups.count == 1 ? groups.first : nil
    }

    func assign(_ group: BallGroup, to shooter: Int) -> [Int: BallGroup] {
        var m: [Int: BallGroup] = [:]
        for t in 0..<teams { m[t] = t == shooter ? group : group.other }
        return m
    }
}

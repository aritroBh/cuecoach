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

    public func apply(_ o: ShotOutcome, to g: GameState) -> RuleResult {
        RuleResult(nextState: g)
    }

    public func choose(_ option: PlayerOption, in g: GameState) -> RuleResult {
        RuleResult(nextState: g)
    }
}

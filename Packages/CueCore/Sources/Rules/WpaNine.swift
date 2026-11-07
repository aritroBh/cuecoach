import Geometry

// WPA 9-ball, Rules of Play eff. 2026-10-21, §5, with Playing Regulation 16 (three-ball break rule)
// and house rule D13 (docs/DECISIONS.md).
extension RulesEngine {
    func nineBreak(_ o: ShotOutcome, _ g: GameState) -> RuleResult {
        let legal = legalTargets(g)                                         // the 1 (WPA 5.7 / 3.2 "on each shot")
        var fouls = cueBallFouls(o)                                        // WPA 3.1
            + headStringFouls(o, g, isBreak: true)                         // WPA 5.3(a) / 3.10
            + contactFouls(o, legal: legal, checkRail: false)              // WPA 3.2; 3.3 replaced by 5.3(b)
            + nineOffTableFouls(o)                                         // WPA 3.5
        let pocketedObjects = objectsPocketed(o)
        let toRail = o.noContact ? 0 : (o.objectBallsToRailOnBreak ?? 4)  // unknown → legal (Reg 25)
        if pocketedObjects.isEmpty && toRail < 4 {
            fouls.append(.illegalBreak)                                    // WPA 5.3(b): "or the shot is a foul"
        }

        if !fouls.isEmpty {
            // D13 / WPA 5.6: a 9 made on a foul break is spotted; WPA 5.7: ball in hand anywhere, no push-out (5.4).
            return nineFoul(o, g, fouls: fouls)
        }
        if o.pocketed[.nine] != nil {
            // WPA 5.5: legally pocketing the 9 wins. D13: even on a "soft" break (overrides Reg 16(5)).
            return over(g, winner: g.shooter, .ninePocketed, fouls: [])
        }

        var n = g
        n.onTable.subtract(pocketedObjects)
        n.ballInHand = .none
        countFouls(&n, shooter: g.shooter, fouled: false)

        let pastOrPocketed = o.objectBallsPastHeadStringOrPocketedOnBreak ?? 3 // unknown → legal (Reg 25)
        if threeBallRule && pastOrPocketed < 3 {
            // WPA 5.3(c) / Reg 16(1)-(2): illegal break; incoming player accepts or hands it back.
            let opts: [PlayerOption] = [.acceptTable, .handBack]
            n.phase = .awaitingOption(PendingOption(chooser: next(g.shooter), reason: .threeBallRule, options: opts))
            return RuleResult(fouls: [], nextState: n, turnPasses: false, options: opts)
        }
        // WPA 5.5: a pocketed ball keeps the breaker at the table; WPA 5.4: the next shot may be a push-out.
        n.phase = .pushOutAvailable
        if pocketedObjects.isEmpty { n.shooter = next(g.shooter) }
        return RuleResult(fouls: [], nextState: n, turnPasses: n.shooter != g.shooter)
    }

    func nineShot(_ o: ShotOutcome, _ g: GameState) -> RuleResult {
        let legal = legalTargets(g)
        // WPA 5.4: push-out only on the shot right after a foul-free break, and only when announced.
        let isPushOut = g.phase == .pushOutAvailable && o.isPushOut
        let fouls = cueBallFouls(o)                                        // WPA 3.1
            + (isPushOut ? [] : contactFouls(o, legal: legal))             // WPA 3.2 / 3.3 (suspended on a push-out, 5.4)
            + nineOffTableFouls(o)                                         // WPA 3.5
        let pocketedObjects = objectsPocketed(o)

        if !fouls.isEmpty { return nineFoul(o, g, fouls: fouls) }

        var n = g
        n.ballInHand = .none
        countFouls(&n, shooter: g.shooter, fouled: false)                  // legal shot clears the count (WPA 3.13)

        if isPushOut {
            // WPA 5.6: a 9 pocketed on a push-out is spotted; no other ball is. 5.5: shooter does not continue.
            n.onTable.subtract(pocketedObjects.subtracting([.nine]))
            let spots: [BallID] = pocketedObjects.contains(.nine) ? [.nine] : []
            let opts: [PlayerOption] = [.acceptTable, .handBack]           // WPA 5.4: the other athlete chooses
            n.phase = .awaitingOption(PendingOption(chooser: next(g.shooter), reason: .pushOut, options: opts))
            return RuleResult(fouls: [], nextState: n, turnPasses: false, spot: spots, options: opts)
        }
        if pocketedObjects.contains(.nine) {
            // WPA 5.5: legally pocketing the 9 wins, incl. combinations / caroms / kisses (D13).
            return over(g, winner: g.shooter, .ninePocketed, fouls: [])
        }
        n.onTable.subtract(pocketedObjects)
        n.phase = .inPlay
        // WPA 5.5: legally pocket any ball and continue; otherwise the incoming player plays from position.
        if pocketedObjects.isEmpty { n.shooter = next(g.shooter) }
        return RuleResult(fouls: [], nextState: n, turnPasses: n.shooter != g.shooter)
    }

    /// WPA 3.5 at 9-ball: object ball off the table is a foul (only the 9 is later spotted, 5.6).
    private func nineOffTableFouls(_ o: ShotOutcome) -> [Foul] {
        o.offTable.filter { !$0.isCue }.sorted().map { Foul.objectBallOffTable($0) }
    }

    /// Standard foul at 9-ball (WPA 5.7): ball in hand anywhere; 9 spotted if pocketed or off (5.6);
    /// third consecutive foul loses the rack (5.8 / 3.13).
    private func nineFoul(_ o: ShotOutcome, _ g: GameState, fouls: [Foul]) -> RuleResult {
        var n = g
        countFouls(&n, shooter: g.shooter, fouled: true)
        if n.consecutiveFouls[g.shooter, default: 0] >= 3 {               // WPA 5.8 (warning: on-screen count, Reg 8)
            return over(n, winner: next(g.shooter), .threeFouls, fouls: fouls)
        }
        let removed = objectsPocketed(o).union(o.offTable.filter { !$0.isCue })
        n.onTable.subtract(removed)                                        // WPA 5.6: "No other object-ball is ever spotted"
        var spots: [BallID] = []
        if removed.contains(.nine) {                                       // WPA 5.6: 9 on a foul or off the table → spotted
            n.onTable.insert(.nine)
            spots = [.nine]
        }
        n.shooter = next(g.shooter)
        n.ballInHand = .anywhere                                           // WPA 5.7 / 1.6
        n.phase = .inPlay
        return RuleResult(fouls: fouls, nextState: n, turnPasses: true, spot: spots)
    }
}

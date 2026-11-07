import Geometry

// Bar / slop 8-ball. Every branch cites docs/RULES.md (B#) or decision D11.
extension RulesEngine {
    func barBreak(_ o: ShotOutcome, _ g: GameState) -> RuleResult {
        let cueFouls = cueBallFouls(o)
        let fouls = cueFouls + headStringFouls(o, g, isBreak: true)
        let pocketedObjects = objectsPocketed(o)

        if o.offTable.contains(.eight) {                     // RULES.md B15: 8 off the table loses, break included
            return over(g, winner: next(g.shooter), .eightOffTable, fouls: fouls)
        }
        if o.pocketed[.eight] != nil {
            if !fouls.isEmpty {                              // RULES.md B5: 8 on the break + scratch loses
                return over(g, winner: next(g.shooter), .eightOnBreakWithFoul, fouls: fouls)
            }
            return over(g, winner: g.shooter, .eightOnBreak, fouls: [])  // RULES.md B4: 8 on the break wins
        }

        // RULES.md B2: legal break = ≥1 ball pocketed or ≥4 to a rail; unknown count is legal (Reg 25).
        let toRail = o.noContact ? 0 : (o.objectBallsToRailOnBreak ?? 4)
        if pocketedObjects.isEmpty && toRail < 4 {
            // RULES.md B2: re-rack, same breaker breaks again (also when the illegal break scratched).
            return RuleResult(fouls: [], nextState: reRacked(g, breakingTeam: g.shooter), turnPasses: false, reRack: true)
        }

        var n = g
        n.onTable.subtract(pocketedObjects)                  // RULES.md B6: pocketed balls stay down
        let spots = barSpotOffTable(o, &n)                   // RULES.md B19
        n.phase = .open                                      // D11 / RULES.md B3: table always open after the break
        n.groups = nil
        countFouls(&n, shooter: g.shooter, fouled: !fouls.isEmpty)
        if !cueFouls.isEmpty {
            n.shooter = next(g.shooter)
            n.ballInHand = .behindHeadString                 // RULES.md B6
        } else if !fouls.isEmpty {
            n.shooter = next(g.shooter)
            n.ballInHand = .anywhere                         // RULES.md B7
        } else {
            n.ballInHand = .none
            if pocketedObjects.isEmpty { n.shooter = next(g.shooter) } // nothing made: turn passes
        }
        return RuleResult(fouls: fouls, nextState: n, turnPasses: n.shooter != g.shooter, spot: spots)
    }

    func barShot(_ o: ShotOutcome, _ g: GameState) -> RuleResult {
        let legal = legalTargets(g)
        let shootingEight = legal == [.eight]
        let cueFouls = cueBallFouls(o)
        // RULES.md B8: cue-ball fouls only (scratch/off table, wrong ball first incl. B17, no contact, no rail),
        // plus head-string placement after a break scratch (B6).
        let fouls = cueFouls + headStringFouls(o, g, isBreak: false) + contactFouls(o, legal: legal)
        let pocketedObjects = objectsPocketed(o)
        let loser = g.shooter, winnerIfLoss = next(g.shooter)

        if o.offTable.contains(.eight) {                     // RULES.md B15
            return over(g, winner: winnerIfLoss, .eightOffTable, fouls: fouls)
        }
        if let eightPocket = o.pocketed[.eight] {
            if !shootingEight {
                // RULES.md B13 (8 early); B14 (8 + last group ball on the same shot)
                let mine = g.groups?[loser]
                let ownLeft = g.onTable.filter { $0.group == mine && mine != nil }
                let reason: GameEndReason = !ownLeft.isEmpty && ownLeft.isSubset(of: pocketedObjects)
                    ? .eightWithLastGroupBall : .eightEarly
                return over(g, winner: winnerIfLoss, reason, fouls: fouls)
            }
            if !fouls.isEmpty {                              // RULES.md B9 (and any foul pocketing the 8)
                return over(g, winner: winnerIfLoss, .eightWithFoul, fouls: fouls)
            }
            if let called = o.calledPocket, called != eightPocket { // RULES.md B12; unknown call is legal (B1, Reg 25)
                return over(g, winner: winnerIfLoss, .eightWrongPocket, fouls: fouls)
            }
            return over(g, winner: loser, .eightPocketed, fouls: [])  // RULES.md B16: combos/kisses allowed
        }
        if shootingEight && !cueFouls.isEmpty {              // RULES.md B9: scratch on the 8 loses even if missed
            return over(g, winner: winnerIfLoss, .scratchOnEight, fouls: fouls)
        }

        var n = g
        n.onTable.subtract(pocketedObjects)                  // RULES.md B18: balls pocketed on a foul stay down
        let spots = barSpotOffTable(o, &n)                   // RULES.md B19
        countFouls(&n, shooter: g.shooter, fouled: !fouls.isEmpty) // RULES.md B21: counted, never penalized

        if !fouls.isEmpty {
            n.shooter = next(g.shooter)
            n.ballInHand = .anywhere                         // RULES.md B7 (B20: no "two shots")
            return RuleResult(fouls: fouls, nextState: n, turnPasses: true, spot: spots)
        }

        n.ballInHand = .none
        if n.groups == nil && !o.calledSafety, let group = decidingGroup(pocketedObjects, order: o.pocketOrder) {
            n.groups = assign(group, to: g.shooter)          // D11 / RULES.md B3
        }
        n.phase = n.groups == nil ? .open : .inPlay
        // RULES.md B1: slop counts — any own-group ball (any ball on an open table) keeps the turn.
        // RULES.md B22: a called safety passes the turn.
        let keepsTurn: Bool
        if o.calledSafety {
            keepsTurn = false
        } else if let mine = n.groups?[g.shooter] {
            keepsTurn = pocketedObjects.contains { $0.group == mine }
        } else {
            keepsTurn = !pocketedObjects.isEmpty
        }
        if !keepsTurn { n.shooter = next(g.shooter) }
        return RuleResult(fouls: [], nextState: n, turnPasses: !keepsTurn, spot: spots)
    }

    /// RULES.md B19: a non-8 object ball off the table is spotted on the foot spot, no foul.
    private func barSpotOffTable(_ o: ShotOutcome, _ n: inout GameState) -> [BallID] {
        let spots = o.offTable.filter { !$0.isCue && $0 != .eight }.sorted()
        n.onTable.formUnion(spots)
        return spots
    }
}

import Geometry

// WPA 8-ball, Rules of Play eff. 2026-10-21, §4. Each branch cites the rule it implements.
extension RulesEngine {
    func wpaEightBreak(_ o: ShotOutcome, _ g: GameState) -> RuleResult {
        let cueFouls = cueBallFouls(o)                                    // WPA 3.1
        let offObjects = o.offTable.filter { !$0.isCue }.sorted()
        // WPA 4.3(b): no call, no required first ball; 3.3 is replaced by the 4.3(d) break requirement.
        let fouls = cueFouls + headStringFouls(o, g, isBreak: true)        // WPA 4.3(a) / 3.10
            + offObjects.map { Foul.objectBallOffTable($0) }               // WPA 4.3(g)
        let pocketedObjects = objectsPocketed(o)

        var n = g
        n.groups = nil
        n.ballInHand = .none
        n.onTable.subtract(pocketedObjects)
        n.onTable.subtract(offObjects)                                     // WPA 4.3(g): remain out of play...
        var spots: [BallID] = []
        if offObjects.contains(.eight) {                                   // ...except the 8, which is spotted (4.3(g), 4.7)
            n.onTable.insert(.eight)
            spots = [.eight]
        }
        countFouls(&n, shooter: g.shooter, fouled: !fouls.isEmpty)

        func pending(_ chooser: Int, _ reason: OptionReason, _ opts: [PlayerOption]) -> RuleResult {
            n.phase = .awaitingOption(PendingOption(chooser: chooser, reason: reason, options: opts))
            return RuleResult(fouls: fouls, nextState: n, turnPasses: false, spot: spots, options: opts)
        }

        // 4.8 losses "do not apply to the break shot" (WPA 4.8, last line).
        if o.pocketed[.eight] != nil {
            if !fouls.isEmpty {                                            // WPA 4.3(f): opponent chooses
                return pending(next(g.shooter), .eightOnFoulBreak, [.spotEightBallInHandAboveHeadString, .reBreak])
            }
            return pending(g.shooter, .eightOnLegalBreak, [.spotEightAndAccept, .reBreak]) // WPA 4.3(e)
        }

        let toRail = o.noContact ? 0 : (o.objectBallsToRailOnBreak ?? 4)  // unknown count → legal (Reg 25)
        let legalBreak = !pocketedObjects.isEmpty || toRail >= 4           // WPA 4.3(d)
        let scratched = !cueFouls.isEmpty

        if !legalBreak {
            // WPA 4.3(d) options; if the break also fouled, add 4.3(g)/(h)(2) kitchen ball in hand.
            // With the cue ball pocketed/off, "accept the table" is replaced by kitchen BIH (RULES.md interp. 2).
            var opts: [PlayerOption] = scratched ? [] : [.acceptTable]
            if !fouls.isEmpty { opts.append(.ballInHandAboveHeadString) }
            opts += [.reBreak, .reBreakByOffender]
            return pending(next(g.shooter), .illegalBreak, opts)
        }
        if !fouls.isEmpty {
            if scratched {
                // WPA 4.3(h): accepting the table is meaningless with the cue ball pocketed / off the table,
                // so the incoming player gets cue ball in hand above the head string (RULES.md interp. 2).
                n.shooter = next(g.shooter)
                n.ballInHand = .behindHeadString
                n.phase = .open
                return RuleResult(fouls: fouls, nextState: n, turnPasses: true, spot: spots)
            }
            return pending(next(g.shooter), .breakFoul, [.acceptTable, .ballInHandAboveHeadString]) // WPA 4.3(g)/(h)
        }
        n.phase = .open                                                    // WPA 4.3(c): table remains open
        if pocketedObjects.isEmpty { n.shooter = next(g.shooter) }         // WPA 4.3(c): continues only if he pockets
        return RuleResult(fouls: [], nextState: n, turnPasses: n.shooter != g.shooter, spot: spots)
    }

    func wpaEightShot(_ o: ShotOutcome, _ g: GameState) -> RuleResult {
        let legal = legalTargets(g)
        let offObjects = o.offTable.filter { !$0.isCue }.sorted()
        let fouls = cueBallFouls(o)                                        // WPA 3.1
            + headStringFouls(o, g, isBreak: false)                       // WPA 3.10 / 3.11
            + contactFouls(o, legal: legal)                               // WPA 3.2 (+4.4 8-first), 3.3
            + offObjects.map { Foul.objectBallOffTable($0) }               // WPA 3.5
        let pocketedObjects = objectsPocketed(o)
        let mine = g.groups?[g.shooter]
        // Shooting the 8: group cleared (WPA 4.6), or open table with a cleared group and the 8 played (WPA 4.4).
        // An unobserved first contact / call is resolved in the shooter's favour (Reg 25); an explicit call of
        // another ball means the shooter was not playing the 8.
        let calledOther = o.calledBall.map { $0 != .eight } ?? false
        let onEight = mine != nil ? legal == [.eight]
                                  : legal.contains(.eight) && (o.firstContact ?? .eight) == .eight && !calledOther
        let winnerIfLoss = next(g.shooter)

        if o.offTable.contains(.eight) {                                   // WPA 4.8(d)
            return over(g, winner: winnerIfLoss, .eightOffTable, fouls: fouls)
        }
        if let eightPocket = o.pocketed[.eight] {
            if !fouls.isEmpty {                                            // WPA 4.8(a)
                return over(g, winner: winnerIfLoss, .eightWithFoul, fouls: fouls)
            }
            if !onEight {
                // WPA 4.8(b); 8 + last group ball is "before his group is cleared" (4.8(b) + 4.6, interpretation).
                let ownLeft = g.onTable.filter { mine != nil && $0.group == mine }
                let reason: GameEndReason = !ownLeft.isEmpty && ownLeft.isSubset(of: pocketedObjects)
                    ? .eightWithLastGroupBall : .eightEarly
                return over(g, winner: winnerIfLoss, reason, fouls: fouls)
            }
            if o.calledSafety {                                            // WPA 4.6/4.8(c): a safety calls no pocket,
                return over(g, winner: winnerIfLoss, .eightNotCalled, fouls: fouls) // so the 8 was not called
            }
            if calledOther {                                               // WPA 4.6: "then the 8-ball is the called ball";
                return over(g, winner: winnerIfLoss, .eightNotCalled, fouls: fouls) // its pocket was not called, 4.8(c)
            }
            if let called = o.calledPocket, called != eightPocket {      // WPA 4.8(c); unobserved call → legal (Reg 25)
                return over(g, winner: winnerIfLoss, .eightWrongPocket, fouls: fouls)
            }
            return over(g, winner: g.shooter, .eightPocketed, fouls: [])
        }

        var n = g
        n.onTable.subtract(pocketedObjects)                                // WPA 4.7: nothing else is ever spotted
        n.onTable.subtract(offObjects)
        countFouls(&n, shooter: g.shooter, fouled: !fouls.isEmpty)         // WPA 3.13 not in 8-ball: no penalty

        if !fouls.isEmpty {
            n.shooter = next(g.shooter)
            n.ballInHand = .anywhere                                       // WPA 4.9 / 1.6
            return RuleResult(fouls: fouls, nextState: n, turnPasses: true)
        }

        n.ballInHand = .none
        // Balls credited to the shooter: the called ball legally pocketed in the called pocket (WPA 1.7, 4.4, 4.5).
        // No call recorded = obvious shot (WPA 1.7) → every pocketed ball the shooter could have called counts.
        let callable: (BallID) -> Bool = { ball in
            if let mine { return ball.group == mine }                      // WPA 4.6: called ball from own group
            return ball.group != nil                                       // WPA 4.4: open table, any but the 8
        }
        var credited: Set<BallID> = []
        if o.calledSafety {
            credited = []                                                  // WPA 4.6: safety, play passes
        } else if let called = o.calledBall {
            if let p = o.pocketed[called], o.calledPocket == nil || o.calledPocket == p, callable(called) {
                credited = [called]
            }
        } else {
            credited = pocketedObjects.filter(callable)
        }
        if n.groups == nil {
            let group = o.calledBall.flatMap { credited.contains($0) ? $0.group : nil }
                ?? decidingGroup(credited, order: o.pocketOrder)
            if let group { n.groups = assign(group, to: g.shooter) }      // WPA 4.4
        }
        n.phase = n.groups == nil ? .open : .inPlay
        let keepsTurn = !credited.isEmpty                                  // WPA 4.5 / 4.4
        if !keepsTurn { n.shooter = next(g.shooter) }
        return RuleResult(fouls: [], nextState: n, turnPasses: !keepsTurn)
    }
}

import Geometry
import Testing
@testable import Rules

@Suite("Scripted full games")
struct ScriptedGameTests {
    @Test func bar_runOutToWin_thenWinnerBreaks() {
        let e = RulesEngine(ruleSet: .barEight, teams: 2)
        var g = e.newGame(breaker: 0)
        // Break: 3 and 12 drop — table stays open (D11), breaker continues.
        var r = e.apply(brk(pocket: [3: .footLeft, 12: .headRight]), to: g)
        g = r.nextState
        #expect(g.isTableOpen && g.shooter == 0)
        // First legal pocket decides the group: 1 → solids.
        r = e.apply(shot(first: 1, pocket: [1: .footRight]), to: g); g = r.nextState
        #expect(g.groups == [0: .solids, 1: .stripes] && g.shooter == 0)
        // Run the remaining solids (slop counts).
        for n in [2, 4, 5, 6, 7] {
            r = e.apply(shot(first: n, pocket: [n: .sideLeft]), to: g); g = r.nextState
            #expect(!r.turnPasses)
        }
        #expect(e.legalTargets(g) == [.eight])
        #expect(e.requiresCall(g, target: .eight))
        r = e.apply(shot(first: 8, pocket: [8: .headLeft], calledPocket: .headLeft), to: g)
        #expect(r.winner == 0 && r.endReason == .eightPocketed)
        let next = e.nextGame(after: r.nextState)
        #expect(next.breaker == 0 && next.phase == .breakShot) // B25
    }

    @Test func bar_opponentStealsAfterFoul_andWins() {
        let e = RulesEngine(ruleSet: .barEight, teams: 2)
        var g = e.apply(brk(toRail: 5), to: e.newGame(breaker: 0)).nextState    // legal, nothing made → team 1
        g = e.apply(shot(first: 9, pocket: [9: .footLeft]), to: g).nextState     // team 1 takes stripes
        #expect(g.groups == [1: .stripes, 0: .solids])
        g = e.apply(shot(first: 10, rail: false), to: g).nextState                // no-rail foul → team 0 BIH
        #expect(g.shooter == 0 && g.ballInHand == .anywhere)
        g = e.apply(shot(first: 10), to: g).nextState                             // wrong ball → team 1 BIH
        #expect(g.shooter == 1 && g.ballInHand == .anywhere)
        for n in 10...15 { g = e.apply(shot(first: n, pocket: [n: .sideRight]), to: g).nextState }
        let r = e.apply(shot(first: 8, pocket: [8: .footLeft], calledPocket: .footLeft), to: g)
        #expect(r.winner == 1)
        #expect(e.nextGame(after: r.nextState).breaker == 1) // B25: winner breaks
    }

    @Test func wpaEight_eightOnBreakSpot_thenGroupsAndWin() {
        let e = RulesEngine(ruleSet: .wpaEight, teams: 2)
        var r = e.apply(brk(pocket: [8: .sideLeft]), to: e.newGame(breaker: 1))     // 4.3(e)
        r = e.choose(.spotEightAndAccept, in: r.nextState)
        var g = r.nextState
        #expect(g.shooter == 1 && g.onTable.contains(.eight) && g.isTableOpen)
        r = e.apply(shot(first: 14, pocket: [14: .footLeft], calledBall: 14, calledPocket: .footLeft), to: g)
        g = r.nextState
        #expect(g.groups?[1] == .stripes)
        for n in [9, 10, 11, 12, 13, 15] {
            g = e.apply(shot(first: n, pocket: [n: .headLeft], calledBall: n, calledPocket: .headLeft), to: g).nextState
        }
        r = e.apply(shot(first: 8, pocket: [8: .sideRight], calledBall: 8, calledPocket: .sideRight), to: g)
        #expect(r.winner == 1)
        #expect(e.nextGame(after: r.nextState).breaker == 0) // WPA 1.3: alternate
    }

    @Test func wpaNine_pushOutHandBack_thenThreeFoulLoss() {
        let e = RulesEngine(ruleSet: .wpaNine, teams: 2)
        var g = e.newGame(breaker: 0)
        var r = e.apply(brk(toRail: 5, past: 4), to: g); g = r.nextState              // legal dry break
        #expect(g.shooter == 1 && g.phase == .pushOutAvailable)
        r = e.apply(shot(first: 6, rail: false, pushOut: true), to: g); g = r.nextState // team 1 pushes
        r = e.choose(.handBack, in: g); g = r.nextState                                // team 0 hands back
        #expect(g.shooter == 1 && g.phase == .inPlay)
        g = e.apply(shot(first: 5), to: g).nextState                                   // team 1 foul #1
        g = e.apply(shot(first: 1), to: g).nextState                                   // team 0 legal safety
        g = e.apply(shot(first: 2), to: g).nextState                                   // team 1 foul #2
        g = e.apply(shot(first: 1), to: g).nextState                                   // team 0 legal safety
        #expect(g.shooter == 1 && g.shooterOnTwoFouls)                                 // Reg 8 warning shown
        r = e.apply(shot(first: 1, pocket: [0: .footLeft]), to: g)                     // team 1 foul #3
        #expect(r.winner == 0 && r.endReason == .threeFouls)
        let next = e.nextGame(after: r.nextState)
        #expect(next.breaker == 1 && next.consecutiveFouls.isEmpty)                    // WPA 1.3 alternate
    }

    @Test func wpaNine_softBreakHandedBack_breakerPushes_runsOutWithCombo() {
        let e = RulesEngine(ruleSet: .wpaNine, teams: 2)
        var r = e.apply(brk(pocket: [2: .footLeft], toRail: 4, past: 1), to: e.newGame(breaker: 0)) // Reg 16 violation
        r = e.choose(.handBack, in: r.nextState)                                            // Reg 16(4)
        var g = r.nextState
        #expect(g.shooter == 0 && g.phase == .pushOutAvailable)
        r = e.apply(shot(first: 7, rail: false, pushOut: true), to: g)                      // breaker pushes out
        r = e.choose(.acceptTable, in: r.nextState); g = r.nextState                        // opponent plays
        #expect(g.shooter == 1)
        g = e.apply(shot(first: 1, pocket: [1: .footLeft]), to: g).nextState
        r = e.apply(shot(first: 3, pocket: [9: .sideLeft]), to: g)                          // 3→9 combo
        #expect(r.winner == 1 && r.endReason == .ninePocketed)
    }
}

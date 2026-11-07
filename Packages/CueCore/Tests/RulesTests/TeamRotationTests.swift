import Foundation
import Geometry
import Testing
@testable import Rules

/// SPEC §4: teams alternate shooters in a set order, editable mid-game. WPA Reg 27 (doubles).
@Suite("Team rotation (SPEC §4, WPA Reg 27)")
struct TeamRotationTests {
    private func miss(_ e: RulesEngine, _ g: GameState) -> GameState {
        e.apply(shot(first: e.legalTargets(g).min()!.number), to: g).nextState // legal, nothing pocketed
    }

    @Test func formatInit_setsPlayersPerTeam() {
        let e = RulesEngine(ruleSet: .wpaNine, format: .threeVsThree)
        #expect(e.teams == 2 && e.playersPerTeam == 3)
        #expect(e.newGame().lineups == [[0, 1, 2], [0, 1, 2]])
    }

    @Test func oneVsOne_alwaysPlayerZero() {
        let e = RulesEngine(ruleSet: .wpaNine, teams: 2)
        var g = e.newGame().with(phase: .inPlay, ballInHand: BallInHand.none)
        for _ in 0..<4 { g = miss(e, g); #expect(g.activePlayer == 0) }
    }

    @Test(arguments: [GameFormat.twoVsTwo, .threeVsThree, .fourVsFour])
    func reg27_perTurnRotation(_ f: GameFormat) {
        let e = RulesEngine(ruleSet: .wpaNine, format: f)
        let n = f.playersPerTeam
        var g = e.newGame(breaker: 0)
        #expect(g.shooter == 0 && g.activePlayer == 0)        // team 0's first breaker
        g = e.apply(brk(toRail: 5, past: 4), to: g).nextState // dry break
        var expected: [(Int, Int)] = []
        var seen: [(Int, Int)] = [(g.shooter, g.activePlayer)]
        // Team 1 starts with member 0; team 0 continues after its breaker (member 1).
        for k in 0..<(2 * n) { expected.append(k % 2 == 0 ? (1, (k / 2) % n) : (0, (k / 2 + 1) % n)) }
        for _ in 1..<(2 * n) { g = miss(e, g); seen.append((g.shooter, g.activePlayer)) }
        #expect(seen.map { $0.0 } == expected.map { $0.0 })
        #expect(seen.map { $0.1 } == expected.map { $0.1 })
    }

    @Test func continuingTurn_samePlayer() {
        let e = RulesEngine(ruleSet: .wpaNine, format: .twoVsTwo)
        var g = e.apply(brk(pocket: [2: .footLeft]), to: e.newGame()).nextState
        #expect(g.activePlayer == 0)
        g = e.apply(shot(first: 1, pocket: [1: .footLeft]), to: g).nextState
        #expect(g.shooter == 0 && g.activePlayer == 0)
    }

    @Test func foulGivesIncomingTeamItsNextMember() {
        let e = RulesEngine(ruleSet: .barEight, format: .twoVsTwo)
        var g = e.apply(brk(toRail: 5), to: e.newGame()).nextState    // team 1 member 0
        g = e.apply(shot(first: 8), to: g).nextState                  // B17 foul → team 0 member 1
        #expect(g.shooter == 0 && g.activePlayer == 1 && g.ballInHand == .anywhere)
    }

    @Test func reg27_4_pushOutPassedBack_partnerShoots() {
        let e = RulesEngine(ruleSet: .wpaNine, format: .twoVsTwo)
        var g = e.apply(brk(toRail: 5, past: 4), to: e.newGame()).nextState // team 1 member 0 may push
        #expect(g.shooter == 1 && g.activePlayer == 0)
        g = e.apply(shot(first: 5, pushOut: true), to: g).nextState
        let back = e.choose(.handBack, in: g).nextState
        #expect(back.shooter == 1 && back.activePlayer == 1)              // "push out for the partner"
        let accepted = e.choose(.acceptTable, in: g).nextState
        #expect(accepted.shooter == 0 && accepted.activePlayer == 1)      // team 0's next member
    }

    @Test func reg27_2_breakersAlternatePerTeam_wpa() {
        let e = RulesEngine(ruleSet: .wpaNine, format: .twoVsTwo)
        var g = e.newGame(breaker: 0)
        var breakers: [(Int, Int)] = [(g.shooter, g.activePlayer)]
        for _ in 0..<3 {
            g = e.nextGame(after: g.with(phase: .over(winner: 0)))
            breakers.append((g.shooter, g.activePlayer))
        }
        #expect(breakers.map { $0.0 } == [0, 1, 0, 1])   // WPA 1.3
        #expect(breakers.map { $0.1 } == [0, 0, 1, 1])   // Reg 27(2)
    }

    @Test func reg27_2_breakersAlternatePerTeam_barWinnerBreaks() {
        let e = RulesEngine(ruleSet: .barEight, format: .twoVsTwo)
        var g = e.newGame(breaker: 0)
        g = e.nextGame(after: g.with(phase: .over(winner: 0)))
        #expect(g.shooter == 0 && g.activePlayer == 1)
        g = e.nextGame(after: g.with(phase: .over(winner: 0)))
        #expect(g.shooter == 0 && g.activePlayer == 0)
    }

    @Test func b2_reBreak_samePlayerBreaksAgain() {
        let e = RulesEngine(ruleSet: .barEight, format: .twoVsTwo)
        let g = e.nextGame(after: e.newGame().with(phase: .over(winner: 0))) // team 0 member 1 breaks
        let r = e.apply(brk(toRail: 2), to: g)
        #expect(r.reRack && r.nextState.shooter == 0 && r.nextState.activePlayer == 1)
    }

    @Test func reorder_midGame_keepsWhoIsUpNext() {
        let e = RulesEngine(ruleSet: .wpaNine, format: .threeVsThree)
        var g = e.newGame().with(phase: .inPlay, ballInHand: BallInHand.none) // team 0 member 0 at table
        g = e.reorder(team: 0, order: [2, 0, 1], in: g)
        #expect(g.lineups[0] == [2, 0, 1] && g.activePlayer == 0)
        g = miss(e, g)                     // team 1
        g = miss(e, g)                     // team 0: member after 0 in new order → 1
        #expect(g.shooter == 0 && g.activePlayer == 1)
        g = miss(e, g); g = miss(e, g)
        #expect(g.activePlayer == 2)
    }

    @Test func handBackNotOffered_isNoOp_noRotation() {
        let e = RulesEngine(ruleSet: .wpaNine, format: .twoVsTwo)
        let g = e.newGame().with(phase: .inPlay)
        #expect(e.choose(.handBack, in: g).nextState == g)
    }

    @Test func reorder_invalidOrder_ignored() {
        let e = RulesEngine(ruleSet: .wpaNine, format: .twoVsTwo)
        let g = e.newGame()
        #expect(e.reorder(team: 0, order: [0, 0], in: g) == g)
        #expect(e.reorder(team: 0, order: [0, 1, 2], in: g) == g)
        #expect(e.reorder(team: 5, order: [1, 0], in: g) == g)
    }

    /// Interpretation: WPA 3.13 / Reg 27 keep no per-athlete count in doubles, so fouls count per team.
    @Test func wpa3_13_doublesFoulsCountPerTeam_A1A2A1_loses() {
        let e = RulesEngine(ruleSet: .wpaNine, format: .twoVsTwo)
        var g = e.newGame().with(onTable: balls([3, 4, 9]), phase: .inPlay, ballInHand: BallInHand.none)
        var foulers: [Int] = []
        foulers.append(g.activePlayer); g = e.apply(shot(first: 4), to: g).nextState // A member 0 fouls
        g = miss(e, g)                                                                // B legal
        foulers.append(g.activePlayer); g = e.apply(shot(first: 4), to: g).nextState // A member 1 fouls
        g = miss(e, g)                                                                // B legal
        #expect(g.shooterOnTwoFouls)
        foulers.append(g.activePlayer)
        let r = e.apply(shot(first: 4), to: g)                                        // A member 0 fouls
        #expect(foulers == [0, 1, 0])
        #expect(r.winner == 1 && r.endReason == .threeFouls)
    }

    @Test func rosterSurvivesCodable() throws {
        let e = RulesEngine(ruleSet: .barEight, format: .fourVsFour)
        let g = e.reorder(team: 1, order: [3, 2, 1, 0], in: e.newGame())
        let d = try JSONEncoder().encode(g)
        #expect(try JSONDecoder().decode(GameState.self, from: d) == g)
    }
}

import Foundation
import Geometry
import Testing
@testable import Rules

@Suite("Rule-set vote (SPEC §3)")
struct VoteTests {
    @Test func vote_majorityWins() {
        #expect(Vote.winner([.wpaNine, .wpaNine, .barEight]) == .wpaNine)
        #expect(Vote.winner([.wpaEight]) == .wpaEight)
    }
    @Test func vote_pluralityWinsWithThreeWaySplit() {
        #expect(Vote.winner([.wpaEight, .wpaEight, .wpaNine, .barEight]) == .wpaEight)
    }
    @Test func vote_tieFallsBackToBarEight() {
        #expect(Vote.winner([.wpaEight, .wpaNine]) == .barEight)
        #expect(Vote.winner([.wpaEight, .wpaEight, .wpaNine, .wpaNine]) == .barEight)
    }
    @Test func vote_emptyFallsBackToBarEight() {
        #expect(Vote.winner([]) == .barEight)
    }
}

@Suite("Initial state and targets")
struct StateTests {
    @Test func newGame_eightBall_fullRackBreakPhaseKitchen() {
        let e = RulesEngine(ruleSet: .barEight, teams: 2)
        let g = e.newGame(breaker: 1)
        #expect(g.onTable == balls(1...15))
        #expect(g.phase == .breakShot)
        #expect(g.shooter == 1 && g.breaker == 1)
        #expect(g.groups == nil && g.isTableOpen)
        #expect(g.ballInHand == .behindHeadString)
        #expect(g.ruleSet == .barEight && g.teams == 2)
    }
    @Test func newGame_nineBall_nineBallRack() {
        let g = RulesEngine(ruleSet: .wpaNine, teams: 2).newGame()
        #expect(g.onTable == balls(1...9))
        #expect(g.ballInHand == .behindHeadString) // WPA 5.3(a)
    }
    @Test func codableRoundTrip() throws {
        let e = RulesEngine(ruleSet: .wpaNine, teams: 2)
        var g = e.newGame()
        g.phase = .awaitingOption(PendingOption(chooser: 1, reason: .pushOut, options: [.acceptTable, .handBack]))
        let data = try JSONEncoder().encode(g)
        #expect(try JSONDecoder().decode(GameState.self, from: data) == g)
    }

    @Test func legalTargets_eightBreak_anyBall() { // WPA 4.3(b)
        let e = RulesEngine(ruleSet: .wpaEight, teams: 2)
        #expect(e.legalTargets(e.newGame()) == balls(1...15))
    }
    @Test func legalTargets_openTable_excludesEight() { // WPA 4.4, RULES.md B17
        for rs in [RuleSetID.barEight, .wpaEight] {
            let e = RulesEngine(ruleSet: rs, teams: 2)
            let g = e.newGame().with(onTable: balls([1, 2, 8, 9]), phase: .open)
            #expect(e.legalTargets(g) == balls([1, 2, 9]))
        }
    }
    @Test func legalTargets_groupsSet_ownGroupOnly() { // WPA 4.9 / 3.2
        let e = RulesEngine(ruleSet: .wpaEight, teams: 2)
        let g = e.newGame().with(shooter: 1, groups: [0: .solids, 1: .stripes],
                                 onTable: balls([1, 2, 8, 9, 10]), phase: .inPlay)
        #expect(e.legalTargets(g) == balls([9, 10]))
    }
    @Test func legalTargets_groupCleared_eightOnly() { // WPA 4.6
        let e = RulesEngine(ruleSet: .barEight, teams: 2)
        let g = e.newGame().with(shooter: 0, groups: [0: .solids, 1: .stripes],
                                 onTable: balls([8, 9, 10]), phase: .inPlay)
        #expect(e.legalTargets(g) == [.eight])
    }
    @Test func wpa4_4_openTableGroupCleared_eightBecomesLegal() {
        let e = RulesEngine(ruleSet: .wpaEight, teams: 2)
        let g = e.newGame().with(onTable: balls([8, 9, 10]), phase: .open)
        #expect(e.legalTargets(g) == balls([8, 9, 10]))
    }
    @Test func b17_bar_openTableGroupCleared_eightStillIllegal() {
        let e = RulesEngine(ruleSet: .barEight, teams: 2)
        let g = e.newGame().with(onTable: balls([8, 9, 10]), phase: .open)
        #expect(e.legalTargets(g) == balls([9, 10]))
    }
    @Test func legalTargets_nineBall_lowestOnly() { // WPA 5.7 / 3.2
        let e = RulesEngine(ruleSet: .wpaNine, teams: 2)
        #expect(e.legalTargets(e.newGame()) == [b(1)])
        let g = e.newGame().with(onTable: balls([3, 5, 9]), phase: .inPlay)
        #expect(e.legalTargets(g) == [b(3)])
    }
    @Test func legalTargets_noneWhileAwaitingOrOver() {
        let e = RulesEngine(ruleSet: .wpaNine, teams: 2)
        let g = e.newGame().with(phase: .over(winner: 0))
        #expect(e.legalTargets(g).isEmpty)
    }

    @Test func b1_bar_onlyEightRequiresCall() {
        let e = RulesEngine(ruleSet: .barEight, teams: 2)
        let g = e.newGame().with(phase: .inPlay)
        #expect(e.requiresCall(g, target: .eight))
        #expect(!e.requiresCall(g, target: b(3)))
        #expect(!e.requiresCall(e.newGame(), target: .eight)) // B4: no call on the break
    }
    @Test func wpa4_6_everyShotButBreakRequiresCall() {
        let e = RulesEngine(ruleSet: .wpaEight, teams: 2)
        #expect(e.requiresCall(e.newGame().with(phase: .open), target: b(3)))
        #expect(e.requiresCall(e.newGame().with(phase: .inPlay), target: .eight))
        #expect(!e.requiresCall(e.newGame(), target: b(3))) // WPA 4.3(b)
    }
    @Test func wpa5_nineBall_noCalls() {
        let e = RulesEngine(ruleSet: .wpaNine, teams: 2)
        #expect(!e.requiresCall(e.newGame().with(phase: .inPlay), target: .nine))
    }

    @Test func reg8_onTwoFoulsWarning_nineBallOnly() {
        let nine = RulesEngine(ruleSet: .wpaNine, teams: 2)
        #expect(nine.newGame().with(shooter: 1, fouls: [1: 2]).shooterOnTwoFouls)
        #expect(!nine.newGame().with(shooter: 1, fouls: [1: 1]).shooterOnTwoFouls)
        let eight = RulesEngine(ruleSet: .wpaEight, teams: 2)
        #expect(!eight.newGame().with(shooter: 1, fouls: [1: 2]).shooterOnTwoFouls) // WPA 3.13
    }
}

import Geometry
import Testing
@testable import Rules

private let nine = RulesEngine(ruleSet: .wpaNine, teams: 2)
private let noThreeBall = RulesEngine(ruleSet: .wpaNine, teams: 2, threeBallRule: false)
private func inPlay(_ on: [Int] = [3, 4, 9], shooter: Int = 0) -> GameState {
    nine.newGame().with(shooter: shooter, onTable: balls(on), phase: .inPlay, ballInHand: BallInHand.none)
}
private func pending(_ r: RuleResult) -> PendingOption? {
    if case .awaitingOption(let p) = r.nextState.phase { return p }
    return nil
}

@Suite("WPA 9-ball — break (5.3, Reg 16, D13)")
struct NineBreakTests {
    @Test func wpa5_3_legalBreakWithPocket_breakerContinues_pushOutAvailable() {
        let r = nine.apply(brk(pocket: [2: .footLeft], past: 3), to: nine.newGame())
        #expect(r.fouls.isEmpty && !r.turnPasses && r.nextState.shooter == 0)
        #expect(r.nextState.phase == .pushOutAvailable && r.nextState.ballInHand == .none)
        #expect(!r.nextState.onTable.contains(b(2)))
    }
    @Test func wpa5_4_legalBreakNoPocket_incomingMayPushOut() {
        let r = nine.apply(brk(toRail: 5, past: 3), to: nine.newGame())
        #expect(r.turnPasses && r.nextState.shooter == 1 && r.nextState.phase == .pushOutAvailable)
        #expect(r.nextState.ballInHand == .none)
    }
    @Test func wpa5_3b_fourBallRule_violation_isFoul_ballInHandAnywhere() {
        let r = nine.apply(brk(toRail: 3, past: 3), to: nine.newGame())
        #expect(r.fouls == [.illegalBreak])
        #expect(r.nextState.shooter == 1 && r.nextState.ballInHand == .anywhere && r.nextState.phase == .inPlay)
        #expect(r.nextState.consecutiveFouls[0] == 1)
    }
    @Test func wpa5_7_3_2_breakMustHitOneFirst() {
        let r = nine.apply(brk(first: 3, pocket: [2: .footLeft]), to: nine.newGame())
        #expect(r.fouls == [.wrongBallFirst(b(3))] && r.nextState.ballInHand == .anywhere)
    }
    @Test func wpa5_7_scratchOnBreak_ballInHandAnywhere_noPushOut() {
        let r = nine.apply(brk(pocket: [0: .footLeft, 2: .sideLeft]), to: nine.newGame())
        #expect(r.fouls == [.scratch])
        #expect(r.nextState.ballInHand == .anywhere && r.nextState.phase == .inPlay) // 5.4 needs a foul-free break
        #expect(!r.nextState.onTable.contains(b(2)))
    }
    @Test func wpa5_7_badPlacementOnBreak_foul() { // 3.10
        let r = nine.apply(brk(startedAbove: false), to: nine.newGame())
        #expect(r.fouls == [.badCueBallPlacement] && r.nextState.ballInHand == .anywhere)
    }
    @Test func wpa5_5_nineOnLegalBreak_wins() {
        let r = nine.apply(brk(pocket: [9: .footLeft], past: 4), to: nine.newGame())
        #expect(r.winner == 0 && r.endReason == .ninePocketed)
    }
    @Test func d13_nineOnSoftBreak_stillWins() { // overrides Reg 16(5)
        let r = nine.apply(brk(pocket: [9: .footLeft], toRail: 4, past: 1), to: nine.newGame())
        #expect(r.winner == 0 && r.endReason == .ninePocketed)
    }
    @Test func d13_nineOnBreakWithScratch_spotted_ballInHandAnywhere() { // 5.6, 5.7
        let r = nine.apply(brk(pocket: [9: .footLeft, 0: .sideLeft]), to: nine.newGame())
        #expect(r.winner == nil && r.fouls == [.scratch])
        #expect(r.spot == [.nine] && r.nextState.onTable.contains(.nine))
        #expect(r.nextState.shooter == 1 && r.nextState.ballInHand == .anywhere)
    }
    @Test func wpa5_6_nineOffTableOnBreak_spotted_otherBallsStayOut() {
        let r = nine.apply(brk(off: [9, 5]), to: nine.newGame())
        #expect(r.fouls == [.objectBallOffTable(b(5)), .objectBallOffTable(.nine)])
        #expect(r.spot == [.nine] && r.nextState.onTable.contains(.nine) && !r.nextState.onTable.contains(b(5)))
    }
    @Test func reg16_threeBallRuleViolation_incomingAcceptsOrHandsBack() {
        let r = nine.apply(brk(toRail: 4, past: 2), to: nine.newGame())
        #expect(r.fouls.isEmpty)
        #expect(pending(r) == PendingOption(chooser: 1, reason: .threeBallRule, options: [.acceptTable, .handBack]))
    }
    @Test func reg16_countIncludesPocketedBalls_satisfied() {
        let r = nine.apply(brk(pocket: [2: .footLeft], past: 3), to: nine.newGame())
        #expect(pending(r) == nil && r.nextState.phase == .pushOutAvailable)
    }
    @Test func reg16_violationEvenWhenBallPocketed() {
        let r = nine.apply(brk(pocket: [2: .footLeft], past: 2), to: nine.newGame())
        #expect(pending(r)?.reason == .threeBallRule && pending(r)?.chooser == 1)
        #expect(!r.nextState.onTable.contains(b(2)))
    }
    @Test func reg16_3_accept_noPushOut() {
        let r = nine.apply(brk(toRail: 4, past: 2), to: nine.newGame())
        let c = nine.choose(.acceptTable, in: r.nextState)
        #expect(c.nextState.shooter == 1 && c.nextState.phase == .inPlay && c.nextState.ballInHand == .none)
    }
    @Test func reg16_4_handBack_breakerMayPushOut() {
        let r = nine.apply(brk(toRail: 4, past: 2), to: nine.newGame())
        let c = nine.choose(.handBack, in: r.nextState)
        #expect(c.nextState.shooter == 0 && c.nextState.phase == .pushOutAvailable)
    }
    @Test func reg16_unknownCount_legal() {
        let r = nine.apply(brk(toRail: 4, past: nil), to: nine.newGame())
        #expect(pending(r) == nil)
    }
    @Test func reg16_configurableOff() {
        let r = noThreeBall.apply(brk(toRail: 4, past: 0), to: noThreeBall.newGame())
        #expect(pending(r) == nil && r.nextState.phase == .pushOutAvailable && r.nextState.shooter == 1)
    }
    @Test func reg16_foulTakesPrecedenceOverThreeBallRule() {
        let r = nine.apply(brk(pocket: [0: .footLeft], toRail: 4, past: 0), to: nine.newGame())
        #expect(pending(r) == nil && r.nextState.ballInHand == .anywhere)
    }
}

@Suite("WPA 9-ball — push-out (5.4–5.6)")
struct NinePushOutTests {
    private var afterBreak: GameState {
        nine.apply(brk(toRail: 5, past: 3), to: nine.newGame()).nextState // team 1 may push
    }
    @Test func wpa5_4_pushOut_suspendsWrongBallAndRail_opponentChooses() {
        let r = nine.apply(shot(first: 5, rail: false, pushOut: true), to: afterBreak)
        #expect(r.fouls.isEmpty)
        #expect(pending(r) == PendingOption(chooser: 0, reason: .pushOut, options: [.acceptTable, .handBack]))
        #expect(r.nextState.shooter == 1)
    }
    @Test func wpa5_4_pushOut_noContactAllowed() {
        let r = nine.apply(shot(rail: false, noContact: true, pushOut: true), to: afterBreak)
        #expect(r.fouls.isEmpty)
    }
    @Test func wpa5_4_pushOut_choosePlay() {
        let r = nine.apply(shot(first: 5, pushOut: true), to: afterBreak)
        let c = nine.choose(.acceptTable, in: r.nextState)
        #expect(c.nextState.shooter == 0 && c.nextState.phase == .inPlay && c.nextState.ballInHand == .none)
    }
    @Test func wpa5_4_pushOut_chooseHandBack() {
        let r = nine.apply(shot(first: 5, pushOut: true), to: afterBreak)
        let c = nine.choose(.handBack, in: r.nextState)
        #expect(c.nextState.shooter == 1 && c.nextState.phase == .inPlay)
    }
    @Test func wpa5_4_scratchOnPushOut_isFoul() {
        let r = nine.apply(shot(first: 5, pocket: [0: .footLeft], pushOut: true), to: afterBreak)
        #expect(r.fouls == [.scratch] && pending(r) == nil)
        #expect(r.nextState.shooter == 0 && r.nextState.ballInHand == .anywhere && r.nextState.phase == .inPlay)
    }
    @Test func wpa5_6_nineOnPushOut_spotted_noWin() {
        let r = nine.apply(shot(first: 5, pocket: [9: .footLeft, 4: .sideLeft], pushOut: true), to: afterBreak)
        #expect(r.winner == nil && r.spot == [.nine] && r.nextState.onTable.contains(.nine))
        #expect(!r.nextState.onTable.contains(b(4))) // other balls stay down
        #expect(pending(r)?.chooser == 0)            // 5.5: shooter does not continue
    }
    @Test func wpa5_4_onlyShotAfterBreak_normalShotClosesWindow() {
        let r = nine.apply(shot(first: 1, pocket: [1: .footLeft]), to: afterBreak)
        #expect(r.nextState.phase == .inPlay)
        let r2 = nine.apply(shot(first: 5, rail: false, pushOut: true), to: r.nextState)
        #expect(r2.fouls.contains(.wrongBallFirst(b(5)))) // push-out no longer available
    }
    @Test func wpa5_4_pushOutAfterBreakFoul_notAvailable() {
        let g = nine.apply(brk(pocket: [0: .footLeft]), to: nine.newGame()).nextState
        let r = nine.apply(shot(first: 5, pushOut: true), to: g)
        #expect(r.fouls == [.wrongBallFirst(b(5))])
    }
    @Test func wpa5_4_breakerWhoContinues_mayPushOut() {
        let g = nine.apply(brk(pocket: [2: .footLeft]), to: nine.newGame()).nextState
        let r = nine.apply(shot(first: 6, rail: false, pushOut: true), to: g)
        #expect(r.fouls.isEmpty && pending(r)?.chooser == 1)
    }
    @Test func wpa5_4_pushOutAvailable_normalShotAppliesAllRules() {
        let r = nine.apply(shot(first: 5), to: afterBreak)
        #expect(r.fouls == [.wrongBallFirst(b(5))])
    }
    @Test func pushOutFlagIgnoredOutsidePushPhase() {
        let r = nine.apply(shot(first: 4, pushOut: true), to: inPlay())
        #expect(r.fouls == [.wrongBallFirst(b(4))])
    }
}

@Suite("WPA 9-ball — play, fouls, three-foul rule (5.5–5.8)")
struct NinePlayTests {
    @Test func wpa5_5_legalPocket_continues() {
        let r = nine.apply(shot(first: 3, pocket: [4: .footLeft]), to: inPlay())
        #expect(r.fouls.isEmpty && !r.turnPasses && !r.nextState.onTable.contains(b(4)))
    }
    @Test func wpa5_5_noPocket_incomingPlaysFromPosition() {
        let r = nine.apply(shot(first: 3), to: inPlay())
        #expect(r.turnPasses && r.nextState.shooter == 1 && r.nextState.ballInHand == .none)
    }
    @Test func wpa5_5_nineByCombination_wins() { // D13
        let r = nine.apply(shot(first: 3, pocket: [9: .footLeft]), to: inPlay())
        #expect(r.winner == 0 && r.endReason == .ninePocketed)
    }
    @Test func wpa5_5_nineByCarom_withOtherBalls_wins() {
        let r = nine.apply(shot(first: 3, pocket: [9: .footLeft, 3: .sideLeft]), to: inPlay())
        #expect(r.winner == 0)
    }
    @Test func wpa3_2_nineFirstWhenNotLowest_foul_nineSpotted() { // 5.6
        let r = nine.apply(shot(first: 9, pocket: [9: .footLeft]), to: inPlay())
        #expect(r.winner == nil && r.fouls == [.wrongBallFirst(.nine)])
        #expect(r.spot == [.nine] && r.nextState.onTable.contains(.nine) && r.nextState.ballInHand == .anywhere)
    }
    @Test func wpa5_6_nineOnScratch_spotted() {
        let r = nine.apply(shot(first: 3, pocket: [9: .footLeft, 0: .sideLeft]), to: inPlay())
        #expect(r.winner == nil && r.spot == [.nine])
    }
    @Test func wpa5_7_3_5_objectBallOffTable_foul_staysOut() {
        let r = nine.apply(shot(first: 3, off: [4]), to: inPlay())
        #expect(r.fouls == [.objectBallOffTable(b(4))] && r.spot.isEmpty && !r.nextState.onTable.contains(b(4)))
    }
    @Test func wpa5_6_nineOffTable_spotted_foul() {
        let r = nine.apply(shot(first: 3, off: [9]), to: inPlay())
        #expect(r.fouls == [.objectBallOffTable(.nine)] && r.spot == [.nine] && r.nextState.onTable.contains(.nine))
    }
    @Test func wpa5_7_noRail_foul() {
        let r = nine.apply(shot(first: 3, rail: false), to: inPlay())
        #expect(r.fouls == [.noRailAfterContact] && r.nextState.ballInHand == .anywhere)
    }
    @Test func wpa5_7_noContact_foul() {
        let r = nine.apply(shot(rail: nil, noContact: true), to: inPlay())
        #expect(r.fouls == [.noContact])
    }
    @Test func wpa5_7_ballPocketedOnFoul_staysDown() {
        let r = nine.apply(shot(first: 4, pocket: [3: .footLeft]), to: inPlay())
        #expect(!r.nextState.onTable.contains(b(3)) && r.spot.isEmpty)
    }
    @Test func reg25_unobserved_legal() {
        let r = nine.apply(shot(rail: nil), to: inPlay())
        #expect(r.fouls.isEmpty)
    }
    @Test func wpa5_8_threeConsecutiveFouls_loseRack() {
        let r = nine.apply(shot(first: 4), to: inPlay().with(fouls: [0: 2]))
        #expect(r.winner == 1 && r.endReason == .threeFouls && r.nextState.phase == .over(winner: 1))
    }
    @Test func wpa3_13_legalShotResetsCount() {
        let r = nine.apply(shot(first: 3), to: inPlay().with(fouls: [0: 2]))
        #expect(r.nextState.consecutiveFouls[0] == 0 && r.winner == nil)
    }
    @Test func wpa3_13_countsArePerTeam() {
        var g = inPlay()
        g = nine.apply(shot(first: 4), to: g).nextState          // team 0: 1
        g = nine.apply(shot(first: 4), to: g).nextState          // team 1: 1
        #expect(g.consecutiveFouls == [0: 1, 1: 1])
        g = nine.apply(shot(first: 4), to: g).nextState          // team 0: 2
        #expect(g.shooterOnTwoFouls == false)                    // team 1 at table, on 1
        g = nine.apply(shot(first: 4), to: g).nextState          // team 1: 2
        #expect(g.shooterOnTwoFouls)                             // Reg 8: team 0 on two fouls
        let r = nine.apply(shot(first: 4), to: g)                // team 0: 3 → loses
        #expect(r.winner == 1)
    }
    @Test func wpa3_13_singleRack_newRackResetsCounts() {
        let over = inPlay().with(phase: .over(winner: 0), fouls: [0: 2, 1: 2])
        #expect(nine.nextGame(after: over).consecutiveFouls.isEmpty)
    }
    @Test func wpa1_3_breaksAlternate() {
        let over = nine.newGame(breaker: 1).with(phase: .over(winner: 1))
        #expect(nine.nextGame(after: over).breaker == 0)
    }
    @Test func wpa5_9_stalemate_originalBreakerReBreaks() {
        let g = nine.stalemate(nine.newGame(breaker: 1).with(shooter: 0, phase: .inPlay))
        #expect(g.shooter == 1 && g.onTable == balls(1...9))
    }
    @Test func teamRotation_threeTeams() {
        let e = RulesEngine(ruleSet: .wpaNine, teams: 3)
        var g = e.newGame().with(onTable: balls([3, 4, 9]), phase: .inPlay, ballInHand: BallInHand.none)
        g = e.apply(shot(first: 3), to: g).nextState
        #expect(g.shooter == 1)
        g = e.apply(shot(first: 3), to: g).nextState
        #expect(g.shooter == 2)
        g = e.apply(shot(first: 3), to: g).nextState
        #expect(g.shooter == 0)
    }
}

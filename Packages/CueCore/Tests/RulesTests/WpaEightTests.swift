import Geometry
import Testing
@testable import Rules

private let wpa = RulesEngine(ruleSet: .wpaEight, teams: 2)
private let solidsStripes: [Int: BallGroup] = [0: .solids, 1: .stripes]
private let openTable = wpa.newGame().with(phase: .open, ballInHand: BallInHand.none)
private func inPlay(_ on: [Int] = [2, 5, 8, 9, 10]) -> GameState {
    wpa.newGame().with(shooter: 0, groups: solidsStripes, onTable: balls(on), phase: .inPlay, ballInHand: BallInHand.none)
}
private let onEight = inPlay([8, 9, 10])

private func pending(_ r: RuleResult) -> PendingOption? {
    if case .awaitingOption(let p) = r.nextState.phase { return p }
    return nil
}

@Suite("WPA 8-ball — break (4.3)")
struct WpaEightBreakTests {
    @Test func wpa4_3c_ballPocketedNoFoul_breakerContinues_tableOpen() {
        let r = wpa.apply(brk(pocket: [3: .footLeft, 11: .headLeft]), to: wpa.newGame())
        #expect(r.fouls.isEmpty && !r.turnPasses && r.nextState.shooter == 0)
        #expect(r.nextState.groups == nil && r.nextState.phase == .open)
        #expect(r.nextState.ballInHand == .none)
        #expect(!r.nextState.onTable.contains(b(3)) && !r.nextState.onTable.contains(b(11)))
    }
    @Test func wpa4_3b_anyBallFirstOnBreak() {
        let r = wpa.apply(brk(first: 8, pocket: [3: .footLeft]), to: wpa.newGame())
        #expect(r.fouls.isEmpty)
    }
    @Test func wpa4_3d_legalBreakNoPocket_turnPasses() {
        let r = wpa.apply(brk(toRail: 4), to: wpa.newGame())
        #expect(r.fouls.isEmpty && r.turnPasses && r.nextState.shooter == 1 && r.nextState.ballInHand == .none)
        #expect(r.nextState.phase == .open)
    }
    @Test func wpa4_3d_illegalBreak_incomingChooses() {
        let r = wpa.apply(brk(toRail: 3), to: wpa.newGame())
        #expect(r.fouls.isEmpty) // an illegal break is not a foul
        #expect(pending(r) == PendingOption(chooser: 1, reason: .illegalBreak,
                                            options: [.acceptTable, .reBreak, .reBreakByOffender]))
        #expect(r.options == [.acceptTable, .reBreak, .reBreakByOffender])
    }
    @Test func wpa4_3d1_acceptTable_incomingShootsFromPosition() {
        let r = wpa.apply(brk(toRail: 3), to: wpa.newGame())
        let c = wpa.choose(.acceptTable, in: r.nextState)
        #expect(c.nextState.shooter == 1 && c.nextState.ballInHand == .none && c.nextState.phase == .open)
        #expect(c.turnPasses)
    }
    @Test func wpa4_3d2_reRackAndBreak_incomingBreaks() {
        let r = wpa.apply(brk(toRail: 3), to: wpa.newGame())
        let c = wpa.choose(.reBreak, in: r.nextState)
        #expect(c.reRack && c.nextState.phase == .breakShot && c.nextState.shooter == 1)
        #expect(c.nextState.onTable == balls(1...15) && c.nextState.ballInHand == .behindHeadString)
    }
    @Test func wpa4_3d3_offenderBreaksAgain() {
        let r = wpa.apply(brk(toRail: 3), to: wpa.newGame())
        let c = wpa.choose(.reBreakByOffender, in: r.nextState)
        #expect(c.reRack && c.nextState.phase == .breakShot && c.nextState.shooter == 0)
    }
    @Test func wpa4_3e_eightOnLegalBreak_breakerChooses() {
        let r = wpa.apply(brk(pocket: [8: .sideLeft]), to: wpa.newGame())
        #expect(r.winner == nil && r.fouls.isEmpty) // not a foul, not a win
        #expect(pending(r) == PendingOption(chooser: 0, reason: .eightOnLegalBreak,
                                            options: [.spotEightAndAccept, .reBreak]))
        #expect(!r.nextState.onTable.contains(.eight))
    }
    @Test func wpa4_3e1_spotEight_breakerContinues() { // RULES.md interpretation 1
        let r = wpa.apply(brk(pocket: [8: .sideLeft, 4: .footLeft]), to: wpa.newGame())
        let c = wpa.choose(.spotEightAndAccept, in: r.nextState)
        #expect(c.spot == [.eight] && c.nextState.onTable.contains(.eight))
        #expect(!c.nextState.onTable.contains(b(4)))
        #expect(c.nextState.shooter == 0 && c.nextState.ballInHand == .none && c.nextState.phase == .open)
        #expect(!c.turnPasses)
    }
    @Test func wpa4_3e2_reBreak_breakerBreaks() {
        let r = wpa.apply(brk(pocket: [8: .sideLeft]), to: wpa.newGame())
        let c = wpa.choose(.reBreak, in: r.nextState)
        #expect(c.reRack && c.nextState.shooter == 0 && c.nextState.phase == .breakShot)
    }
    @Test func wpa4_3f_eightOnFoulBreak_opponentChooses_notLoss() {
        let r = wpa.apply(brk(pocket: [8: .sideLeft, 0: .footLeft]), to: wpa.newGame())
        #expect(r.winner == nil && r.fouls == [.scratch])
        #expect(pending(r) == PendingOption(chooser: 1, reason: .eightOnFoulBreak,
                                            options: [.spotEightBallInHandAboveHeadString, .reBreak]))
    }
    @Test func wpa4_3f1_spotEight_kitchenBallInHand() {
        let r = wpa.apply(brk(pocket: [8: .sideLeft, 0: .footLeft]), to: wpa.newGame())
        let c = wpa.choose(.spotEightBallInHandAboveHeadString, in: r.nextState)
        #expect(c.spot == [.eight] && c.nextState.onTable.contains(.eight))
        #expect(c.nextState.shooter == 1 && c.nextState.ballInHand == .behindHeadString)
        #expect(c.turnPasses)
    }
    @Test func wpa4_3f2_reBreak_opponentBreaks() {
        let r = wpa.apply(brk(pocket: [8: .sideLeft, 0: .footLeft]), to: wpa.newGame())
        let c = wpa.choose(.reBreak, in: r.nextState)
        #expect(c.reRack && c.nextState.shooter == 1)
    }
    @Test func wpa4_3g_objectBallOffTableOnBreak_foulStaysOut_options() {
        let r = wpa.apply(brk(pocket: [3: .footLeft], off: [12]), to: wpa.newGame())
        #expect(r.fouls == [.objectBallOffTable(b(12))])
        #expect(!r.nextState.onTable.contains(b(12)) && r.spot.isEmpty) // 4.7: no other ball is ever spotted
        #expect(pending(r) == PendingOption(chooser: 1, reason: .breakFoul,
                                            options: [.acceptTable, .ballInHandAboveHeadString]))
    }
    @Test func wpa4_3g_eightOffTableOnBreak_spotted_notLoss() { // 4.3(g), 4.7, 4.8 last line
        let r = wpa.apply(brk(off: [8]), to: wpa.newGame())
        #expect(r.winner == nil && r.fouls == [.objectBallOffTable(.eight)])
        #expect(r.spot == [.eight] && r.nextState.onTable.contains(.eight))
        #expect(pending(r)?.options == [.acceptTable, .ballInHandAboveHeadString])
    }
    @Test func wpa4_3g2_kitchenBallInHand() {
        let r = wpa.apply(brk(off: [12]), to: wpa.newGame())
        let c = wpa.choose(.ballInHandAboveHeadString, in: r.nextState)
        #expect(c.nextState.shooter == 1 && c.nextState.ballInHand == .behindHeadString && c.nextState.phase == .open)
    }
    @Test func wpa4_3g1_acceptTable_noBallInHand() {
        let r = wpa.apply(brk(off: [12]), to: wpa.newGame())
        let c = wpa.choose(.acceptTable, in: r.nextState)
        #expect(c.nextState.shooter == 1 && c.nextState.ballInHand == .none)
    }
    @Test func wpa4_3h_scratchOnBreak_kitchenBallInHand_noChoice() { // RULES.md interpretation 2
        let r = wpa.apply(brk(pocket: [0: .footLeft, 3: .sideLeft]), to: wpa.newGame())
        #expect(r.fouls == [.scratch] && r.turnPasses && r.options.isEmpty)
        #expect(r.nextState.shooter == 1 && r.nextState.ballInHand == .behindHeadString)
        #expect(r.nextState.phase == .open && !r.nextState.onTable.contains(b(3)))
    }
    @Test func wpa4_3h_badPlacementOnBreak_options() { // 3.10
        let r = wpa.apply(brk(toRail: 4, startedAbove: false), to: wpa.newGame())
        #expect(r.fouls == [.badCueBallPlacement])
        #expect(pending(r)?.options == [.acceptTable, .ballInHandAboveHeadString])
    }
    @Test func wpa4_3d_h_illegalBreakWithScratch_combinedOptions() {
        let r = wpa.apply(brk(pocket: [0: .footLeft], toRail: 2), to: wpa.newGame())
        #expect(r.fouls == [.scratch])
        #expect(pending(r) == PendingOption(chooser: 1, reason: .illegalBreak,
                                            options: [.ballInHandAboveHeadString, .reBreak, .reBreakByOffender]))
    }
    @Test func wpa4_3d_g_illegalBreakWithBallOffTable_combinedOptions() {
        let r = wpa.apply(brk(off: [12], toRail: 2), to: wpa.newGame())
        #expect(pending(r)?.options == [.acceptTable, .ballInHandAboveHeadString, .reBreak, .reBreakByOffender])
    }
    @Test func choose_optionNotOffered_isNoOp() {
        let r = wpa.apply(brk(toRail: 3), to: wpa.newGame())
        let c = wpa.choose(.spotEightAndAccept, in: r.nextState)
        #expect(c.nextState == r.nextState)
    }
    @Test func apply_whileAwaitingOption_isNoOp() {
        let r = wpa.apply(brk(toRail: 3), to: wpa.newGame())
        #expect(wpa.apply(shot(first: 1), to: r.nextState).nextState == r.nextState)
    }
}

@Suite("WPA 8-ball — open table, calls, groups (4.4–4.7)")
struct WpaEightGroupTests {
    @Test func wpa4_4_calledBallLegallyPocketed_assignsGroup() {
        let r = wpa.apply(shot(first: 11, pocket: [11: .footLeft], calledBall: 11, calledPocket: .footLeft), to: openTable)
        #expect(r.nextState.groups == [0: .stripes, 1: .solids] && r.nextState.phase == .inPlay)
        #expect(!r.turnPasses)
    }
    @Test func wpa4_4_calledBallMissed_otherBallDrops_tableStaysOpen_turnPasses() {
        let r = wpa.apply(shot(first: 11, pocket: [3: .footLeft], calledBall: 11, calledPocket: .footLeft), to: openTable)
        #expect(r.nextState.groups == nil && r.turnPasses && r.fouls.isEmpty)
        #expect(!r.nextState.onTable.contains(b(3))) // 4.7: stays down
    }
    @Test func wpa1_7_calledBallWrongPocket_doesNotCount() {
        let r = wpa.apply(shot(first: 11, pocket: [11: .sideLeft], calledBall: 11, calledPocket: .footLeft), to: openTable)
        #expect(r.nextState.groups == nil && r.turnPasses)
    }
    @Test func wpa1_7_obviousShot_noCallRecorded_pocketedBallCounts() {
        let r = wpa.apply(shot(first: 4, pocket: [4: .footLeft]), to: openTable)
        #expect(r.nextState.groups == [0: .solids, 1: .stripes] && !r.turnPasses)
    }
    @Test func wpa4_4_combinationAcrossGroups_allowed_calledBallDecides() {
        let r = wpa.apply(shot(first: 3, pocket: [12: .footLeft], calledBall: 12, calledPocket: .footLeft), to: openTable)
        #expect(r.fouls.isEmpty && r.nextState.groups?[0] == .stripes)
    }
    @Test func wpa4_4_eightFirstOnOpenTable_foul() {
        let r = wpa.apply(shot(first: 8), to: openTable)
        #expect(r.fouls == [.wrongBallFirst(.eight)] && r.nextState.ballInHand == .anywhere)
    }
    @Test func wpa4_4_groupClearedOnOpenTable_eightPlayableForWin() {
        let g = openTable.with(onTable: balls([8, 9, 10]))
        let r = wpa.apply(shot(first: 8, pocket: [8: .footLeft], calledBall: 8, calledPocket: .footLeft), to: g)
        #expect(r.winner == 0 && r.endReason == .eightPocketed)
    }
    @Test func wpa4_5_calledOwnBallPocketed_continues() {
        let r = wpa.apply(shot(first: 2, pocket: [2: .headLeft], calledBall: 2, calledPocket: .headLeft), to: inPlay())
        #expect(!r.turnPasses && r.fouls.isEmpty)
    }
    @Test func wpa4_5_uncalledOwnBallDrops_turnPasses_ballStaysDown() {
        let r = wpa.apply(shot(first: 2, pocket: [5: .headLeft], calledBall: 2, calledPocket: .footLeft), to: inPlay())
        #expect(r.turnPasses && r.fouls.isEmpty && !r.nextState.onTable.contains(b(5)))
    }
    @Test func wpa4_6_safety_turnPasses_pocketedBallStaysDown() {
        let r = wpa.apply(shot(first: 2, pocket: [2: .headLeft], safety: true), to: inPlay())
        #expect(r.turnPasses && r.fouls.isEmpty && !r.nextState.onTable.contains(b(2)))
    }
    @Test func wpa4_6_safetyOnOpenTable_assignsNoGroup() {
        let r = wpa.apply(shot(first: 2, pocket: [2: .headLeft], safety: true), to: openTable)
        #expect(r.nextState.groups == nil && r.turnPasses)
    }
}

@Suite("WPA 8-ball — fouls (4.9, 3.x)")
struct WpaEightFoulTests {
    @Test func wpa4_9_scratch_ballInHandAnywhere() {
        let r = wpa.apply(shot(first: 2, pocket: [0: .footLeft]), to: inPlay())
        #expect(r.fouls == [.scratch] && r.nextState.ballInHand == .anywhere && r.nextState.shooter == 1)
    }
    @Test func wpa3_2_wrongBallFirst_foul() {
        let r = wpa.apply(shot(first: 9), to: inPlay())
        #expect(r.fouls == [.wrongBallFirst(b(9))] && r.nextState.ballInHand == .anywhere)
    }
    @Test func wpa3_3_noRailAfterContact_foul() {
        let r = wpa.apply(shot(first: 2, rail: false), to: inPlay())
        #expect(r.fouls == [.noRailAfterContact])
    }
    @Test func wpa3_3_noContact_foul() {
        let r = wpa.apply(shot(rail: nil, noContact: true), to: inPlay())
        #expect(r.fouls == [.noContact])
    }
    @Test func wpa2_7_pocketedBallCountsAsRail() {
        let r = wpa.apply(shot(first: 2, pocket: [9: .footLeft], rail: false), to: inPlay())
        #expect(r.fouls.isEmpty && r.turnPasses)
    }
    @Test func wpa3_5_objectBallOffTable_foul_notSpotted() { // 4.7
        let r = wpa.apply(shot(first: 2, off: [9]), to: inPlay())
        #expect(r.fouls == [.objectBallOffTable(b(9))] && r.spot.isEmpty && !r.nextState.onTable.contains(b(9)))
        #expect(r.nextState.ballInHand == .anywhere)
    }
    @Test func wpa3_10_3_11_kitchenFouls_afterBreakFoul() {
        let g = inPlay().with(ballInHand: .behindHeadString)
        #expect(wpa.apply(shot(first: 2, startedAbove: false), to: g).fouls == [.badCueBallPlacement])
        #expect(wpa.apply(shot(first: 2, crossedFirst: false), to: g).fouls == [.badPlayFromAboveHeadString])
    }
    @Test func wpa4_9_kitchenOnlyAfterBreakFouls_normalFoulIsAnywhere() {
        let r = wpa.apply(shot(first: 9), to: inPlay().with(ballInHand: .behindHeadString))
        #expect(r.nextState.ballInHand == .anywhere)
    }
    @Test func wpa3_13_noThreeFoulRuleInEightBall() {
        let r = wpa.apply(shot(first: 9), to: inPlay().with(fouls: [0: 2]))
        #expect(r.winner == nil && r.nextState.consecutiveFouls[0] == 3)
    }
    @Test func reg25_nothingObserved_legal() {
        let r = wpa.apply(shot(rail: nil), to: inPlay())
        #expect(r.fouls.isEmpty && r.turnPasses && r.nextState.ballInHand == .none)
    }
    @Test func wpa4_7_ballPocketedOnFoul_staysDown() {
        let r = wpa.apply(shot(first: 9, pocket: [2: .footLeft]), to: inPlay())
        #expect(!r.nextState.onTable.contains(b(2)) && r.spot.isEmpty)
    }
}

@Suite("WPA 8-ball — losing the rack (4.8)")
struct WpaEightLossTests {
    @Test func wpa4_8_legalEightInCalledPocket_wins() {
        let r = wpa.apply(shot(first: 8, pocket: [8: .footLeft], calledBall: 8, calledPocket: .footLeft), to: onEight)
        #expect(r.winner == 0 && r.endReason == .eightPocketed)
    }
    @Test func wpa4_8a_eightAndFoul_loses() {
        let r = wpa.apply(shot(first: 8, pocket: [8: .footLeft, 0: .sideLeft], calledPocket: .footLeft), to: onEight)
        #expect(r.winner == 1 && r.endReason == .eightWithFoul)
    }
    @Test func wpa4_8a_eightWithWrongBallFirst_loses() {
        let r = wpa.apply(shot(first: 9, pocket: [8: .footLeft], calledPocket: .footLeft), to: onEight)
        #expect(r.winner == 1 && r.endReason == .eightWithFoul)
    }
    @Test func wpa4_8b_eightBeforeGroupCleared_loses() {
        let r = wpa.apply(shot(first: 2, pocket: [8: .footLeft]), to: inPlay())
        #expect(r.winner == 1 && r.endReason == .eightEarly)
    }
    @Test func wpa4_8b_4_6_eightWithLastGroupBall_loses() {
        let r = wpa.apply(shot(first: 2, pocket: [2: .footLeft, 8: .sideLeft], calledBall: 2, calledPocket: .footLeft),
                          to: inPlay([2, 8, 9]))
        #expect(r.winner == 1 && r.endReason == .eightWithLastGroupBall)
    }
    @Test func wpa4_8c_eightInUncalledPocket_loses() {
        let r = wpa.apply(shot(first: 8, pocket: [8: .sideRight], calledBall: 8, calledPocket: .footLeft), to: onEight)
        #expect(r.winner == 1 && r.endReason == .eightWrongPocket)
    }
    @Test func wpa4_8d_eightOffTable_loses() {
        let r = wpa.apply(shot(first: 8, off: [8]), to: onEight)
        #expect(r.winner == 1 && r.endReason == .eightOffTable)
    }
    @Test func wpa4_9_scratchOnEightWithoutPocketing_foulOnly() {
        let r = wpa.apply(shot(first: 8, pocket: [0: .footLeft]), to: onEight)
        #expect(r.winner == nil && r.fouls == [.scratch] && r.nextState.ballInHand == .anywhere)
    }
    @Test func reg25_unknownCalledPocket_eightWins() {
        let r = wpa.apply(shot(first: 8, pocket: [8: .footLeft]), to: onEight)
        #expect(r.winner == 0)
    }
    @Test func wpa1_3_breaksAlternate() {
        let over = wpa.newGame(breaker: 0).with(shooter: 1, phase: .over(winner: 0))
        #expect(wpa.nextGame(after: over).breaker == 1)
        #expect(wpa.nextGame(after: wpa.newGame(breaker: 1).with(phase: .over(winner: 1))).breaker == 0)
    }
    @Test func wpa4_11_stalemate_originalBreakerReBreaks() {
        let g = wpa.stalemate(inPlay().with(shooter: 1))
        #expect(g.shooter == 0 && g.phase == .breakShot)
    }
}

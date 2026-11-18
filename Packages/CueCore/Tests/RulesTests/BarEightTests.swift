import Geometry
import Testing
@testable import Rules

private let bar = RulesEngine(ruleSet: .barEight, teams: 2)
private let solidsStripes: [Int: BallGroup] = [0: .solids, 1: .stripes]
/// Open table, team 0 to shoot, no ball in hand.
private let openTable = bar.newGame().with(phase: .open, ballInHand: BallInHand.none)
/// Groups set, team 0 (solids) to shoot.
private func inPlay(_ on: [Int] = [2, 5, 8, 9, 10]) -> GameState {
    bar.newGame().with(shooter: 0, groups: solidsStripes, onTable: balls(on), phase: .inPlay, ballInHand: BallInHand.none)
}
/// Team 0 (solids) has cleared its group and is on the 8.
private let onEight = inPlay([8, 9, 10])

@Suite("Bar 8-ball — break (RULES.md B2–B6, B15, B19)")
struct BarBreakTests {
    @Test func b2_illegalBreak_reRackSameBreakerReBreaks() {
        let r = bar.apply(brk(toRail: 3), to: bar.newGame(breaker: 1))
        #expect(r.reRack)
        #expect(r.nextState.phase == .breakShot)
        #expect(r.nextState.shooter == 1)
        #expect(r.nextState.onTable == balls(1...15))
        #expect(r.fouls.isEmpty)
    }
    @Test func b2_legalBreakNoPocket_turnPasses_noBallInHand() {
        let r = bar.apply(brk(toRail: 4), to: bar.newGame())
        #expect(!r.reRack && r.turnPasses)
        #expect(r.nextState.shooter == 1)
        #expect(r.nextState.ballInHand == .none)
        #expect(r.nextState.phase == .open)
    }
    @Test func b2_reg25_unknownRailCount_breakIsLegal() {
        let r = bar.apply(brk(toRail: nil), to: bar.newGame())
        #expect(!r.reRack && r.fouls.isEmpty)
    }
    @Test func b2_illegalBreakWithScratch_stillReRackSameBreaker() {
        let r = bar.apply(brk(pocket: [0: .footLeft], toRail: 2), to: bar.newGame())
        #expect(r.reRack && r.nextState.shooter == 0 && r.nextState.phase == .breakShot)
    }
    @Test func b3_d11_breakPocketsOneGroup_tableStaysOpen_breakerContinues() {
        let r = bar.apply(brk(pocket: [3: .footLeft], toRail: 2), to: bar.newGame())
        #expect(r.nextState.groups == nil)
        #expect(r.nextState.phase == .open)
        #expect(!r.turnPasses && r.nextState.shooter == 0)
        #expect(!r.nextState.onTable.contains(b(3)))
    }
    @Test func b4_eightOnBreak_wins() {
        let r = bar.apply(brk(pocket: [8: .sideLeft]), to: bar.newGame())
        #expect(r.winner == 0 && r.endReason == .eightOnBreak)
        #expect(r.nextState.phase == .over(winner: 0))
    }
    @Test func b5_eightOnBreakWithScratch_loses() {
        let r = bar.apply(brk(pocket: [8: .sideLeft, 0: .footLeft]), to: bar.newGame())
        #expect(r.winner == 1 && r.endReason == .eightOnBreakWithFoul)
        #expect(r.fouls.contains(.scratch))
    }
    @Test func b5_eightOnBreakWithCueOffTable_loses() {
        let r = bar.apply(brk(pocket: [8: .sideLeft], off: [0]), to: bar.newGame())
        #expect(r.winner == 1 && r.endReason == .eightOnBreakWithFoul)
    }
    @Test func b6_scratchOnBreak_opponentKitchenBallInHand_ballsStayDown() {
        let r = bar.apply(brk(pocket: [0: .footLeft, 3: .headLeft, 10: .sideRight]), to: bar.newGame())
        #expect(r.fouls == [.scratch])
        #expect(r.turnPasses && r.nextState.shooter == 1)
        #expect(r.nextState.ballInHand == .behindHeadString)
        #expect(r.nextState.onTable == balls(1...15).subtracting(balls([3, 10])))
        #expect(r.nextState.groups == nil) // D11
        #expect(r.winner == nil)
    }
    @Test func b7_badPlacementOnBreak_ballInHandAnywhere() {
        let r = bar.apply(brk(startedAbove: false), to: bar.newGame())
        #expect(r.fouls == [.badCueBallPlacement])
        #expect(r.nextState.ballInHand == .anywhere && r.nextState.shooter == 1)
    }
    @Test func b15_eightOffTableOnBreak_loses() {
        let r = bar.apply(brk(off: [8]), to: bar.newGame())
        #expect(r.winner == 1 && r.endReason == .eightOffTable)
    }
    @Test func b19_objectBallOffTableOnBreak_spottedNoFoul() {
        let r = bar.apply(brk(off: [5], toRail: 4), to: bar.newGame())
        #expect(r.fouls.isEmpty)
        #expect(r.spot == [b(5)])
        #expect(r.nextState.onTable.contains(b(5)))
    }
}

@Suite("Bar 8-ball — groups (RULES.md B3 / D11)")
struct BarGroupTests {
    @Test func b3_d11_firstLegallyPocketedBallDecidesGroup() {
        let r = bar.apply(shot(first: 10, pocket: [10: .footLeft]), to: openTable)
        #expect(r.nextState.groups == [0: .stripes, 1: .solids])
        #expect(r.nextState.phase == .inPlay)
        #expect(!r.turnPasses && r.nextState.shooter == 0)
    }
    @Test func b3_d11_pocketOrderDecidesMixedShot() {
        let r = bar.apply(shot(first: 3, pocket: [3: .footLeft, 10: .sideLeft], order: [10, 3]), to: openTable)
        #expect(r.nextState.groups == [0: .stripes, 1: .solids])
        #expect(!r.turnPasses)
    }
    @Test func b3_mixedShotUnknownOrder_tableStaysOpen_shooterContinues() {
        let r = bar.apply(shot(first: 3, pocket: [3: .footLeft, 10: .sideLeft]), to: openTable)
        #expect(r.nextState.groups == nil && r.nextState.phase == .open)
        #expect(!r.turnPasses)
    }
    @Test func b3_foulOnOpenTable_assignsNoGroup_b18_ballStaysDown() {
        let r = bar.apply(shot(first: 3, pocket: [3: .footLeft, 0: .sideLeft]), to: openTable)
        #expect(r.nextState.groups == nil)
        #expect(r.fouls == [.scratch])
        #expect(!r.nextState.onTable.contains(b(3)))
        #expect(r.nextState.ballInHand == .anywhere && r.nextState.shooter == 1)
    }
    @Test func b3_secondTeamShooting_getsGroupOpponentGetsOther() {
        let r = bar.apply(shot(first: 4, pocket: [4: .footLeft]), to: openTable.with(shooter: 1))
        #expect(r.nextState.groups == [1: .solids, 0: .stripes])
    }
    @Test func b22_calledSafety_ballStaysDown_turnPasses_noGroup() {
        let r = bar.apply(shot(first: 4, pocket: [4: .footLeft], safety: true), to: openTable)
        #expect(r.turnPasses && r.fouls.isEmpty)
        #expect(r.nextState.groups == nil)
        #expect(!r.nextState.onTable.contains(b(4)))
    }
}

@Suite("Bar 8-ball — fouls (RULES.md B7, B8, B17–B21)")
struct BarFoulTests {
    @Test func b1_slopCounts_uncalledOwnBallContinues() {
        let r = bar.apply(shot(first: 2, pocket: [5: .headRight]), to: inPlay())
        #expect(r.fouls.isEmpty && !r.turnPasses)
        #expect(!r.nextState.onTable.contains(b(5)))
    }
    @Test func b1_pocketingOnlyOpponentBall_turnPasses_noFoul() {
        let r = bar.apply(shot(first: 2, pocket: [10: .headRight]), to: inPlay())
        #expect(r.fouls.isEmpty && r.turnPasses)
        #expect(r.nextState.ballInHand == .none)
        #expect(!r.nextState.onTable.contains(b(10)))
    }
    @Test func b7_scratch_ballInHandAnywhere() {
        let r = bar.apply(shot(first: 2, pocket: [0: .footLeft]), to: inPlay())
        #expect(r.fouls == [.scratch])
        #expect(r.turnPasses && r.nextState.ballInHand == .anywhere && r.nextState.shooter == 1)
    }
    @Test func b7_cueOffTable_ballInHandAnywhere() {
        let r = bar.apply(shot(first: 2, off: [0]), to: inPlay())
        #expect(r.fouls == [.cueBallOffTable] && r.nextState.ballInHand == .anywhere)
    }
    @Test func b8_wrongBallFirst_foul() {
        let r = bar.apply(shot(first: 10), to: inPlay())
        #expect(r.fouls == [.wrongBallFirst(b(10))] && r.nextState.ballInHand == .anywhere)
    }
    @Test func b8_noContact_foul() {
        let r = bar.apply(shot(rail: nil, noContact: true), to: inPlay())
        #expect(r.fouls == [.noContact] && r.turnPasses)
    }
    @Test func b8_noRailAfterContact_foul() {
        let r = bar.apply(shot(first: 2, rail: false), to: inPlay())
        #expect(r.fouls == [.noRailAfterContact])
    }
    @Test func b8_wpa2_7_pocketedBallCountsAsRail() {
        let r = bar.apply(shot(first: 2, pocket: [2: .footLeft], rail: false), to: inPlay())
        #expect(r.fouls.isEmpty && !r.turnPasses)
    }
    @Test func b8_wpa2_7_offTableBallCountsAsRail() {
        let r = bar.apply(shot(first: 2, off: [10], rail: false), to: inPlay())
        #expect(r.fouls.isEmpty)
    }
    @Test func reg25_unobservedContactAndRail_isLegal() {
        let r = bar.apply(shot(first: nil, rail: nil), to: inPlay())
        #expect(r.fouls.isEmpty && r.turnPasses && r.nextState.ballInHand == .none)
    }
    @Test func b6_kitchenBallInHand_placementAndCrossingFouls() {
        let g = inPlay().with(ballInHand: .behindHeadString)
        #expect(bar.apply(shot(first: 2, startedAbove: false), to: g).fouls == [.badCueBallPlacement])
        #expect(bar.apply(shot(first: 2, crossedFirst: false), to: g).fouls == [.badPlayFromAboveHeadString])
        #expect(bar.apply(shot(first: 2, startedAbove: true, crossedFirst: true), to: g).fouls.isEmpty)
        #expect(bar.apply(shot(first: 2, crossedFirst: false), to: g).nextState.ballInHand == .anywhere)
    }
    @Test func headStringFields_ignoredWithoutKitchenBallInHand() {
        let r = bar.apply(shot(first: 2, startedAbove: false, crossedFirst: false), to: inPlay())
        #expect(r.fouls.isEmpty)
    }
    @Test func b17_eightFirstOnOpenTable_foul() {
        let r = bar.apply(shot(first: 8), to: openTable)
        #expect(r.fouls == [.wrongBallFirst(.eight)] && r.nextState.ballInHand == .anywhere)
        #expect(r.winner == nil)
    }
    @Test func b18_ballPocketedOnFoul_staysDown_countsForOwner() {
        let r = bar.apply(shot(first: 10, pocket: [5: .footLeft]), to: inPlay())
        #expect(!r.nextState.onTable.contains(b(5)))
        #expect(r.nextState.groups == solidsStripes)
        #expect(r.spot.isEmpty)
    }
    @Test func b19_objectBallOffTable_spotted_noFoul() {
        let r = bar.apply(shot(first: 2, off: [10]), to: inPlay())
        #expect(r.fouls.isEmpty && r.spot == [b(10)] && r.nextState.onTable.contains(b(10)))
        #expect(r.turnPasses) // nothing pocketed
    }
    @Test func b20_b21_noThreeFoulRule() {
        let g = inPlay().with(fouls: [0: 2])
        let r = bar.apply(shot(first: 10), to: g)
        #expect(r.winner == nil && r.nextState.consecutiveFouls[0] == 3)
    }
    @Test func legalShot_resetsConsecutiveFouls() {
        let r = bar.apply(shot(first: 2, pocket: [2: .footLeft]), to: inPlay().with(fouls: [0: 2]))
        #expect(r.nextState.consecutiveFouls[0] == 0)
    }
    @Test func b20_noTwoShots_incomingGetsOneTurnWithBallInHand() {
        let r = bar.apply(shot(first: 10), to: inPlay())
        let r2 = bar.apply(shot(first: 9, rail: true), to: r.nextState)
        #expect(r2.turnPasses && r2.nextState.shooter == 0 && r2.nextState.ballInHand == .none)
    }
}

@Suite("Bar 8-ball — the 8 (RULES.md B9–B16)")
struct BarEightBallTests {
    @Test func b16_eightInCalledPocket_wins() {
        let r = bar.apply(shot(first: 8, pocket: [8: .footLeft], calledPocket: .footLeft), to: onEight)
        #expect(r.winner == 0 && r.endReason == .eightPocketed && r.nextState.phase == .over(winner: 0))
    }
    @Test func b16_eightByKissWithOtherBallDropping_stillWins() {
        let r = bar.apply(shot(first: 8, pocket: [8: .footLeft, 10: .sideLeft], calledPocket: .footLeft), to: onEight)
        #expect(r.winner == 0)
    }
    @Test func b1_reg25_unknownCalledPocket_eightWins() {
        let r = bar.apply(shot(first: 8, pocket: [8: .footLeft]), to: onEight)
        #expect(r.winner == 0)
    }
    @Test func b9_scratchWhileShootingEight_eightNotPocketed_loses() {
        let r = bar.apply(shot(first: 8, pocket: [0: .footLeft]), to: onEight)
        #expect(r.winner == 1 && r.endReason == .scratchOnEight)
    }
    @Test func b9_cueOffTableWhileShootingEight_loses() {
        let r = bar.apply(shot(first: 8, off: [0]), to: onEight)
        #expect(r.winner == 1 && r.endReason == .scratchOnEight)
    }
    @Test func b9_eightAndScratch_loses() {
        let r = bar.apply(shot(first: 8, pocket: [8: .footLeft, 0: .headLeft], calledPocket: .footLeft), to: onEight)
        #expect(r.winner == 1 && r.endReason == .eightWithFoul)
    }
    @Test func b9_eightWithNonScratchFoul_loses() { // interpretation: any foul while pocketing the 8 loses
        let r = bar.apply(shot(first: 10, pocket: [8: .footLeft], calledPocket: .footLeft), to: onEight)
        #expect(r.winner == 1 && r.endReason == .eightWithFoul)
    }
    @Test func b10_otherFoulOnEightShot_eightNotPocketed_foulOnly() {
        let r = bar.apply(shot(first: 10), to: onEight)
        #expect(r.winner == nil && r.fouls == [.wrongBallFirst(b(10))])
        #expect(r.nextState.ballInHand == .anywhere && r.nextState.shooter == 1)
    }
    @Test func b10_noRailOnEightShot_foulOnly() {
        let r = bar.apply(shot(first: 8, rail: false), to: onEight)
        #expect(r.winner == nil && r.fouls == [.noRailAfterContact])
    }
    @Test func b12_eightInWrongPocket_loses() {
        let r = bar.apply(shot(first: 8, pocket: [8: .footRight], calledPocket: .footLeft), to: onEight)
        #expect(r.winner == 1 && r.endReason == .eightWrongPocket)
    }
    @Test func b13_eightEarly_loses() {
        let r = bar.apply(shot(first: 2, pocket: [8: .footLeft], calledPocket: .footLeft), to: inPlay())
        #expect(r.winner == 1 && r.endReason == .eightEarly)
    }
    @Test func b13_eightOnOpenTable_loses() {
        let r = bar.apply(shot(first: 3, pocket: [8: .footLeft]), to: openTable)
        #expect(r.winner == 1 && r.endReason == .eightEarly)
    }
    @Test func b14_eightAndLastGroupBallSameShot_loses() {
        let r = bar.apply(shot(first: 2, pocket: [2: .footLeft, 8: .sideLeft], calledPocket: .sideLeft),
                          to: inPlay([2, 8, 9]))
        #expect(r.winner == 1 && r.endReason == .eightWithLastGroupBall)
    }
    @Test func b15_eightOffTable_loses() {
        let r = bar.apply(shot(first: 2, off: [8]), to: inPlay())
        #expect(r.winner == 1 && r.endReason == .eightOffTable)
    }
    @Test func applyAfterGameOver_isNoOp() {
        let over = onEight.with(phase: .over(winner: 0))
        let r = bar.apply(shot(first: 8, pocket: [0: .footLeft]), to: over)
        #expect(r.nextState == over && r.fouls.isEmpty && r.winner == nil)
    }
}

@Suite("Bar 8-ball — racks (RULES.md B24, B25)")
struct BarRackTests {
    @Test func b25_winnerBreaksNext() {
        let over = bar.newGame(breaker: 0).with(phase: .over(winner: 1))
        let g = bar.nextGame(after: over)
        #expect(g.breaker == 1 && g.shooter == 1 && g.phase == .breakShot && g.onTable == balls(1...15))
        let over2 = bar.newGame(breaker: 0).with(phase: .over(winner: 0))
        #expect(bar.nextGame(after: over2).breaker == 0)
    }
    @Test func b24_stalemate_sameBreakerReRacks() {
        let g = bar.stalemate(inPlay().with(shooter: 1))
        #expect(g.phase == .breakShot && g.shooter == 0 && g.onTable == balls(1...15) && g.groups == nil)
    }
}

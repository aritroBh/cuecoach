import Geometry
import Testing
@testable import Rules

/// WPA Playing Regulation 25: an unobserved (`nil`) field must never create a foul, a loss, or a worse outcome
/// than the same shot with the favourable observation.
@Suite("Reg 25 — nil observations never hurt the shooter")
struct Reg25AuditTests {
    static let eights: [RuleSetID] = [.barEight, .wpaEight]

    // WPA 4.4 + Reg 25: open table, a group cleared, 8 in the called pocket, first contact not observed.
    @Test func wpa4_4_reg25_openTableGroupCleared_unobservedFirstContact_eightWins() {
        let e = RulesEngine(ruleSet: .wpaEight, teams: 2)
        let g = e.newGame().with(onTable: balls([8, 9, 10]), phase: .open, ballInHand: BallInHand.none)
        let r = e.apply(shot(first: nil, pocket: [8: .footLeft], calledPocket: .footLeft), to: g)
        #expect(r.winner == 0 && r.endReason == .eightPocketed)
    }

    @Test(arguments: RuleSetID.allCases)
    func reg25_allNilObservations_normalShot_noFoul(_ rs: RuleSetID) {
        let e = RulesEngine(ruleSet: rs, teams: 2)
        let g = e.newGame().with(phase: rs == .wpaNine ? .inPlay : .open, ballInHand: .behindHeadString)
        let r = e.apply(ShotOutcome(), to: g)
        #expect(r.fouls.isEmpty && r.winner == nil && r.nextState.ballInHand == .none)
    }

    @Test(arguments: RuleSetID.allCases)
    func reg25_allNilObservations_break_legal(_ rs: RuleSetID) {
        let e = RulesEngine(ruleSet: rs, teams: 2)
        let r = e.apply(ShotOutcome(isBreak: true), to: e.newGame())
        #expect(r.fouls.isEmpty && !r.reRack && r.options.isEmpty && r.winner == nil)
    }

    @Test(arguments: eights)
    func reg25_onEight_unobservedFirstContactAndRail_eightWins(_ rs: RuleSetID) {
        let e = RulesEngine(ruleSet: rs, teams: 2)
        let g = e.newGame().with(shooter: 0, groups: [0: .solids, 1: .stripes], onTable: balls([8, 9]),
                                 phase: .inPlay, ballInHand: BallInHand.none)
        let r = e.apply(ShotOutcome(pocketed: [.eight: .footLeft]), to: g)
        #expect(r.winner == 0)
    }

    @Test(arguments: eights)
    func reg25_unobservedPlacementOnKitchenBallInHand_noFoul(_ rs: RuleSetID) {
        let e = RulesEngine(ruleSet: rs, teams: 2)
        let g = e.newGame().with(shooter: 0, groups: [0: .solids, 1: .stripes], phase: .inPlay,
                                 ballInHand: .behindHeadString)
        let r = e.apply(ShotOutcome(firstContact: b(1), pocketed: [b(1): .footLeft]), to: g)
        #expect(r.fouls.isEmpty && !r.turnPasses)
    }

    @Test func reg25_wpaEight_unobservedCall_ownBallCounts() {
        let e = RulesEngine(ruleSet: .wpaEight, teams: 2)
        let g = e.newGame().with(shooter: 0, groups: [0: .solids, 1: .stripes], phase: .inPlay,
                                 ballInHand: BallInHand.none)
        let r = e.apply(ShotOutcome(pocketed: [b(3): .sideLeft]), to: g)
        #expect(!r.turnPasses && r.fouls.isEmpty)
    }

    @Test func reg25_nine_unobservedThreeBallCountAndRails_legalBreakPushOutAvailable() {
        let e = RulesEngine(ruleSet: .wpaNine, teams: 2)
        let r = e.apply(ShotOutcome(isBreak: true, firstContact: b(1)), to: e.newGame())
        #expect(r.fouls.isEmpty && r.nextState.phase == .pushOutAvailable)
    }
}

@Suite("WPA 4.6 — calling the 8")
struct CallingEightTests {
    private static let wpa = RulesEngine(ruleSet: .wpaEight, teams: 2)
    private static let onEight = wpa.newGame().with(shooter: 0, groups: [0: .solids, 1: .stripes],
                                                    onTable: balls([8, 9, 10]), phase: .inPlay,
                                                    ballInHand: BallInHand.none)

    @Test func wpa4_6_4_8c_onEight_calledOtherBall_eightDrops_loses() {
        let r = Self.wpa.apply(shot(first: 8, pocket: [8: .footLeft], calledBall: 10, calledPocket: .footLeft),
                               to: Self.onEight)
        #expect(r.winner == 1 && r.endReason == .eightNotCalled)
    }
    @Test func wpa4_6_onEight_noCallRecorded_eightInferred_wins() {
        let r = Self.wpa.apply(shot(first: 8, pocket: [8: .footLeft], calledPocket: .footLeft), to: Self.onEight)
        #expect(r.winner == 0)
    }
    @Test func wpa4_4_openTableGroupCleared_calledOtherBall_eightDrops_loses() {
        let g = Self.wpa.newGame().with(onTable: balls([8, 9, 10]), phase: .open, ballInHand: BallInHand.none)
        let r = Self.wpa.apply(shot(first: nil, pocket: [8: .footLeft], calledBall: 9, calledPocket: .footLeft), to: g)
        #expect(r.winner == 1)
    }
    @Test func b1_bar_onlyEightPocketIsCalled_calledBallIgnored() {
        let bar = RulesEngine(ruleSet: .barEight, teams: 2)
        let g = Self.onEight.with()
        var bg = g; bg.ruleSet = .barEight
        let r = bar.apply(shot(first: 8, pocket: [8: .footLeft], calledBall: 10, calledPocket: .footLeft), to: bg)
        #expect(r.winner == 0)
    }
}

import Geometry
import Testing
@testable import Rules

/// Adversarial QA audit of the rules engine against docs/RULES.md, DECISIONS D11/D13/D15/D17 and the
/// WPA Rules of Play / Playing Regulations eff. 2026-10-21. Passing tests are kept as regressions
/// (findings R1-R3 are fixed).
@Suite("Audit: adversarial rules scenarios")
struct AuditTests {
    let bar = RulesEngine(ruleSet: .barEight)
    let wpa8 = RulesEngine(ruleSet: .wpaEight)
    let nine = RulesEngine(ruleSet: .wpaNine)

    private func onEight(_ e: RulesEngine, shooter: Int = 0) -> GameState {
        e.newGame().with(shooter: shooter, groups: [0: .solids, 1: .stripes], onTable: balls([8, 9, 10]),
                         phase: .inPlay, ballInHand: BallInHand.none)
    }

    /// 9-ball: a foul-free dry break, team 1 to shoot with the push-out available.
    private func afterDryNineBreak(_ e: RulesEngine) -> GameState {
        e.apply(brk(toRail: 5, past: 4), to: e.newGame()).nextState
    }

    // MARK: - 8 (or 9) + scratch on the break, each rule set

    @Test func bar_b5_eightAndScratchOnBreak_breakerLoses() {
        let r = bar.apply(brk(pocket: [8: .footLeft, 0: .headLeft]), to: bar.newGame())
        #expect(r.winner == 1 && r.endReason == .eightOnBreakWithFoul)
        #expect(r.fouls.contains(.scratch))
    }

    @Test func bar_b5_eightAndCueOffTableOnBreak_breakerLoses() {
        let r = bar.apply(brk(pocket: [8: .footLeft], off: [0]), to: bar.newGame())
        #expect(r.winner == 1 && r.endReason == .eightOnBreakWithFoul)
    }

    @Test func bar_b5_eightAndScratchOnOtherwiseSoftBreak_losesNotReRack() {
        // B5 beats the D15 "illegal break + scratch = re-rack" path: the 8 dropped, so the break was not empty.
        let r = bar.apply(brk(pocket: [8: .footLeft, 0: .headLeft], toRail: 0), to: bar.newGame())
        #expect(r.winner == 1 && !r.reRack)
    }

    @Test func bar_b4_eightAloneOnSoftBreak_wins() {
        let r = bar.apply(brk(pocket: [8: .sideLeft], toRail: 0), to: bar.newGame())
        #expect(r.winner == 0 && r.endReason == .eightOnBreak)
    }

    @Test func bar_b15_eightOffTableOnIllegalBreak_losesNotReRack() {
        let r = bar.apply(brk(off: [8], toRail: 1), to: bar.newGame())
        #expect(r.winner == 1 && r.endReason == .eightOffTable && !r.reRack)
    }

    @Test func wpa8_4_3f_eightAndScratchOnBreak_opponentChooses() {
        let g = wpa8.newGame()
        let r = wpa8.apply(brk(pocket: [8: .footLeft, 3: .sideLeft, 0: .headLeft]), to: g)
        #expect(r.winner == nil)
        guard case .awaitingOption(let p) = r.nextState.phase else { Issue.record("no option"); return }
        #expect(p.chooser == 1 && p.reason == .eightOnFoulBreak)
        #expect(Set(p.options) == [.spotEightBallInHandAboveHeadString, .reBreak])
        let spot = wpa8.choose(.spotEightBallInHandAboveHeadString, in: r.nextState)
        #expect(spot.spot == [.eight])
        #expect(spot.nextState.shooter == 1 && spot.nextState.ballInHand == .behindHeadString)
        #expect(spot.nextState.onTable.contains(.eight) && !spot.nextState.onTable.contains(b(3)))
        #expect(spot.nextState.groups == nil && spot.nextState.phase == .open)
        let rb = wpa8.choose(.reBreak, in: r.nextState)
        #expect(rb.reRack && rb.nextState.shooter == 1 && rb.nextState.phase == .breakShot)
        #expect(rb.nextState.onTable.count == 15)
    }

    @Test func wpa8_4_8_eightOffTableOnBreak_isNotALoss_spottedAndFoul() {
        let r = wpa8.apply(brk(pocket: [2: .footLeft], off: [8]), to: wpa8.newGame())
        #expect(r.winner == nil && r.spot == [.eight] && r.fouls.contains(.objectBallOffTable(.eight)))
        guard case .awaitingOption(let p) = r.nextState.phase else { Issue.record("no option"); return }
        #expect(p.chooser == 1 && Set(p.options) == [.acceptTable, .ballInHandAboveHeadString]) // 4.3(g)
        #expect(r.nextState.onTable.contains(.eight))
    }

    @Test func wpa8_4_3e_eightOnLegalBreak_spotAndAccept_breakerContinues() {
        let r = wpa8.apply(brk(pocket: [8: .footRight]), to: wpa8.newGame())
        guard case .awaitingOption(let p) = r.nextState.phase else { Issue.record("no option"); return }
        #expect(p.chooser == 0 && p.reason == .eightOnLegalBreak)
        let s = wpa8.choose(.spotEightAndAccept, in: r.nextState)
        #expect(s.nextState.shooter == 0 && s.nextState.ballInHand == BallInHand.none && !s.turnPasses)
        #expect(s.nextState.onTable.contains(.eight))
    }

    @Test func nine_d13_nineAndScratchOnBreak_spottedBallInHandAnywhere() {
        let r = nine.apply(brk(pocket: [9: .footLeft, 0: .headLeft]), to: nine.newGame())
        #expect(r.winner == nil && r.spot == [.nine] && r.fouls.contains(.scratch))
        #expect(r.nextState.shooter == 1 && r.nextState.ballInHand == .anywhere)
        #expect(r.nextState.phase == .inPlay)                    // WPA 5.4: no push-out after a foul break
        #expect(r.nextState.onTable.contains(.nine))
    }

    @Test func nine_eightAndScratchOnBreak_eightStaysDown() {
        let r = nine.apply(brk(pocket: [8: .footLeft, 0: .headLeft]), to: nine.newGame())
        #expect(r.spot.isEmpty && !r.nextState.onTable.contains(.eight)) // WPA 5.6: only the 9 is spotted
        #expect(r.nextState.ballInHand == .anywhere)
    }

    @Test func nine_nineOnBreak_wrongBallFirst_spottedNotWin() {
        let r = nine.apply(brk(first: 3, pocket: [9: .footLeft]), to: nine.newGame())
        #expect(r.winner == nil && r.spot == [.nine] && r.fouls.contains(.wrongBallFirst(b(3))))
    }

    @Test func nine_nineOffTableOnBreak_spottedFoul() {
        let r = nine.apply(brk(pocket: [2: .footLeft], off: [9]), to: nine.newGame())
        #expect(r.winner == nil && r.spot == [.nine] && r.nextState.ballInHand == .anywhere)
    }

    // MARK: - 9 on the push-out (WPA 5.4 / 5.6)

    @Test func nine_5_6_nineOnPushOut_spotted_otherBallsStayDown_opponentChooses() {
        let g = afterDryNineBreak(nine)
        let r = nine.apply(shot(first: 5, pocket: [9: .footLeft, 4: .sideLeft], pushOut: true), to: g)
        #expect(r.winner == nil && r.fouls.isEmpty && r.spot == [.nine])
        #expect(r.nextState.onTable.contains(.nine) && !r.nextState.onTable.contains(b(4)))
        guard case .awaitingOption(let p) = r.nextState.phase else { Issue.record("no option"); return }
        #expect(p.chooser == 0 && p.reason == .pushOut)
        let back = nine.choose(.handBack, in: r.nextState).nextState
        #expect(back.shooter == 1 && back.phase == .inPlay && back.onTable.contains(.nine))
        let acc = nine.choose(.acceptTable, in: r.nextState).nextState
        #expect(acc.shooter == 0 && acc.phase == .inPlay)
    }

    @Test func nine_nineOnPushOut_withScratch_isFoulSpottedNoOption() {
        let g = afterDryNineBreak(nine)
        let r = nine.apply(shot(first: 5, pocket: [9: .footLeft, 0: .headLeft], pushOut: true), to: g)
        #expect(r.winner == nil && r.spot == [.nine] && r.fouls.contains(.scratch))
        #expect(r.nextState.shooter == 0 && r.nextState.ballInHand == .anywhere && r.options.isEmpty)
    }

    @Test func nine_nineOffTableOnPushOut_foulSpotted() {
        let g = afterDryNineBreak(nine)
        let r = nine.apply(shot(first: 5, off: [9], pushOut: true), to: g)
        #expect(r.fouls.contains(.objectBallOffTable(.nine)) && r.spot == [.nine] && r.winner == nil)
    }

    @Test func nine_pushOut_noContactNoRail_notAFoul() {
        let g = afterDryNineBreak(nine)
        let r = nine.apply(shot(rail: false, noContact: true, pushOut: true), to: g)
        #expect(r.fouls.isEmpty)
    }

    @Test func nine_pushOut_notAvailableAfterFoulBreak() {
        let g = nine.apply(brk(pocket: [0: .headLeft]), to: nine.newGame()).nextState
        let r = nine.apply(shot(first: 5, pushOut: true), to: g)
        #expect(r.fouls.contains(.wrongBallFirst(b(5))))
    }

    @Test func nine_secondPushOut_isNormalShot() {
        let g = afterDryNineBreak(nine)
        let p = nine.apply(shot(first: 5, pushOut: true), to: g).nextState
        let acc = nine.choose(.acceptTable, in: p).nextState
        let r = nine.apply(shot(first: 5, pushOut: true), to: acc)
        #expect(r.fouls.contains(.wrongBallFirst(b(5))))
    }

    @Test func nine_pushOutFlagOnLaterShot_nineCombo_winsNotSpotted() {
        // Push-out flag on a shot where no push-out is allowed must not suppress a legal 9 win.
        let g = nine.newGame().with(onTable: balls([3, 9]), phase: .inPlay, ballInHand: BallInHand.none)
        let r = nine.apply(shot(first: 3, pocket: [9: .footLeft], pushOut: true), to: g)
        #expect(r.winner == 0 && r.endReason == .ninePocketed)
    }

    @Test func nine_reg16_4_handedBack_breakerPushesOut_nineSpotted_opponentChoosesAgain() {
        let g = nine.apply(brk(toRail: 5, past: 2), to: nine.newGame()).nextState
        let back = nine.choose(.handBack, in: g).nextState
        #expect(back.shooter == 0 && back.phase == .pushOutAvailable)
        let r = nine.apply(shot(first: 4, pocket: [9: .sideRight], pushOut: true), to: back)
        #expect(r.spot == [.nine] && r.winner == nil)
        guard case .awaitingOption(let p) = r.nextState.phase else { Issue.record("no option"); return }
        #expect(p.chooser == 1 && p.reason == .pushOut)
    }

    // MARK: - Three-ball rule edge counts (WPA 5.3(c), Reg 16)

    @Test(arguments: [0, 1, 2])
    func nine_reg16_fewerThanThree_illegal(_ past: Int) {
        let r = nine.apply(brk(toRail: 6, past: past), to: nine.newGame())
        #expect(r.fouls.isEmpty && r.winner == nil)
        guard case .awaitingOption(let p) = r.nextState.phase else { Issue.record("no option"); return }
        #expect(p.chooser == 1 && p.reason == .threeBallRule && Set(p.options) == [.acceptTable, .handBack])
    }

    @Test(arguments: [3, 4, 9])
    func nine_reg16_threeOrMore_legal(_ past: Int) {
        let r = nine.apply(brk(toRail: 6, past: past), to: nine.newGame())
        #expect(r.nextState.phase == .pushOutAvailable && r.nextState.shooter == 1)
    }

    @Test func nine_reg16_onePocketedPlusTwoCrossed_legal_breakerContinues() {
        let r = nine.apply(brk(pocket: [5: .footLeft], toRail: 2, past: 3), to: nine.newGame())
        #expect(r.nextState.phase == .pushOutAvailable && r.nextState.shooter == 0)
    }

    @Test func nine_reg16_onePocketedPlusOneCrossed_illegal_pocketedStaysDown() {
        let r = nine.apply(brk(pocket: [5: .footLeft], toRail: 6, past: 2), to: nine.newGame())
        guard case .awaitingOption(let p) = r.nextState.phase else { Issue.record("no option"); return }
        #expect(p.reason == .threeBallRule && !r.nextState.onTable.contains(b(5)) && r.spot.isEmpty)
    }

    @Test
    func nine_reg16_threePocketed_alwaysSatisfiesRule_evenIfCountUnderReported() {
        // Reg 16(1): three pocketed balls satisfy the rule on their own. A tracker that reports only head-string
        // crossings (0) must not turn a three-ball make into an illegal break.
        let r = nine.apply(brk(pocket: [2: .footLeft, 3: .footRight, 4: .sideLeft], toRail: 0, past: 0),
                           to: nine.newGame())
        #expect(r.nextState.phase == .pushOutAvailable && r.nextState.shooter == 0)
    }

    @Test func nine_reg16_ruleOff_softBreakLegal() {
        let e = RulesEngine(ruleSet: .wpaNine, threeBallRule: false)
        let r = e.apply(brk(toRail: 4, past: 0), to: e.newGame())
        #expect(r.nextState.phase == .pushOutAvailable)
    }

    @Test func nine_5_3b_fewRails_isFoul_beatsThreeBallOption() {
        let r = nine.apply(brk(toRail: 3, past: 0), to: nine.newGame())
        #expect(r.fouls.contains(.illegalBreak) && r.nextState.ballInHand == .anywhere)
        #expect(r.nextState.phase == .inPlay && r.options.isEmpty)
    }

    @Test func nine_reg16_3_accepted_noPushOut() {
        let g = nine.apply(brk(toRail: 5, past: 1), to: nine.newGame()).nextState
        let acc = nine.choose(.acceptTable, in: g).nextState
        #expect(acc.shooter == 1 && acc.phase == .inPlay)
        let r = nine.apply(shot(first: 4, pushOut: true), to: acc)
        #expect(r.fouls.contains(.wrongBallFirst(b(4))))
    }

    @Test func nine_d13_nineOnSoftBreak_wins() {
        let r = nine.apply(brk(pocket: [9: .footLeft], toRail: 1, past: 1), to: nine.newGame())
        #expect(r.winner == 0 && r.endReason == .ninePocketed)
    }

    // MARK: - Team rotation across re-racks (D17, Reg 27(2))

    @Test func bar_2v2_illegalBreakReRack_sameAthlete_thenBreakRotationAdvancesOnce() {
        let e = RulesEngine(ruleSet: .barEight, format: .twoVsTwo)
        var g = e.newGame(breaker: 0)
        let rr = e.apply(brk(toRail: 1), to: g)
        #expect(rr.reRack && rr.nextState.shooter == 0 && rr.nextState.activePlayer == 0)
        g = e.apply(brk(toRail: 5), to: rr.nextState).nextState      // legal dry re-break
        #expect(g.shooter == 1 && g.activePlayer == 0)                // B1
        g = e.nextGame(after: g.with(phase: .over(winner: 0)))
        #expect(g.shooter == 0 && g.activePlayer == 1)                // A2 breaks the next rack
    }

    @Test func bar_2v2_reRackTwice_sameAthleteEachTime() {
        let e = RulesEngine(ruleSet: .barEight, format: .twoVsTwo)
        var g = e.nextGame(after: e.newGame().with(phase: .over(winner: 0)))  // A2 breaks
        for _ in 0..<3 {
            let r = e.apply(brk(toRail: 0), to: g)
            #expect(r.reRack && r.nextState.activePlayer == 1 && r.nextState.shooter == 0)
            g = r.nextState
        }
        #expect(g.nextBreaker[0] == 0)                                // A1 still next to break
    }

    @Test func wpa8_2v2_reBreakByOffender_sameAthlete() {
        let e = RulesEngine(ruleSet: .wpaEight, format: .twoVsTwo)
        let g = e.nextGame(after: e.newGame().with(phase: .over(winner: 0)))   // team 1, B1 breaks
        let r = e.apply(brk(toRail: 1), to: g)
        let rb = e.choose(.reBreakByOffender, in: r.nextState)
        #expect(rb.reRack && rb.nextState.shooter == 1 && rb.nextState.activePlayer == 0)
    }

    @Test
    func wpa8_2v2_reBreakByIncomingTeam_thenStalemate_consistentBreaker() {
        let e = RulesEngine(ruleSet: .wpaEight, format: .twoVsTwo)
        // Rack 1: A1 breaks. Rack 2: B1 breaks. B1's break is illegal; team A chooses to re-break → A2 breaks.
        var g = e.nextGame(after: e.newGame(breaker: 0).with(phase: .over(winner: 0)))
        #expect(g.shooter == 1 && g.activePlayer == 0)
        let r = e.apply(brk(toRail: 1), to: g)
        g = e.choose(.reBreak, in: r.nextState).nextState
        #expect(g.shooter == 0 && g.activePlayer == 1)                // A2 at the table for the re-break
        let s = e.stalemate(g)
        // WPA 4.11: "the original breaker of the rack will break again". Either reading is acceptable —
        // B1 (opening break) or A2 (broke this rack) — but never a mixed team/slot such as B2.
        let who = (s.shooter, s.activePlayer)
        #expect(who == (1, 0) || who == (0, 1), "stalemate breaker was team \(who.0) slot \(who.1)")
    }

    @Test func wpa8_2v2_eightOnLegalBreak_spotAndAccept_sameAthleteContinues() {
        let e = RulesEngine(ruleSet: .wpaEight, format: .twoVsTwo)
        let g = e.nextGame(after: e.newGame().with(phase: .over(winner: 0)))
        let r = e.apply(brk(pocket: [8: .footLeft]), to: g)
        let s = e.choose(.spotEightAndAccept, in: r.nextState).nextState
        #expect(s.shooter == 1 && s.activePlayer == 0)
    }

    @Test func bar_2v2_breakScratch_kitchenBIH_incomingMember_thenBadPlacement_nextMember() {
        let e = RulesEngine(ruleSet: .barEight, format: .twoVsTwo)
        var g = e.apply(brk(pocket: [3: .footLeft, 0: .headLeft]), to: e.newGame()).nextState
        #expect(g.shooter == 1 && g.activePlayer == 0 && g.ballInHand == .behindHeadString)
        g = e.apply(shot(first: 4, startedAbove: false, crossedFirst: true), to: g).nextState
        #expect(g.shooter == 0 && g.activePlayer == 1 && g.ballInHand == .anywhere)
    }

    @Test func nine_2v2_threeBallHandBack_breakingTeamPartnerShoots() {
        let e = RulesEngine(ruleSet: .wpaNine, format: .twoVsTwo)
        let g = e.apply(brk(toRail: 5, past: 1), to: e.newGame()).nextState
        let back = e.choose(.handBack, in: g).nextState
        #expect(back.shooter == 0 && back.activePlayer == 1)
    }

    // MARK: - Ball in hand above the head string after a break scratch

    @Test(arguments: [RuleSetID.barEight, .wpaEight])
    func eight_breakScratch_kitchenBIH_legalPlay_noFoul(_ rs: RuleSetID) {
        let e = RulesEngine(ruleSet: rs)
        let g = e.apply(brk(pocket: [3: .footLeft, 0: .headLeft]), to: e.newGame()).nextState
        #expect(g.shooter == 1 && g.ballInHand == .behindHeadString && g.groups == nil)
        let r = e.apply(shot(first: 10, startedAbove: true, crossedFirst: true), to: g)
        #expect(r.fouls.isEmpty)
    }

    @Test(arguments: [RuleSetID.barEight, .wpaEight])
    func eight_breakScratch_kitchenBIH_placedBelowHeadString_foul(_ rs: RuleSetID) {
        let e = RulesEngine(ruleSet: rs)
        let g = e.apply(brk(pocket: [3: .footLeft, 0: .headLeft]), to: e.newGame()).nextState
        let r = e.apply(shot(first: 10, startedAbove: false), to: g)
        #expect(r.fouls == [.badCueBallPlacement] && r.nextState.shooter == 0)
        #expect(r.nextState.ballInHand == .anywhere)
    }

    @Test(arguments: [RuleSetID.barEight, .wpaEight])
    func eight_breakScratch_kitchenBIH_didNotCross_foul(_ rs: RuleSetID) {
        let e = RulesEngine(ruleSet: rs)
        let g = e.apply(brk(pocket: [3: .footLeft, 0: .headLeft]), to: e.newGame()).nextState
        let r = e.apply(shot(first: 10, startedAbove: true, crossedFirst: false), to: g)
        #expect(r.fouls == [.badPlayFromAboveHeadString])
    }

    @Test(arguments: [RuleSetID.barEight, .wpaEight])
    func eight_breakScratch_kitchenBIH_unobservedPlacement_noFoul(_ rs: RuleSetID) {
        let e = RulesEngine(ruleSet: rs)
        let g = e.apply(brk(pocket: [3: .footLeft, 0: .headLeft]), to: e.newGame()).nextState
        #expect(e.apply(shot(first: 10), to: g).fouls.isEmpty)
    }

    @Test func eight_kitchenFoulPocketingBall_ballStaysDown_tableStaysOpen() {
        let g = bar.apply(brk(pocket: [3: .footLeft, 0: .headLeft]), to: bar.newGame()).nextState
        let r = bar.apply(shot(first: 10, pocket: [10: .footRight], startedAbove: false), to: g)
        #expect(r.nextState.groups == nil && !r.nextState.onTable.contains(b(10)))
    }

    @Test func nine_breakScratch_ballInHandAnywhere_noHeadStringFouls() {
        let g = nine.apply(brk(pocket: [0: .headLeft]), to: nine.newGame()).nextState
        #expect(g.ballInHand == .anywhere)
        let r = nine.apply(shot(first: 1, startedAbove: false, crossedFirst: false), to: g)
        #expect(r.fouls.isEmpty)
    }

    @Test func wpa8_4_3d_illegalBreakWithScratch_noAcceptTable_bihGoesToKitchen() {
        let r = wpa8.apply(brk(pocket: [0: .headLeft], toRail: 2), to: wpa8.newGame())
        guard case .awaitingOption(let p) = r.nextState.phase else { Issue.record("no option"); return }
        #expect(!p.options.contains(.acceptTable) && p.options.contains(.ballInHandAboveHeadString))
        let s = wpa8.choose(.ballInHandAboveHeadString, in: r.nextState).nextState
        #expect(s.shooter == 1 && s.ballInHand == .behindHeadString)
        #expect(wpa8.apply(shot(first: 5, startedAbove: false), to: s).fouls.contains(.badCueBallPlacement))
    }

    @Test func bar_d15_illegalBreakWithScratch_reRackSameBreaker() {
        let r = bar.apply(brk(pocket: [0: .headLeft], toRail: 1), to: bar.newGame())
        #expect(r.reRack && r.nextState.shooter == 0 && r.nextState.ballInHand == .behindHeadString)
    }

    // MARK: - nil observations (Reg 25)

    @Test(arguments: RuleSetID.allCases)
    func reg25_emptyOutcome_everyPlayingPhase_noFoul(_ rs: RuleSetID) {
        let e = RulesEngine(ruleSet: rs)
        for phase in [Phase.open, .inPlay, .pushOutAvailable, .breakShot] {
            let g = e.newGame().with(phase: phase)
            let r = e.apply(ShotOutcome(), to: g)
            #expect(r.fouls.isEmpty && r.winner == nil && !r.reRack, "\(rs) \(phase)")
        }
    }

    @Test(arguments: [RuleSetID.barEight, .wpaEight])
    func reg25_onEight_eightDropsNothingElseObserved_wins(_ rs: RuleSetID) {
        let e = RulesEngine(ruleSet: rs)
        let r = e.apply(ShotOutcome(pocketed: [.eight: .footLeft]), to: onEight(e))
        #expect(r.winner == 0 && r.endReason == .eightPocketed)
    }

    @Test func reg25_bar_breakUnknownRailCount_nothingPocketed_notReRacked() {
        let r = bar.apply(brk(toRail: nil), to: bar.newGame())
        #expect(!r.reRack && r.nextState.shooter == 1)
    }

    @Test func reg25_contradictoryNoContactWithFirstContact_trustsContact() {
        let g = nine.newGame().with(onTable: balls([2, 9]), phase: .inPlay, ballInHand: BallInHand.none)
        let r = nine.apply(shot(first: 2, noContact: true), to: g)
        #expect(r.fouls.isEmpty)
    }

    @Test func reg25_nilRailNothingPocketed_noRailFoulNotInvented() {
        let g = nine.newGame().with(onTable: balls([2, 9]), phase: .inPlay, ballInHand: BallInHand.none)
        #expect(nine.apply(shot(first: 2, rail: nil), to: g).fouls.isEmpty)
    }

    @Test func noContactObserved_foulInEveryRuleSet() {
        for rs in RuleSetID.allCases {
            let e = RulesEngine(ruleSet: rs)
            let g = e.newGame().with(phase: rs == .wpaNine ? .inPlay : .open, ballInHand: BallInHand.none)
            #expect(e.apply(shot(noContact: true), to: g).fouls == [.noContact], "\(rs)")
        }
    }

    // MARK: - Safety and the 8 (WPA 1.7 / 2.16 / 4.6 / 4.8(c))

    @Test
    func wpa8_4_8c_eightDropsOnCalledSafety_loses() {
        let r = wpa8.apply(shot(first: 8, pocket: [8: .footLeft], safety: true), to: onEight(wpa8))
        #expect(r.winner == 1 && r.endReason == .eightNotCalled)
    }

    @Test func wpa8_openTableSafety_pocketedBallStaysDown_tableOpen_turnPasses() {
        let g = wpa8.newGame().with(phase: .open, ballInHand: BallInHand.none)
        let r = wpa8.apply(shot(first: 3, pocket: [3: .sideLeft], safety: true), to: g)
        #expect(r.nextState.groups == nil && !r.nextState.onTable.contains(b(3)) && r.turnPasses)
    }

    @Test func bar_openTableSafety_noGroupAssigned_turnPasses() {
        let g = bar.newGame().with(phase: .open, ballInHand: BallInHand.none)
        let r = bar.apply(shot(first: 3, pocket: [3: .sideLeft], safety: true), to: g)
        #expect(r.nextState.groups == nil && r.turnPasses)
    }

    // MARK: - Losing the rack edge cases

    @Test(arguments: [RuleSetID.barEight, .wpaEight])
    func eightWithLastGroupBall_loses(_ rs: RuleSetID) {
        let e = RulesEngine(ruleSet: rs)
        let g = e.newGame().with(groups: [0: .solids, 1: .stripes], onTable: balls([7, 8, 12]), phase: .inPlay,
                                 ballInHand: BallInHand.none)
        let r = e.apply(shot(first: 7, pocket: [7: .footLeft, 8: .footRight]), to: g)
        #expect(r.winner == 1 && r.endReason == .eightWithLastGroupBall)
    }

    @Test(arguments: [RuleSetID.barEight, .wpaEight])
    func openTable_eightDropsWithScratch_loses(_ rs: RuleSetID) {
        let e = RulesEngine(ruleSet: rs)
        let g = e.newGame().with(phase: .open, ballInHand: BallInHand.none)
        let r = e.apply(shot(first: 3, pocket: [8: .footLeft, 0: .sideLeft]), to: g)
        #expect(r.winner == 1)
    }

    @Test func bar_b9_scratchOnEight_eightMissed_loses() {
        let r = bar.apply(shot(first: 8, pocket: [0: .footLeft]), to: onEight(bar))
        #expect(r.winner == 1 && r.endReason == .scratchOnEight)
    }

    @Test func bar_b10_wrongBallFirstOnEight_foulOnly() {
        let r = bar.apply(shot(first: 9), to: onEight(bar))
        #expect(r.winner == nil && r.nextState.ballInHand == .anywhere && r.nextState.shooter == 1)
    }

    @Test func wpa8_scratchOnEight_eightMissed_foulOnly() {
        let r = wpa8.apply(shot(first: 8, pocket: [0: .footLeft]), to: onEight(wpa8))
        #expect(r.winner == nil && r.nextState.ballInHand == .anywhere)
    }

    @Test func wpa8_lastGroupBallOffTable_staysOut_shooterNowOnEight() {
        let g = wpa8.newGame().with(groups: [0: .solids, 1: .stripes], onTable: balls([7, 8, 12]),
                                    phase: .inPlay, ballInHand: BallInHand.none)
        let r = wpa8.apply(shot(first: 7, off: [7]), to: g)       // WPA 4.7: never spotted
        #expect(!r.nextState.onTable.contains(b(7)) && r.nextState.shooter == 1)
        #expect(wpa8.legalTargets(r.nextState.with(shooter: 0)) == [.eight])
    }

    @Test func bar_b19_lastGroupBallOffTable_spotted_notOnEight() {
        let g = bar.newGame().with(groups: [0: .solids, 1: .stripes], onTable: balls([7, 8, 12]),
                                   phase: .inPlay, ballInHand: BallInHand.none)
        let r = bar.apply(shot(first: 7, off: [7]), to: g)
        #expect(r.spot == [b(7)] && r.nextState.onTable.contains(b(7)) && r.fouls.isEmpty)
    }

    // MARK: - Groups (D11 / D15)

    @Test func bar_d11_breakMadeOnlySolids_tableStillOpen() {
        let r = bar.apply(brk(pocket: [1: .footLeft, 2: .footRight, 3: .sideLeft]), to: bar.newGame())
        #expect(r.nextState.groups == nil && r.nextState.phase == .open && r.nextState.shooter == 0)
    }

    @Test func bar_d15_bothGroupsUnknownOrder_openAndContinue() {
        let g = bar.newGame().with(phase: .open, ballInHand: BallInHand.none)
        let r = bar.apply(shot(first: 3, pocket: [3: .footLeft, 11: .footRight]), to: g)
        #expect(r.nextState.groups == nil && !r.turnPasses)
    }

    @Test func bar_d11_bothGroupsKnownOrder_firstDecides() {
        let g = bar.newGame().with(phase: .open, ballInHand: BallInHand.none)
        let r = bar.apply(shot(first: 3, pocket: [3: .footLeft, 11: .footRight], order: [11, 3]), to: g)
        #expect(r.nextState.groups?[0] == .stripes && !r.turnPasses)
    }

    @Test func bar_b18_foulOnOpenTable_noGroupAssigned() {
        let g = bar.newGame().with(phase: .open, ballInHand: BallInHand.none)
        let r = bar.apply(shot(first: 3, pocket: [3: .footLeft, 0: .sideLeft]), to: g)
        #expect(r.nextState.groups == nil && !r.nextState.onTable.contains(b(3)))
    }

    // MARK: - Three-foul rule scope (WPA 3.13 / 5.8)

    @Test(arguments: [RuleSetID.barEight, .wpaEight])
    func eight_noThreeFoulLoss(_ rs: RuleSetID) {
        let e = RulesEngine(ruleSet: rs)
        var g = e.newGame().with(phase: .open, ballInHand: BallInHand.none)
        for _ in 0..<6 {
            let r = e.apply(shot(first: 8), to: g)   // B17 / 4.4 foul
            #expect(r.winner == nil)
            g = r.nextState
        }
    }

    @Test func nine_threeFouls_legalShotBetweenResets() {
        var g = nine.newGame().with(onTable: balls([3, 4, 9]), phase: .inPlay, ballInHand: BallInHand.none)
        g = nine.apply(shot(first: 4), to: g).nextState                 // A foul 1
        g = nine.apply(shot(first: 3), to: g).nextState                 // B legal
        g = nine.apply(shot(first: 4), to: g).nextState                 // A foul 2
        g = nine.apply(shot(first: 3), to: g).nextState                 // B legal
        g = nine.apply(shot(first: 3), to: g).nextState                 // A legal → resets
        #expect(g.consecutiveFouls[0] == 0)
        g = nine.apply(shot(first: 3), to: g).nextState                 // B legal
        let r = nine.apply(shot(first: 4), to: g)                       // A foul 1 again
        #expect(r.winner == nil && r.nextState.consecutiveFouls[0] == 1)
    }

    @Test func nine_thirdFoulIsAPushOutScratch_loses() {
        var g = afterDryNineBreak(nine).with(fouls: [1: 2])
        let r = nine.apply(shot(first: 5, pocket: [0: .footLeft], pushOut: true), to: g)
        #expect(r.winner == 0 && r.endReason == .threeFouls)
        g = r.nextState
        #expect(g.winner == 0)
    }

    @Test func freshRack_resetsFoulCounts() {
        let g = nine.nextGame(after: nine.newGame().with(phase: .over(winner: 1), fouls: [0: 2, 1: 2]))
        #expect(g.consecutiveFouls.values.allSatisfy { $0 == 0 })
    }

    // MARK: - Applying shots in non-shot phases

    @Test func shotWhileAwaitingOption_isIgnored() {
        let g = nine.apply(brk(toRail: 5, past: 1), to: nine.newGame()).nextState
        let r = nine.apply(shot(first: 1, pocket: [9: .footLeft]), to: g)
        #expect(r.nextState == g && r.winner == nil)
    }

    @Test func shotAfterRackOver_isIgnored() {
        let g = nine.newGame().with(phase: .over(winner: 0))
        #expect(nine.apply(shot(first: 1, pocket: [9: .footLeft]), to: g).nextState == g)
    }
}

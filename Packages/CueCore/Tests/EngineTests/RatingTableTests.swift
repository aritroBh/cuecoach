import Testing
@testable import Engine

// docs/RATING_CLASSES.md (D18): first matching row wins. One test per row and per trigger.

/// A routine pot, best choice, made with position: the baseline every case edits.
func input(_ edit: (inout RatingInput) -> Void = { _ in }) -> RatingInput {
    var i = RatingInput(isBook: false, wpBefore: 0.60, wpAfter: 0.66, loss: 0, lossSE: 0, chosenIsBest: true,
                        onlyMoveGap: 0.04, difficulty: 0.85, bestDifficulty: 0.85, isSafety: false,
                        opponentBestMake: 0.6, shooterBestPotBefore: 0.85, fouled: false, lostRack: false,
                        wonRack: false, executed: true,
                        execution: ExecutionRating(result: .made, position: .inZone),
                        intentConfidence: 1, baselineP: 0.85)
    edit(&i)
    return i
}

private func cls(_ i: RatingInput) -> DecisionRating { Ratings.rate(i).decision }

@Test func row1_book() {
    #expect(cls(input { $0.isBook = true }) == .book)
    #expect(cls(input { $0.isBook = true; $0.lostRack = true; $0.fouled = true }) == .book)   // never rated beyond
}

@Test func row2_blunder_lostRack() { #expect(cls(input { $0.lostRack = true; $0.wpAfter = 0 }) == .blunder) }
@Test func row2_blunder_bigSwing() { #expect(cls(input { $0.wpBefore = 0.7; $0.wpAfter = 0.38 }) == .blunder) }
@Test func row2_blunder_handsOverTheTable() {
    // Opponent ≥ 75% after when the shooter was ≥ 50% before (Swing −0.28, not ≤ −0.30).
    #expect(cls(input { $0.wpBefore = 0.52; $0.wpAfter = 0.24 }) == .blunder)
}

@Test func row3_mistake_foul() {
    #expect(cls(input { $0.fouled = true; $0.executed = false; $0.wpBefore = 0.5; $0.wpAfter = 0.40 }) == .mistake)
}
@Test func row3_mistake_loss() { #expect(cls(input { $0.loss = 0.20; $0.chosenIsBest = false; $0.bestDifficulty = 0.4 }) == .mistake) }
@Test func row3_mistake_swing() { #expect(cls(input { $0.wpBefore = 0.6; $0.wpAfter = 0.42 }) == .mistake) }

@Test func row4_miss() {
    // Easy ball on (best D 0.8); went for something 0.12 worse and made it.
    #expect(cls(input { $0.loss = 0.12; $0.chosenIsBest = false; $0.bestDifficulty = 0.8; $0.difficulty = 0.4 }) == .miss)
}
@Test func row4_miss_needsAnEasyBest() {
    #expect(cls(input { $0.loss = 0.12; $0.chosenIsBest = false; $0.bestDifficulty = 0.5 }) == .inaccuracy)
}

@Test func row5_inaccuracy() {
    #expect(cls(input { $0.loss = 0.10; $0.chosenIsBest = false; $0.bestDifficulty = 0.6 }) == .inaccuracy)
}

@Test func row6_brilliantEligibleShowsGreatLive() {
    let i = input { $0.difficulty = 0.2; $0.baselineP = 0.2; $0.wpBefore = 0.30; $0.wpAfter = 0.70 }
    let r = Ratings.rate(i)
    #expect(r.decision == .great)
    #expect(r.brilliantEligible)
}

@Test func row6_brilliantSafety() {
    // Safety: opponent left ≤ 20%, shooter's best pot before ≤ 40%, Swing ≥ +25.
    let i = input { $0.isSafety = true; $0.difficulty = 0.7; $0.opponentBestMake = 0.1; $0.shooterBestPotBefore = 0.35
                    $0.wpBefore = 0.40; $0.wpAfter = 0.70; $0.execution = ExecutionRating(result: .made, position: .notApplicable) }
    #expect(Ratings.rate(i).brilliantEligible)
    var easyPot = i; easyPot.shooterBestPotBefore = 0.6     // a pot was on: not a brilliant safety
    #expect(!Ratings.rate(easyPot).brilliantEligible)
}

@Test func row6_brilliantDecidingTheRackFromBehind() {
    let i = input { $0.difficulty = 0.25; $0.wpBefore = 0.45; $0.wpAfter = 0.65; $0.wonRack = true }
    #expect(Ratings.rate(i).brilliantEligible)                 // Swing only +0.20 but decides the rack from ≤ 50%
}

@Test func row6_brilliantNeedsLowLossAndExecution() {
    let base = input { $0.difficulty = 0.2; $0.wpBefore = 0.30; $0.wpAfter = 0.70 }
    #expect(!Ratings.rate(input { $0 = base; $0.loss = 0.025; $0.chosenIsBest = false }).brilliantEligible)
    #expect(!Ratings.rate(input { $0 = base; $0.executed = false }).brilliantEligible)
    #expect(!Ratings.rate(input { $0 = base; $0.intentConfidence = 0.5 }).brilliantEligible)
}

@Test func row7_great_hardShot() { #expect(cls(input { $0.difficulty = 0.45 }) == .great) }
@Test func row7_great_onlyMove() { #expect(cls(input { $0.onlyMoveGap = 0.2 }) == .great) }
@Test func row7_great_strongResult() { #expect(cls(input { $0.wpBefore = 0.5; $0.wpAfter = 0.67 }) == .great) }
@Test func row7_great_toleratesSmallLoss() {
    #expect(cls(input { $0.difficulty = 0.45; $0.loss = 0.025; $0.chosenIsBest = false }) == .great)
}
@Test func row7_great_needsConfidentIntent() {
    // RATINGS §5: same shot with intentConfidence 0.55 → Best (no promotion).
    #expect(cls(input { $0.onlyMoveGap = 0.2; $0.intentConfidence = 0.55 }) == .best)
}

@Test func row8_best() { #expect(cls(input()) == .best) }

@Test func row9_good() { #expect(cls(input { $0.loss = 0.04; $0.chosenIsBest = false }) == .good) }

@Test func row10_okay_loss() { #expect(cls(input { $0.loss = 0.06; $0.chosenIsBest = false }) == .okay) }
@Test func row10_okay_madeButMissedPosition() {
    #expect(cls(input { $0.execution = ExecutionRating(result: .made, position: .outOfZone) }) == .okay)
}
@Test func row10_okay_soundChoiceMissed() {
    #expect(cls(input { $0.executed = false; $0.execution = ExecutionRating(result: .miss, position: .notApplicable)
                        $0.wpAfter = 0.52 }) == .okay)
}

@Test func lossInsideNoiseIsTreatedAsZero() {
    // RATINGS §2.2: L := 0 when L < 1.645·SE (benefit of the doubt).
    #expect(cls(input { $0.loss = 0.04; $0.lossSE = 0.03; $0.chosenIsBest = false }) == .best)
}

@Test func negativeRowsBeatSpecialRows() {
    // Hard shot made, but a foul: Mistake, never Great.
    #expect(cls(input { $0.difficulty = 0.2; $0.fouled = true; $0.wpAfter = 0.55 }) == .mistake)
}

// MARK: - Brilliant post-game: at most one, and only the Shot of the Game (D18 criterion 1)

private func record(_ i: RatingInput) -> ShotRatingRecord { ShotRatingRecord(input: i, rating: Ratings.rate(i)) }

@Test func brilliant_isTheSingleTopShotOfTheGame() {
    let eligibleA = input { $0.difficulty = 0.2; $0.baselineP = 0.2; $0.wpBefore = 0.30; $0.wpAfter = 0.70 }
    let eligibleB = input { $0.difficulty = 0.1; $0.baselineP = 0.1; $0.wpBefore = 0.20; $0.wpAfter = 0.75 }
    let game = [record(input()), record(eligibleA), record(eligibleB), record(input { $0.isBook = true })]
    #expect(Ratings.selectBrilliant(game) == 2)
    let final = Ratings.finalize(game)
    #expect(final.filter { $0 == .brilliant }.count == 1)
    #expect(final[2] == .brilliant)
    #expect(final[1] == .great)                                 // the other qualifier stays Great
}

@Test func brilliant_noneWhenTheShotOfTheGameDoesNotQualify() {
    // Top SotG is a missed-pot swing (not eligible); an eligible shot with a smaller score is not promoted.
    let eligible = input { $0.difficulty = 0.25; $0.baselineP = 0.5; $0.wpBefore = 0.40; $0.wpAfter = 0.66 }
    let bigBlunder = input { $0.lostRack = true; $0.wpBefore = 0.9; $0.wpAfter = 0; $0.baselineP = 0.1 }
    let game = [record(eligible), record(bigBlunder)]
    #expect(Ratings.selectBrilliant(game) == nil)
    #expect(!Ratings.finalize(game).contains(.brilliant))
}

@Test func brilliant_breaksAreNeverShotOfTheGame() {
    let breakShot = input { $0.isBook = true; $0.wpBefore = 0.5; $0.wpAfter = 0.95; $0.baselineP = 0 }
    let eligible = input { $0.difficulty = 0.2; $0.baselineP = 0.2; $0.wpBefore = 0.30; $0.wpAfter = 0.70 }
    #expect(Ratings.selectBrilliant([record(breakShot), record(eligible)]) == 1)
}

@Test func sotgScore_followsSpec9() {
    // SPEC §9: |swing| × (1 − baseline P), bonus for the game winner.
    let i = input { $0.wpBefore = 0.4; $0.wpAfter = 0.8; $0.baselineP = 0.25 }
    #expect(abs(Ratings.sotgScore(i) - 0.4 * 0.75) < 1e-12)
    var w = i; w.wonRack = true
    #expect(Ratings.sotgScore(w) > Ratings.sotgScore(i))
}

@Test func brilliant_atMostOncePerGame_property() {
    // 300 seeded random games of 40 shots: never more than one Brilliant, and only on an eligible shot.
    let rng = EngineRNG(seed: 77)
    var k = 0
    func u() -> Double { k += 1; return (rng.normals(state: 1, stream: 9, sample: 2 * k).x / 6 + 0.5).clamped }
    for _ in 0..<300 {
        var game: [ShotRatingRecord] = []
        for _ in 0..<40 {
            let i = input { $0.isBook = u() < 0.05; $0.wpBefore = u(); $0.wpAfter = u(); $0.difficulty = u()
                            $0.baselineP = u(); $0.wonRack = u() > 0.95; $0.isSafety = u() > 0.8
                            $0.opponentBestMake = u(); $0.shooterBestPotBefore = u() }
            game.append(record(i))
        }
        let final = Ratings.finalize(game)
        let idx = final.indices.filter { final[$0] == .brilliant }
        #expect(idx.count <= 1)
        for j in idx { #expect(game[j].rating.brilliantEligible) }
    }
}

private extension Double { var clamped: Double { Swift.min(1, Swift.max(0, self)) } }

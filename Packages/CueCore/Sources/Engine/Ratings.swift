import Foundation

/// Every number in docs/RATING_CLASSES.md (D18) and RATINGS.md §4, in win-probability units (0–1).
/// Starting points; calibrated on the 20 reference positions. Never shown to players.
public struct RatingThresholds: Hashable, Codable, Sendable {
    public var version = 1
    public var bestLoss = 0.02
    public var goodLoss = 0.05
    public var okayLoss = 0.08
    public var inaccuracyLoss = 0.08
    public var mistakeLoss = 0.15
    public var mistakeSwing = -0.15
    public var blunderSwing = -0.30
    /// Blunder "hands the table over": opponent ≥ 75% after when the shooter was ≥ 50% before.
    public var handOverOpponentAfter = 0.75
    public var handOverShooterBefore = 0.50
    public var missBestDifficulty = 0.70
    public var missLoss = 0.10
    public var greatLoss = 0.03
    public var greatDifficulty = 0.50
    public var greatOnlyMoveGap = 0.10
    public var greatSwing = 0.15
    public var brilliantLoss = 0.02
    public var brilliantPotDifficulty = 0.30
    public var brilliantSafetyOpponent = 0.20
    public var brilliantSafetyShooterBestPot = 0.40
    public var brilliantSwing = 0.25
    public var brilliantDecidesFromWP = 0.50
    /// κ: minimum intent confidence for a promotion (RATINGS §2.1).
    public var intentConfidence = 0.7
    /// z for "L := 0 when L < z·SE" (RATINGS §2.2).
    public var lossZ = 1.645
    /// SPEC §9 game-winner bonus on the Shot-of-the-Game score (placeholder).
    public var sotgWinnerBonus = 0.25
    public init() {}
    public static let `default` = RatingThresholds()
}

/// Everything the pure classifier needs (RATINGS §11 `RatingInput`, trimmed to what D18 reads).
public struct RatingInput: Hashable, Codable, Sendable {
    public var isBook: Bool
    /// Shooter's team WP before (W₀) and after (W₁) the shot.
    public var wpBefore: Double
    public var wpAfter: Double
    /// EV(best) − EV(chosen) on paired CRN samples, and its SE.
    public var loss: Double
    public var lossSE: Double
    public var chosenIsBest: Bool
    /// Only-move gap G = EV(best) − EV(second best).
    public var onlyMoveGap: Double
    /// This player's P(intended outcome) for the chosen shot, and for the best one.
    public var difficulty: Double
    public var bestDifficulty: Double
    /// Defensive intent (safety, hit-kick, deliberate miss).
    public var isSafety: Bool
    /// Rₒ: opponent's best make chance after the actual result.
    public var opponentBestMake: Double
    /// Shooter's best pot P(make) before the shot.
    public var shooterBestPotBefore: Double
    public var fouled: Bool
    public var lostRack: Bool
    public var wonRack: Bool
    /// The intended outcome happened (D18 "successfully executed").
    public var executed: Bool
    public var execution: ExecutionRating
    public var intentConfidence: Double
    /// Reference-skill P(make), for the Shot-of-the-Game weight.
    public var baselineP: Double

    public init(isBook: Bool, wpBefore: Double, wpAfter: Double, loss: Double, lossSE: Double, chosenIsBest: Bool,
                onlyMoveGap: Double, difficulty: Double, bestDifficulty: Double, isSafety: Bool,
                opponentBestMake: Double, shooterBestPotBefore: Double, fouled: Bool, lostRack: Bool, wonRack: Bool,
                executed: Bool, execution: ExecutionRating, intentConfidence: Double, baselineP: Double) {
        self.isBook = isBook
        self.wpBefore = wpBefore
        self.wpAfter = wpAfter
        self.loss = loss
        self.lossSE = lossSE
        self.chosenIsBest = chosenIsBest
        self.onlyMoveGap = onlyMoveGap
        self.difficulty = difficulty
        self.bestDifficulty = bestDifficulty
        self.isSafety = isSafety
        self.opponentBestMake = opponentBestMake
        self.shooterBestPotBefore = shooterBestPotBefore
        self.fouled = fouled
        self.lostRack = lostRack
        self.wonRack = wonRack
        self.executed = executed
        self.execution = execution
        self.intentConfidence = intentConfidence
        self.baselineP = baselineP
    }

    public var swing: Double { wpAfter - wpBefore }
}

public struct ShotRating: Hashable, Codable, Sendable {
    /// Live class. A Brilliant candidate shows as `.great` until `Ratings.finalize` (D18).
    public var decision: DecisionRating
    public var execution: ExecutionRating
    /// Meets Brilliant criteria 2–5; becomes Brilliant post-game only if it is the Shot of the Game.
    public var brilliantEligible: Bool
    public var sotgScore: Double
}

/// One rated shot, as stored for the post-game pass.
public struct ShotRatingRecord: Hashable, Codable, Sendable {
    public var input: RatingInput
    public var rating: ShotRating
    public init(input: RatingInput, rating: ShotRating) {
        self.input = input
        self.rating = rating
    }
}

/// Pure, synchronous classifier (D18 table, first matching row wins).
public enum Ratings {
    /// Loss with the benefit of the doubt: 0 when it is inside the paired-sample noise (RATINGS §2.2).
    public static func effectiveLoss(_ i: RatingInput, _ t: RatingThresholds = .default) -> Double {
        i.chosenIsBest || i.loss < t.lossZ * i.lossSE ? 0 : max(0, i.loss)
    }

    /// SPEC §9: |WPA swing| × (1 − baseline P(make)), plus a bonus for the game-winning shot. Book shots score 0.
    public static func sotgScore(_ i: RatingInput, _ t: RatingThresholds = .default) -> Double {
        guard !i.isBook else { return 0 }
        return abs(i.swing) * (1 - min(1, max(0, i.baselineP))) + (i.wonRack ? t.sotgWinnerBonus : 0)
    }

    static func promotable(_ i: RatingInput, _ t: RatingThresholds) -> Bool {
        i.executed && i.intentConfidence >= t.intentConfidence
    }

    /// Brilliant criteria 2–5 plus "successfully executed" (D18).
    public static func brilliantEligible(_ i: RatingInput, _ t: RatingThresholds = .default) -> Bool {
        guard !i.isBook, promotable(i, t), effectiveLoss(i, t) <= t.brilliantLoss else { return false }
        let hard = i.isSafety
            ? i.opponentBestMake <= t.brilliantSafetyOpponent && i.shooterBestPotBefore <= t.brilliantSafetyShooterBestPot
            : i.difficulty <= t.brilliantPotDifficulty
        let changed = i.swing >= t.brilliantSwing || (i.wonRack && i.wpBefore <= t.brilliantDecidesFromWP)
        return hard && changed
    }

    public static func rate(_ i: RatingInput, _ t: RatingThresholds = .default) -> ShotRating {
        let sotg = sotgScore(i, t)
        func out(_ d: DecisionRating, eligible: Bool = false) -> ShotRating {
            ShotRating(decision: d, execution: i.execution, brilliantEligible: eligible, sotgScore: sotg)
        }
        let loss = effectiveLoss(i, t)
        let swing = i.swing
        // 1 Book
        if i.isBook { return out(.book) }
        // 2 Blunder
        if i.lostRack || swing <= t.blunderSwing
            || (i.wpBefore >= t.handOverShooterBefore && 1 - i.wpAfter >= t.handOverOpponentAfter) {
            return out(.blunder)
        }
        // 3 Mistake
        if i.fouled || loss >= t.mistakeLoss || swing <= t.mistakeSwing { return out(.mistake) }
        // 4 Miss (missed chance by choice)
        if !i.chosenIsBest && i.bestDifficulty >= t.missBestDifficulty && loss >= t.missLoss { return out(.miss) }
        // 5 Inaccuracy
        if loss >= t.inaccuracyLoss { return out(.inaccuracy) }
        // 6 Brilliant: decided post-game; live it shows as Great.
        if brilliantEligible(i, t) { return out(.great, eligible: true) }
        // 7 Great
        if promotable(i, t) && loss <= t.greatLoss
            && (i.difficulty <= t.greatDifficulty || (i.chosenIsBest && i.onlyMoveGap >= t.greatOnlyMoveGap)
                || swing >= t.greatSwing) {
            return out(.great)
        }
        // 8 Best / 10 Okay (sound choice executed below its intent)
        if loss <= t.bestLoss {
            let fully = i.executed && i.execution.position != .outOfZone
            return out(fully ? .best : .okay)
        }
        // 9 Good, 10 Okay
        return out(loss <= t.goodLoss ? .good : .okay)
    }

    /// Post-game (D18): the Shot of the Game — highest SotG score over non-Book shots, earliest on ties — is
    /// Brilliant if it meets criteria 2–5. At most one per game; possibly none.
    public static func selectBrilliant(_ game: [ShotRatingRecord], _ t: RatingThresholds = .default) -> Int? {
        var top: Int?
        for (k, r) in game.enumerated() where !r.input.isBook {
            if top == nil || r.rating.sotgScore > game[top!].rating.sotgScore { top = k }
        }
        guard let top, game[top].rating.brilliantEligible, game[top].rating.decision == .great else { return nil }
        return top
    }

    /// Final classes for the game review: the live classes with the Brilliant upgrade applied.
    public static func finalize(_ game: [ShotRatingRecord], _ t: RatingThresholds = .default) -> [DecisionRating] {
        var d = game.map(\.rating.decision)
        if let b = selectBrilliant(game, t) { d[b] = .brilliant }
        return d
    }
}

import Foundation

public enum BiasDirection: String, Codable, Sendable, CaseIterable, Hashable {
    case positive, negative
    public var opposite: BiasDirection { self == .positive ? .negative : .positive }
}

public struct BiasKey: Hashable, Codable, Sendable {
    public var axis: BiasAxis
    public var direction: BiasDirection
    public init(axis: BiasAxis, direction: BiasDirection) { self.axis = axis; self.direction = direction }
}

/// A tendency the detector is confident about.
public struct DetectedBias: Equatable, Sendable {
    public var key: BiasKey
    /// CUSUM statistic / threshold; ≥ 1 when active, ≤ cap / threshold.
    public var evidence: Double
    /// Mean signed error over the current run, in the caller's units. For drawing the
    /// player's average line only; never shown as a number.
    public var meanError: Double
    /// Signed (non-neutral) attempts in the current run.
    public var attempts: Int
}

/// Detects a consistent same-sign bias per axis with a one-sided **sign CUSUM** in each direction
/// (Page's CUSUM on the sign log-likelihood ratio, H0: P(+)=½ vs H1: P(+)=`alternativeP`).
///
/// Why signs: scale-free (works in degrees, m/s or "pocket widths" alike) and robust to the
/// outliers tracking produces. Errors with |e| < `deadZone` are neutral (not actionable).
/// Fires only when the statistic ≥ `threshold` **and** the run holds ≥ `minimumAttempts`
/// signed attempts (SPEC §10: "same-sign bias over ≥8 attempts"). The statistic is capped at
/// `cap` so a long habit can be unlearned in a handful of corrected attempts.
public struct BiasDetector: Equatable, Sendable, Codable {
    public struct Config: Equatable, Sendable, Codable {
        public var deadZone: Double
        public var alternativeP: Double
        public var threshold: Double
        public var cap: Double
        public var minimumAttempts: Int

        /// Tuned on synthetic N(0,1) noise with deadZone 0.25 (unit = one noise σ): per axis &
        /// direction ≈1% false alarms per 100 attempts; ≥98% detection of a 1σ bias in 60.
        public static let standard = Config(deadZone: 0.25, alternativeP: 0.75, threshold: 7,
                                            cap: 10.5, minimumAttempts: 8)

        public init(deadZone: Double, alternativeP: Double, threshold: Double, cap: Double, minimumAttempts: Int) {
            precondition(alternativeP > 0.5 && alternativeP < 1, "alternativeP must be in (0.5, 1)")
            precondition(threshold > 0 && cap >= threshold && deadZone >= 0 && minimumAttempts >= 1)
            self.deadZone = deadZone; self.alternativeP = alternativeP
            self.threshold = threshold; self.cap = cap; self.minimumAttempts = minimumAttempts
        }

        /// Same test in different error units (only the dead zone has units).
        public func scaled(by k: Double) -> Config {
            Config(deadZone: deadZone * k, alternativeP: alternativeP, threshold: threshold,
                   cap: cap, minimumAttempts: minimumAttempts)
        }

        var agreeStep: Double { log(alternativeP / 0.5) }
        var disagreeStep: Double { log((1 - alternativeP) / 0.5) }
    }

    struct Run: Equatable, Sendable, Codable {
        var statistic = 0.0
        var attempts = 0
        var errorSum = 0.0
    }

    public let config: Config
    private var runs: [BiasKey: Run] = [:]

    public init(config: Config = .standard) { self.config = config }

    public mutating func observe(_ axis: BiasAxis, error e: Double) {
        guard e.isFinite, abs(e) >= config.deadZone, e != 0 else { return }
        for dir in BiasDirection.allCases {
            let key = BiasKey(axis: axis, direction: dir)
            var r = runs[key] ?? Run()
            let agrees = (e > 0) == (dir == .positive)
            r.statistic = min(config.cap, max(0, r.statistic + (agrees ? config.agreeStep : config.disagreeStep)))
            if r.statistic == 0 { r = Run() } else { r.attempts += 1; r.errorSum += e }
            runs[key] = r
        }
    }

    public func statistic(_ axis: BiasAxis, _ direction: BiasDirection) -> Double {
        runs[BiasKey(axis: axis, direction: direction)]?.statistic ?? 0
    }

    /// Active biases, strongest evidence first (ties: larger |mean error|, then axis order).
    public func activeBiases() -> [DetectedBias] {
        runs.compactMap { key, r -> DetectedBias? in
            guard r.statistic >= config.threshold, r.attempts >= config.minimumAttempts else { return nil }
            return DetectedBias(key: key, evidence: r.statistic / config.threshold,
                                meanError: r.errorSum / Double(r.attempts), attempts: r.attempts)
        }.sorted { a, b in
            if a.evidence != b.evidence { return a.evidence > b.evidence }
            if abs(a.meanError) != abs(b.meanError) { return abs(a.meanError) > abs(b.meanError) }
            let order = BiasAxis.allCases
            return order.firstIndex(of: a.key.axis)! < order.firstIndex(of: b.key.axis)!
        }
    }

    /// Clears an axis, e.g. after its correction has been shown.
    public mutating func reset(_ axis: BiasAxis) {
        for dir in BiasDirection.allCases { runs[BiasKey(axis: axis, direction: dir)] = nil }
    }
}

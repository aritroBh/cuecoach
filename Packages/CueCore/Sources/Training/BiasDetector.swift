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
    /// Mean of the run's errors **in the detected direction**, in the axis unit, so its sign always
    /// matches `key.direction` (opposing outliers can't flip the drawn line). For drawing the
    /// player's average line only; never shown as a number.
    public var meanError: Double
    /// Signed (non-neutral) attempts in the current run.
    public var attempts: Int
    /// Share of those attempts in the detected direction (0…1].
    public var consistency: Double
}

/// Detects a consistent same-sign bias per axis with a one-sided **sign CUSUM** in each direction
/// (Page's CUSUM on the sign log-likelihood ratio, H0: P(+)=½ vs H1: P(+)=`alternativeP`).
///
/// Why signs: scale-free (works in degrees, m/s or "pocket widths" alike) and robust to the
/// outliers tracking produces. Errors with |e| < `deadZone` are on target: they are not evidence
/// *for* a bias, but they pull both statistics down by half a disagreeing step, so a player who
/// fixes a habit by hitting precisely clears it. Each axis has its own config (units differ).
/// Fires only when the statistic ≥ `threshold` **and** the run holds ≥ `minimumAttempts`
/// signed attempts (SPEC §10: "same-sign bias over ≥8 attempts"). The statistic is capped at
/// `cap` so a long habit can be unlearned in a handful of corrected attempts.
public struct BiasDetector: Equatable, Sendable, Codable {
    public struct Config: Equatable, Sendable, Codable {
        private enum CodingKeys: String, CodingKey { case deadZone, alternativeP, threshold, cap, minimumAttempts }
        public var deadZone: Double
        public var alternativeP: Double
        public var threshold: Double
        public var cap: Double
        public var minimumAttempts: Int

        /// Tuned on synthetic N(0,1) noise with deadZone 0.25 (unit = one noise σ), with dead-zone
        /// decay on: per axis & direction ≈0.25% false alarms per 100 attempts; ≈99% detection of a
        /// 1σ bias in 60 (median 25). From the cap, ~5 opposite or ~9 precise attempts clear it.
        public static let standard = Config(deadZone: 0.25, alternativeP: 0.75, threshold: 5.5,
                                            cap: 8.5, minimumAttempts: 8)

        /// `standard` scaled to each axis' unit via `BiasAxis.typicalNoise`.
        public static let calibrated: [BiasAxis: Config] = Dictionary(uniqueKeysWithValues:
            BiasAxis.allCases.map { ($0, standard.scaled(by: $0.typicalNoise)) })

        public init(deadZone: Double, alternativeP: Double, threshold: Double, cap: Double, minimumAttempts: Int) {
            precondition(Self.isValid(deadZone: deadZone, alternativeP: alternativeP, threshold: threshold,
                                      cap: cap, minimumAttempts: minimumAttempts), "invalid BiasDetector.Config")
            self.deadZone = deadZone; self.alternativeP = alternativeP
            self.threshold = threshold; self.cap = cap; self.minimumAttempts = minimumAttempts
        }

        /// Decoding validates like `init`, so stored data can't produce a detector that never fires.
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let dz = try c.decode(Double.self, forKey: .deadZone), p = try c.decode(Double.self, forKey: .alternativeP)
            let t = try c.decode(Double.self, forKey: .threshold), cap = try c.decode(Double.self, forKey: .cap)
            let m = try c.decode(Int.self, forKey: .minimumAttempts)
            guard Self.isValid(deadZone: dz, alternativeP: p, threshold: t, cap: cap, minimumAttempts: m) else {
                throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath,
                                                        debugDescription: "invalid BiasDetector.Config"))
            }
            self.init(deadZone: dz, alternativeP: p, threshold: t, cap: cap, minimumAttempts: m)
        }

        static func isValid(deadZone: Double, alternativeP: Double, threshold: Double, cap: Double,
                            minimumAttempts: Int) -> Bool {
            alternativeP > 0.5 && alternativeP < 1 && threshold > 0 && threshold.isFinite
                && cap >= threshold && cap.isFinite && deadZone >= 0 && deadZone.isFinite && minimumAttempts >= 1
        }

        /// Same test in different error units (only the dead zone has units).
        public func scaled(by k: Double) -> Config {
            Config(deadZone: deadZone * k, alternativeP: alternativeP, threshold: threshold,
                   cap: cap, minimumAttempts: minimumAttempts)
        }

        var agreeStep: Double { log(alternativeP / 0.5) }
        var disagreeStep: Double { log((1 - alternativeP) / 0.5) }
        var neutralStep: Double { disagreeStep / 2 }
    }

    struct Run: Equatable, Sendable, Codable {
        var statistic = 0.0
        var attempts = 0          // signed attempts in the run
        var agreeCount = 0
        var agreeSum = 0.0        // errors in this run's direction only
    }

    private let configs: [BiasAxis: Config]
    private var runs: [BiasKey: Run] = [:]

    /// One config for every axis (errors already in a common unit, e.g. σ).
    public init(config: Config = .standard) {
        self.configs = Dictionary(uniqueKeysWithValues: BiasAxis.allCases.map { ($0, config) })
    }
    /// A config per axis; must cover every axis.
    public init(configs: [BiasAxis: Config]) {
        precondition(Set(configs.keys) == Set(BiasAxis.allCases), "configs must cover every BiasAxis")
        self.configs = configs
    }

    public func config(for axis: BiasAxis) -> Config { configs[axis]! }

    public mutating func observe(_ axis: BiasAxis, error e: Double) {
        guard e.isFinite else { return }
        let config = config(for: axis)
        let neutral = abs(e) < config.deadZone || e == 0
        for dir in BiasDirection.allCases {
            let key = BiasKey(axis: axis, direction: dir)
            var r = runs[key] ?? Run()
            let agrees = !neutral && (e > 0) == (dir == .positive)
            let step = neutral ? config.neutralStep : (agrees ? config.agreeStep : config.disagreeStep)
            r.statistic = min(config.cap, max(0, r.statistic + step))
            if r.statistic == 0 {
                r = Run()
            } else if !neutral {
                r.attempts += 1
                if agrees { r.agreeCount += 1; r.agreeSum += e }
            }
            runs[key] = r
        }
    }

    public func statistic(_ axis: BiasAxis, _ direction: BiasDirection) -> Double {
        runs[BiasKey(axis: axis, direction: direction)]?.statistic ?? 0
    }

    /// Active biases, strongest evidence first (ties: more consistent, larger |mean error|, axis order).
    public func activeBiases() -> [DetectedBias] {
        runs.compactMap { key, r -> DetectedBias? in
            let config = config(for: key.axis)
            guard r.statistic >= config.threshold, r.attempts >= config.minimumAttempts, r.agreeCount > 0
            else { return nil }
            return DetectedBias(key: key, evidence: r.statistic / config.threshold,
                                meanError: r.agreeSum / Double(r.agreeCount), attempts: r.attempts,
                                consistency: Double(r.agreeCount) / Double(r.attempts))
        }.sorted { a, b in
            if a.evidence != b.evidence { return a.evidence > b.evidence }
            if a.consistency != b.consistency { return a.consistency > b.consistency }
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

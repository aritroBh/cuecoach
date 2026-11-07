import Foundation
import Geometry
import Physics
import Rules

/// Search budget (engine.md §6.2, §9.2). Sim counts, not wall time; re-set after the device benchmark.
public struct EngineBudget: Hashable, Codable, Sendable {
    /// Offensive arms entering Monte Carlo.
    public var topK: Int
    /// Defensive arms (safeties, hit-kicks).
    public var safeties: Int
    /// Push-out arms (only in `.pushOutAvailable`).
    public var pushOuts: Int
    /// Samples per arm in Sequential-Halving round 0 (even; antithetic pairs). Doubles every round.
    public var initialSamples: Int
    /// Sequential-Halving rounds.
    public var rounds: Int
    /// Samples per parallel work item.
    public var chunk: Int
    /// Concurrent work items in flight (results never depend on it).
    public var maxParallel: Int
    /// Rating top-up: the chosen arm is extended to at least this many paired samples.
    public var ratingSamples: Int

    public init(topK: Int = 12, safeties: Int = 4, pushOuts: Int = 4, initialSamples: Int = 16, rounds: Int = 4,
                chunk: Int = 8, maxParallel: Int = ProcessInfo.processInfo.activeProcessorCount,
                ratingSamples: Int = 64) {
        self.topK = topK
        self.safeties = safeties
        self.pushOuts = pushOuts
        self.initialSamples = max(2, initialSamples + initialSamples % 2)
        self.rounds = max(1, rounds)
        self.chunk = max(2, chunk + chunk % 2)
        self.maxParallel = max(1, maxParallel)
        self.ratingSamples = ratingSamples
    }

    /// engine.md §6.2: 12 + 4 arms, 16 → 128 samples per surviving arm.
    public static let standard = EngineBudget()
}

/// Deterministic work counters (no wall time, so `Evaluation` stays bit-identical across runs).
public struct EngineStats: Hashable, Codable, Sendable {
    public var candidates = 0
    public var arms = 0
    public var sims = 0
    public init() {}
}

/// One scored candidate. EVs are in win-probability units for the shooter's team (RATINGS §2).
public struct CandidateScore: Hashable, Codable, Sendable {
    /// The candidate with its throw-corrected stroke.
    public var candidate: Candidate
    /// Analytic P(intended outcome) for the shooter (pots: P(make); defence: P(legal hit)).
    public var pMakeAnalytic: Double
    /// Same with the reference skill (RATINGS UD-8 baseline; Shot-of-the-Game weight).
    public var pBaseline: Double
    /// Monte Carlo share of samples where the intended outcome happened.
    public var pIntended: Double
    public var ev: Double
    public var evSE: Double
    /// E[W | intended outcome] and E[W | not] (RATINGS B4 two-way test). nil when no such samples.
    public var evMake: Double?
    public var evMiss: Double?
    /// Best sampled W among intended pots where the shooter stays at the table (position zone v̂).
    public var bestLeaf: Double?
    /// Monte Carlo samples (0 = scored by the Quick tier only; `ev` is then the Quick estimate).
    public var samples: Int
    public var quickScore: Double
}

public struct Evaluation: Hashable, Codable, Sendable {
    public enum Tier: String, Codable, Sendable { case quick, full }
    public var tier: Tier
    /// Hash of the quantised (0.5 mm) state + game state; seeds the CRN streams.
    public var stateHash: UInt64
    /// The quantised state the engine actually searched.
    public var state: TableState
    public var game: GameState
    public var shooter: Int
    public var skill: SkillModel
    public var opponentSkill: SkillModel
    /// Analytic WP of the shooter's team before the shot (`ShotEngine.winProbability`; W₀).
    public var winProbability: Double
    /// Best first; Monte Carlo arms ahead of Quick-only candidates.
    public var ranked: [CandidateScore]
    /// Only-move gap G = EV(best) − EV(second).
    public var secondBestGap: Double
    /// Shooter's best pot P(make) before the shot (D18 Brilliant safety rule).
    public var shooterBestPot: Double
    /// Rank-1 candidate of the naive "highest P(make), ignore the leave" policy (RATINGS §3.2).
    public var naivePick: UInt32?
    /// Per-sample W by candidate id (host-local; used for paired loss SE in `rate`).
    public var paired: [UInt32: [Double]]
    public var stats: EngineStats

    public var best: CandidateScore? { ranked.first }
    public func score(_ id: UInt32) -> CandidateScore? { ranked.first { $0.candidate.id == id } }
}

import Foundation
import Geometry
import Physics
import Rules

/// "Stockfish for pool" (SPEC §5.5). The actor holds configuration only; searches run in task-group
/// children off the actor and are deterministic for a given seed, state and budget.
public actor ShotEngine {
    public let seed: UInt64
    public let simulator: Simulator
    public let budget: EngineBudget
    /// Skill assumed when a caller gives none (new players, engine.md UD-E10).
    public let defaultSkill: SkillModel
    public let threeBallRule: Bool

    public init(seed: UInt64 = 0, simulator: Simulator = Simulator(), budget: EngineBudget = .standard,
                defaultSkill: SkillModel = .reference, threeBallRule: Bool = true) {
        self.seed = seed
        self.simulator = simulator
        self.budget = budget
        self.defaultSkill = defaultSkill
        self.threeBallRule = threeBallRule
    }

    nonisolated func rules(for g: GameState) -> RulesEngine {
        RulesEngine(ruleSet: g.ruleSet, teams: max(2, g.teams), playersPerTeam: max(1, g.lineups.first?.count ?? 1),
                    threeBallRule: threeBallRule)
    }

    /// Pure, synchronous candidate list (geometry only), at the default skill.
    public nonisolated func candidates(_ s: TableState, _ g: GameState) -> [Candidate] {
        candidates(s, g, skill: defaultSkill)
    }

    /// The candidate list `evaluate(_:_:skill:)` searches for this skill (same ids, same order).
    public nonisolated func candidates(_ s: TableState, _ g: GameState, skill: SkillModel) -> [Candidate] {
        CandidateGenerator(rules: rules(for: g), skill: skill).generate(Evaluator.quantised(s), g)
    }

    public func evaluate(_ s: TableState, _ g: GameState, skill: SkillModel) async -> Evaluation {
        await evaluate(s, g, skill: skill, opponentSkill: defaultSkill, budget: budget)
    }

    public func evaluate(_ s: TableState, _ g: GameState, skill: SkillModel, opponentSkill: SkillModel,
                         budget: EngineBudget? = nil) async -> Evaluation {
        let ev = Evaluator(simulator: simulator, rules: rules(for: g), seed: seed, budget: budget ?? self.budget,
                           skill: skill, opponentSkill: opponentSkill, state: s, game: g)
        return await Self.run(ev)
    }

    @concurrent nonisolated static func run(_ e: Evaluator) async -> Evaluation { await e.run() }

    /// Analytic win probability of the shooter's team (eval bar; W₀/W₁ for ratings).
    public nonisolated func winProbability(_ s: TableState, _ g: GameState) -> Double {
        winProbability(s, g, skill: defaultSkill, opponentSkill: defaultSkill)
    }

    public nonisolated func winProbability(_ s: TableState, _ g: GameState, skill: SkillModel,
                                           opponentSkill: SkillModel) -> Double {
        var skills = [opponentSkill, opponentSkill]
        skills[min(1, max(0, g.shooter))] = skill
        return WinModel(rules: rules(for: g), skills: skills).shooterWP(Evaluator.quantised(s), g)
    }
}

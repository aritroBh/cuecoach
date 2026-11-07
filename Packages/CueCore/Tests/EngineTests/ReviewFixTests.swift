import Foundation
import Testing
import Geometry
import Physics
import Rules
@testable import Engine

// Regression tests for the supervisor's round-1 findings on the engine module.

private func play(_ c: Candidate, on s: TableState) -> ShotTrace {
    var start = s
    if let q = c.cuePlacement { start.balls[.cue] = BallState(position: q) }
    return Simulator().simulate(start, stroke: c.stroke)
}

private func safetyPosition() -> (TableState, GameState) {
    (Fx.table(cue: Vec2(0.25, 0.75), [1: Vec2(Fx.spec.length - Fx.R, 0.52), 2: Vec2(1.0, 0.2), 3: Vec2(0.9, 0.85)]),
     Fx.nineBall([1, 2, 3]))
}

// MAJOR 1: a safety's Shot-of-the-Game weight must not be forced to 0 by analytic P = 1 (RATINGS §10: the SotG
// baseline is the player's own D).
@Test func review_safetyBaselineIsThePlayersDifficultyNotOne() async {
    let engine = ShotEngine(seed: 3, budget: .test)
    let (s, g) = safetyPosition()
    let e = await engine.evaluate(s, g, skill: .amateur)
    let safety = e.ranked.first { $0.candidate.kind == .safety && $0.samples > 0 }!.candidate
    let i = await engine.ratingInput(chosen: safety, outcome: play(safety, on: e.state), eval: e)
    #expect(i.isSafety)
    #expect(i.baselineP == i.difficulty)
    #expect(i.baselineP < 1)
    var hard = i; hard.difficulty = 0.7; hard.baselineP = 0.7; hard.wpAfter = hard.wpBefore + 0.3
    #expect(Ratings.sotgScore(hard) > 0.05)
}

// MAJOR 2: cancelling the evaluate() task stops the search early.
@Test func review_cancelledEvaluationStopsEarly() async {
    let (s, g) = Fx.midGame10()
    var big = EngineBudget.standard; big.rounds = 6; big.maxParallel = 2
    let engine = ShotEngine(seed: 1, budget: big)
    let full = await ShotEngine(seed: 1, budget: .test).evaluate(s, g, skill: .amateur)
    let task = Task { await engine.evaluate(s, g, skill: .amateur) }
    task.cancel()
    let e = await task.value
    #expect(e.tier == .quick)
    #expect(e.stats.sims < full.stats.sims)
}

// MAJOR 3: candidates() must line up with evaluate() for a non-default skill.
@Test func review_candidatesForASkillMatchTheEvaluation() async {
    let engine = ShotEngine(seed: 3, budget: .test)
    let (s, g) = Fx.midGame10()
    let e = await engine.evaluate(s, g, skill: .beginner)
    let listed = engine.candidates(s, g, skill: .beginner)
    let gen = CandidateGenerator(rules: RulesEngine(ruleSet: g.ruleSet), skill: .beginner).generate(e.state, g)
    #expect(listed == gen)
    // A candidate taken from a list built at another skill is still recognised as the engine's best shot.
    let best = e.ranked[0].candidate
    let other = engine.candidates(s, g).first {
        $0.kind == best.kind && $0.target == best.target && $0.objectBall == best.objectBall && $0.pocket == best.pocket
            && $0.meterStep == best.meterStep && $0.stroke.tipOffset == best.stroke.tipOffset
            && $0.cuePlacement == best.cuePlacement
    }
    #expect(other != nil)
    if var other {
        other.id = 9_999
        let i = await engine.ratingInput(chosen: other, outcome: play(best, on: e.state), eval: e)
        #expect(i.chosenIsBest)
    }
}

// MAJOR 4: an off-table ball reported by tracking is a foul in the rating.
@Test func review_offTableBallMakesTheShotAFoul() async {
    let engine = ShotEngine(seed: 3, budget: .test)
    let (s, g) = Fx.straightIn()
    let e = await engine.evaluate(s, g, skill: .amateur)
    let best = e.ranked[0].candidate
    let trace = play(best, on: e.state)
    let clean = await engine.ratingInput(chosen: best, outcome: trace, eval: e)
    #expect(!clean.fouled)
    let i = await engine.ratingInput(chosen: best, outcome: trace, eval: e, offTable: [Fx.b(5)])
    #expect(i.fouled)
    let (d, _) = await engine.rate(chosen: best, outcome: trace, eval: e, offTable: [Fx.b(5)])
    #expect(d == .mistake || d == .blunder)
    let r = await engine.record(chosen: best, outcome: trace, eval: e, offTable: [Fx.b(5)])
    #expect(r.input.fouled)
}

// MINOR: budgets mutated after init are normalised before use.
@Test func review_mutatedBudgetIsNormalised() async {
    var b = EngineBudget.test
    b.maxParallel = 0; b.chunk = 0; b.initialSamples = 3
    let n = b.normalized
    #expect(n.maxParallel == 1 && n.chunk == 2 && n.initialSamples == 4)
    let (s, g) = Fx.straightIn()
    let e = await ShotEngine(seed: 1, budget: b).evaluate(s, g, skill: .amateur)
    #expect(!e.ranked.isEmpty)
    #expect(e.ranked[0].samples % 2 == 0)
}

import Foundation
import Testing
import Geometry
import Physics
import Rules
@testable import Engine

// RATINGS §2: after the rating top-up extends the chosen arm, every chosen-arm signal (difficulty, the safety
// SotG baseline, v̂) must come from the topped-up samples, not the pre-top-up summary.

@Test func rate_topUpRefreshesDifficultyAcrossTheGreatBoundary() async {
    let engine = ShotEngine(seed: 3, budget: .test)
    let (s, g) = Fx.midGame10()
    let e = await engine.evaluate(s, g, skill: .beginner)
    let ev = Evaluator(simulator: Simulator(), rules: engine.rules(for: e.game), seed: 3,
                       budget: .test, skill: e.skill, opponentSkill: e.opponentSkill, state: e.state, game: e.game)
    let bound = RatingThresholds.default.greatDifficulty
    let bestN = e.paired[e.ranked[0].candidate.id]?.count ?? 0
    #expect(bestN >= 8)
    // Find an arm whose first k paired samples sit on the other side of the boundary from all `bestN`.
    var found: (Int, CandidateScore, [Evaluator.Sample], Double)?
    search: for (idx, arm) in e.ranked.enumerated().dropFirst() where arm.samples > 0 && !arm.candidate.kind.isBook {
        let start = ev.startState(arm.candidate)
        let full = (0..<bestN).map { ev.sample(arm.candidate, start: start, index: $0) }
        let pFull = Double(full.filter(\.intended).count) / Double(full.count)
        for k in stride(from: 2, to: min(arm.samples, bestN), by: 2) {
            let q = Evaluator.Quick(candidate: arm.candidate, pAnalytic: arm.pMakeAnalytic, pBaseline: arm.pBaseline,
                                    score: arm.quickScore, sims: 0)
            let stale = ev.summarise(q, Array(full.prefix(k)))
            if (stale.pIntended <= bound) != (pFull <= bound) { found = (idx, stale, full, pFull); break search }
        }
    }
    guard let (idx, stale, full, pFull) = found else { Issue.record("no arm crosses the boundary"); return }
    var e2 = e
    e2.ranked[idx] = stale                                      // a genuinely under-sampled arm (k < bestN)
    e2.paired[stale.candidate.id] = full.prefix(stale.samples).map(\.w)
    let c = stale.candidate
    var start = e.state
    if let q = c.cuePlacement { start.balls[.cue] = BallState(position: q) }
    let trace = Simulator().simulate(start, stroke: c.stroke)
    let i = await engine.ratingInput(chosen: c, outcome: trace, eval: e2)
    #expect(abs(i.difficulty - pFull) < 1e-12, "difficulty \(i.difficulty) stale \(stale.pIntended) full \(pFull)")
    #expect((i.difficulty <= bound) == (pFull <= bound))
    if i.isSafety { #expect(i.baselineP == i.difficulty) }
}

@Test func evaluator_extendMatchesSummarisingEverySample() async {
    let engine = ShotEngine(seed: 3, budget: .test)
    let (s, g) = Fx.midGame10()
    let e = await engine.evaluate(s, g, skill: .beginner)
    let ev = Evaluator(simulator: Simulator(), rules: engine.rules(for: e.game), seed: 3, budget: .test,
                       skill: e.skill, opponentSkill: e.opponentSkill, state: e.state, game: e.game)
    for arm in e.ranked where arm.samples > 0 {
        let start = ev.startState(arm.candidate)
        let full = (0..<24).map { ev.sample(arm.candidate, start: start, index: $0) }
        let q = Evaluator.Quick(candidate: arm.candidate, pAnalytic: arm.pMakeAnalytic, pBaseline: arm.pBaseline,
                                score: arm.quickScore, sims: 0)
        let whole = ev.summarise(q, full)
        let ext = ev.extend(ev.summarise(q, Array(full.prefix(6))), with: Array(full.dropFirst(6)), allW: full.map(\.w))
        #expect(ext.samples == whole.samples && ext.pIntended == whole.pIntended && ext.bestLeaf == whole.bestLeaf)
        #expect(abs(ext.ev - whole.ev) < 1e-12 && abs(ext.evSE - whole.evSE) < 1e-12)
        #expect(abs((ext.evMake ?? -1) - (whole.evMake ?? -1)) < 1e-12)
        #expect(abs((ext.evMiss ?? -1) - (whole.evMiss ?? -1)) < 1e-12)
    }
}

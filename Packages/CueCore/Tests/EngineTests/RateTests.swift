import Foundation
import Testing
import Geometry
import Physics
import Rules
@testable import Engine

private let engine = ShotEngine(seed: 3, budget: .test)

private func play(_ c: Candidate, on s: TableState) -> ShotTrace {
    var start = s
    if let q = c.cuePlacement { start.balls[.cue] = BallState(position: q) }
    return Simulator().simulate(start, stroke: c.stroke)
}

@Test func rate_bestPotMadeIsBestOrGreat() async {
    let (s, g) = Fx.straightIn()
    let e = await engine.evaluate(s, g, skill: .amateur)
    let best = e.ranked[0].candidate
    let trace = play(best, on: e.state)
    let (d, x) = await engine.rate(chosen: best, outcome: trace, eval: e)
    #expect(d == .best || d == .great)
    #expect(x.result == .made)
    let i = await engine.ratingInput(chosen: best, outcome: trace, eval: e)
    #expect(i.chosenIsBest && i.loss == 0)
    #expect(i.wpBefore == e.winProbability)
}

@Test func rate_scratchingIsNegative() async {
    let (s, g) = Fx.straightIn()
    let e = await engine.evaluate(s, g, skill: .amateur)
    let best = e.ranked[0].candidate
    // Same line with stun at 1.6 m/s follows the 1 into the pocket (see the outcome tests).
    let c = s.balls[.cue]!.position, o = s.balls[Fx.b(1)]!.position
    let trace = Simulator().simulate(e.state, stroke: Stroke(direction: o - c, speed: 1.6))
    #expect(trace.final.balls[.cue]!.motion == .pocketed)
    let (d, x) = await engine.rate(chosen: best, outcome: trace, eval: e)
    #expect(d == .mistake || d == .blunder)
    #expect(x.result == .miss)
}

@Test func rate_choosingAFarWorseShotIsPenalised() async {
    let (s, g) = Fx.straightIn()
    let e = await engine.evaluate(s, g, skill: .amateur)
    // The worst Monte Carlo arm.
    let worst = e.ranked.filter { $0.samples > 0 }.min { $0.ev < $1.ev }!
    #expect(e.ranked[0].ev - worst.ev > 0.15)
    let trace = play(worst.candidate, on: e.state)
    let i = await engine.ratingInput(chosen: worst.candidate, outcome: trace, eval: e)
    #expect(i.loss > 0.1)
    #expect(Ratings.rate(i).decision.isNegative)
}

@Test func rate_toppingUpAQuickOnlyCandidateUsesPairedSamples() async {
    let (s, g) = Fx.midGame10()
    let e = await engine.evaluate(s, g, skill: .amateur)
    guard let unsampled = e.ranked.first(where: { $0.samples == 0 && $0.candidate.intendsPot }) else {
        Issue.record("expected a Quick-only pot"); return
    }
    let trace = play(unsampled.candidate, on: e.state)
    let a = await engine.ratingInput(chosen: unsampled.candidate, outcome: trace, eval: e)
    let b = await engine.ratingInput(chosen: unsampled.candidate, outcome: trace, eval: e)
    #expect(a == b)                                        // deterministic top-up
    #expect(a.lossSE > 0)
    #expect(!a.chosenIsBest)
}

@Test func rate_pottingTheEightEarlyIsABlunder() async {
    // Bar 8-ball, solids: the 8 hangs in the foot-right corner; the shooter hits the 8 straight in.
    let p = Fx.footRight, u = Vec2(1, 1).normalized
    let s = Fx.table(cue: p - u * 0.6, [8: p - u * 0.2, 1: Vec2(0.5, 0.2), 9: Vec2(0.4, 0.8)])
    let g = Fx.eightBall([1, 8, 9])
    let e = await engine.evaluate(s, g, skill: .amateur)
    let trace = Simulator().simulate(e.state, stroke: Stroke(direction: u, speed: 1.3))
    #expect(trace.final.balls[.eight]!.motion == .pocketed)
    let (d, _) = await engine.rate(chosen: e.ranked[0].candidate, outcome: trace, eval: e)
    #expect(d == .blunder)
}

@Test func rate_breakIsBook() async {
    let s = Fx.table(cue: Fx.spec.headSpot, [1: Fx.spec.footSpot, 2: Fx.spec.footSpot + Vec2(0.05, 0.029)])
    var g = Fx.nineBall([1, 2], phase: .breakShot); g.ballInHand = .behindHeadString
    let e = await engine.evaluate(s, g, skill: .amateur)
    let c = e.ranked[0].candidate
    let (d, _) = await engine.rate(chosen: c, outcome: play(c, on: e.state), eval: e)
    #expect(d == .book)
}

@Test func rate_safetyIntentIsFlagged() async {
    let s = Fx.table(cue: Vec2(0.25, 0.75), [1: Vec2(Fx.spec.length - Fx.R, 0.52), 2: Vec2(1.0, 0.2), 3: Vec2(0.9, 0.85)])
    let e = await engine.evaluate(s, Fx.nineBall([1, 2, 3]), skill: .amateur)
    let safety = e.ranked.first { $0.candidate.kind == .safety }!.candidate
    let i = await engine.ratingInput(chosen: safety, outcome: play(safety, on: e.state), eval: e)
    #expect(i.isSafety)
    #expect(i.opponentBestMake >= 0 && i.opponentBestMake <= 1)
}

import Foundation
import Testing
import Geometry
import Physics
import Rules
@testable import Engine

// MARK: - trace → ShotOutcome (engine.md R9: one builder)

@Test func outcome_straightInPotIsRecorded() {
    let (s, g) = Fx.straightIn()
    let c = s.balls[.cue]!.position, o = s.balls[Fx.b(1)]!.position
    let trace = Simulator().simulate(s, stroke: Stroke(direction: o - c, speed: 1.6))
    let out = OutcomeBuilder.outcome(from: trace, game: g, candidate: nil)
    #expect(out.firstContact == Fx.b(1))
    #expect(out.noContact == false)
    #expect(out.pocketed[Fx.b(1)] == .footRight)
    #expect(out.pocketOrder.first == Fx.b(1))
    #expect(out.isBreak == false)
}

@Test func outcome_missingEverythingIsNoContact() {
    let (s, g) = Fx.straightIn()
    let trace = Simulator().simulate(s, stroke: Stroke(direction: Vec2(0, 1), speed: 0.5))
    let out = OutcomeBuilder.outcome(from: trace, game: g, candidate: nil)
    #expect(out.firstContact == nil)
    #expect(out.noContact)
}

@Test func outcome_carriesCallAndPushOutFromCandidate() {
    let (s, _) = Fx.straightIn()
    let g = Fx.eightBall([1, 5, 7], ruleSet: .wpaEight)
    let c = Candidate(id: 0, kind: .direct, target: Fx.b(1), objectBall: Fx.b(1), pocket: .footRight,
                      stroke: Stroke(direction: Vec2(1, 1), speed: 1.3), meterStep: 2)
    let trace = Simulator().simulate(s, stroke: c.stroke)
    let out = OutcomeBuilder.outcome(from: trace, game: g, candidate: c)
    #expect(out.calledPocket == .footRight)
    #expect(out.calledBall == Fx.b(1))
    let push = Candidate(id: 1, kind: .pushOut, target: nil, objectBall: nil, pocket: nil,
                         stroke: Stroke(direction: Vec2(1, 0), speed: 0.8), meterStep: 1)
    #expect(OutcomeBuilder.outcome(from: trace, game: Fx.nineBall([1], phase: .pushOutAvailable), candidate: push).isPushOut)
    let safe = Candidate(id: 2, kind: .safety, target: Fx.b(1), objectBall: nil, pocket: nil,
                         stroke: Stroke(direction: Vec2(1, 0), speed: 0.8), meterStep: 1)
    #expect(OutcomeBuilder.outcome(from: trace, game: g, candidate: safe).calledSafety)
}

// MARK: - Analytic P(make) (engine.md §4.3)

/// OB 1 m from the foot-right corner on its bisector; CB 1 m from the OB at the given cut.
func cornerShot(cut degrees: Double, cueDistance d: Double = 1.0, obDistance dp: Double = 1.0) -> (Vec2, Vec2, Pocket) {
    let p = Fx.footRight
    let u = Vec2(1, 1).normalized                    // OB → pocket
    let o = p - u * dp
    let ghost = o - u * (2 * Fx.R)
    let incoming = u.rotated(by: degrees * .pi / 180)
    return (ghost - incoming * d, o, .footRight)
}

@Test func analyticP_isAProbabilityAndOrderedBySkill() {
    let (c, o, p) = cornerShot(cut: 30)
    let pb = AnalyticP.direct(cue: c, object: o, pocket: p, spec: Fx.spec, skill: .beginner)
    let pa = AnalyticP.direct(cue: c, object: o, pocket: p, spec: Fx.spec, skill: .amateur)
    let ps = AnalyticP.direct(cue: c, object: o, pocket: p, spec: Fx.spec, skill: .strong)
    for v in [pb, pa, ps] { #expect(v >= 0 && v <= 1) }
    #expect(pb < pa && pa < ps)
    // engine.md §5.1 tier targets on this exact shot: 55 / 75 / 90%.
    #expect(abs(pb - 0.55) < 0.08)
    #expect(abs(pa - 0.75) < 0.08)
    #expect(abs(ps - 0.90) < 0.06)
}

@Test func analyticP_isMonotoneInDistanceAndCut() {
    let skill = SkillModel.amateur
    var last = 1.0
    for d in [0.3, 0.6, 1.0, 1.4] {
        let (c, o, p) = cornerShot(cut: 20, cueDistance: d)
        let v = AnalyticP.direct(cue: c, object: o, pocket: p, spec: Fx.spec, skill: skill)
        #expect(v < last); last = v
    }
    last = 1.0
    for cut in [0.0, 20, 40, 60, 75] {
        let (c, o, p) = cornerShot(cut: cut)
        let v = AnalyticP.direct(cue: c, object: o, pocket: p, spec: Fx.spec, skill: skill)
        #expect(v < last + 1e-12); last = v
    }
}

@Test func analyticP_noNoiseIsCertainInsideTheWindow() {
    let (c, o, p) = cornerShot(cut: 30)
    let perfect = SkillModel(sigmaAim: 1e-9, sigmaSpeedRel: 1e-9, sigmaTip: 0)
    #expect(AnalyticP.direct(cue: c, object: o, pocket: p, spec: Fx.spec, skill: perfect) > 0.999)
}

@Test func analyticP_combosAreHarderThanTheSameDirect() {
    let (c, o, p) = cornerShot(cut: 10, cueDistance: 0.5, obDistance: 0.4)
    let direct = AnalyticP.direct(cue: c, object: o, pocket: p, spec: Fx.spec, skill: .amateur)
    let u = Vec2(1, 1).normalized
    let first = o - u * 0.25                         // first OB 25 cm behind, straight combo
    let cueC = first - u * 0.5
    let combo = AnalyticP.combo(cue: cueC, first: first, second: o, pocket: p, spec: Fx.spec, skill: .amateur)
    #expect(combo > 0 && combo < direct)
}

@Test func outcome_pocketIsTheGeometryPocketNearestTheCapture() {
    // Regression: Physics labels the (L, W) pocket `headRight`; Geometry calls it `footRight`. The builder
    // trusts positions, not labels.
    for p in Pocket.allCases {
        let c = Fx.spec.pocketCenter(p)
        let towardInside = (Vec2(Fx.spec.length / 2, Fx.spec.width / 2) - c).normalized
        #expect(OutcomeBuilder.nearestPocket(to: c - towardInside * 0.03, spec: Fx.spec) == p)
    }
}

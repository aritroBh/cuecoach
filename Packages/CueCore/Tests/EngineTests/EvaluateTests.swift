import Foundation
import Testing
import Geometry
import Physics
import Rules
@testable import Engine

extension EngineBudget {
    /// Small budget so debug-build tests stay fast.
    static let test = EngineBudget(topK: 6, safeties: 3, pushOuts: 3, initialSamples: 8, rounds: 3)
}

private func eval(_ s: TableState, _ g: GameState, skill: SkillModel = .amateur, seed: UInt64 = 1,
                  budget: EngineBudget = .test) async -> Evaluation {
    await ShotEngine(seed: seed, budget: budget).evaluate(s, g, skill: skill)
}

@Test func evaluate_straightInPicksThePot() async {
    let (s, g) = Fx.straightIn()
    let e = await eval(s, g)
    let best = e.ranked[0]
    #expect(best.candidate.kind == .direct)
    #expect(best.candidate.objectBall == Fx.b(1) && best.candidate.pocket == .footRight)
    #expect(best.ev > 0.5)
    #expect(best.pIntended > 0.8)
    #expect(best.samples == e.ranked.map(\.samples).max())
    #expect(e.stats.sims > 0)
}

@Test func evaluate_isDeterministicAcrossInstancesAndParallelism() async {
    let (s, g) = Fx.midGame10()
    var narrow = EngineBudget.test; narrow.maxParallel = 1
    var wide = EngineBudget.test; wide.maxParallel = 8
    let a = await eval(s, g, budget: narrow)
    let b = await eval(s, g, budget: wide)
    let c = await eval(s, g, budget: wide)
    #expect(a == b)
    #expect(b == c)
}

@Test func evaluate_seedChangesSamplesNotStructure() async {
    let (s, g) = Fx.midGame10()
    let a = await eval(s, g, seed: 1), b = await eval(s, g, seed: 2)
    #expect(a.ranked.map(\.ev) != b.ranked.map(\.ev))
}

@Test func evaluate_subQuantumJitterGivesTheSameResult() async {
    // Positions on the 0.5 mm grid, then nudged by 0.2 mm: quantisation maps both to the same state.
    let (s0, g) = Fx.straightIn()
    var s = s0
    for (id, b) in s0.balls {
        s.balls[id]!.position = Vec2((b.position.x / 0.0005).rounded() * 0.0005, (b.position.y / 0.0005).rounded() * 0.0005)
    }
    var j = s
    for id in j.balls.keys { j.balls[id]!.position += Vec2(0.0002, -0.0002) }
    let a = await eval(s, g), b = await eval(j, g)
    #expect(a.ranked == b.ranked)
    #expect(a.stateHash == b.stateHash)
}

@Test func evaluate_snookeredPicksALegalHit() async {
    let s = Fx.table(cue: Vec2(0.4, 0.5), [1: Vec2(1.0, 0.5), 2: Vec2(0.7, 0.5), 3: Vec2(0.7, 0.44),
                                           4: Vec2(0.7, 0.56), 5: Vec2(0.7, 0.38), 6: Vec2(0.7, 0.62)])
    let e = await eval(s, Fx.nineBall([1, 2, 3, 4, 5, 6]))
    let k = e.ranked[0].candidate.kind
    #expect({ if case .kick = k { true } else { k == .safety } }())
}

@Test func evaluate_deadComboOnTheNineBeatsEverything() async {
    // Reference #9: dead 2 → 9 combo in the foot-right corner.
    let p = Fx.footRight, u = Vec2(1, 1).normalized
    let nine = p - u * 0.20, two = nine - u * 0.20, cue = two - u * 0.45
    let s = Fx.table(cue: cue, [2: two, 9: nine, 5: Vec2(0.3, 0.8), 7: Vec2(0.5, 0.15)])
    let e = await eval(s, Fx.nineBall([2, 5, 7, 9]))
    #expect(e.ranked[0].candidate.kind == .combo(via: Fx.b(9)))
    #expect(e.ranked[0].ev > 0.8)
}

@Test func evaluate_nothingMakeablePrefersDefence() async {
    // Reference #11: the 1 is frozen on the foot rail far from any pocket line; the CB is at the other end.
    let s = Fx.table(cue: Vec2(0.25, 0.75), [1: Vec2(Fx.spec.length - Fx.R, 0.52), 2: Vec2(1.0, 0.2), 3: Vec2(0.9, 0.85)])
    let e = await eval(s, Fx.nineBall([1, 2, 3]))
    #expect(!e.ranked[0].candidate.kind.isOffensive)
}

@Test func evaluate_pushOutArmsAreValuedThroughTheOption() async {
    let (s, g0) = Fx.straightIn()
    var g = g0; g.phase = .pushOutAvailable
    let e = await eval(s, g)
    let pushes = e.ranked.filter { $0.candidate.kind == .pushOut && $0.samples > 0 }
    #expect(!pushes.isEmpty)
    for p in pushes { #expect(p.ev >= 0 && p.ev <= 1) }
}

@Test func evaluate_breakIsBookAndNotSimulated() async {
    let s = Fx.table(cue: Fx.spec.headSpot, [1: Fx.spec.footSpot, 2: Fx.spec.footSpot + Vec2(0.05, 0.029)])
    var g = Fx.nineBall([1, 2], phase: .breakShot); g.ballInHand = .behindHeadString
    let e = await eval(s, g)
    #expect(e.stats.sims == 0)
    #expect(!e.ranked.isEmpty && e.ranked.allSatisfy { $0.candidate.kind == .breakShot })
}

@Test func evaluate_reportsBaselineAndNaivePick() async {
    let (s, g) = Fx.midGame10()
    let e = await eval(s, g)
    #expect(e.naivePick != nil)
    #expect(e.shooterBestPot > 0)
    for c in e.ranked where c.candidate.kind.isOffensive {
        #expect(c.pBaseline >= 0 && c.pBaseline <= 1)
    }
    #expect(abs(e.winProbability - WinModel(rules: RulesEngine(ruleSet: .barEight), skills: [.amateur, .amateur])
        .shooterWP(e.state, g)) < 1e-12)
}

@Test func evaluate_throwCorrectedAimDiffersFromGeometricOnACut() async {
    // Reference #7 analogue: a 40° cut needs throw correction; the refined aim differs from ghost-ball aim.
    let (c, o, _) = cornerShot(cut: 40, cueDistance: 0.6, obDistance: 0.5)
    let s = Fx.table(cue: c, [1: o, 6: Vec2(0.3, 0.2)])
    let e = await eval(s, Fx.nineBall([1, 6]))
    let pot = e.ranked.first { $0.candidate.kind == .direct && $0.candidate.pocket == .footRight
        && $0.candidate.stroke.tipOffset == .zero }
    #expect(pot != nil)
    if let pot, let ghost = pot.candidate.ghost {
        let geometric = (ghost - c).angle
        #expect(abs(pot.candidate.stroke.direction.angle - geometric) > 1e-4)
    }
}

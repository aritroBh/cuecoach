import Foundation
import Testing
import Geometry
import Physics
import Rules
@testable import Engine

private func model(_ g: GameState, _ a: SkillModel = .amateur, _ b: SkillModel = .amateur) -> WinModel {
    WinModel(rules: RulesEngine(ruleSet: g.ruleSet), skills: [a, b])
}

@Test func wp_isBoundedAndComplementary() {
    for (s, g) in [Fx.straightIn(), Fx.midGame10()] {
        let m = model(g)
        let w0 = m.wp(s, g, forTeam: 0), w1 = m.wp(s, g, forTeam: 1)
        #expect(w0 > 0 && w0 < 1)
        #expect(abs(w0 + w1 - 1) < 1e-12)
        #expect(abs(m.shooterWP(s, g) - w0) < 1e-12)
    }
}

@Test func wp_overIsCertain() {
    let (s, g0) = Fx.straightIn()
    var g = g0; g.phase = .over(winner: 1)
    #expect(model(g).wp(s, g, forTeam: 1) == 1)
    #expect(model(g).wp(s, g, forTeam: 0) == 0)
}

@Test func wp_isMonotoneInOwnAndOpponentBalls() {
    let (s, g) = Fx.midGame10()
    let base = model(g).shooterWP(s, g)
    var fewerOwn = g; fewerOwn.onTable.remove(Fx.b(4))      // a solid gone (shooter has solids)
    var fewerTheirs = g; fewerTheirs.onTable.remove(Fx.b(12))
    #expect(model(g).shooterWP(s, fewerOwn) > base)
    #expect(model(g).shooterWP(s, fewerTheirs) < base)
}

@Test func wp_ballInHandRaisesTheShooter() {
    // Cue ball buried on the head rail behind balls; ball in hand is better.
    let s = Fx.table(cue: Vec2(0.03, 0.5), [1: Vec2(1.2, 0.3), 2: Vec2(0.09, 0.5), 3: Vec2(1.6, 0.7)])
    let none = Fx.nineBall([1, 2, 3])
    let bih = Fx.nineBall([1, 2, 3], bih: .anywhere)
    #expect(model(none).shooterWP(s, bih) > model(none).shooterWP(s, none))
}

@Test func wp_opponentOnTwoFoulsHelpsTheShooter() {
    let (s, g) = Fx.straightIn()
    var two = g; two.consecutiveFouls = [1: 2]
    #expect(model(g).shooterWP(s, two) > model(g).shooterWP(s, g))
}

@Test func wp_skillMatters() {
    let (s, g) = Fx.midGame10()
    #expect(model(g, .strong, .beginner).shooterWP(s, g) > model(g, .beginner, .strong).shooterWP(s, g))
}

@Test func wp_easyLastNineIsAlmostWon() {
    // Reference position #2: easy last ball.
    let p = Fx.footRight, u = Vec2(1, 1).normalized
    let s = Fx.table(cue: p - u * 0.6, [9: p - u * 0.25])
    let g = Fx.nineBall([9])
    #expect(model(g).shooterWP(s, g) >= 0.85)
}

// MARK: - Value of a rules result (engine.md §6.1)

@Test func value_pushOutIsTheOpponentsBestChoice() {
    let (s, g0) = Fx.straightIn()
    var g = g0; g.phase = .pushOutAvailable
    let rules = RulesEngine(ruleSet: .wpaNine)
    let r = rules.apply(ShotOutcome(firstContact: nil, noContact: true, anyRailAfterContact: false, isPushOut: true), to: g)
    #expect(!r.options.isEmpty)
    let m = model(g)
    let v = m.value(after: r, state: s, forTeam: 0)
    let accept = m.value(after: rules.choose(.acceptTable, in: r.nextState), state: s, forTeam: 0)
    let back = m.value(after: rules.choose(.handBack, in: r.nextState), state: s, forTeam: 0)
    #expect(abs(v - min(accept, back)) < 1e-12)
}

@Test func value_scratchIsWorseThanAPlainMiss() {
    let (s, g) = Fx.straightIn()
    let rules = RulesEngine(ruleSet: .wpaNine)
    let miss = rules.apply(ShotOutcome(firstContact: Fx.b(1), anyRailAfterContact: true), to: g)
    let scratch = rules.apply(ShotOutcome(firstContact: Fx.b(1), pocketed: [.cue: .footLeft],
                                          anyRailAfterContact: true), to: g)
    var after = s; after.balls[.cue]!.motion = .pocketed
    let m = model(g)
    #expect(m.value(after: scratch, state: after, forTeam: 0) < m.value(after: miss, state: s, forTeam: 0))
}

@Test func value_eightEarlyLoses() {
    let (s, g) = Fx.midGame10()
    let rules = RulesEngine(ruleSet: .barEight)
    let r = rules.apply(ShotOutcome(firstContact: Fx.b(1), pocketed: [.eight: .footLeft], anyRailAfterContact: true), to: g)
    #expect(model(g).value(after: r, state: s, forTeam: 0) == 0)
}

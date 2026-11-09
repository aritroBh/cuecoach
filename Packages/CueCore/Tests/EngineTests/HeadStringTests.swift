import Testing
import Geometry
import Physics
import Rules
@testable import Engine

// WPA 3.11 (docs/research/rules-notes.md §1, RULES.md B6): with ball in hand above the head string, "the cue ball
// must either cross the Head String or contact a ball on or below it". The builder reads the cue ball's path.

private func kitchenGame() -> GameState { Fx.eightBall([1, 9], groups: nil, bih: .behindHeadString) }

/// Cue in the kitchen, rail-first off the foot rail (beyond the head string), back to a kitchen ball.
private func footRailBackToKitchen() -> ShotTrace {
    let cue = Vec2(0.20, 0.30)
    let railX = Fx.spec.length - Fx.R
    let aim = Vec2(railX, 0.508)                          // mirror: returns towards y ≈ 0.716 at x = 0.20
    let back = Vec2(0.30, 0.30 + 2 * (0.508 - 0.30) * (railX - 0.30) / (railX - 0.20))
    let s = Fx.table(cue: cue, [1: back, 9: Vec2(1.6, 0.15)])
    return Simulator().simulate(s, stroke: Stroke(direction: aim - cue, speed: 3.2))
}

@Test func headString_railFirstAcrossThenKitchenBall_isLegal() {
    let trace = footRailBackToKitchen()
    let g = kitchenGame()
    let out = OutcomeBuilder.outcome(from: trace, game: g, candidate: nil)
    #expect(out.firstContact == Fx.b(1))                  // precondition: the shot does what the test says
    #expect(trace.initial.balls[Fx.b(1)]!.position.x < Fx.spec.headStringX)
    #expect(out.cueBallStartedAboveHeadString == true)
    #expect(out.cueBallCrossedHeadStringFirst == true)
    let r = RulesEngine(ruleSet: .barEight).apply(out, to: g)
    #expect(!r.fouls.contains(.badPlayFromAboveHeadString))
}

@Test func headString_directKitchenBall_isAFoul() {
    let cue = Vec2(0.20, 0.30), ob = Vec2(0.40, 0.30)
    let s = Fx.table(cue: cue, [1: ob, 9: Vec2(1.6, 0.15)])
    let trace = Simulator().simulate(s, stroke: Stroke(direction: ob - cue, speed: 1.0))
    let g = kitchenGame()
    let out = OutcomeBuilder.outcome(from: trace, game: g, candidate: nil)
    #expect(out.firstContact == Fx.b(1))
    #expect(out.cueBallCrossedHeadStringFirst == false)
    #expect(RulesEngine(ruleSet: .barEight).apply(out, to: g).fouls.contains(.badPlayFromAboveHeadString))
}

@Test func headString_railInsideKitchenThenKitchenBall_isAFoul() {
    // Off the near side rail, never leaving the kitchen, onto a kitchen ball.
    let cue = Vec2(0.10, 0.30), ob = Vec2(0.30, 0.30)
    let railY = Fx.spec.width - Fx.R
    let aim = Vec2(0.20, railY)                           // mirror point halfway in x
    let s = Fx.table(cue: cue, [1: ob, 9: Vec2(1.6, 0.15)])
    let trace = Simulator().simulate(s, stroke: Stroke(direction: aim - cue, speed: 1.5))
    let out = OutcomeBuilder.outcome(from: trace, game: kitchenGame(), candidate: nil)
    #expect(out.firstContact == Fx.b(1))
    #expect(out.cueBallCrossedHeadStringFirst == false)
}

@Test func headString_directBallBelowHeadString_isLegal() {
    let cue = Vec2(0.20, 0.50), ob = Vec2(1.20, 0.50)
    let s = Fx.table(cue: cue, [1: ob, 9: Vec2(1.6, 0.15)])
    let trace = Simulator().simulate(s, stroke: Stroke(direction: ob - cue, speed: 1.5))
    let out = OutcomeBuilder.outcome(from: trace, game: kitchenGame(), candidate: nil)
    #expect(out.firstContact == Fx.b(1))
    #expect(out.cueBallCrossedHeadStringFirst == true)
}

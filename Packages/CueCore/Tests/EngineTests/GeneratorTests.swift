import Foundation
import Testing
import Geometry
import Physics
import Rules
@testable import Engine

private func gen(_ s: TableState, _ g: GameState) -> [Candidate] {
    CandidateGenerator(rules: RulesEngine(ruleSet: g.ruleSet)).generate(s, g)
}

@Test func generator_straightInHasTheDirectPot() {
    let (s, g) = Fx.straightIn()
    let cs = gen(s, g)
    #expect(cs.contains { $0.kind == .direct && $0.objectBall == Fx.b(1) && $0.pocket == .footRight })
}

@Test func generator_nineBallOnlyAimsAtTheLowestBall() {
    let (s, g) = Fx.straightIn()
    for c in gen(s, g) where c.kind != .pushOut {
        #expect(c.target == Fx.b(1), "\(c.kind) targets \(String(describing: c.target))")
    }
}

@Test func generator_speedsAreMeterStepsAndIdsAreUnique() {
    let (s, g) = Fx.midGame10()
    let cs = gen(s, g)
    #expect(Set(cs.map(\.id)).count == cs.count)
    for c in cs {
        #expect((1...5).contains(c.meterStep))
        #expect(abs(c.stroke.speed - CandidateGenerator.meterSpeeds[c.meterStep - 1]) < 1e-12)
    }
}

@Test func generator_banksKicksAndSafetiesExistEvenWhenDirectsDo() {
    let (s, g) = Fx.midGame10()
    let cs = gen(s, g)
    #expect(cs.contains { $0.kind == .direct })
    #expect(cs.contains { if case .bank = $0.kind { true } else { false } })
    #expect(cs.contains { if case .kick = $0.kind { true } else { false } })
    #expect(cs.contains { $0.kind == .safety })
}

@Test func generator_blockedDirectIsDroppedAndBankOffered() {
    // Reference #6: a blocker sits on the 1 → foot-right line, so no direct there; a clean bank remains.
    let o = Vec2(1.3, 0.55)
    let cue = Vec2(0.7, 0.30)
    let p = Fx.footRight
    let blocker = o + (p - o) * 0.5
    let s = Fx.table(cue: cue, [1: o, 2: blocker])
    let cs = gen(s, Fx.nineBall([1, 2]))
    #expect(!cs.contains { $0.kind == .direct && $0.pocket == .footRight })
    #expect(cs.contains { if case .bank = $0.kind { $0.objectBall == Fx.b(1) } else { false } })
}

@Test func generator_bankGeometryMirrorsThePocket() {
    // 1 near the left rail; a one-rail bank off the left rail into the right side pocket.
    let s = Fx.table(cue: Vec2(1.45, 0.75), [1: Vec2(1.3, 0.25)])
    let cs = gen(s, Fx.nineBall([1]))
    let bank = cs.first { $0.kind == .bank(.left) && $0.pocket == .sideRight }
    #expect(bank != nil)
    if let bank, let ghost = bank.ghost {
        let mirrored = EngineGeometry.mirror(Fx.spec.pocketCenter(.sideRight), across: .left, spec: Fx.spec)
        let o = Vec2(1.3, 0.25)
        #expect(abs(EngineGeometry.angleBetween(o - ghost, mirrored - o)) < 1e-9)
    }
}

@Test func generator_snookeredGivesKicks() {
    // 1 hidden behind a wall of balls; no clear line from the CB.
    let cue = Vec2(0.4, 0.5)
    let o = Vec2(1.0, 0.5)
    let s = Fx.table(cue: cue, [1: o, 2: Vec2(0.7, 0.5), 3: Vec2(0.7, 0.44), 4: Vec2(0.7, 0.56),
                                5: Vec2(0.7, 0.38), 6: Vec2(0.7, 0.62)])
    let cs = gen(s, Fx.nineBall([1, 2, 3, 4, 5, 6]))
    #expect(!cs.contains { $0.kind == .direct })
    #expect(cs.filter { if case .kick = $0.kind { true } else { false } }.count >= 2)
}

@Test func generator_comboOntoTheNine() {
    // 2 → 9 → foot-right, both nearly straight.
    let p = Fx.footRight
    let u = Vec2(1, 1).normalized
    let nine = p - u * 0.20
    let two = nine - u * 0.20
    let cue = two - u * 0.45
    let s = Fx.table(cue: cue, [2: two, 9: nine, 5: Vec2(0.3, 0.8)])
    let cs = gen(s, Fx.nineBall([2, 5, 9]))
    #expect(cs.contains { $0.kind == .combo(via: Fx.b(9)) && $0.objectBall == Fx.b(9) && $0.target == Fx.b(2) })
}

@Test func generator_pushOutsOnlyWhenAvailable() {
    let (s, g) = Fx.straightIn()
    #expect(!gen(s, g).contains { $0.kind == .pushOut })
    var g2 = g; g2.phase = .pushOutAvailable
    let cs = gen(s, g2)
    #expect(cs.filter { $0.kind == .pushOut }.count >= 24)
    #expect(cs.contains { $0.kind == .direct })              // may still shoot normally
}

@Test func generator_breakPhaseGivesOnlyBookBreaks() {
    let s = Fx.table(cue: Fx.spec.headSpot, [1: Fx.spec.footSpot, 2: Fx.spec.footSpot + Vec2(0.05, 0.029)])
    var g = Fx.nineBall([1, 2], phase: .breakShot)
    g.ballInHand = .behindHeadString
    let cs = gen(s, g)
    #expect(!cs.isEmpty && cs.allSatisfy { $0.kind == .breakShot })
    #expect(cs.allSatisfy { ($0.cuePlacement?.x ?? 99) < Fx.spec.headStringX })
}

@Test func generator_ballInHandBehindHeadStringRespectsTheKitchen() {
    let s = Fx.table(cue: nil, [1: Vec2(1.5, 0.3), 2: Vec2(0.3, 0.5), 3: Vec2(1.7, 0.8)])
    let g = Fx.nineBall([1, 2, 3], bih: .behindHeadString)
    let cs = gen(s, g).filter { $0.kind != .safety }
    #expect(!cs.isEmpty)
    for c in cs {
        #expect(c.cuePlacement != nil)
        #expect(c.cuePlacement!.x < Fx.spec.headStringX)
    }
}

@Test func generator_ballInHandAnywherePlacesTheCueNearTheShot() {
    let s = Fx.table(cue: nil, [1: Vec2(1.5, 0.3), 3: Vec2(1.7, 0.8)])
    let cs = gen(s, Fx.nineBall([1, 3], bih: .anywhere))
    let directs = cs.filter { $0.kind == .direct }
    #expect(!directs.isEmpty)
    #expect(directs.allSatisfy { $0.cuePlacement != nil })
    // Every placement is on the cloth and clear of other balls.
    for c in directs {
        let q = c.cuePlacement!
        #expect(q.x > Fx.R && q.x < Fx.spec.length - Fx.R && q.y > Fx.R && q.y < Fx.spec.width - Fx.R)
        for (_, b) in s.balls { #expect(b.position.distance(to: q) > 2 * Fx.R) }
    }
}

@Test func generator_eightBallTargetsOwnGroupOnly() {
    let (s, g) = Fx.midGame10()
    for c in gen(s, g) {
        if let t = c.target { #expect(t.group == .solids, "\(t)") }
    }
}

@Test func generator_capsAreRespected() {
    let (s, g) = Fx.midGame10()
    let caps = GeneratorCaps()
    let cs = gen(s, g)
    #expect(Set(cs.filter { $0.kind == .direct }.map { "\($0.objectBall!)-\($0.pocket!)" }).count <= caps.maxTargetPockets)
    #expect(cs.filter { if case .bank = $0.kind { true } else { false } }.count <= caps.banks)
    #expect(cs.filter { $0.kind == .safety }.count <= caps.safeties)
}

import Foundation
import Testing
import Geometry
import Physics
@testable import Engine

// MARK: - RNG (engine.md §6.3: proper mixer, antithetics, CRN by sample index)

@Test func rng_isDeterministicAndStreamSensitive() {
    let r = EngineRNG(seed: 42)
    #expect(r.normals(state: 7, stream: 0, sample: 4) == EngineRNG(seed: 42).normals(state: 7, stream: 0, sample: 4))
    #expect(r.normals(state: 7, stream: 0, sample: 4) != r.normals(state: 8, stream: 0, sample: 4))
    #expect(r.normals(state: 7, stream: 0, sample: 4) != r.normals(state: 7, stream: 1, sample: 4))
    #expect(r.normals(state: 7, stream: 0, sample: 4) != EngineRNG(seed: 43).normals(state: 7, stream: 0, sample: 4))
}

@Test func rng_oddSamplesAreAntitheticOfEven() {
    let r = EngineRNG(seed: 1)
    for k in 0..<10 {
        #expect(r.normals(state: 3, stream: 0, sample: 2 * k + 1) == -r.normals(state: 3, stream: 0, sample: 2 * k))
    }
}

@Test func rng_normalMomentsAreStandard() {
    let r = EngineRNG(seed: 9)
    var sum = 0.0, sq = 0.0
    let n = 20_000
    for i in stride(from: 0, to: n, by: 2) {     // even samples only (odd are antithetic copies)
        let z = r.normals(state: 11, stream: 0, sample: i)
        for v in [z.x, z.y, z.z, z.w] { sum += v; sq += v * v }
    }
    let m = Double(n / 2 * 4)
    #expect(abs(sum / m) < 0.03)
    #expect(abs(sq / m - 1) < 0.05)
}

@Test func rng_mixerHasNoCollisionsOnSmallGrid() {
    var seen = Set<UInt64>()
    for s in 0..<64 { for st in 0..<16 { for i in 0..<64 {
        seen.insert(EngineRNG.mix(UInt64(s), UInt64(st), UInt64(i)))
    } } }
    #expect(seen.count == 64 * 16 * 64)
}

// MARK: - SkillModel (engine.md §5.1)

@Test func skill_tiersAreOrdered() {
    #expect(SkillModel.beginner.sigmaAim > SkillModel.amateur.sigmaAim)
    #expect(SkillModel.amateur.sigmaAim > SkillModel.strong.sigmaAim)
    #expect(SkillModel.beginner.sigmaSpeedRel > SkillModel.strong.sigmaSpeedRel)
}

@Test func skill_zeroNoiseReturnsNominalStroke() {
    let s = Stroke(direction: Vec2(1, 1), speed: 2, tipOffset: Vec2(0, 0.3))
    let p = SkillModel.amateur.perturbed(s, noise: SIMD4(0, 0, 0, 0))
    #expect(abs(p.direction.angle - s.direction.angle) < 1e-12)
    #expect(abs(p.speed - 2) < 1e-12)
    #expect(p.tipOffset == s.tipOffset)
}

@Test func skill_noiseScalesWithSigma() {
    let s = Stroke(direction: Vec2(1, 0), speed: 2)
    let p = SkillModel.amateur.perturbed(s, noise: SIMD4(1, 1, 0, 0))
    #expect(abs(p.direction.angle - SkillModel.amateur.sigmaAim) < 1e-9)
    #expect(abs(p.speed - 2 * (1 + SkillModel.amateur.sigmaSpeedRel)) < 1e-9)
}

@Test func skill_tipBeyondMiscueRadiusIsAMiscue() {
    let s = Stroke(direction: Vec2(1, 0), speed: 2, tipOffset: Vec2(0, 0.45))
    let p = SkillModel.beginner.perturbed(s, noise: SIMD4(0, 0, 0, 10))
    #expect(p.tipOffset.length <= 0.5)
    #expect(p.speed < 1.0)                       // miscue: speed × 0.3
}

// MARK: - Geometry helpers

@Test func geometry_clearAndBlockedPaths() {
    let R = TableSpec.ballRadius
    let blockers = [Vec2(0.5, 0.0)]
    #expect(!EngineGeometry.pathClear(from: Vec2(0, 0), to: Vec2(1, 0), blockers: blockers))
    #expect(EngineGeometry.pathClear(from: Vec2(0, 0), to: Vec2(1, 0), blockers: [Vec2(0.5, 2 * R + 0.001)]))
    #expect(!EngineGeometry.pathClear(from: Vec2(0, 0), to: Vec2(1, 0), blockers: [Vec2(0.5, 2 * R - 0.001)]))
    // A blocker behind the start doesn't count.
    #expect(EngineGeometry.pathClear(from: Vec2(0, 0), to: Vec2(1, 0), blockers: [Vec2(-0.2, 0)]))
}

@Test func geometry_cutAngle() {
    let p = Vec2(2, 0)
    #expect(abs(EngineGeometry.cutAngle(cue: Vec2(0, 0), object: Vec2(1, 0), pocket: p)) < 1e-9)
    let ob = Vec2(1, 0)
    let ghost = AimGeometry.ghostBall(object: ob, pocket: Vec2(1, 1))
    let cue = ghost + Vec2(-1, 0)              // CB comes in along +x, OB goes along +y: 90°
    #expect(abs(EngineGeometry.cutAngle(cue: cue, object: ob, pocket: Vec2(1, 1)) - .pi / 2) < 1e-6)
}

@Test func geometry_mirrorAcrossRails() {
    let spec = TableSpec(size: .sevenFoot)
    let R = TableSpec.ballRadius
    let m = EngineGeometry.mirror(Vec2(0.5, 0.3), across: .left, spec: spec)
    #expect(abs(m.x - 0.5) < 1e-12 && abs(m.y - (2 * R - 0.3)) < 1e-12)
    let f = EngineGeometry.mirror(Vec2(1.0, 0.3), across: .foot, spec: spec)
    #expect(abs(f.x - (2 * (spec.length - R) - 1.0)) < 1e-12)
}

@Test func geometry_tp34GainMatchesExactFormulaForSmallErrors() {
    // Dr. Dave TP 3.4 eq. 1 vs its linearisation, φ ≤ 30°, Δφ = 0.1°, d ∈ [0.2, 2] m. engine.md §13.1 says < 2%;
    // the second-order term reaches ~2.1% at d = 2 m, φ = 30°, so the bound here is 2.5%.
    let R = TableSpec.ballRadius
    let dphi = 0.1 * .pi / 180
    for d in stride(from: 0.2, through: 2.0, by: 0.2) {
        for deg in [0.0, 10, 20, 30] {
            let phi = deg * .pi / 180
            let exact = asin((d / (2 * R)) * sin(dphi) + sin(phi - dphi)) - phi + dphi
            let lin = EngineGeometry.throwGain(distance: d, cut: phi) * dphi
            #expect(abs(lin - exact) / abs(exact) < 0.025, "d=\(d) φ=\(deg)")
        }
    }
}

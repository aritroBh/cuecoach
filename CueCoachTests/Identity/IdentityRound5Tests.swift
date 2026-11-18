import Foundation
import Testing
@testable import CueCoach

// Residuals after Codex r3b, under D28 (docs/DECISIONS.md): held-out ship-gate calibration with CI + coverage,
// and no tap ever binds a guest's look-alike vector to a registered player.

private func stored(_ e: Embedding) -> StoredRecognitionTemplates {
    StoredRecognitionTemplates(faceEmbedding: nil, appearanceEmbedding: try! EmbeddingCodec.encode([e]),
                               optedInAt: .now, version: IdentityConsentTerms.current)
}

@MainActor @Suite struct GuestLookalikeTapTests {
    func record(_ s: IdentitySession, _ sample: Embedding) -> UUID {
        let shot = UUID()
        s.record(shot: shot, ShooterIdentification(attribution: .unknown(suggested: Synth.a, confidence: 0.5, shooterTrackID: 1),
                                                   shooterAppearance: sample), expectedShooter: Synth.a)
        return shot
    }

    @Test func unmodelledGuestPresentMeansATapNeverTeaches() {
        // We can't measure how much the vector looks like the guest, so it is never learned (the tap still credits A).
        let s = IdentitySession(players: [(Synth.a, stored(Synth.axis(1, model: bodyModel)))], guests: [Synth.d],
                                faceModelID: faceModel, bodyModelID: bodyModel)
        let shot = record(s, Synth.near(1, cos: 0.97, other: 9, model: bodyModel))
        #expect(s.correct(shot: shot, to: Synth.a)?.playerID == Synth.a)
        #expect(s.snapshot().appearanceGallery[Synth.a] == [Synth.axis(1, model: bodyModel)])
        #expect(s.pendingSampleCount == 0)
    }

    @Test func sampleAsLikeTheGuestAsThePlayerIsNotLearned() {
        let s = IdentitySession(players: [(Synth.a, stored(Synth.axis(1, model: bodyModel)))], guests: [Synth.d],
                                faceModelID: faceModel, bodyModelID: bodyModel)
        s.grantGuestClothesConsent(Synth.d)
        s.bind(Synth.d, appearance: Synth.near(1, cos: 0.9, other: 2, model: bodyModel))   // guest looks like A
        let shot = record(s, Synth.near(1, cos: 0.95, other: 2, model: bodyModel))
        _ = s.correct(shot: shot, to: Synth.a)
        #expect(s.snapshot().appearanceGallery[Synth.a] == [Synth.axis(1, model: bodyModel)])
    }

    @Test func sampleClearlyMoreLikeThePlayerThanEveryModelledGuestIsLearned() {
        let s = IdentitySession(players: [(Synth.a, stored(Synth.axis(1, model: bodyModel)))], guests: [Synth.d],
                                faceModelID: faceModel, bodyModelID: bodyModel)
        s.grantGuestClothesConsent(Synth.d)
        s.bind(Synth.d, appearance: Synth.axis(5, model: bodyModel))                        // guest looks different
        let sample = Synth.near(1, cos: 0.95, other: 9, model: bodyModel)
        let shot = record(s, sample)
        _ = s.correct(shot: shot, to: Synth.a)
        #expect(s.snapshot().appearanceGallery[Synth.a]?.contains(sample.normalised!) == true)
    }
}

@Suite struct HeldOutShipGateTests {
    static func subjects(_ n: Int, spread: Float, seed: UInt64 = 7) -> [[Embedding]] {
        var rng = StressRNG(seed: seed)
        return (0..<n).map { i in (0..<12).map { _ in
            var v = [Float](repeating: 0, count: 64); v[i] = 1
            for k in v.indices { v[k] += Float(rng.uniform(-Double(spread)...Double(spread))) }
            return Embedding(modelID: "m", vector: v).normalised!
        } }
    }

    @Test func splitIsDisjointAndCoversEveryone() {
        let (cal, rep) = FaceBenchmark.split(Array(0..<21))
        #expect(Set(cal).isDisjoint(with: Set(rep)))
        #expect(Set(cal + rep) == Set(0..<21))
        #expect(abs(cal.count - rep.count) <= 1)
    }

    @Test func wilsonUpperBoundIsSane() {
        #expect(abs(FaceBenchmark.wilsonUpper(successes: 0, n: 200) - 0.0188) < 0.001)
        #expect(FaceBenchmark.wilsonUpper(successes: 5, n: 10) > 0.5)
        #expect(FaceBenchmark.wilsonUpper(successes: 0, n: 0) == 1)
    }

    @Test func passReportsHeldOutMetricsWithIntervalsAndCoverage() {
        guard case .pass(let r) = FaceBenchmark.evaluate(subjects: Self.subjects(20, spread: 0.05), modelID: "m") else {
            Issue.record("expected pass"); return
        }
        #expect(r.calibrationSubjects + r.reportSubjects == 20 && r.calibrationSubjects >= 10)
        #expect(r.fpirUpper95 >= r.fpir && r.fpirUpper95 < 0.05)
        #expect(r.misidentificationUpper95 >= 0)
        #expect(r.tarLower95 <= r.tar)
        #expect(r.coverage > 0.9 && r.coverage <= 1)
    }

    @Test func confusablePairInTheReportHalfFailsEvenWhenTheCalibrationHalfIsClean() {
        // Indices 1 and 3 both land in the report half; the threshold is fitted without ever seeing them.
        var s = Self.subjects(20, spread: 0.05)
        s[3] = s[1].map { e in var v = e.vector; v[3] += 0.02; return Embedding(modelID: "m", vector: v).normalised! }
        let (_, rep) = FaceBenchmark.split(Array(0..<20))
        #expect(rep.contains(1) && rep.contains(3))
        if case .pass = FaceBenchmark.evaluate(subjects: s, modelID: "m") { Issue.record("confusable report pair must fail") }
    }

    @Test func tooFewVolunteersForTwoDisjointHalvesIsInsufficient() {
        #expect(FaceBenchmark.evaluate(subjects: Self.subjects(12, spread: 0.05), modelID: "m") == .insufficientData)
    }
}

import Foundation
import CoreGraphics
import Testing
@testable import CueCoach

// Codex round-3 findings (identity-r3-codex.md), fixed test-first.

private let clothes = RecognitionConsent(clothes: true, face: false)

private func stored(body: [Embedding]) -> StoredRecognitionTemplates {
    StoredRecognitionTemplates(faceEmbedding: nil, appearanceEmbedding: try! EmbeddingCodec.encode(body),
                               optedInAt: Date(timeIntervalSince1970: 0), version: IdentityConsentTerms.current)
}

@Suite struct GuestNeverAutoTests {
    @Test func identityFaceNeverAutoCreditsARegisteredPlayerWhileAGuestIsPresent() {
        // r3 BLOCKER: even an identity model has false accepts at FAR 1e-3; with a guest at the table, ask.
        let r = IdentityRoster(entries: [RosterEntry(playerID: Synth.a, consent: .init(clothes: false, face: true)),
                                         RosterEntry(playerID: Synth.d, isGuest: true)])
        var trained = ShooterAttributor(); trained.parameters.face = ShooterAttributionTests.identityFace
        let out = trained.attribute(views: [[TrackEvidence(trackID: 1, poseScore: 0.95, distanceToCueBall: 0.05,
                                                           faceSimilarity: [Synth.a: 0.99])]],
                                    context: AttributionContext(roster: r, expectedShooter: Synth.a))
        #expect(out.source == .unknown && out.playerID == nil)
    }
}

@MainActor @Suite struct TapTeachingTests {
    @Test func aMisTapCannotBindAnUnlikeVectorWhileSomeoneUnconsentedIsAtTheTable() {
        // r3 BLOCKER: a guest is present; the held sample only weakly resembles A. A tap "A" must not teach A.
        let s = IdentitySession(players: [(Synth.a, stored(body: [Synth.axis(1, model: bodyModel)])),
                                          (Synth.b, stored(body: [Synth.axis(2, model: bodyModel)]))],
                                guests: [Synth.d], faceModelID: faceModel, bodyModelID: bodyModel)
        let shot = UUID()
        let guestLook = Synth.near(2, cos: 0.7, other: 9, model: bodyModel)   // held: resembles B
        s.record(shot: shot, ShooterIdentification(attribution: .unknown(suggested: Synth.a, confidence: 0.5, shooterTrackID: 1),
                                                   shooterAppearance: guestLook), expectedShooter: Synth.a)
        _ = s.correct(shot: shot, to: Synth.a)
        #expect(s.snapshot().appearanceGallery[Synth.a] == [Synth.axis(1, model: bodyModel)])
    }

    @Test func ceilingIsRetractedWhenTheShotIsTappedBack() {
        let s = IdentitySession(players: [(Synth.a, stored(body: [Synth.axis(1, model: bodyModel)])), (Synth.b, nil)],
                                faceModelID: faceModel, bodyModelID: bodyModel)
        let shot = UUID()
        s.record(shot: shot, ShooterIdentification(
            attribution: Attribution(playerID: Synth.a, source: .auto, confidence: 0.9, shooterTrackID: 1), shooterAppearance: nil,
            evidence: [TrackEvidence(trackID: 1, poseScore: 0.95, distanceToCueBall: 0.05, appearanceSimilarity: [Synth.a: 0.9])]),
            expectedShooter: Synth.a)
        _ = s.correct(shot: shot, to: Synth.b)
        #expect(s.snapshot().appearanceClaimCeiling[Synth.a] == 0.9)
        _ = s.correct(shot: shot, to: Synth.a)   // mis-tap undone
        #expect(s.snapshot().appearanceClaimCeiling[Synth.a] == nil)
    }
}

/// Cropper returning a fixed set of faces for any image.
struct FixedCropper: FaceCropping {
    let count: Int
    func faces(in image: CGImage) async -> [AlignedFace] {
        (0..<count).map { k in AlignedFace(image: testImage(width: 112, height: 112), box: .zero, quality: 0.9,
                                           interOcularPixels: 40 + Double(k)) }
    }
}

@Suite struct RegistrationFaceOwnershipTests {
    @Test func aFrameWithMoreThanOneAdmissibleFaceIsNeverEnrolled() async throws {
        // r3 BLOCKER: another person in the selfie frame must not be enrolled as the owner.
        guard let model = FaceEmbeddingExtractor.bundled() else { return }   // needs the installed model
        let two = AlignedFaceExtractor(cropper: FixedCropper(count: 2), embedder: model)
        await #expect(throws: AlignedFaceExtractor.Failure.notExactlyOneFace) {
            _ = try await two.embedding(of: testImage(width: 8))
        }
        let one = AlignedFaceExtractor(cropper: FixedCropper(count: 1), embedder: model)
        #expect(try await one.embedding(of: testImage(width: 8)).vector.count == 512)
    }
}

@MainActor @Suite struct RegistrationRound4Tests {
    let capture = RegistrationCapture(faceImages: (0..<4).map { _ in testImage(width: 3) },
                                      bodyImages: (0..<6).map { _ in testImage(width: 5) })

    @Test func deleteStopsExtractionImmediately() async throws {
        let stack = try PersistenceStack(inMemory: true)
        let owner = Fixture.owner(); stack.competitiveContext.insert(owner); try stack.competitiveContext.save()
        let body = DeletingExtractor(modelID: bodyModel) { try? IdentityPrivacy.deleteMyRecognitionData(stack: stack, session: nil) { _ in } }
        let counter = SpyExtractor(modelID: bodyModel)
        struct Both: EmbeddingExtracting {
            let a: DeletingExtractor, b: SpyExtractor
            var modelID: String { a.modelID }
            func embedding(of image: CGImage) async throws -> Embedding { _ = try await b.embedding(of: image); return try await a.embedding(of: image) }
        }
        await #expect(throws: RegistrationError.deletedDuringRegistration) {
            try await RecognitionRegistrar(stack: stack, face: nil, body: Both(a: body, b: counter))
                .register(owner, decision: ConsentDecision(consent: clothes, agreedAt: .now), capture: capture)
        }
        #expect(counter.calls == 1)   // no further images embedded after the delete
    }

    @Test func outdatedTermsAreRefusedBeforeAnyProcessing() async throws {
        let stack = try PersistenceStack(inMemory: true)
        let owner = Fixture.owner(); stack.competitiveContext.insert(owner); try stack.competitiveContext.save()
        let body = SpyExtractor(modelID: bodyModel)
        var d = ConsentDecision(consent: clothes, agreedAt: .now); d.termsVersion = IdentityConsentTerms.current - 1
        await #expect(throws: RegistrationError.consentOutdated) {
            try await RecognitionRegistrar(stack: stack, face: nil, body: body).register(owner, decision: d, capture: capture)
        }
        #expect(try body.calls == 0 && stack.recognition(for: owner.id) == nil)
    }

    @Test func futureTermsVersionAlsoNeedsReconsent() {
        let r = StoredRecognitionTemplates(faceEmbedding: nil, appearanceEmbedding: try! EmbeddingCodec.encode([Synth.axis(1, model: bodyModel)]),
                                           optedInAt: .now, version: IdentityConsentTerms.current + 1)
        #expect(IdentityConsentTerms.needsReconsent(r, faceModelID: faceModel, bodyModelID: bodyModel))
    }

    @Test func deletionGoesThroughTheTemplateStore() throws {
        // r3 MAJOR: delete targets the same store registration writes to.
        final class MemoryStore: RecognitionTemplateStore {
            var rows: [UUID: StoredRecognitionTemplates] = [:]
            var deletionGeneration = 0
            func templates(for id: UUID) throws -> StoredRecognitionTemplates? { rows[id] }
            func replaceTemplates(_ t: StoredRecognitionTemplates, for id: UUID) throws { rows[id] = t }
            func deleteTemplates(for ids: Set<UUID>) throws { deletionGeneration += 1; for i in ids { rows[i] = nil } }
        }
        let store = MemoryStore()
        store.rows[Synth.a] = stored(body: [Synth.axis(1, model: bodyModel)])
        let session = IdentitySession(players: [(Synth.a, store.rows[Synth.a])], faceModelID: faceModel, bodyModelID: bodyModel)
        var revoked: [UUID] = []
        try IdentityPrivacy.deleteRecognitionData(of: [Synth.a], store: store, session: session) { revoked.append($0) }
        #expect(store.rows.isEmpty && store.deletionGeneration == 1 && revoked == [Synth.a])
        #expect(session.snapshot().appearanceGallery.isEmpty)
    }
}

@Suite struct ShipGateRound4Tests {
    func subjects(_ n: Int, spread: Float) -> [[Embedding]] {
        var rng = SystemRandomNumberGenerator()
        return (0..<n).map { i in (0..<12).map { _ in
            var v = [Float](repeating: 0, count: 64); v[i] = 1
            for k in v.indices { v[k] += Float.random(in: -spread...spread, using: &rng) }
            return Embedding(modelID: "m", vector: v).normalised!
        } }
    }

    @Test func passReportsHeldOutOpenSetMetrics() {
        guard case .pass(let r) = FaceBenchmark.evaluate(subjects: subjects(12, spread: 0.05), modelID: "m") else {
            Issue.record("expected pass"); return
        }
        #expect(r.fpir <= FaceBenchmark.maxFPIR)
        #expect(r.misidentifications == 0)
        #expect(r.folds >= 3)
    }

    @Test func aGuestLikeConfusableSetFailsTheOpenSetGateEvenIfVerificationLooksFine() {
        // Two subjects are near-identical twins: verification TAR stays high, but a held-out twin matches the other.
        var s = subjects(12, spread: 0.05)
        s[1] = s[0].map { e in var v = e.vector; v[1] += 0.02; return Embedding(modelID: "m", vector: v).normalised! }
        if case .pass = FaceBenchmark.evaluate(subjects: s, modelID: "m") { Issue.record("twins must fail the open-set gate") }
    }

    @MainActor @Test func benchmarkNeedsItsOwnConsentAndExpires() {
        let bench = FaceBenchmarkSession(modelID: "m", startedAt: Date(timeIntervalSince1970: 0))
        let t0 = Date(timeIntervalSince1970: 0)
        #expect(bench.addSubject([Synth.axis(1, model: "m")], consent: nil, now: t0) == nil)
        #expect(bench.addSubject([Synth.axis(1, model: "m")], consent: FaceBenchConsent(agreedAt: t0), now: t0) != nil)
        #expect(bench.subjectCount(now: t0) == 1)
        bench.expireIfNeeded(now: Date(timeIntervalSince1970: 8 * 86_400))
        #expect(bench.subjectCount == 0)
    }
}

// Codex round-3b follow-ups.
@MainActor @Suite struct Round3bTests {
    @Test func facesFromDifferentPeopleAcrossFramesAreNeverEnrolled() async throws {
        let stack = try PersistenceStack(inMemory: true)
        let owner = Fixture.owner(); stack.competitiveContext.insert(owner); try stack.competitiveContext.save()
        // SpyExtractor: width → axis. Frames 3,3,3,7: the fourth face is someone else (orthogonal).
        let mixed = RegistrationCapture(faceImages: [3, 3, 3, 7].map { testImage(width: $0) }, bodyImages: [])
        await #expect(throws: RegistrationError.inconsistentFaces) {
            try await RecognitionRegistrar(stack: stack, face: SpyExtractor(modelID: faceModel), body: SpyExtractor(modelID: bodyModel))
                .register(owner, decision: ConsentDecision(consent: .init(clothes: false, face: true), agreedAt: .now), capture: mixed)
        }
        #expect((try stack.recognition(for: owner.id)) == nil)
    }

    @Test func aGuestAtTheTableAlwaysNeedsResemblanceForATapToTeach() {
        // Guest D granted session clothes consent → everyone consented, but D is still a guest.
        let body = try! EmbeddingCodec.encode([Synth.axis(1, model: bodyModel)])
        let s = IdentitySession(players: [(Synth.a, StoredRecognitionTemplates(faceEmbedding: nil, appearanceEmbedding: body,
                                                                               optedInAt: .now, version: IdentityConsentTerms.current))],
                                guests: [Synth.d], faceModelID: faceModel, bodyModelID: bodyModel)
        s.grantGuestClothesConsent(Synth.d)
        let shot = UUID()
        let unlike = Synth.axis(9, model: bodyModel)
        s.record(shot: shot, ShooterIdentification(attribution: .unknown(suggested: Synth.a, confidence: 0.5, shooterTrackID: 1),
                                                   shooterAppearance: unlike), expectedShooter: Synth.a)
        _ = s.correct(shot: shot, to: Synth.a)
        #expect(s.snapshot().appearanceGallery[Synth.a] == [Synth.axis(1, model: bodyModel)])
    }

    @Test func idleBenchmarkExpiresOnAnyRead() {
        let t0 = Date(timeIntervalSince1970: 0)
        let bench = FaceBenchmarkSession(modelID: "m", startedAt: t0)
        _ = bench.addSubject([Synth.axis(1, model: "m")], consent: FaceBenchConsent(agreedAt: t0), now: t0)
        #expect(bench.subjectCount(now: Date(timeIntervalSince1970: 8 * 86_400)) == 0)
    }
}

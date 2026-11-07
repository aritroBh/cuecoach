import Foundation
import CoreGraphics
import SwiftData
import Testing
@testable import CueCoach

/// A blank CGImage whose width encodes which synthetic identity it "shows".
func testImage(width: Int, height: Int = 8) -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.3, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage()!
}

/// Fake extractor: image width w → unit vector on axis (w % 16). Counts calls.
final class SpyExtractor: EmbeddingExtracting, @unchecked Sendable {
    let modelID: String
    private let lock = NSLock()
    private var _calls = 0
    var calls: Int { lock.withLock { _calls } }
    init(modelID: String) { self.modelID = modelID }
    func embedding(of image: CGImage) async throws -> Embedding {
        lock.withLock { _calls += 1 }
        return Synth.axis(image.width % Synth.dim, model: modelID)
    }
}

let faceModel = "fake.face.v1"
let bodyModel = "fake.body.v1"

@MainActor
@Suite struct RegistrationTests {
    func setup() throws -> (PersistenceStack, PlayerProfile, SpyExtractor, SpyExtractor) {
        let stack = try PersistenceStack(inMemory: true)
        let owner = Fixture.owner()
        stack.competitiveContext.insert(owner)
        try stack.competitiveContext.save()
        return (stack, owner, SpyExtractor(modelID: faceModel), SpyExtractor(modelID: bodyModel))
    }
    let capture = RegistrationCapture(faceImages: (0..<4).map { _ in testImage(width: 3) },
                                      bodyImages: (0..<4).map { _ in testImage(width: 5) })

    @Test func noConsentMeansNoProcessingAndNothingStored() async throws {
        let (stack, owner, face, body) = try setup()
        let reg = RecognitionRegistrar(stack: stack, face: face, body: body)
        await #expect(throws: RegistrationError.consentRequired) {
            try await reg.register(owner, decision: ConsentDecision(consent: .none, agreedAt: Fixture.t0), capture: capture)
        }
        #expect(face.calls == 0 && body.calls == 0)
        #expect(owner.recognition == nil)
        #expect(try Fixture.count(RecognitionData.self, stack.competitiveContext) == 0)
    }

    @Test func clothesOnlyConsentNeverTouchesFaceImages() async throws {
        let (stack, owner, face, body) = try setup()
        let reg = RecognitionRegistrar(stack: stack, face: face, body: body)
        try await reg.register(owner, decision: ConsentDecision(consent: .init(clothes: true, face: false), agreedAt: Fixture.t0),
                               capture: capture)
        #expect(face.calls == 0)
        #expect(body.calls == 4)
        let r = try #require(owner.recognition)
        #expect(r.faceEmbedding == nil)
        #expect(EmbeddingCodec.decodeOrNil(r.appearanceEmbedding)?.first == Synth.axis(5, model: bodyModel))
        #expect(r.optedInAt == Fixture.t0)
    }

    @Test func faceAndClothesConsentStoresBoth() async throws {
        let (stack, owner, face, body) = try setup()
        let reg = RecognitionRegistrar(stack: stack, face: face, body: body)
        try await reg.register(owner, decision: ConsentDecision(consent: .init(clothes: true, face: true), agreedAt: Fixture.t0),
                               capture: capture)
        let t = IdentityTemplates(owner.recognition, faceModelID: faceModel, bodyModelID: bodyModel)
        #expect(t.face.count == 4 && t.body.count == 4)
        #expect(RecognitionConsent(faceData: owner.recognition?.faceEmbedding, appearanceData: owner.recognition?.appearanceEmbedding)
                == .init(clothes: true, face: true))
    }

    @Test func registrationOnlyForTheLocalOwner() async throws {
        let (stack, _, face, body) = try setup()
        let peer = PlayerProfile(name: "Sam", avatarSymbol: "star", avatarColor: "red", isSessionGuest: true)
        stack.competitiveContext.insert(peer)
        let reg = RecognitionRegistrar(stack: stack, face: face, body: body)
        await #expect(throws: RegistrationError.notLocalOwner) {
            try await reg.register(peer, decision: ConsentDecision(consent: .init(clothes: true, face: true), agreedAt: .now),
                                   capture: capture)
        }
        #expect(peer.recognition == nil)
    }

    @Test func tooFewSamplesIsRejectedAndNothingStored() async throws {
        let (stack, owner, face, body) = try setup()
        let reg = RecognitionRegistrar(stack: stack, face: face, body: body)
        await #expect(throws: RegistrationError.notEnoughSamples) {
            try await reg.register(owner, decision: ConsentDecision(consent: .init(clothes: true, face: false), agreedAt: .now),
                                   capture: RegistrationCapture(faceImages: [], bodyImages: [testImage(width: 5)]))
        }
        #expect(owner.recognition == nil)
    }

    @Test func reRegistrationReplacesTheOldRow() async throws {
        let (stack, owner, face, body) = try setup()
        let reg = RecognitionRegistrar(stack: stack, face: face, body: body)
        try await reg.register(owner, decision: ConsentDecision(consent: .init(clothes: true, face: true), agreedAt: .now), capture: capture)
        try await reg.register(owner, decision: ConsentDecision(consent: .init(clothes: true, face: false), agreedAt: .now), capture: capture)
        #expect(try Fixture.count(RecognitionData.self, stack.competitiveContext) == 1)
        #expect(owner.recognition?.faceEmbedding == nil)
    }

    @Test func templatesFromAnotherModelAreIgnored() async throws {
        let (stack, owner, face, body) = try setup()
        try await RecognitionRegistrar(stack: stack, face: face, body: body)
            .register(owner, decision: ConsentDecision(consent: .init(clothes: true, face: true), agreedAt: .now), capture: capture)
        let t = IdentityTemplates(owner.recognition, faceModelID: "face.v2", bodyModelID: bodyModel)
        #expect(t.face.isEmpty)
        #expect(t.body.count == 4)
    }

    @Test func deleteWipesStorageSessionTemplatesAndEmitsRevoke() async throws {
        let (stack, owner, face, body) = try setup()
        try await RecognitionRegistrar(stack: stack, face: face, body: body)
            .register(owner, decision: ConsentDecision(consent: .init(clothes: true, face: true), agreedAt: .now), capture: capture)
        let session = IdentitySession(profiles: [owner], faceModelID: faceModel, bodyModelID: bodyModel)
        #expect(session.snapshot().roster.consent(of: owner.id) == .init(clothes: true, face: true))
        var revoked: [UUID] = []
        try IdentityPrivacy.deleteMyRecognitionData(stack: stack, session: session) { revoked.append($0) }
        #expect(owner.recognition == nil)
        #expect(try Fixture.count(RecognitionData.self, stack.competitiveContext) == 0)
        let snap = session.snapshot()
        #expect(snap.roster.consent(of: owner.id) == .none)
        #expect(snap.appearanceGallery[owner.id] == nil && snap.faceGallery[owner.id] == nil)
        #expect(revoked == [owner.id])
        // Profile + history untouched.
        #expect(try Fixture.count(PlayerProfile.self, stack.competitiveContext) == 1)
    }
}

@MainActor
@Suite struct IdentitySessionTests {
    func consentedProfile(_ id: UUID, body axis: Int, face: Int? = nil) -> PlayerProfile {
        let p = PlayerProfile(id: id, name: "P", avatarSymbol: "star", avatarColor: "red", isSessionGuest: true)
        p.recognition = RecognitionData(
            faceEmbedding: face.map { try! EmbeddingCodec.encode([Synth.axis($0, model: faceModel)]) },
            appearanceEmbedding: try! EmbeddingCodec.encode([Synth.axis(axis, model: bodyModel)]),
            optedInAt: Fixture.t0, version: EmbeddingCodec.formatVersion)
        return p
    }
    func plain(_ id: UUID) -> PlayerProfile { PlayerProfile(id: id, name: "Q", avatarSymbol: "star", avatarColor: "blue") }

    @Test func rosterAndGalleriesComeFromStoredConsentOnly() {
        let s = IdentitySession(profiles: [consentedProfile(Synth.a, body: 1, face: 2), plain(Synth.b)],
                                guests: [Synth.c], faceModelID: faceModel, bodyModelID: bodyModel)
        let snap = s.snapshot()
        #expect(snap.roster.ids.sorted { $0.uuidString < $1.uuidString } == [Synth.a, Synth.b, Synth.c])
        #expect(snap.appearanceGallery.keys.sorted { $0.uuidString < $1.uuidString } == [Synth.a])
        #expect(snap.faceGallery.keys.sorted { $0.uuidString < $1.uuidString } == [Synth.a])
        #expect(snap.roster.entries.first { $0.playerID == Synth.c }?.isGuest == true)
        #expect(snap.roster.consent(of: Synth.c) == .none)
    }

    @Test func bindOnlyWorksForClothesConsentedPlayers() {
        let s = IdentitySession(profiles: [consentedProfile(Synth.a, body: 1), plain(Synth.b)],
                                faceModelID: faceModel, bodyModelID: bodyModel)
        #expect(s.bind(Synth.a, appearance: Synth.axis(4, model: bodyModel)))
        #expect(!s.bind(Synth.b, appearance: Synth.axis(5, model: bodyModel)))
        #expect(s.snapshot().appearanceGallery[Synth.a]?.contains(Synth.axis(4, model: bodyModel)) == true)
        #expect(s.snapshot().appearanceGallery[Synth.b] == nil)
        #expect(!s.bind(Synth.a, appearance: Synth.axis(4, model: "other")))
    }

    @Test func galleryIsCappedAndKeepsTheRegistrationSeed() {
        let s = IdentitySession(profiles: [consentedProfile(Synth.a, body: 1)], faceModelID: faceModel, bodyModelID: bodyModel)
        for i in 0..<20 { _ = s.bind(Synth.a, appearance: Synth.near(2, cos: 0.9, other: 3 + i % 10, model: bodyModel)) }
        let g = s.snapshot().appearanceGallery[Synth.a]!
        #expect(g.count == IdentitySession.maxExemplars)
        #expect(g.contains(Synth.axis(1, model: bodyModel)))
    }

    @Test func guestSessionConsentIsOffUnlessGranted() {
        let s = IdentitySession(profiles: [], guests: [Synth.c], faceModelID: faceModel, bodyModelID: bodyModel)
        #expect(!s.bind(Synth.c, appearance: Synth.axis(1, model: bodyModel)))
        s.grantGuestClothesConsent(Synth.c)
        #expect(s.bind(Synth.c, appearance: Synth.axis(1, model: bodyModel)))
        s.grantGuestClothesConsent(Synth.d)   // not a guest in this session → ignored
        #expect(!s.snapshot().roster.contains(Synth.d))
    }

    @Test func oneTapCorrectionOverridesAndLearnsOnlyForConsented() {
        let s = IdentitySession(profiles: [consentedProfile(Synth.a, body: 1), consentedProfile(Synth.b, body: 2), plain(Synth.c)],
                                faceModelID: faceModel, bodyModelID: bodyModel)
        let shot1 = UUID(), shot2 = UUID()
        s.record(shot: shot1, ShooterIdentification(attribution: Attribution(playerID: Synth.a, source: .auto, confidence: 0.9, shooterTrackID: 1),
                                                    shooterAppearance: Synth.axis(7, model: bodyModel)))
        let fixed = s.correct(shot: shot1, to: Synth.b)
        #expect(fixed == Attribution(playerID: Synth.b, source: .tap, confidence: 1, shooterTrackID: 1))
        #expect(s.attribution(for: shot1)?.source == .tap)
        #expect(s.snapshot().appearanceGallery[Synth.b]?.contains(Synth.axis(7, model: bodyModel)) == true)

        s.record(shot: shot2, ShooterIdentification(attribution: Attribution(playerID: Synth.a, source: .auto, confidence: 0.9, shooterTrackID: 1),
                                                    shooterAppearance: Synth.axis(8, model: bodyModel)))
        _ = s.correct(shot: shot2, to: Synth.c)          // non-consented: no gallery for C, sample dropped
        #expect(s.snapshot().appearanceGallery[Synth.c] == nil)
        #expect(s.correct(shot: UUID(), to: Synth.a) == nil)          // unknown shot
        #expect(s.correct(shot: shot1, to: Synth.d) == nil)           // not in roster
    }

    @Test func correctionStatsReportTapRateAndPreTapAccuracy() {
        let s = IdentitySession(profiles: [plain(Synth.a), plain(Synth.b)], faceModelID: faceModel, bodyModelID: bodyModel)
        for i in 0..<10 {
            s.record(shot: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", i))!,
                     ShooterIdentification(attribution: Attribution(playerID: Synth.a, source: i < 6 ? .auto : .turnOrder,
                                                                    confidence: 0.9, shooterTrackID: nil), shooterAppearance: nil))
        }
        _ = s.correct(shot: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!, to: Synth.b)
        let st = s.stats
        #expect(st.total == 10 && st.tapped == 1)
        #expect(abs(st.correctBeforeTap - 0.9) < 1e-9)
        #expect(st.auto == 6 && st.turnOrder == 4)
    }

    @Test func revokeAndEndClearEverythingInRAM() {
        let s = IdentitySession(profiles: [consentedProfile(Synth.a, body: 1, face: 2), consentedProfile(Synth.b, body: 3)],
                                faceModelID: faceModel, bodyModelID: bodyModel)
        let shot = UUID()
        s.record(shot: shot, ShooterIdentification(attribution: Attribution(playerID: Synth.a, source: .auto, confidence: 0.9, shooterTrackID: 1),
                                                   shooterAppearance: Synth.axis(9, model: bodyModel)))
        s.revoke(Synth.a)
        #expect(s.snapshot().appearanceGallery[Synth.a] == nil)
        #expect(s.snapshot().faceGallery[Synth.a] == nil)
        #expect(!s.bind(Synth.a, appearance: Synth.axis(1, model: bodyModel)))
        #expect(s.pendingSampleCount == 0)
        s.end()
        #expect(s.snapshot().appearanceGallery.isEmpty && s.snapshot().faceGallery.isEmpty)
        #expect(s.snapshot().roster.ids.isEmpty)
    }
}

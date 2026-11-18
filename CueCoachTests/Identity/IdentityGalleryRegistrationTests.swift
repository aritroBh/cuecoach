import Foundation
import SwiftData
import Testing
@testable import CueCoach

/// Integration: Identity's templates live in the backup-excluded recognition store (wt/audit), and every
/// `IdentitySession` built for play registers with the stack, so a one-tap delete, guest purge or promotion
/// clears its in-memory galleries synchronously and Undo reloads them.
@MainActor
@Suite struct IdentityGalleryRegistrationTests {
    let capture = RegistrationCapture(faceImages: (0..<4).map { _ in testImage(width: 3) },
                                      bodyImages: (0..<4).map { _ in testImage(width: 5) })
    let both = RecognitionConsent(clothes: true, face: true)

    func registeredOwner() async throws -> (PersistenceStack, PlayerProfile) {
        let stack = try PersistenceStack(inMemory: true)
        let owner = Fixture.owner()
        stack.competitiveContext.insert(owner)
        try stack.competitiveContext.save()
        try await RecognitionRegistrar(stack: stack, face: SpyExtractor(modelID: faceModel), body: SpyExtractor(modelID: bodyModel))
            .register(owner, decision: ConsentDecision(consent: both, agreedAt: .now), capture: capture)
        return (stack, owner)
    }

    @Test func registrationWritesTheRecognitionStoreNotTheCompetitiveStore() async throws {
        let (stack, owner) = try await registeredOwner()
        #expect(try stack.recognition(for: owner.id)?.appearanceEmbedding != nil)
        #expect(try stack.recognitionContext.fetchCount(FetchDescriptor<RecognitionData>()) == 1)
        // The competitive store (backed up with the device) has no recognition model at all.
        #expect(!PersistenceStack.competitiveModels.contains { $0 == RecognitionData.self })
    }

    @Test func oneTapDeleteClearsTheSessionAndUndoReloadsIt() async throws {
        let (stack, owner) = try await registeredOwner()
        let session = IdentitySession.registered(on: stack, players: [owner.id], guests: [],
                                                 faceModelID: faceModel, bodyModelID: bodyModel)
        #expect(session.snapshot().roster.consent(of: owner.id) == both)
        #expect(session.snapshot().appearanceGallery[owner.id] != nil)

        let undo = try stack.beginRecognitionDeletion()
        var snap = session.snapshot()
        #expect(snap.roster.consent(of: owner.id) == .none)
        #expect(snap.appearanceGallery[owner.id] == nil && snap.faceGallery[owner.id] == nil)

        try stack.undoRecognitionDeletion(undo)
        snap = session.snapshot()
        #expect(snap.roster.consent(of: owner.id) == both)
        #expect(snap.appearanceGallery[owner.id] != nil && snap.faceGallery[owner.id] != nil)

        try stack.deleteMyRecognitionData()
        #expect(session.snapshot().roster.consent(of: owner.id) == .none)
        #expect(session.snapshot().appearanceGallery.isEmpty)
    }

    @Test func purgeAllAlsoDropsSessionOnlyGuestTemplates() async throws {
        let (stack, owner) = try await registeredOwner()
        let guest = UUID()
        let session = IdentitySession.registered(on: stack, players: [owner.id], guests: [guest],
                                                 faceModelID: faceModel, bodyModelID: bodyModel)
        session.grantGuestClothesConsent(guest)
        #expect(session.bind(guest, appearance: Synth.axis(7, model: bodyModel)))
        try stack.deleteMyRecognitionData()
        let snap = session.snapshot()
        #expect(snap.appearanceGallery[guest] == nil)
        #expect(snap.roster.consent(of: guest) == .none)
    }

    @Test func profileDeleteClearsOnlyThatPlayer() async throws {
        let (stack, owner) = try await registeredOwner()
        let other = PlayerProfile(name: "B", avatarSymbol: "s", avatarColor: "c")
        stack.competitiveContext.insert(other)
        try stack.competitiveContext.save()
        try stack.storeRecognition(profileID: other.id, faceEmbedding: nil,
                                   appearanceEmbedding: try EmbeddingCodec.encode([Synth.axis(9, model: bodyModel)]),
                                   optedInAt: .now, version: IdentityConsentTerms.current)
        let session = IdentitySession.registered(on: stack, players: [owner.id, other.id], guests: [],
                                                 faceModelID: faceModel, bodyModelID: bodyModel)
        #expect(session.snapshot().appearanceGallery[other.id] != nil)
        try stack.deleteProfile(other)
        #expect(session.snapshot().appearanceGallery[other.id] == nil)
        #expect(session.snapshot().appearanceGallery[owner.id] != nil)
    }

    @Test func endedSessionIsNotRevivedByUndo() async throws {
        let (stack, owner) = try await registeredOwner()
        let session = IdentitySession.registered(on: stack, players: [owner.id], guests: [],
                                                 faceModelID: faceModel, bodyModelID: bodyModel)
        let undo = try stack.beginRecognitionDeletion()
        session.end()
        try stack.undoRecognitionDeletion(undo)
        #expect(session.snapshot().appearanceGallery.isEmpty)
        #expect(session.snapshot().roster.entries.isEmpty)
    }

    @Test func stagedDeleteAbortsAnInFlightRegistration() async throws {
        let stack = try PersistenceStack(inMemory: true)
        let owner = Fixture.owner()
        stack.competitiveContext.insert(owner)
        try stack.competitiveContext.save()
        let body = DeletingExtractor(modelID: bodyModel) { _ = try? stack.beginRecognitionDeletion() }
        await #expect(throws: RegistrationError.deletedDuringRegistration) {
            try await RecognitionRegistrar(stack: stack, face: nil, body: body)
                .register(owner, decision: ConsentDecision(consent: .init(clothes: true, face: false), agreedAt: .now),
                          capture: capture)
        }
        #expect(try stack.recognition(for: owner.id) == nil)
    }
}

/// Codex integ-wiring rerun MAJOR: withdrawing benchmark consent purges that volunteer's held embeddings at once.
@MainActor
@Suite struct BenchmarkWithdrawalTests {
    @Test func withdrawingConsentPurgesHeldEmbeddings() {
        let s = FaceBenchmarkSession(modelID: "m")
        let keep = FaceBenchConsentFlow.grant(), gone = FaceBenchConsentFlow.grant()
        let e = Embedding(modelID: "m", vector: [1, 0, 0]).normalised!
        s.addSubject([e, e], consent: keep)
        s.addSubject([e, e, e], consent: gone)
        #expect(s.heldEmbeddingCount == 5)
        FaceBenchConsentFlow.withdraw(gone)
        #expect(s.heldEmbeddingCount == 2)
        FaceBenchConsentFlow.withdraw(keep)
    }
}

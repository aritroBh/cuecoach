import Foundation
import CoreGraphics
import SwiftData

// Opt-in registration on the player's own phone (SPEC §2 privacy, §5.8; research §7.1).
// Images are embedded and dropped in the same call; only vectors reach RecognitionData.

/// Image → embedding. The real one wraps Vision (`VisionFeaturePrintExtractor`); tests use fakes.
protocol EmbeddingExtracting: Sendable {
    /// Identifies model + version; templates from another modelID are ignored.
    var modelID: String { get }
    /// True only for a face model trained for identity (AuraFace). Generic feature prints are never registered as
    /// face templates (face-embedding.md F5).
    var isIdentityTrained: Bool { get }
    func embedding(of image: CGImage) async throws -> Embedding
}

extension EmbeddingExtracting {
    var isIdentityTrained: Bool { false }
}

/// Made only by the consent screen's deliberate "Agree" tap.
/// Together with the stored row this is the consent record {type, version, date} (research §7.1):
/// type = which templates exist, version = `RecognitionData.version`, date = `optedInAt`.
struct ConsentDecision: Hashable, Sendable {
    var consent: RecognitionConsent
    var agreedAt: Date
    /// Version of the consent text / data-use terms the player agreed to.
    var termsVersion: Int = IdentityConsentTerms.current
}

/// `RecognitionData.version` is the consent-terms version (the codec format lives inside the blob).
enum IdentityConsentTerms {
    /// Bump when the consent text or how recognition data is used changes.
    static let current = 1

    /// Ask again when the player agreed to older terms, or a model change made a consented template unusable.
    static func needsReconsent(_ r: RecognitionData?, faceModelID: String, bodyModelID: String) -> Bool {
        needsReconsent(r.map(StoredRecognitionTemplates.init), faceModelID: faceModelID, bodyModelID: bodyModelID)
    }

    static func needsReconsent(_ r: StoredRecognitionTemplates?, faceModelID: String, bodyModelID: String) -> Bool {
        guard let r else { return false }
        if r.version != current { return true }
        let t = IdentityTemplates(r, faceModelID: faceModelID, bodyModelID: bodyModelID)
        return (r.faceEmbedding != nil && t.face.isEmpty) || (r.appearanceEmbedding != nil && t.body.isEmpty)
    }
}

struct RegistrationCapture: @unchecked Sendable {
    var faceImages: [CGImage]
    var bodyImages: [CGImage]
}

enum RegistrationError: Error, Equatable {
    case consentRequired
    case notLocalOwner
    case notEnoughSamples
    /// "Delete my recognition data" ran while embeddings were being computed: nothing is written.
    case deletedDuringRegistration
    /// Face consent needs an identity-trained face model; none is installed (or only a generic one was offered).
    case faceModelUnavailable
    /// The face captures are not all the same person (someone else got into a frame): nothing is enrolled.
    case inconsistentFaces
    /// The decision was made on older (or newer) consent terms than this app's: show the current text again.
    case consentOutdated
}

@MainActor
struct RecognitionRegistrar {
    static let minSamples = 3
    static let maxSamples = 12

    let store: any RecognitionTemplateStore
    /// nil when no identity-trained face model is installed: face consent then can't be registered.
    let face: (any EmbeddingExtracting)?
    let body: any EmbeddingExtracting

    init(store: any RecognitionTemplateStore, face: (any EmbeddingExtracting)?, body: any EmbeddingExtracting) {
        self.store = store; self.face = face; self.body = body
    }

    /// Current-store convenience (`PlayerProfile.recognition`). `save` is a seam for tests.
    init(stack: PersistenceStack, face: (any EmbeddingExtracting)?, body: any EmbeddingExtracting,
         save: @escaping @MainActor (ModelContext) throws -> Void = { try $0.save() }) {
        self.init(store: ProfileRecognitionTemplateStore(stack: stack, save: save), face: face, body: body)
    }

    /// Gate: no consent → throws before any image is processed or any row is written. This explicit registration
    /// capture (and a one-tap confirmation later) is the only way a template is ever taught.
    func register(_ owner: PlayerProfile, decision: ConsentDecision, capture: RegistrationCapture) async throws {
        let c = decision.consent
        guard c.clothes || c.face else { throw RegistrationError.consentRequired }
        guard decision.termsVersion == IdentityConsentTerms.current else { throw RegistrationError.consentOutdated }
        guard owner.isLocalOwner else { throw RegistrationError.notLocalOwner }
        if c.face, !(face?.isIdentityTrained ?? false) { throw RegistrationError.faceModelUnavailable }
        if c.face, capture.faceImages.count < Self.minSamples { throw RegistrationError.notEnoughSamples }
        if c.clothes, capture.bodyImages.count < Self.minSamples { throw RegistrationError.notEnoughSamples }

        // A delete that lands during the awaits below must win: never write templates back after it.
        let deletions = store.deletionGeneration
        let faces = c.face ? try await embed(capture.faceImages, with: face!, since: deletions) : nil
        let bodies = c.clothes ? try await embed(capture.bodyImages, with: body, since: deletions) : nil
        if let faces, faces.count < Self.minSamples { throw RegistrationError.notEnoughSamples }
        if let faces, !Self.samePerson(faces) { throw RegistrationError.inconsistentFaces }
        if let bodies, bodies.count < Self.minSamples { throw RegistrationError.notEnoughSamples }

        // Encode before touching the store, so a codec error leaves nothing dirty.
        let faceData = try faces.map(EmbeddingCodec.encode)
        let bodyData = try bodies.map(EmbeddingCodec.encode)
        guard deletions == store.deletionGeneration else { throw RegistrationError.deletedDuringRegistration }
        guard owner.isLocalOwner, owner.modelContext != nil else { throw RegistrationError.notLocalOwner }
        try store.replaceTemplates(StoredRecognitionTemplates(faceEmbedding: faceData, appearanceEmbedding: bodyData,
                                                              optedInAt: decision.agreedAt, version: decision.termsVersion),
                                   for: owner.id)
    }

    /// Every face capture must resemble the others: a different person in one frame fails the whole registration
    /// rather than being enrolled as the owner. Floor is an assumption (identity models put different people near 0);
    /// the §6 benchmark tunes it.
    static let sameFaceFloor = 0.4
    static func samePerson(_ faces: [Embedding]) -> Bool {
        guard let mean = Embedding.mean(faces) else { return false }
        return faces.allSatisfy { ($0.cosine(mean) ?? -1) >= sameFaceFloor }
    }

    /// Stops at once (before the next image) when a delete lands or the task is cancelled (r3 MAJOR).
    private func embed(_ images: [CGImage], with x: any EmbeddingExtracting, since deletions: Int) async throws -> [Embedding] {
        var out: [Embedding] = []
        for img in images.prefix(Self.maxSamples) {
            guard deletions == store.deletionGeneration else { throw RegistrationError.deletedDuringRegistration }
            try Task.checkCancellation()
            if let e = try? await x.embedding(of: img), e.modelID == x.modelID, let n = e.normalised { out.append(n) }
        }
        return out
    }
}

/// Usable templates from a stored row, filtered to the current models.
struct IdentityTemplates: Sendable {
    var face: [Embedding]
    var body: [Embedding]

    init(_ r: RecognitionData?, faceModelID: String, bodyModelID: String) {
        self.init(r.map(StoredRecognitionTemplates.init), faceModelID: faceModelID, bodyModelID: bodyModelID)
    }

    init(_ r: StoredRecognitionTemplates?, faceModelID: String, bodyModelID: String) {
        face = (EmbeddingCodec.decodeOrNil(r?.faceEmbedding) ?? []).filter { $0.modelID == faceModelID }
        body = (EmbeddingCodec.decodeOrNil(r?.appearanceEmbedding) ?? []).filter { $0.modelID == bodyModelID }
    }
}

@MainActor
enum IdentityPrivacy {
    /// Settings → "Delete my recognition data": wipes the stored template, clears this session's RAM copies,
    /// and calls `onRevoke` per owner so Mesh can send `IdentityRevoke` to peers. `onRevoke` is required: a caller
    /// with no mesh passes an explicit no-op, so peers holding templates in RAM can't be forgotten by omission.
    /// Same, against any template store (the one registration writes to).
    static func deleteRecognitionData(of owners: Set<UUID>, store: some RecognitionTemplateStore, session: IdentitySession?,
                                      onRevoke: (UUID) -> Void) throws {
        try store.deleteTemplates(for: owners)
        for id in owners.sorted(by: { $0.uuidString < $1.uuidString }) { session?.revoke(id); onRevoke(id) }
    }

    static func deleteMyRecognitionData(stack: PersistenceStack, session: IdentitySession?,
                                        onRevoke: (UUID) -> Void) throws {
        let owners = try stack.competitiveContext.fetch(FetchDescriptor<PlayerProfile>(predicate: #Predicate { $0.isLocalOwner }))
        let ids = owners.map(\.id)
        try stack.deleteMyRecognitionData()
        for id in ids { session?.revoke(id); onRevoke(id) }
    }
}

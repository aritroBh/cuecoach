import Foundation
import CoreGraphics
import SwiftData

// Opt-in registration on the player's own phone (SPEC §2 privacy, §5.8; research §7.1).
// Images are embedded and dropped in the same call; only vectors reach RecognitionData.

/// Image → embedding. The real one wraps Vision (`VisionFeaturePrintExtractor`); tests use fakes.
protocol EmbeddingExtracting: Sendable {
    /// Identifies model + version; templates from another modelID are ignored.
    var modelID: String { get }
    func embedding(of image: CGImage) async throws -> Embedding
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
        guard let r else { return false }
        if r.version < current { return true }
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
}

@MainActor
struct RecognitionRegistrar {
    static let minSamples = 3
    static let maxSamples = 12

    let stack: PersistenceStack
    let face: any EmbeddingExtracting
    let body: any EmbeddingExtracting
    /// Seam for tests (a failing save). Production always uses `ModelContext.save`.
    var save: @MainActor (ModelContext) throws -> Void = { try $0.save() }

    /// Gate: no consent → throws before any image is processed or any row is written.
    func register(_ owner: PlayerProfile, decision: ConsentDecision, capture: RegistrationCapture) async throws {
        let c = decision.consent
        guard c.clothes || c.face else { throw RegistrationError.consentRequired }
        guard owner.isLocalOwner else { throw RegistrationError.notLocalOwner }
        if c.face, capture.faceImages.count < Self.minSamples { throw RegistrationError.notEnoughSamples }
        if c.clothes, capture.bodyImages.count < Self.minSamples { throw RegistrationError.notEnoughSamples }

        // A delete that lands during the awaits below must win: never write templates back after it.
        let deletions = RecognitionDeletionLog.generation
        let faces = c.face ? try await embed(capture.faceImages, with: face) : nil
        let bodies = c.clothes ? try await embed(capture.bodyImages, with: body) : nil
        if let faces, faces.count < Self.minSamples { throw RegistrationError.notEnoughSamples }
        if let bodies, bodies.count < Self.minSamples { throw RegistrationError.notEnoughSamples }

        // Encode before touching the store, so a codec error leaves nothing dirty.
        let faceData = try faces.map(EmbeddingCodec.encode)
        let bodyData = try bodies.map(EmbeddingCodec.encode)
        guard deletions == RecognitionDeletionLog.generation else { throw RegistrationError.deletedDuringRegistration }
        guard owner.isLocalOwner, owner.modelContext != nil else { throw RegistrationError.notLocalOwner }
        let ctx = stack.competitiveContext
        if let old = owner.recognition { owner.recognition = nil; ctx.delete(old) }
        let row = RecognitionData(faceEmbedding: faceData, appearanceEmbedding: bodyData,
                                  optedInAt: decision.agreedAt, version: decision.termsVersion)
        ctx.insert(row)
        owner.recognition = row
        do { try save(ctx) } catch {
            // Never leave "old row deleted, new row inserted" pending for some later save to commit.
            ctx.rollback()
            throw error
        }
    }

    private func embed(_ images: [CGImage], with x: any EmbeddingExtracting) async throws -> [Embedding] {
        var out: [Embedding] = []
        for img in images.prefix(Self.maxSamples) {
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
        face = (EmbeddingCodec.decodeOrNil(r?.faceEmbedding) ?? []).filter { $0.modelID == faceModelID }
        body = (EmbeddingCodec.decodeOrNil(r?.appearanceEmbedding) ?? []).filter { $0.modelID == bodyModelID }
    }
}

@MainActor
enum IdentityPrivacy {
    /// Settings → "Delete my recognition data": wipes the stored template, clears this session's RAM copies,
    /// and calls `onRevoke` per owner so Mesh can send `IdentityRevoke` to peers. `onRevoke` is required: a caller
    /// with no mesh passes an explicit no-op, so peers holding templates in RAM can't be forgotten by omission.
    static func deleteMyRecognitionData(stack: PersistenceStack, session: IdentitySession?,
                                        onRevoke: (UUID) -> Void) throws {
        let owners = try stack.competitiveContext.fetch(FetchDescriptor<PlayerProfile>(predicate: #Predicate { $0.isLocalOwner }))
        let ids = owners.map(\.id)
        try stack.deleteMyRecognitionData()
        for id in ids { session?.revoke(id); onRevoke(id) }
    }
}

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
struct ConsentDecision: Hashable, Sendable {
    var consent: RecognitionConsent
    var agreedAt: Date
}

struct RegistrationCapture: @unchecked Sendable {
    var faceImages: [CGImage]
    var bodyImages: [CGImage]
}

enum RegistrationError: Error, Equatable {
    case consentRequired
    case notLocalOwner
    case notEnoughSamples
}

@MainActor
struct RecognitionRegistrar {
    static let minSamples = 3
    static let maxSamples = 12

    let stack: PersistenceStack
    let face: any EmbeddingExtracting
    let body: any EmbeddingExtracting

    /// Gate: no consent → throws before any image is processed or any row is written.
    func register(_ owner: PlayerProfile, decision: ConsentDecision, capture: RegistrationCapture) async throws {
        let c = decision.consent
        guard c.clothes || c.face else { throw RegistrationError.consentRequired }
        guard owner.isLocalOwner else { throw RegistrationError.notLocalOwner }
        if c.face, capture.faceImages.count < Self.minSamples { throw RegistrationError.notEnoughSamples }
        if c.clothes, capture.bodyImages.count < Self.minSamples { throw RegistrationError.notEnoughSamples }

        let faces = c.face ? try await embed(capture.faceImages, with: face) : nil
        let bodies = c.clothes ? try await embed(capture.bodyImages, with: body) : nil
        if let faces, faces.count < Self.minSamples { throw RegistrationError.notEnoughSamples }
        if let bodies, bodies.count < Self.minSamples { throw RegistrationError.notEnoughSamples }

        let ctx = stack.competitiveContext
        if let old = owner.recognition { owner.recognition = nil; ctx.delete(old) }
        let row = RecognitionData(faceEmbedding: try faces.map(EmbeddingCodec.encode),
                                  appearanceEmbedding: try bodies.map(EmbeddingCodec.encode),
                                  optedInAt: decision.agreedAt, version: EmbeddingCodec.formatVersion)
        ctx.insert(row)
        owner.recognition = row
        try ctx.save()
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
    /// and calls `onRevoke` per owner so Mesh can send `IdentityRevoke` to peers.
    static func deleteMyRecognitionData(stack: PersistenceStack, session: IdentitySession?,
                                        onRevoke: (UUID) -> Void = { _ in }) throws {
        let owners = try stack.competitiveContext.fetch(FetchDescriptor<PlayerProfile>(predicate: #Predicate { $0.isLocalOwner }))
        let ids = owners.map(\.id)
        try stack.deleteMyRecognitionData()
        for id in ids { session?.revoke(id); onRevoke(id) }
    }
}

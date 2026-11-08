import Foundation
import SwiftData

// Where consented recognition templates live (D26: on the phone, no expiry, backup-excluded, one-tap delete).
// Identity codes against this small protocol only. Today's adapter maps it onto `PlayerProfile.recognition`;
// the privacy worker's backup-excluded Recognition store (wt/audit) conforms instead at merge time.

/// Value copy of one profile's stored templates. Consent record = {which blobs exist, `version`, `optedInAt`}.
struct StoredRecognitionTemplates: Hashable, Sendable {
    var faceEmbedding: Data?
    var appearanceEmbedding: Data?
    var optedInAt: Date
    /// Consent-terms version (`IdentityConsentTerms.current` when written).
    var version: Int
}

@MainActor
protocol RecognitionTemplateStore {
    func templates(for profileID: UUID) throws -> StoredRecognitionTemplates?
    /// Replaces the profile's templates in one commit; on failure nothing changes.
    func replaceTemplates(_ t: StoredRecognitionTemplates, for profileID: UUID) throws
    /// One-tap delete for these profiles; bumps `deletionGeneration` first so in-flight registrations abort.
    func deleteTemplates(for profileIDs: Set<UUID>) throws
    /// Bumped by every "delete recognition data", so an in-flight registration can tell it was overtaken.
    var deletionGeneration: Int { get }
}

extension StoredRecognitionTemplates {
    init(_ r: RecognitionData) {
        self.init(faceEmbedding: r.faceEmbedding, appearanceEmbedding: r.appearanceEmbedding, optedInAt: r.optedInAt,
                  version: r.version)
    }
}

/// Adapter over the current competitive store (`PlayerProfile.recognition`). Replaced at merge by the
/// backup-excluded recognition store; nothing else in Identity touches SwiftData for templates.
@MainActor
struct ProfileRecognitionTemplateStore: RecognitionTemplateStore {
    let stack: PersistenceStack
    /// Seam for tests (a failing save). Production always uses `ModelContext.save`.
    var save: @MainActor (ModelContext) throws -> Void = { try $0.save() }

    private func profile(_ id: UUID) throws -> PlayerProfile? {
        try stack.competitiveContext.fetch(FetchDescriptor<PlayerProfile>(predicate: #Predicate { $0.id == id })).first
    }

    func templates(for profileID: UUID) throws -> StoredRecognitionTemplates? {
        try profile(profileID)?.recognition.map(StoredRecognitionTemplates.init)
    }

    func replaceTemplates(_ t: StoredRecognitionTemplates, for profileID: UUID) throws {
        let ctx = stack.competitiveContext
        guard let owner = try profile(profileID) else { throw RegistrationError.notLocalOwner }
        if let old = owner.recognition { owner.recognition = nil; ctx.delete(old) }
        let row = RecognitionData(faceEmbedding: t.faceEmbedding, appearanceEmbedding: t.appearanceEmbedding,
                                  optedInAt: t.optedInAt, version: t.version)
        ctx.insert(row)
        owner.recognition = row
        do { try save(ctx) } catch {
            // Never leave "old row deleted, new row inserted" pending for some later save to commit.
            ctx.rollback()
            throw error
        }
    }

    var deletionGeneration: Int { RecognitionDeletionLog.generation }

    func deleteTemplates(for profileIDs: Set<UUID>) throws {
        RecognitionDeletionLog.recordDeletion()
        let ctx = stack.competitiveContext
        for id in profileIDs {
            if let p = try profile(id), let r = p.recognition { p.recognition = nil; ctx.delete(r) }
        }
        try save(ctx)
    }
}

extension IdentitySession {
    /// Convenience for callers holding `PlayerProfile`s from the current store.
    convenience init(profiles: [PlayerProfile], guests: [UUID] = [], faceModelID: String, bodyModelID: String) {
        self.init(players: profiles.map { ($0.id, $0.recognition.map(StoredRecognitionTemplates.init)) }, guests: guests,
                  faceModelID: faceModelID, bodyModelID: bodyModelID)
    }

    func addPlayer(_ p: PlayerProfile) { addPlayer(id: p.id, stored: p.recognition.map(StoredRecognitionTemplates.init)) }

    /// Loads a player from any template store (reads only; the session never writes).
    func addPlayer(id: UUID, from store: some RecognitionTemplateStore) {
        addPlayer(id: id, stored: (try? store.templates(for: id)) ?? nil)
    }
}

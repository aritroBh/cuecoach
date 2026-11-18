import Foundation
import SwiftData

// Where consented recognition templates live (D26: on the phone, no expiry, backup-excluded, one-tap delete).
// Identity codes against this small protocol only; `StackRecognitionTemplateStore` maps it onto the privacy
// worker's backup-excluded recognition store (wt/audit).

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

/// Adapter over the backup-excluded recognition store (`PersistenceStack`, wt/audit): one row per profile in
/// `Recognition/Recognition.store`, never in `Competitive.store` or a backup. Nothing else in Identity touches
/// SwiftData for templates.
@MainActor
struct StackRecognitionTemplateStore: RecognitionTemplateStore {
    let stack: PersistenceStack
    /// Seam for tests (a failing save). Production always uses `ModelContext.save`.
    var save: @MainActor (ModelContext) throws -> Void = { try $0.save() }

    func templates(for profileID: UUID) throws -> StoredRecognitionTemplates? {
        try stack.recognition(for: profileID).map(StoredRecognitionTemplates.init)
    }

    /// Refuses (`RecognitionError.revoked`) an opt-in made at or before the profile's last delete.
    func replaceTemplates(_ t: StoredRecognitionTemplates, for profileID: UUID) throws {
        do {
            try stack.storeRecognition(profileID: profileID, faceEmbedding: t.faceEmbedding,
                                       appearanceEmbedding: t.appearanceEmbedding, optedInAt: t.optedInAt,
                                       version: t.version, save: save)
        } catch RecognitionError.unknownProfile {
            throw RegistrationError.notLocalOwner
        }
    }

    var deletionGeneration: Int { RecognitionDeletionLog.generation }

    /// Saved; tells every registered gallery (the stack bumps the deletion generation first).
    /// Also fences each profile (persisted revocation tombstone), so a registration started with an earlier
    /// consent can never write templates back, even after a relaunch.
    func deleteTemplates(for profileIDs: Set<UUID>) throws {
        RecognitionDeletionLog.recordDeletion()
        let ctx = stack.competitiveContext
        let now = Date.now
        for p in try ctx.fetch(FetchDescriptor<PlayerProfile>()) where profileIDs.contains(p.id) { PersistenceStack.fence(p, at: now) }
        if ctx.hasChanges { try ctx.save() }
        try stack.dropRecognition(of: profileIDs)
    }
}

extension IdentitySession {
    /// The production constructor: loads each player's templates from the recognition store and registers the
    /// session's galleries with the stack, so a one-tap delete, a guest purge or a profile delete clears them at
    /// once and an Undo reloads them. The stack holds the session weakly.
    static func registered(on stack: PersistenceStack, players: [UUID], guests: [UUID],
                           faceModelID: String, bodyModelID: String) -> IdentitySession {
        let store = StackRecognitionTemplateStore(stack: stack)
        let s = IdentitySession(players: players.map { ($0, (try? store.templates(for: $0)) ?? nil) }, guests: guests,
                                faceModelID: faceModelID, bodyModelID: bodyModelID)
        s.reloadTemplates = { id in (try? store.templates(for: id)) ?? nil }
        stack.register(s)
        return s
    }

    /// Loads a player from any template store (reads only; the session never writes).
    func addPlayer(id: UUID, from store: some RecognitionTemplateStore) {
        addPlayer(id: id, stored: (try? store.templates(for: id)) ?? nil)
    }
}

extension IdentitySession: RecognitionGallery {
    func recognitionDidChange(_ change: RecognitionChange) {
        switch change {
        case .purgedAll:
            // Every template is gone, session-only guest ones included.
            for e in snapshot().roster.entries { revoke(e.playerID) }
        case .purged(let ids):
            for id in ids where snapshot().roster.contains(id) { revoke(id) }
        case .restored(let ids):
            guard !hasEnded, let reload = reloadTemplates else { return }
            for e in snapshot().roster.entries where ids.contains(e.playerID) && !e.isGuest {
                addPlayer(id: e.playerID, stored: reload(e.playerID))
            }
        }
    }
}

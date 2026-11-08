import Foundation
import SwiftData

/// The Undo window's in-memory snapshot of a staged delete. Never encoded, never written to disk.
struct RecognitionUndo: Sendable {
    let records: [RecognitionRecord]
}

extension PersistenceStack {
    // MARK: Read / write (D26: face and appearance templates persist with the profile, no expiry)

    func recognition(for profileID: UUID) throws -> RecognitionData? {
        try recognitionContext.fetch(FetchDescriptor<RecognitionData>(predicate: #Predicate { $0.profileID == profileID }))
            .first
    }

    var hasRecognitionData: Bool {
        get throws { try recognitionContext.fetchCount(FetchDescriptor<RecognitionData>()) > 0 }
    }

    /// Stores (or replaces) a profile's templates. Refuses an opt-in made at or before the profile's revocation,
    /// so deleted data can't come back through a stale capture or a peer.
    func storeRecognition(profileID: UUID, faceEmbedding: Data?, appearanceEmbedding: Data?, optedInAt: Date,
                          version: Int) throws {
        let profiles = try competitiveContext.fetch(FetchDescriptor<PlayerProfile>(predicate: #Predicate { $0.id == profileID }))
        guard let profile = profiles.first else { throw RecognitionError.unknownProfile }
        if let revoked = profile.recognitionRevokedAt, BackupV1.millis(optedInAt) <= BackupV1.millis(revoked) {
            throw RecognitionError.revoked
        }
        let ctx = recognitionContext
        for old in try ctx.fetch(FetchDescriptor<RecognitionData>(predicate: #Predicate { $0.profileID == profileID })) {
            ctx.delete(old)
        }
        ctx.insert(RecognitionData(profileID: profileID, faceEmbedding: faceEmbedding,
                                   appearanceEmbedding: appearanceEmbedding, optedInAt: optedInAt, version: version))
        try ctx.save()
        try protectRecognitionFiles()
    }

    /// Re-applies backup exclusion + `.complete` to files the store created since (WAL, external blobs).
    func protectRecognitionFiles() throws {
        if let directory { try RecognitionStoreFiles.protect(in: directory) }
    }

    // MARK: One-tap delete

    /// Settings → "Delete recognition data", step 1 of the Undo flow: takes an in-memory snapshot, removes every
    /// row from the context (nothing is saved, so nothing is written but an empty marker file) and clears every
    /// gallery. Follow with `undoRecognitionDeletion` or `deleteMyRecognitionData` (the commit). If the app dies
    /// first, the marker makes the next launch commit.
    func beginRecognitionDeletion() throws -> RecognitionUndo {
        let ctx = recognitionContext
        let rows = try ctx.fetch(FetchDescriptor<RecognitionData>())
        let undo = RecognitionUndo(records: rows.map(\.record))
        if let directory {
            try RecognitionStoreFiles.prepareDirectory(in: directory)
            FileManager.default.createFile(atPath: RecognitionStoreFiles.pendingDeleteURL(in: directory).path,
                                           contents: nil, attributes: [.protectionKey: FileProtectionType.complete])
        }
        for r in rows { ctx.delete(r) }
        notifyGalleries(.purgedAll)
        return undo
    }

    /// Undo inside the window: puts the snapshot back. Rolls back the staged deletes and re-inserts any row that a
    /// commit already removed, then drops the marker.
    func undoRecognitionDeletion(_ undo: RecognitionUndo) throws {
        let ctx = recognitionContext
        ctx.rollback()
        let present = Set(try ctx.fetch(FetchDescriptor<RecognitionData>()).map(\.id))
        for r in undo.records where !present.contains(r.id) { ctx.insert(RecognitionData(r)) }
        if ctx.hasChanges { try ctx.save() }
        if let directory { try? FileManager.default.removeItem(at: RecognitionStoreFiles.pendingDeleteURL(in: directory)) }
        try protectRecognitionFiles()
        notifyGalleries(.restored(Set(undo.records.map(\.profileID))))
    }

    /// The commit (and the direct one-call delete): empties the whole recognition store, destroying its files so
    /// no page, WAL frame or external blob keeps a template, stamps a revocation tombstone on the local owner,
    /// and clears every gallery. Profiles, games and stats are untouched. Safe to call twice.
    func deleteMyRecognitionData(now: Date = .now) throws {
        let ctx = recognitionContext
        try ctx.delete(model: RecognitionData.self)
        try ctx.save()
        try recognitionContainer.deleteAllData()
        recognitionContainer = try RecognitionStoreFiles.container(in: directory, inMemory: directory == nil)
        if let directory {
            try? FileManager.default.removeItem(at: RecognitionStoreFiles.pendingDeleteURL(in: directory))
            try RecognitionStoreFiles.protect(in: directory)
        }
        let c = competitiveContext
        for owner in try c.fetch(FetchDescriptor<PlayerProfile>(predicate: #Predicate { $0.isLocalOwner })) {
            owner.recognitionRevokedAt = now   // merged max-wins on import, so no updatedAt bump is needed
        }
        if c.hasChanges { try c.save() }
        notifyGalleries(.purgedAll)
    }

    // MARK: Guests and profiles

    /// Session end: drop every peer profile cached for the session and their templates.
    /// Shots keep the guest's `shooterID` as plain history.
    func purgeSessionGuests() throws {
        let c = competitiveContext
        let ids = Set(try c.fetch(FetchDescriptor<PlayerProfile>(predicate: #Predicate { $0.isSessionGuest })).map(\.id))
        try dropRecognition(of: ids)
        try c.delete(model: PlayerProfile.self, where: #Predicate { $0.isSessionGuest })
        try c.save()
    }

    /// A live session guest becomes a saved profile. Its session templates go unless the person consented to
    /// being remembered at promotion time (`keepRecognition`).
    func promoteSessionGuest(_ id: UUID, keepRecognition: Bool) throws {
        let c = competitiveContext
        guard let p = try c.fetch(FetchDescriptor<PlayerProfile>(predicate: #Predicate { $0.id == id })).first,
              p.isSessionGuest else { return }
        if !keepRecognition { try dropRecognition(of: [id]) }
        p.isSessionGuest = false
        try c.save()
    }

    /// Deletes a profile and its templates (the store split means there is no cascade).
    func deleteProfile(_ profile: PlayerProfile) throws {
        try dropRecognition(of: [profile.id])
        competitiveContext.delete(profile)
        try competitiveContext.save()
    }

    /// Removes these profiles' templates (saved) and tells the galleries. No-op for an empty set or no rows.
    func dropRecognition(of ids: Set<UUID>) throws {
        guard !ids.isEmpty else { return }
        let ctx = recognitionContext
        let rows = try ctx.fetch(FetchDescriptor<RecognitionData>()).filter { ids.contains($0.profileID) }
        guard !rows.isEmpty else { return }
        for r in rows { ctx.delete(r) }
        try ctx.save()
        notifyGalleries(.purged(Set(rows.map(\.profileID))))
    }

    /// Templates whose profile is gone (deleted elsewhere, or a crash between the two saves) are removed on open.
    func pruneOrphanRecognition() throws {
        let known = Set(try competitiveContext.fetch(FetchDescriptor<PlayerProfile>()).map(\.id))
        let orphans = try recognitionContext.fetch(FetchDescriptor<RecognitionData>()).filter { !known.contains($0.profileID) }
        guard !orphans.isEmpty else { return }
        for r in orphans { recognitionContext.delete(r) }
        try recognitionContext.save()
    }
}

import Foundation
import SwiftData
import Testing
@testable import CueCoach

/// Codex integ-privacy-r3 findings, fixed at integration.
@MainActor
@Suite struct PrivacyR3Tests {
    func stackWithOwner() throws -> (PersistenceStack, PlayerProfile) {
        let stack = try PersistenceStack(inMemory: true)
        let owner = PlayerProfile(name: "Ari", avatarSymbol: "s", avatarColor: "c", isLocalOwner: true)
        stack.competitiveContext.insert(owner)
        try stack.competitiveContext.save()
        try stack.storeRecognition(profileID: owner.id, faceEmbedding: nil, appearanceEmbedding: Data([1]),
                                   optedInAt: Date(timeIntervalSince1970: 1_000), version: 1)
        return (stack, owner)
    }

    /// MAJOR (import tombstone / Undo after promotion fence): a template opted in at or before the profile's
    /// revocation is never read, whatever path left the row behind.
    @Test func templatesAtOrBeforeTheTombstoneAreNeverRead() throws {
        let (stack, owner) = try stackWithOwner()
        #expect(try stack.recognition(for: owner.id) != nil)
        owner.recognitionRevokedAt = Date(timeIntervalSince1970: 2_000)   // e.g. a restored backup's tombstone
        try stack.competitiveContext.save()
        #expect(try stack.recognition(for: owner.id) == nil)
        #expect(try StackRecognitionTemplateStore(stack: stack).templates(for: owner.id) == nil)
    }

    /// MAJOR: a per-profile delete persists a fence, so a registration carrying an earlier consent can't write back.
    @Test func perProfileDeleteFencesStaleConsent() throws {
        let (stack, owner) = try stackWithOwner()
        let store = StackRecognitionTemplateStore(stack: stack)
        try store.deleteTemplates(for: [owner.id])
        #expect(owner.recognitionRevokedAt != nil)
        #expect(throws: RecognitionError.revoked) {
            try store.replaceTemplates(StoredRecognitionTemplates(faceEmbedding: nil, appearanceEmbedding: Data([2]),
                                                                  optedInAt: Date(timeIntervalSince1970: 1_500), version: 1),
                                       for: owner.id)
        }
        // A fresh consent after the delete is fine.
        try store.replaceTemplates(StoredRecognitionTemplates(faceEmbedding: nil, appearanceEmbedding: Data([3]),
                                                              optedInAt: Date.now.addingTimeInterval(1), version: 1),
                                   for: owner.id)
        #expect(try store.templates(for: owner.id)?.appearanceEmbedding == Data([3]))
    }

    /// MAJOR (rebuttal check): writing the scrub marker twice (a crash between the marker and the migration's
    /// save, then the stage re-running) must not throw.
    @Test func scrubMarkerIsIdempotent() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try RecognitionMigration.markScrubPending(in: dir)
        try RecognitionMigration.markScrubPending(in: dir)
        #expect(RecognitionMigration.isScrubPending(in: dir))
    }

    /// MAJOR: a crash after the scrub removed its marker but before backups were re-enabled must not leave the
    /// competitive store excluded for good; the next open repairs it.
    @Test func competitiveStoreIsReincludedOnTheNextOpen() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("re-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try PersistenceStack(directory: dir)
        let url = dir.appendingPathComponent("Competitive.store")
        try RecognitionMigration.setCompetitiveExcluded(true, storeURL: url)   // "crash" state
        #expect(!RecognitionMigration.isScrubPending(in: dir))
        _ = try PersistenceStack(directory: dir)
        #expect(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == false)
    }
}

/// Codex integ-privacy-r3 rerun MAJORs.
@MainActor
@Suite struct PrivacyR3RerunTests {
    final class Gallery: RecognitionGallery {
        var changes: [RecognitionChange] = []
        func recognitionDidChange(_ change: RecognitionChange) { changes.append(change) }
    }

    func stack(guest: Bool = false) throws -> (PersistenceStack, PlayerProfile) {
        let stack = try PersistenceStack(inMemory: true)
        let p = PlayerProfile(name: "Ari", avatarSymbol: "s", avatarColor: "c", isLocalOwner: !guest, isSessionGuest: guest)
        stack.competitiveContext.insert(p)
        try stack.competitiveContext.save()
        try stack.storeRecognition(profileID: p.id, faceEmbedding: nil, appearanceEmbedding: Data([1]),
                                   optedInAt: Date(timeIntervalSince1970: 1_000), version: 1)
        return (stack, p)
    }

    /// Backup.swift:210: importing a later revocation purges the row and tells registered galleries at once.
    @Test func importedTombstonePurgesTheRowAndTheGalleries() throws {
        let (local, p) = try stack()
        let g = Gallery()
        local.register(g)
        // The same profile on another phone, revoked later.
        let other = try PersistenceStack(inMemory: true)
        let q = PlayerProfile(id: p.id, name: "Ari", avatarSymbol: "s", avatarColor: "c", isLocalOwner: true)
        q.recognitionRevokedAt = Date(timeIntervalSince1970: 5_000)
        q.updatedAt = .now.addingTimeInterval(60)
        other.competitiveContext.insert(q)
        try other.competitiveContext.save()
        try local.importBackup(other.exportBackup())
        #expect(try local.recognitionContext.fetchCount(FetchDescriptor<RecognitionData>()) == 0)
        #expect(g.changes.contains(.purged([p.id])))
    }

    /// Backup.swift:108: no import while a one-tap delete is inside its Undo window (it would commit or race it).
    @Test func importIsRefusedDuringAStagedDelete() throws {
        let (local, _) = try stack()
        let data = try local.exportBackup()
        let undo = try local.beginRecognitionDeletion()
        #expect(throws: BackupError.pendingChanges) { try local.importBackup(data) }
        try local.undoRecognitionDeletion(undo)
    }

    /// Undo never brings back templates of a profile fenced inside the window (e.g. a guest promoted without consent).
    @Test func undoSkipsProfilesFencedDuringTheWindow() throws {
        let (local, guest) = try stack(guest: true)
        let g = Gallery()
        local.register(g)
        let undo = try local.beginRecognitionDeletion()
        try local.promoteSessionGuest(guest.id, keepRecognition: false)
        try local.undoRecognitionDeletion(undo)
        #expect(try local.recognitionContext.fetchCount(FetchDescriptor<RecognitionData>()) == 0)
        #expect(!g.changes.contains(.restored([guest.id])))
    }
}

/// Codex final-review MAJOR: the post-import purge can fail after the stores committed. Galleries are told first,
/// the row is unreadable anyway (tombstone), and every open retries the purge.
@MainActor
@Suite struct PrivacyFinalTests {
    @Test func revokedTemplatesLeftOnDiskArePurgedOnTheNextOpen() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rv-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let id: UUID
        do {
            let s = try PersistenceStack(directory: dir)
            let p = PlayerProfile(name: "Ari", avatarSymbol: "s", avatarColor: "c", isLocalOwner: true)
            s.competitiveContext.insert(p)
            try s.competitiveContext.save()
            try s.storeRecognition(profileID: p.id, faceEmbedding: nil, appearanceEmbedding: Data([1]),
                                   optedInAt: Date(timeIntervalSince1970: 1_000), version: 1)
            p.recognitionRevokedAt = Date(timeIntervalSince1970: 2_000)   // tombstone saved, purge "failed"
            try s.competitiveContext.save()
            id = p.id
        }
        let reopened = try PersistenceStack(directory: dir)
        let pid = id
        #expect(try reopened.recognitionContext.fetchCount(FetchDescriptor<RecognitionData>(predicate: #Predicate { $0.profileID == pid })) == 0)
    }

    /// Discriminating (interim review): the gallery checks, while it is being told, that the row is still on
    /// disk. The old order (delete + save, then notify) would see 0 rows.
    @Test func dropTellsGalleriesBeforeTouchingTheStore() throws {
        @MainActor final class G: RecognitionGallery {
            let stack: PersistenceStack
            var rowsWhenTold: [Int] = []
            init(_ s: PersistenceStack) { stack = s }
            func recognitionDidChange(_ change: RecognitionChange) {
                rowsWhenTold.append((try? ModelContext(stack.recognitionContainer).fetchCount(FetchDescriptor<RecognitionData>())) ?? -1)
            }
        }
        let s = try PersistenceStack(inMemory: true)
        let p = PlayerProfile(name: "Ari", avatarSymbol: "s", avatarColor: "c", isLocalOwner: true)
        s.competitiveContext.insert(p)
        try s.competitiveContext.save()
        try s.storeRecognition(profileID: p.id, faceEmbedding: nil, appearanceEmbedding: Data([1]),
                               optedInAt: .now, version: 1)
        let g = G(s)
        s.register(g)
        try s.dropRecognition(of: [p.id])
        #expect(g.rowsWhenTold == [1])
        #expect(try s.recognitionContext.fetchCount(FetchDescriptor<RecognitionData>()) == 0)
    }
}

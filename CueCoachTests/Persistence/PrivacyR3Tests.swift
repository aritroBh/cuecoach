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

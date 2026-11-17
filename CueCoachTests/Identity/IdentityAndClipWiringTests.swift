import CoreGraphics
import Foundation
import SwiftData
import Geometry
import Rules
import Engine
import Testing
@testable import CueCoach

private struct DeterministicTestBodyExtractor: EmbeddingExtracting {
    var modelID: String { "test.body.v1" }
    func embedding(of image: CGImage) async throws -> Embedding {
        Embedding(modelID: modelID, vector: [0.6, 0.8, 0.0, 0.0])
    }
}

@MainActor
@Suite(.serialized) struct IdentityAndClipWiringTests {
    @Test func optInEnrollmentWritesTemplatesAndOneTapDeletePurgesActiveSession() async throws {
        let stack = try PersistenceStack(inMemory: true)
        let owner = PlayerProfile(name: "Aritro", avatarSymbol: "hare.fill", avatarColor: "teal", isLocalOwner: true)
        stack.competitiveContext.insert(owner)
        try stack.competitiveContext.save()

        let suiteName = "cc.test.identity.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settingsStore = PersistenceSettingsStore(stack: stack)
        let settingsVM = SettingsViewModel(store: settingsStore, defaults: defaults, announce: { _ in })
        #expect(!settingsVM.hasRecognitionData)

        let bodyExtractor = DeterministicTestBodyExtractor()
        let enrollModel = IdentityRegistrationModel(
            stack: stack, faceExtractor: nil, bodyExtractor: bodyExtractor)
        let ok = await enrollModel.enroll()
        #expect(ok)
        #expect(enrollModel.step == .done)

        settingsVM.refreshRecognitionStatus()
        #expect(settingsVM.hasRecognitionData)
        let stored = try stack.recognition(for: owner.id)
        #expect(stored?.appearanceEmbedding != nil)

        // Start an IdentitySession registered on the stack (with a guest present per D28).
        let guestID = UUID()
        let session = IdentitySession.registered(
            on: stack, players: [owner.id], guests: [guestID],
            faceModelID: FaceEmbeddingExtractor.modelID,
            bodyModelID: bodyExtractor.modelID)
        #expect(session.snapshot().appearanceGallery[owner.id]?.isEmpty == false)

        // One-tap Delete in Settings immediately purges the in-RAM gallery!
        settingsVM.deleteTapped()
        #expect(session.snapshot().appearanceGallery[owner.id] == nil)
        #expect(!settingsVM.hasRecognitionData)
    }

    @Test func shotClipRecorderWritesMP4ResolvesPlayableURLAndDeletesCleanly() async throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: "cc-clips-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let recorder = ShotClipRecorder(baseDirectory: tempDir)
        let shotID = UUID()
        let one = BallID(1)!
        let before: [BallID: Vec2] = [.cue: Vec2(0.5, 0.5), one: Vec2(1.4, 0.6)]
        let after: [BallID: Vec2] = [.cue: Vec2(0.9, 0.55)]
        let (rel, url) = try await recorder.exportClip(
            shotID: shotID, tableSize: .sevenFoot,
            before: before, after: after, pocketed: [one: .footRight])

        #expect(rel == "Clips/\(shotID.uuidString).mp4")
        #expect(FileManager.default.fileExists(atPath: url.path))
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        #expect(size > 256, "Exported MP4 should have non-trivial video payload")

        let resolved = ShotClipStore.resolveURL(relativePath: rel, baseDirectory: tempDir)
        #expect(resolved != nil)
        #expect(ShotClipStore.resolveURL(relativePath: "Clips/../escape.mp4", baseDirectory: tempDir) == nil)

        // Verify GameReviewModel play hook presents `activeClip`.
        let player = ReviewPlayer(id: UUID(), name: "Aritro", symbol: "hare.fill", colorName: "teal")
        let reviewShot = ReviewShot(
            id: shotID, index: 0, shooter: player, team: 0, rating: .brilliant,
            pre: nil, post: nil, pocketed: [one: .footRight], fouls: [], paths: [:],
            alternative: nil, wpaDelta: 0.35)
        let data = GameReviewData(
            gameIndex: 0, teams: [[player], []], score: [1, 0], winnerTeam: 0,
            isFinished: true, winProb: [0.5, 1.0], shots: [reviewShot],
            shotOfGame: ReviewHighlight(shotID: shotID, label: "Brilliant Shot", hasClip: true),
            tableSize: .sevenFoot)
        let reviewModel = GameReviewModel(data: data)
        reviewModel.onPlayClip = { [weak reviewModel] sid in
            if let u = ShotClipStore.resolveURL(relativePath: rel, baseDirectory: tempDir) {
                reviewModel?.presentClip(shotID: sid, url: u)
            }
        }
        #expect(reviewModel.canPlayShotOfGameClip)
        reviewModel.playShotOfGameClip()
        #expect(reviewModel.activeClip?.id == shotID)
        #expect(reviewModel.activeClip?.label == "Brilliant Shot")

        ShotClipStore.deleteClips(relativePaths: [rel], baseDirectory: tempDir)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}

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
        #expect(!ShotClipStore.isValidRelativeClipPath("Clips/"))
        #expect(!ShotClipStore.isValidRelativeClipPath("Clips/."))
        #expect(!ShotClipStore.isValidRelativeClipPath("Clips/not-a-uuid.mp4"))
        ShotClipStore.deleteClips(relativePaths: ["Clips/", "Clips/.", "Clips/../Clips"], baseDirectory: tempDir)
        #expect(FileManager.default.fileExists(atPath: url.path), "Directory-level strings must never delete sibling valid MP4 clips")

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

    @Test func soloReviewRetainsSessionCallbacksAndGuestTableGuardsUnconfirmedStats() throws {
        let stack = try PersistenceStack(inMemory: true)
        let owner = PlayerProfile(name: "Aritro", avatarSymbol: "hare.fill", avatarColor: "teal", isLocalOwner: true)
        let rival = PlayerProfile(name: "Rival", avatarSymbol: "bolt.fill", avatarColor: "orange", isLocalOwner: false)
        stack.competitiveContext.insert(owner)
        stack.competitiveContext.insert(rival)
        try stack.competitiveContext.save()

        // 1. Solo AppRouter review retains `reviewedGame` so `correctShooter` stays alive after `endGame()`.
        let suiteName = "cc.test.router.review.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let router = AppRouter()
        router.stack = stack
        router.recorder = StackGameRecorder(stack: stack)
        router.defaults = defaults

        let shellOwner = ShellPlayer(id: owner.id, name: owner.name, symbol: owner.avatarSymbol, colorName: owner.avatarColor)
        let shellRival = ShellPlayer(id: rival.id, name: rival.name, symbol: rival.avatarSymbol, colorName: rival.avatarColor)
        router.startGame(GameConfig(ruleSet: .barEight, tableSize: .sevenFoot, teams: [[shellOwner], [shellRival]]))
        guard case .live(let liveSession)? = router.stage, let game = liveSession.game else {
            Issue.record("Expected live session")
            return
        }
        // D52: `LiveSession.isTableQuiet` gates `resolveDispute`.
        #expect(liveSession.isTableQuiet)
        liveSession.tableQuietChanged(false)
        #expect(!liveSession.isTableQuiet)
        liveSession.tableQuietChanged(true)
        #expect(liveSession.isTableQuiet)

        // Settle an early 8-ball foul on Shot 0 (Owner shoots 8 early → Team 1 wins).
        game.shotSettled(SettledShot(rating: .blunder, turnPasses: true,
                                     outcome: ShotOutcome(firstContact: .eight, pocketed: [.eight: .footLeft])))
        let shot0ID = try #require(game.shots.first?.id)
        router.endGame()

        guard case .review(let reviewModel)? = router.stage else {
            Issue.record("Expected review stage")
            return
        }
        #expect(reviewModel.data?.winnerTeam == 1)
        let rivalReview = ReviewPlayer(id: rival.id, name: rival.name, symbol: rival.avatarSymbol, colorName: rival.avatarColor)
        reviewModel.correctShooter(shot0ID, to: rivalReview)
        #expect(reviewModel.data?.winnerTeam == 0, "Retained solo GameSessionModel flips winner to Team 0 on shooter fix")

        // 2. D28: At a guest table with active IdentitySession, unconfirmed turn-order shots on a registered player
        // are flagged `isGuess = true` + `needsShooter = true` until confirmed by tap or strict `.auto`.
        let guestShell = ShellPlayer(id: UUID(), name: "Guest", symbol: "person.fill", colorName: "gold", isGuest: true)
        let guestGame = GameSessionModel(config: GameConfig(ruleSet: .barEight, tableSize: .sevenFoot,
                                                            teams: [[shellOwner], [guestShell]]))
        guestGame.identitySession = IdentitySession.registered(
            on: stack, players: [owner.id], guests: [guestShell.id],
            faceModelID: "test.face", bodyModelID: "test.body")
        guestGame.shotSettled(SettledShot(
            rating: .best, turnPasses: false,
            outcome: ShotOutcome(firstContact: BallID(1)!, pocketed: [BallID(1)!: .footRight])))
        #expect(guestGame.needsShooter)
        #expect(guestGame.shots.first?.isGuess == true)

        let ownerReview = ReviewPlayer(id: owner.id, name: owner.name, symbol: owner.avatarSymbol, colorName: owner.avatarColor)
        let confirmedShotID = try #require(guestGame.shots.first?.id)
        _ = guestGame.correctShooter(shotID: confirmedShotID, to: ownerReview)
        #expect(guestGame.shots.first?.attribution == .tap)
        #expect(guestGame.shots.first?.isGuess == false)
    }
}

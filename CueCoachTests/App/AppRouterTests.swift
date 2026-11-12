import Foundation
import Testing
import Geometry
import Rules
import Training
@testable import CueCoach

@MainActor
@Suite struct AppRouterTests {
    let a = ShellPlayer(id: UUID(), name: "Ari", symbol: "hare.fill", colorName: "teal")
    let b = ShellPlayer(id: UUID(), name: "Sam", symbol: "bolt.fill", colorName: "orange")
    var config: GameConfig { GameConfig(ruleSet: .barEight, tableSize: .sevenFoot, teams: [[a], [b]]) }

    @Test func startsAtHomeWithNothingPresented() {
        let r = AppRouter()
        #expect(r.path.isEmpty)
        #expect(r.stage == nil)
        #expect(r.sheet == nil)
    }

    @Test func gameBranchPushesHubThenNewGameOrJoin() {
        let r = AppRouter()
        r.openGame()
        #expect(r.path == [.gameHub])
        r.openNewGame()
        #expect(r.path == [.gameHub, .newGame])
        r.path.removeLast()
        r.openJoinNearby()
        #expect(r.path == [.gameHub, .joinNearby])
    }

    @Test func trainingBranchPushesPicker() {
        let r = AppRouter()
        r.openTraining()
        #expect(r.path == [.training])
    }

    @Test func openingABranchFromHomeResetsAStalePath() {
        let r = AppRouter()
        r.openGame(); r.openNewGame()
        r.openTraining()
        #expect(r.path == [.training])
    }

    @Test func startGameOpensLiveInGameMode() {
        let r = AppRouter()
        r.openGame(); r.openNewGame()
        r.startGame(config)
        guard case .live(let s)? = r.stage else { Issue.record("no live"); return }
        #expect(s.mode == .game)
        #expect(s.game?.config == config)
    }

    @Test func startTrainingOpensLiveInTrainingModeWithLevel() {
        let r = AppRouter()
        r.openTraining()
        r.startTraining(drill: .long, level: .ghostOnly)
        guard case .live(let s)? = r.stage else { Issue.record("no live"); return }
        #expect(s.mode == .training(level: 3))
        #expect(s.drill == .long)
        #expect(s.game == nil)
    }

    @Test func endGameShowsReviewThenDoneReturnsHome() {
        let r = AppRouter()
        r.openGame(); r.openNewGame()
        r.startGame(config)
        r.endGame()
        guard case .review? = r.stage else { Issue.record("no review"); return }
        r.finishReview()
        #expect(r.stage == nil)
        #expect(r.path.isEmpty)
    }

    @Test func liveClosedInGameGoesToReview() {
        let r = AppRouter()
        r.startGame(config)
        r.liveClosed()
        guard case .review? = r.stage else { Issue.record("no review"); return }
    }

    @Test func liveClosedInTrainingReturnsToPicker() {
        let r = AppRouter()
        r.openTraining()
        r.startTraining(drill: .straightIn, level: .full)
        r.liveClosed()
        #expect(r.stage == nil)
        #expect(r.path == [.training])
    }

    @Test func endGameIsIgnoredOutsideAGame() {
        let r = AppRouter()
        r.endGame()
        #expect(r.stage == nil)
        r.startTraining(drill: .straightIn, level: .full)
        r.endGame()
        guard case .live? = r.stage else { Issue.record("training should stay live"); return }
    }

    @Test func reviewCarriesTheGamesRatedShots() {
        let r = AppRouter()
        r.startGame(config)
        guard case .live(let s)? = r.stage, let game = s.game else { Issue.record("no game"); return }
        game.shotSettled(SettledShot(rating: .great, turnPasses: true, outcome: ShotOutcome()))
        r.endGame()
        guard case .review(let review)? = r.stage, let data = review.data else { Issue.record("no review"); return }
        #expect(data.shots.count == 1)
        #expect(data.shots.first?.rating == .great)
        #expect(!data.isFinished)                 // ended mid-rack: no winner yet
    }

    /// Plan 011: each game gets the router's recorder.
    @Test func startGameHandsTheRecorderToTheGame() throws {
        let r = AppRouter()
        let recorder = StackGameRecorder(stack: try PersistenceStack(inMemory: true))
        r.recorder = recorder
        r.startGame(config)
        guard case .live(let s)? = r.stage, let game = s.game else { Issue.record("no game"); return }
        #expect(game.recorder === recorder)
    }

    @MainActor final class FakeLink: GameMeshLink {
        var peerCount = 1
        var isStopped = false
        var isHost = true
        var hasGameQuorum = true
        var commitSeq: UInt64 = 0
        var onCommittedLog: (@MainActor ([LogEntry], UInt64) -> Void)?
        func append(_ event: GameEvent) {}
        var started = 0, stopped = 0, drains = 0
        /// How long `drain` takes (a slow radio); the router caps it.
        var drainTime: Duration = .zero
        func start() { started += 1 }
        func stop() { stopped += 1 }
        func drain(until deadline: Date) async { drains += 1; try? await Task.sleep(for: drainTime) }
    }

    func meshGame(_ link: FakeLink) -> AppRouter {
        let r = AppRouter()
        r.meshFactory = { _ in link }
        var c = config
        c.sessionTag = 9
        r.startGame(c)
        return r
    }

    /// Codex 010 review 2 (B): End leaves Live at once; only the review data waits for the drain.
    @Test func endingAMeshGameLeavesLiveAtOnceAndReviewLoadsAfterTheDrain() async {
        let link = FakeLink()
        link.drainTime = .milliseconds(300)
        let r = meshGame(link)
        r.endGame()
        guard case .review(let m)? = r.stage else { Issue.record("Live still up"); return }
        #expect(m.phase == .loading)
        #expect(link.stopped == 0)
        #expect(await poll(2) { m.phase == .loaded })
        #expect(link.stopped == 1)
    }

    @Test func aSecondEndGameIsANoOp() async {
        let link = FakeLink()
        link.drainTime = .milliseconds(200)
        let r = meshGame(link)
        r.endGame()
        guard case .review(let first)? = r.stage else { Issue.record("no review"); return }
        r.endGame()
        r.liveClosed()
        guard case .review(let again)? = r.stage else { Issue.record("no review"); return }
        #expect(again === first)
        #expect(await poll(2) { first.phase == .loaded })
        #expect(link.drains == 1 && link.stopped == 1)
    }

    /// D42: never stuck. A link that never drains still yields a review 2 s after End.
    @Test func theTwoSecondCapHoldsWhenTheDrainHangs() async {
        let link = FakeLink()
        link.drainTime = .seconds(30)
        let r = meshGame(link)
        let start = Date()
        r.endGame()
        guard case .review(let m)? = r.stage else { Issue.record("no review"); return }
        #expect(await poll(4) { m.phase == .loaded })
        #expect(Date().timeIntervalSince(start) < 2.8)
        #expect(link.stopped == 1)
    }

    @Test func meshGameStartsTheSessionWithTheLobbyTagAndStopsItAtTheEnd() async {
        let r = AppRouter()
        var tags: [UInt16] = []
        let link = FakeLink()
        r.meshFactory = { tags.append($0); return link }
        var c = config
        c.sessionTag = 42
        r.startGame(c)
        #expect(tags == [42])
        #expect(link.started == 1)
        r.endGame()
        #expect(await poll(2) { link.stopped == 1 })
        r.finishReview()
        #expect(link.stopped == 1)
    }

    @Test func secondStartStopsThePreviousMeshLink() {
        let r = AppRouter()
        let links = [FakeLink(), FakeLink()]
        var i = 0
        r.meshFactory = { _ in defer { i += 1 }; return links[i] }
        var c = config
        c.sessionTag = 7
        r.startGame(c)
        r.startGame(c)
        #expect(links[0].stopped == 1)
        #expect(links[1].started == 1)
    }

    @Test func menuIsUnavailableWhileAiming() {
        let r = AppRouter()
        r.startGame(config)
        guard case .live(let s)? = r.stage else { Issue.record("no live"); return }
        #expect(s.menuAvailable)
        s.isMenuOpen = true
        s.aimStarted()
        #expect(!s.menuAvailable)
        #expect(!s.isMenuOpen)            // an open menu closes the moment aiming starts (SPEC §2)
        s.isMenuOpen = true
        #expect(!s.isMenuOpen)            // and can't reopen until the shot ends
        s.aimEnded()                      // stroke taken: balls still rolling
        #expect(!s.menuAvailable)
        s.ballsSettled()
        #expect(s.menuAvailable)
        s.aimStarted()
        s.aimCancelled()                  // no stroke: nothing will settle
        #expect(s.menuAvailable)
    }

    @Test func settledRatedShotReopensTheMenuAndRecords() {
        let r = AppRouter()
        r.startGame(config)
        guard case .live(let s)? = r.stage, let g = s.game else { Issue.record("no live"); return }
        s.aimStarted(); s.aimEnded()
        s.settled(SettledShot(rating: .best, turnPasses: false, outcome: ShotOutcome(firstContact: BallID(1)!, pocketed: [BallID(1)!: .footLeft])))
        #expect(s.menuAvailable)
        #expect(g.shots.count == 1)
    }

    @Test func aimingAlsoSilencesTheBadge() {
        let r = AppRouter()
        r.startGame(config)
        guard case .live(let s)? = r.stage, let g = s.game else { Issue.record("no live"); return }
        g.shotSettled(SettledShot(rating: .good, turnPasses: false, outcome: ShotOutcome(firstContact: BallID(1)!, pocketed: [BallID(1)!: .footLeft])))
        #expect(g.badge.current != nil)
        s.aimStarted()
        #expect(g.badge.current == nil)
    }

    @Test func singlePhoneGameHasNoMesh() {
        let r = AppRouter()
        var made = 0
        r.meshFactory = { _ in made += 1; return FakeLink() }
        r.startGame(config)
        #expect(made == 0)
    }

    @Test func sheetsOpenFromHome() {
        let r = AppRouter()
        r.sheet = .settings
        #expect(r.sheet == .settings)
        r.sheet = .profile
        #expect(r.sheet == .profile)
    }
}

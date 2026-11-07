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
        game.record(rating: .great)
        r.endGame()
        guard case .review(let data)? = r.stage else { Issue.record("no review"); return }
        #expect(data.shots.count == 1)
        #expect(data.shots.first?.rating == .great)
        #expect(data.isFinished)
    }

    @Test func sheetsOpenFromHome() {
        let r = AppRouter()
        r.sheet = .settings
        #expect(r.sheet == .settings)
        r.sheet = .profile
        #expect(r.sheet == .profile)
    }
}

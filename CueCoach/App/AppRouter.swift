import Foundation
import Observation
import Training

enum ShellRoute: Hashable { case gameHub, newGame, joinNearby, training }

enum ShellSheet: String, Identifiable { case settings, profile; var id: String { rawValue } }

/// One trip into the camera. `game` is nil in Training.
@MainActor final class LiveSession: Identifiable {
    let id = UUID()
    let mode: ShellLiveMode
    let game: GameSessionModel?
    let drill: DrillID?
    init(mode: ShellLiveMode, game: GameSessionModel?, drill: DrillID?) {
        self.mode = mode; self.game = game; self.drill = drill
    }
}

/// What fills the full-screen cover above the navigation stack.
@MainActor enum ShellStage {
    case live(LiveSession)
    case review(GameReviewData)
}

/// The app's navigation state machine (docs/design/app-shell.md).
/// Home → Game hub → New game | Join nearby → Live(.game) → Review → Home;  Home → Training → Live(.training).
@MainActor @Observable
final class AppRouter {
    var path: [ShellRoute] = []
    var sheet: ShellSheet?
    private(set) var stage: ShellStage?

    func openGame() { path = [.gameHub] }
    func openNewGame() { path = [.gameHub, .newGame] }
    func openJoinNearby() { path = [.gameHub, .joinNearby] }
    func openTraining() { path = [.training] }

    func startGame(_ config: GameConfig) {
        stage = .live(LiveSession(mode: .game, game: GameSessionModel(config: config), drill: nil))
    }

    func startTraining(drill: DrillID, level: AssistLevel) {
        stage = .live(LiveSession(mode: .training(level), game: nil, drill: drill))
    }

    /// End game (menu) → review. Ignored in Training or when nothing is live.
    func endGame() {
        guard case .live(let s)? = stage, let game = s.game else { return }
        stage = .review(game.reviewData())
    }

    /// LiveScreen dismissed itself (its own ✕). Game → review; Training → back to the drill picker.
    func liveClosed() {
        guard case .live(let s)? = stage else { return }
        if s.game != nil { endGame() } else { stage = nil }
    }

    /// Training menu "Stop".
    func stopTraining() {
        guard case .live(let s)? = stage, s.game == nil else { return }
        stage = nil
    }

    func finishReview() {
        stage = nil
        path = []
    }
}

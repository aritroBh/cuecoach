import Foundation
import Observation
import Training
import Engine

enum ShellRoute: Hashable { case gameHub, newGame, joinNearby, training }

enum ShellSheet: String, Identifiable { case settings, profile; var id: String { rawValue } }

/// One trip into the camera. `game` is nil in Training.
@MainActor @Observable final class LiveSession: Identifiable {
    let id = UUID()
    let mode: ShellLiveMode
    let game: GameSessionModel?
    let drill: DrillID?
    /// From aim start until the balls settle (or the aim is cancelled). No text may appear: the menu
    /// closes and can't open (SPEC §2).
    private(set) var isAiming = false
    private var menuOpen = false

    init(mode: ShellLiveMode, game: GameSessionModel?, drill: DrillID?) {
        self.mode = mode; self.game = game; self.drill = drill
    }

    var menuAvailable: Bool { !isAiming }
    var isMenuOpen: Bool {
        get { menuOpen && !isAiming }
        set { menuOpen = newValue && !isAiming }
    }

    func aimStarted() {
        isAiming = true
        menuOpen = false
        game?.aimStarted()
    }

    /// Stroke taken: balls are moving, the menu stays closed until `ballsSettled`.
    func aimEnded() { game?.aimEnded() }

    /// Aim abandoned without a stroke.
    func aimCancelled() {
        isAiming = false
        game?.aimEnded()
    }

    /// Balls at rest (Training, or a game shot without a rating yet).
    func ballsSettled() { isAiming = false }

    /// D38: a game shot was lost with no guess: balls at rest, the game records a gap and asks for the shooter.
    func shotLost() {
        isAiming = false
        game?.shotLost()
    }

    /// One-tap turn correction (SPEC §5.8), between shots only: while an aim is open or balls are moving the
    /// shooter is fixed, so a stray tap on a turn disc can't change who is shooting mid-shot.
    func handTurn(toTeam team: Int) {
        guard !isAiming else { return }
        game?.handTurn(toTeam: team)
    }

    /// A game shot settled and was rated, with what the Rules engine saw (kept for Game Review).
    func settled(_ shot: SettledShot) {
        isAiming = false
        game?.shotSettled(shot)
    }
}

/// What fills the full-screen cover above the navigation stack.
@MainActor enum ShellStage {
    case live(LiveSession)
    case review(GameReviewModel)
}

/// The app's navigation state machine (docs/design/app-shell.md).
/// Home → Game hub → New game | Join nearby → Live(.game) → Review → Home;  Home → Training → Live(.training).
@MainActor @Observable
final class AppRouter {
    var path: [ShellRoute] = []
    var sheet: ShellSheet?
    private(set) var stage: ShellStage?
    /// Builds the game's mesh from the lobby's session tag (production: `MeshGameLink`).
    @ObservationIgnored var meshFactory: ((UInt16) -> any GameMeshLink)?
    /// Saves each game's finished rack (production: `StackGameRecorder`; nil = nothing is saved).
    @ObservationIgnored var recorder: (any GameRecorder)?

    func openGame() { path = [.gameHub] }
    func openNewGame() { path = [.gameHub, .newGame] }
    func openJoinNearby() { path = [.gameHub, .joinNearby] }
    func openTraining() { path = [.training] }

    func startGame(_ config: GameConfig) {
        if case .live(let old)? = stage { old.game?.mesh?.stop(); old.game?.mesh = nil }
        let game = GameSessionModel(config: config)
        if let tag = config.sessionTag, let link = meshFactory?(tag) {
            link.start()
            game.mesh = link
        }
        stage = .live(LiveSession(mode: .game, game: game, drill: nil))
    }

    func startTraining(drill: DrillID, level: AssistLevel) {
        stage = .live(LiveSession(mode: .training(level), game: nil, drill: drill))
    }

    /// End game (menu) → review. Ignored in Training or when nothing is live, so a repeat is a no-op.
    /// Live leaves at once. A mesh game's review loads: it waits for this phone's inputs to commit, at most
    /// `endCap` seconds from End (D42: never stuck), then reviews what is committed and stops the link.
    func endGame() {
        guard case .live(let s)? = stage, let game = s.game else { return }
        guard let link = game.mesh else { stage = .review(review(game.reviewData())); return }
        let m = GameReviewModel(source: MeshReviewSource(game: game, link: link,
                                                         deadline: Date().addingTimeInterval(endCap)))
        m.onDone = { [weak self] in self?.finishReview() }
        stage = .review(m)
        Task { await m.load() }   // the link stops even if the review is never shown
    }
    @ObservationIgnored var endCap: Double = 2

    private func review(_ data: GameReviewData) -> GameReviewModel {
        let m = GameReviewModel(data: data)
        m.onDone = { [weak self] in self?.finishReview() }
        return m
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

/// A mesh game's review: the drain (raced against `deadline`), then the snapshot, then the link stops. Loads once;
/// a repeat `load()` (the view's own) awaits the same result.
@MainActor final class MeshReviewSource: GameReviewSource {
    private let game: GameSessionModel
    private let link: any GameMeshLink
    private let deadline: Date
    private var result: Task<GameReviewData, Never>?

    init(game: GameSessionModel, link: any GameMeshLink, deadline: Date) {
        self.game = game; self.link = link; self.deadline = deadline
    }

    func load() async throws -> GameReviewData {
        if let result { return await result.value }
        let (game, link, deadline) = (game, link, deadline)
        let task = Task {
            let drained = Task { await link.drain(until: deadline) }
            let cap = Task {   // a drain that overruns is cancelled at the deadline
                try? await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
                drained.cancel()
            }
            await drained.value
            cap.cancel()
            let data = game.reviewData()
            link.stop()
            if game.mesh === link { game.mesh = nil }
            return data
        }
        result = task
        return await task.value
    }
}

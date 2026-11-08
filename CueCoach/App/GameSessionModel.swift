import Foundation
import Observation
import Engine
import Rules
import Geometry

struct SessionShot: Hashable, Sendable {
    var id: UUID
    var index: Int
    var shooter: ShellPlayer
    var team: Int
    var rating: DecisionRating
}

/// In-game state the chrome shows: whose turn (D17 rotation), the post-shot badge, rated shots for review.
@MainActor @Observable
final class GameSessionModel {
    let config: GameConfig
    /// Current order per team (editable mid-game, SPEC §4).
    private(set) var teams: [[ShellPlayer]]
    /// D17 order: A1, B1, A2, B2, …
    var rotation: [ShellPlayer] {
        GameConfig(ruleSet: config.ruleSet, tableSize: config.tableSize, teams: teams).rotation
    }
    private(set) var turnIndex = 0
    private(set) var shots: [SessionShot] = []
    var isMenuOpen = false
    /// The game's mesh session when other phones joined (nil = this phone only).
    var mesh: (any GameMeshLink)?
    @ObservationIgnored let badge = PostShotBadgeModel()
    /// The game's rules (D11 rule set from setup) and state, which Live rates shots against and advances.
    @ObservationIgnored let rulesEngine: RulesEngine
    @ObservationIgnored private var rulesState: GameState

    init(config: GameConfig) {
        self.config = config
        teams = config.teams
        (rulesEngine, rulesState) = TargetLegality.startingGame(config.ruleSet, teams: config.teams.count)
    }

    /// Rules state with the shooter the chrome shows (a one-tap turn correction moves it too).
    var rules: (RulesEngine, GameState) {
        var g = rulesState
        g.shooter = shootingTeam
        return (rulesEngine, g)
    }

    /// Live settled a shot against `rules`: keep its next state.
    func rulesAdvanced(_ next: GameState) { rulesState = next }

    /// Joiner phones may not know the lineup yet (camera angle only).
    var hasLineup: Bool { !rotation.isEmpty }

    var shooter: ShellPlayer {
        rotation.isEmpty ? ShellPlayer(id: UUID(), name: "", symbol: "person.fill", colorName: "blue")
                         : rotation[turnIndex % rotation.count]
    }
    var shootingTeam: Int { teams.firstIndex { $0.contains(shooter) } ?? 0 }
    /// The other team's next player (shown dimmed).
    var waitingShooter: ShellPlayer? { rotation.isEmpty ? nil : rotation[(turnIndex + 1) % rotation.count] }

    /// Next player in D17 order (always the other team).
    func passTurn() { turnIndex += 1 }

    /// One-tap correction (SPEC §5.8): hand the turn to a team. No-op if it is already theirs.
    func handTurn(toTeam team: Int) {
        guard hasLineup, team != shootingTeam else { return }
        passTurn()
    }

    /// Swap two players within a team; the player shooting now keeps the turn.
    func swap(team: Int, _ a: Int, _ b: Int) {
        guard teams.indices.contains(team), teams[team].indices.contains(a), teams[team].indices.contains(b), a != b else { return }
        let current = shooter
        teams[team].swapAt(a, b)
        if let i = rotation.firstIndex(of: current) { turnIndex = i }
    }

    func record(rating: DecisionRating) {
        shots.append(SessionShot(id: UUID(), index: shots.count, shooter: shooter, team: shootingTeam, rating: rating))
    }

    /// The balls settled and the engine rated the shot: record it, show the badge, rotate if the turn passes.
    @discardableResult
    func shotSettled(rating: DecisionRating, turnPasses: Bool) -> PostShotRating {
        record(rating: rating)
        let s = shots[shots.count - 1]
        let signal = PostShotRating(shotID: s.id, rating: rating, shooterName: s.shooter.name, team: s.team)
        badge.receive(.rated(signal))
        if turnPasses { passTurn() }
        return signal
    }

    func aimStarted() { badge.receive(.aimStarted) }
    func aimEnded() { badge.receive(.aimEnded) }

    func reviewData() -> GameReviewData {
        func rp(_ p: ShellPlayer) -> ReviewPlayer { ReviewPlayer(id: p.id, name: p.name, symbol: p.symbol, colorName: p.colorName) }
        var teams = self.teams.map { $0.map(rp) }
        while teams.count < 2 { teams.append([]) }
        let reviewShots = shots.map {
            ReviewShot(id: $0.id, index: $0.index, shooter: rp($0.shooter), team: $0.team, rating: $0.rating,
                       pre: nil, post: nil, pocketed: [:], fouls: [], paths: [:], alternative: nil, wpaDelta: 0)
        }
        return GameReviewData(gameIndex: 0, teams: teams, score: [0, 0], winnerTeam: nil, isFinished: true,
                              winProb: [], shots: reviewShots, shotOfGame: nil, tableSize: config.tableSize)
    }
}

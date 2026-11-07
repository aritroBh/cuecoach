import Foundation
import Observation
import Engine
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
    let rotation: [ShellPlayer]
    private(set) var turnIndex = 0
    private(set) var shots: [SessionShot] = []
    var isMenuOpen = false
    @ObservationIgnored let badge = PostShotBadgeModel()

    init(config: GameConfig) {
        self.config = config
        rotation = config.rotation
    }

    /// Joiner phones may not know the lineup yet (camera angle only).
    var hasLineup: Bool { !rotation.isEmpty }

    var shooter: ShellPlayer {
        rotation.isEmpty ? ShellPlayer(id: UUID(), name: "", symbol: "person.fill", colorName: "blue")
                         : rotation[turnIndex % rotation.count]
    }
    var shootingTeam: Int { config.team(of: shooter) }
    /// The other team's next player (shown dimmed).
    var waitingShooter: ShellPlayer? { rotation.isEmpty ? nil : rotation[(turnIndex + 1) % rotation.count] }

    /// Next player in D17 order (always the other team).
    func passTurn() { turnIndex += 1 }

    /// One-tap correction (SPEC §5.8): hand the turn to a team. No-op if it is already theirs.
    func handTurn(toTeam team: Int) {
        guard hasLineup, team != shootingTeam else { return }
        passTurn()
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
        var teams = config.teams.map { $0.map(rp) }
        while teams.count < 2 { teams.append([]) }
        let reviewShots = shots.map {
            ReviewShot(id: $0.id, index: $0.index, shooter: rp($0.shooter), team: $0.team, rating: $0.rating,
                       pre: nil, post: nil, pocketed: [:], fouls: [], paths: [:], alternative: nil, wpaDelta: 0)
        }
        return GameReviewData(gameIndex: 0, teams: teams, score: [0, 0], winnerTeam: nil, isFinished: true,
                              winProb: [], shots: reviewShots, shotOfGame: nil, tableSize: config.tableSize)
    }
}

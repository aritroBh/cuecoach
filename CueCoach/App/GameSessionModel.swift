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
    /// Turn changes so far (drives the disc animation and haptic).
    private(set) var turnIndex = 0
    /// D17 per-team cursors: the team at the table, the slot (in its current order) of the player shooting, and per
    /// team the slot that plays its next visit. A mid-game swap moves slots, never a pending visit (review finding 2).
    private var currentTeam = 0
    private var currentSlot = 0
    private var nextSlot: [Int]
    private(set) var shots: [SessionShot] = []
    var isMenuOpen = false
    /// The game's mesh session when other phones joined (nil = this phone only).
    var mesh: (any GameMeshLink)?
    @ObservationIgnored let badge = PostShotBadgeModel()
    /// The game's rules (D11 rule set from setup) and state, which Live rates shots against and advances.
    @ObservationIgnored let rulesEngine: RulesEngine
    @ObservationIgnored private var rulesState: GameState
    /// Ring legality changed outside a settled shot (a between-shots turn hand-over): the new shooter's legal targets.
    /// Same payload as Live's `LiveModel.legalChanged` after a settled shot; the shell forwards it to Live's pipeline.
    @ObservationIgnored var legalChanged: (Set<BallID>) -> Void = { _ in }

    init(config: GameConfig) {
        self.config = config
        teams = config.teams
        nextSlot = Array(repeating: 0, count: config.teams.count)
        currentTeam = config.teams.firstIndex { !$0.isEmpty } ?? 0
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
        guard hasLineup, teams[currentTeam].indices.contains(currentSlot) else {
            return ShellPlayer(id: UUID(), name: "", symbol: "person.fill", colorName: "blue")
        }
        return teams[currentTeam][currentSlot]
    }
    var shootingTeam: Int { hasLineup ? currentTeam : 0 }
    /// The other team's next player (shown dimmed).
    var waitingShooter: ShellPlayer? {
        guard hasLineup else { return nil }
        let t = team(after: currentTeam)
        return teams[t][nextSlot[t] % teams[t].count]
    }

    /// Next player in D17 order (always the other team): this team's next visit moves one slot on.
    func passTurn() {
        turnIndex += 1
        guard hasLineup else { return }
        nextSlot[currentTeam] = (currentSlot + 1) % teams[currentTeam].count
        let t = team(after: currentTeam)
        currentTeam = t
        currentSlot = nextSlot[t] % teams[t].count
    }

    /// The next team with players, in team order.
    private func team(after t: Int) -> Int {
        let n = teams.count
        return (1...n).lazy.map { (t + $0) % n }.first { !self.teams[$0].isEmpty } ?? t
    }

    /// One-tap correction (SPEC §5.8): hand the turn to a team. No-op if it is already theirs.
    /// Call it through `LiveSession.handTurn`, which refuses while a shot is live. The new shooter's legal targets are
    /// pushed at once, so their rings aren't the old team's red/green until the next settled shot.
    func handTurn(toTeam team: Int) {
        guard hasLineup, team != shootingTeam else { return }
        passTurn()
        let (engine, state) = rules
        legalChanged(engine.legalTargets(state))
    }

    /// Swap two players within a team; the player shooting now keeps the turn, and every team's next visit stays
    /// on its slot (so the other team's pending player still shoots next).
    func swap(team: Int, _ a: Int, _ b: Int) {
        guard teams.indices.contains(team), teams[team].indices.contains(a), teams[team].indices.contains(b), a != b else { return }
        teams[team].swapAt(a, b)
        if team == currentTeam {
            if currentSlot == a { currentSlot = b } else if currentSlot == b { currentSlot = a }
        }
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

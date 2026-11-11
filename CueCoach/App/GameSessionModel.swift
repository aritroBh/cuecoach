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
    /// nil = a gap: a lost shot with no guess (D38), result unknown.
    var rating: DecisionRating?
    /// What the Rules engine saw (`SettledShot`); a D31 guess is flagged.
    var pocketed: [BallID: Pocket] = [:]
    var fouls: [Foul] = []
    var isGuess = false
    /// Ball positions (table metres) before and after the shot, from `SettledShot`.
    var before: [BallID: Vec2] = [:]
    var after: [BallID: Vec2] = [:]
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
    /// D38: a lost shot left a gap; the turn discs ask who shoots next until a tap or the next aim.
    private(set) var needsShooter = false
    var isMenuOpen = false
    /// The game's mesh session when other phones joined (nil = this phone only).
    var mesh: (any GameMeshLink)?
    @ObservationIgnored let badge = PostShotBadgeModel()
    /// The game's rules (D11 rule set from setup) and state, which Live rates shots against and advances.
    @ObservationIgnored let rulesEngine: RulesEngine
    @ObservationIgnored private var rulesState: GameState
    /// Ring legality changed outside a settled shot (a between-shots turn hand-over): the new shooter's legal targets.
    /// Same payload as Live's `LiveModel.legalChanged` after a settled shot; `LiveScreenAdapter.hooks` binds it to Live's sink.
    @ObservationIgnored var legalChanged: @MainActor (Set<BallID>) -> Void = { _ in }

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

    func record(rating: DecisionRating) { record(SettledShot(rating: rating, turnPasses: false)) }

    private func record(_ r: SettledShot) {
        shots.append(SessionShot(id: UUID(), index: shots.count, shooter: shooter, team: shootingTeam, rating: r.rating,
                                 pocketed: r.pocketed, fouls: r.fouls, isGuess: r.isGuess,
                                 before: r.before, after: r.after))
    }

    @discardableResult
    func shotSettled(rating: DecisionRating, turnPasses: Bool) -> PostShotRating {
        shotSettled(SettledShot(rating: rating, turnPasses: turnPasses))
    }

    /// The balls settled and the engine rated the shot: record it (with its result, for review), show the badge,
    /// rotate if the turn passes.
    @discardableResult
    func shotSettled(_ shot: SettledShot) -> PostShotRating {
        record(shot)
        let s = shots[shots.count - 1]
        let signal = PostShotRating(shotID: s.id, rating: shot.rating, shooterName: s.shooter.name, team: s.team)
        badge.receive(.rated(signal))
        if shot.turnPasses { passTurn() }
        return signal
    }

    /// D38: a game shot was lost with no guess. (Stub.)
    func shotLost() {}

    func aimStarted() { badge.receive(.aimStarted) }
    func aimEnded() { badge.receive(.aimEnded) }

    /// The review header follows the rules: winner from the rack's final state, score = racks won this session (one
    /// rack per game session), finished only when the rack is over (a mid-rack quit stays locked).
    /// Each rated shot carries what the Rules engine saw (pocketed with pocket, fouls) and its D31 guess flag, plus
    /// pre/post table states from its ball positions with straight paths (none when no position is known).
    func reviewData() -> GameReviewData {
        func rp(_ p: ShellPlayer) -> ReviewPlayer { ReviewPlayer(id: p.id, name: p.name, symbol: p.symbol, colorName: p.colorName) }
        var teams = self.teams.map { $0.map(rp) }
        while teams.count < 2 { teams.append([]) }
        let spec = TableSpec(size: config.tableSize)
        let reviewShots = shots.map { s -> ReviewShot in
            var pre: TableState?, post: TableState?, paths: [BallID: [Vec2]] = [:]
            // A D31 guess has no after table (finalState is empty): no replay rather than a made-up one.
            if !s.before.isEmpty && !s.isGuess {
                let b = TableState(spec: spec, balls: s.before.mapValues { BallState(position: $0, motion: .stationary) })
                var after = s.after.mapValues { BallState(position: $0, motion: .stationary) }
                for id in s.pocketed.keys { after[id] = BallState(position: s.before[id] ?? .zero, motion: .pocketed) }
                let a = TableState(spec: spec, balls: after)
                pre = b; post = a
                paths = ReviewPaths.straight(pre: b, post: a, pocketed: s.pocketed)
            }
            return ReviewShot(id: s.id, index: s.index, shooter: rp(s.shooter), team: s.team, rating: s.rating,
                              pre: pre, post: post, pocketed: s.pocketed, fouls: s.fouls, paths: paths,
                              alternative: nil, wpaDelta: 0, pathsAreTraced: false, isGuess: s.isGuess)
        }
        let winner = rulesState.winner.flatMap { teams.indices.contains($0) ? $0 : nil }
        var score = [Int](repeating: 0, count: teams.count)
        if let winner { score[winner] += 1 }
        return GameReviewData(gameIndex: 0, teams: teams, score: score, winnerTeam: winner, isFinished: winner != nil,
                              winProb: [], shots: reviewShots, shotOfGame: nil, tableSize: config.tableSize)
    }
}

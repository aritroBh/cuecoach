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
    /// `.turnOrder` (D17), or `.tap` once a logged `shooterCorrection` fixed this shot's team.
    var attribution: AttributionSource = .turnOrder
}

/// In-game state the chrome shows: whose turn (D17 rotation), the post-shot badge, rated shots for review.
/// One game log is the source of truth (INTERFACES "Shot log", D39/D41/D38): the host (or this phone alone) appends,
/// and every phone builds `shots`, the badge, the turn and the rules state by folding the committed prefix.
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
    /// The game's mesh session when other phones joined (nil = this phone only). Its committed log drives the fold.
    var mesh: (any GameMeshLink)? {
        didSet {
            oldValue?.onCommittedLog = nil
            mesh?.onCommittedLog = { [weak self] log, seq in self?.ingest(log: log, commitSeq: seq) }
        }
    }
    @ObservationIgnored let badge = PostShotBadgeModel()
    /// The game's rules (D11 rule set from setup) and state, which Live rates shots against. The fold owns the state.
    @ObservationIgnored let rulesEngine: RulesEngine
    @ObservationIgnored private var rulesState: GameState
    /// Ring legality changed outside a settled shot (a between-shots turn hand-over): the new shooter's legal targets.
    /// Same payload as Live's `LiveModel.legalChanged` after a settled shot; `LiveScreenAdapter.hooks` binds it to Live's sink.
    @ObservationIgnored var legalChanged: @MainActor (Set<BallID>) -> Void = { _ in }
    /// The committed log in order (solo: this phone's own log, committed at once).
    @ObservationIgnored private var events: [GameEvent] = []
    /// Mid-game swaps stay local (not logged yet): each is replayed after its first `afterEvent` events.
    @ObservationIgnored private var swaps: [(afterEvent: Int, team: Int, a: Int, b: Int)] = []
    /// Shots whose badge already fired: once per shot id, across re-folds.
    @ObservationIgnored private var badged: Set<UUID> = []
    /// D38: an aim answered the ask once this many events were folded (the current shooter keeps the turn).
    @ObservationIgnored private var askAnsweredAt = -1

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
    /// The fold calls it; a direct call outside the fold lasts only until the next re-fold.
    func passTurn() { hand(to: hasLineup ? team(after: currentTeam) : currentTeam) }

    /// Hand the table to team `t`: this team's next visit moves one slot on, `t` plays its pending visit.
    private func hand(to t: Int) {
        turnIndex += 1
        guard hasLineup else { return }
        nextSlot[currentTeam] = (currentSlot + 1) % teams[currentTeam].count
        currentTeam = t
        currentSlot = nextSlot[t] % teams[t].count
    }

    /// The next team with players, in team order.
    private func team(after t: Int) -> Int {
        let n = teams.count
        return (1...n).lazy.map { (t + $0) % n }.first { !self.teams[$0].isEmpty } ?? t
    }

    /// One-tap correction (SPEC §5.8): hand the turn to a team. No-op if it is already theirs, except while a lost shot
    /// asks for the shooter (D38): then the active team's tap confirms it. D41: only the next shooter changes, as a
    /// logged `.nextShooter` (a client proposes it). Call it through `LiveSession.handTurn`, which refuses while a shot
    /// is live. Once it folds, the new shooter's legal targets are pushed, so their rings aren't the old team's.
    func handTurn(toTeam team: Int) {
        guard hasLineup, teams.indices.contains(team), team != shootingTeam || needsShooter else { return }
        append(.nextShooter(team: team))
    }

    /// Swap two players within a team; the player shooting now keeps the turn, and every team's next visit stays
    /// on its slot (so the other team's pending player still shoots next). Local only: kept and replayed by the fold.
    func swap(team: Int, _ a: Int, _ b: Int) {
        guard teams.indices.contains(team), teams[team].indices.contains(a), teams[team].indices.contains(b), a != b else { return }
        swaps.append((events.count, team, a, b))
        applySwap(team, a, b)
    }

    private func applySwap(_ team: Int, _ a: Int, _ b: Int) {
        guard teams.indices.contains(team), teams[team].indices.contains(a), teams[team].indices.contains(b) else { return }
        teams[team].swapAt(a, b)
        if team == currentTeam {
            if currentSlot == a { currentSlot = b } else if currentSlot == b { currentSlot = a }
        }
    }

    func record(rating: DecisionRating) { shotSettled(SettledShot(rating: rating, turnPasses: false)) }

    @discardableResult
    func shotSettled(rating: DecisionRating, turnPasses: Bool) -> PostShotRating? {
        shotSettled(SettledShot(rating: rating, turnPasses: turnPasses))
    }

    /// The balls settled and Live rated the shot. The host (or this phone alone) logs it; a client drops its own
    /// settle (D39: the host rates). Shot, badge and turn come from the fold. Returns the badge signal when the shot
    /// folded at once (solo), else nil.
    @discardableResult
    func shotSettled(_ shot: SettledShot) -> PostShotRating? {
        guard writesLog else { return nil }
        let id = UUID()
        append(.shot(MeshShotRecord(shotID: id, shooterTeam: shootingTeam, outcome: shot.outcome,
                                    postState: table(shot.after), preState: table(shot.before),
                                    decisionRating: shot.rating, isGuess: shot.isGuess)))
        guard let s = shots.last(where: { $0.id == id }), let rating = s.rating else { return nil }
        return PostShotRating(shotID: s.id, rating: rating, shooterName: s.shooter.name, team: s.team)
    }

    /// D38: a game shot was lost with no guess. The host (or this phone alone) logs a gap for the current shooter,
    /// which asks who shoots next; the shooter stays until a disc tap or the next aim.
    func shotLost() {
        guard writesLog else { return }
        append(.shotLost(shotID: UUID(), shooterTeam: shootingTeam))
    }

    /// A new shot starting answers the ask: the current shooter keeps the turn (D38: never block play).
    func aimStarted() {
        askAnsweredAt = events.count
        needsShooter = false
        badge.receive(.aimStarted)
    }
    func aimEnded() { badge.receive(.aimEnded) }

    // MARK: The log

    /// Solo, or this phone hosts the mesh.
    private var writesLog: Bool { mesh?.isHost ?? true }

    /// Solo: commits at once. Mesh: the host appends (a client proposes); the commit comes back through `ingest`.
    private func append(_ event: GameEvent) {
        if let mesh { mesh.append(event) } else { apply(events + [event]) }
    }

    /// The mesh's log changed: fold its committed prefix. The uncommitted tail never shows.
    func ingest(log: [LogEntry], commitSeq: UInt64) {
        apply(log.filter { $0.seq <= commitSeq }.sorted { $0.seq < $1.seq }.map(\.event))
    }

    private func apply(_ committed: [GameEvent]) {
        let fresh = committed.dropFirst(events.count)
        events = committed
        fold()
        // The badge fires once per shot, for the newest newly committed rated shot only.
        let unseen = shots.filter { !badged.contains($0.id) }
        badged.formUnion(unseen.map(\.id))
        if let s = unseen.last(where: { $0.rating != nil }), let rating = s.rating {
            badge.receive(.rated(PostShotRating(shotID: s.id, rating: rating, shooterName: s.shooter.name, team: s.team)))
        }
        if fresh.contains(where: { if case .nextShooter = $0 { true } else { false } }) {
            let (engine, state) = rules
            legalChanged(engine.legalTargets(state))
        }
    }

    /// Rebuild the turn, shots and rules state from scratch: the `GameConfig` lineup, the committed events and the
    /// local swaps in place.
    private func fold() {
        teams = config.teams
        nextSlot = Array(repeating: 0, count: teams.count)
        currentTeam = teams.firstIndex { !$0.isEmpty } ?? 0
        currentSlot = 0
        turnIndex = 0
        shots = []
        needsShooter = false
        rulesState = TargetLegality.startingGame(config.ruleSet, teams: config.teams.count).1
        var corrected: [UUID: Int] = [:]
        for case .shooterCorrection(let id, let team) in events { corrected[id] = team }
        var lostAt = -1
        for i in 0...events.count {
            for w in swaps where w.afterEvent == i { applySwap(w.team, w.a, w.b) }
            guard i < events.count else { break }
            switch events[i] {
            case .ruleSetChosen, .shooterCorrection:
                break
            case .shot(let r):
                needsShooter = false
                var attribution = AttributionSource.turnOrder
                if let t = corrected[r.shotID] {
                    attribution = .tap
                    if hasLineup, teams.indices.contains(t), !teams[t].isEmpty, t != currentTeam { hand(to: t) }
                }
                var state = rulesState
                state.shooter = shootingTeam
                let result = rulesEngine.apply(r.outcome, to: state)
                let rating = r.decisionRating ?? RuleRating.classify(
                    result, shooter: state.shooter, pocketedObjectBall: r.outcome.pocketed.keys.contains { $0 != .cue })
                shots.append(SessionShot(id: r.shotID, index: shots.count, shooter: shooter, team: shootingTeam,
                                         rating: rating, pocketed: r.outcome.pocketed, fouls: result.fouls,
                                         isGuess: r.isGuess, before: Self.positions(r.preState),
                                         after: Self.positions(r.postState), attribution: attribution))
                rulesState = result.nextState
                if result.turnPasses { passTurn() }
            case .shotLost(let id, _):
                shots.append(SessionShot(id: id, index: shots.count, shooter: shooter, team: shootingTeam, rating: nil))
                needsShooter = true
                lostAt = i
            case .nextShooter(let team):
                guard hasLineup, teams.indices.contains(team), !teams[team].isEmpty else { break }
                needsShooter = false
                if team != currentTeam { hand(to: team) }
            }
        }
        if needsShooter && askAnsweredAt > lostAt { needsShooter = false }
    }

    /// Ball positions as a table state on the game's table (nil when none are known).
    private func table(_ balls: [BallID: Vec2]) -> TableState? {
        balls.isEmpty ? nil : TableState(spec: TableSpec(size: config.tableSize), balls: balls.mapValues { BallState(position: $0) })
    }

    private static func positions(_ t: TableState?) -> [BallID: Vec2] { t?.balls.mapValues(\.position) ?? [:] }

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

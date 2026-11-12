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
    /// `ShotOutcome.firstContact` (nil for a gap).
    var firstContact: BallID? = nil
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
    /// Saves the finished rack (plan 011). nil = nothing is saved.
    @ObservationIgnored var recorder: (any GameRecorder)?
    @ObservationIgnored private let startedAt = Date()
    /// When the fold first gave the rack a winner (the saved `endedAt`).
    @ObservationIgnored private var wonAt: Date?
    /// This phone saved the rack: later commits and `endGame` write nothing more.
    @ObservationIgnored private var saved = false
    /// Folded shots up to and including the one that gave the rack its winner (the saved rack's boundary).
    @ObservationIgnored private var winningShotCount: Int?

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

    /// The balls settled and Live rated the shot. The host (or this phone alone) logs it; a client drops its own
    /// settle (D39: the host rates) and re-pushes the committed legality over what Live published locally. Shot, badge
    /// and turn come from the fold. Returns the badge signal when the shot folded at once (solo), else nil.
    @discardableResult
    func shotSettled(_ shot: SettledShot) -> PostShotRating? {
        guard writesLog else { pushLegal(); return nil }
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
        guard writesLog else { pushLegal(); return }
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

    /// Solo, the host, or a phone whose role is unresolved (the link buffers it; a joiner then drops its shots).
    private var writesLog: Bool { !(mesh?.isJoiner ?? false) }

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
        // Any newly committed event can move the rules state or the shooter: Live's rings follow the fold.
        if !fresh.isEmpty { pushLegal() }
        saveIfWon()
    }

    /// D45: the commit that gives the rack its winner saves it, on the one writer: solo, or the host (role `.host`
    /// only, never `!isJoiner`; a discovering phone never saves) with a majority of the game's members
    /// (`hasGameQuorum`; an island never saves, plan 013 merges first). A throw is logged and retried on the next
    /// commit with the same rack (shots up to the winning one); it never blocks play or review.
    private func saveIfWon() {
        guard winner != nil else { return }
        if wonAt == nil { wonAt = Date() }
        guard !saved, let recorder, let game = finishedGame() else { return }
        if let mesh, !(mesh.isHost && mesh.hasGameQuorum) { return }
        do {
            try recorder.record(game)
            saved = true
        } catch {
            StackGameRecorder.log.error("saving the finished rack failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// The folded rack's winning team, when it has one.
    private var winner: Int? { rulesState.winner.flatMap { config.teams.indices.contains($0) ? $0 : nil } }

    /// The shooter's legal targets in the committed folded state, to Live's rings.
    private func pushLegal() {
        let (engine, state) = rules
        legalChanged(engine.legalTargets(state))
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
        winningShotCount = nil
        var corrected: [UUID: Int] = [:]
        for case .shooterCorrection(let id, let team, _) in events { corrected[id] = team }
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
                                         after: Self.positions(r.postState), attribution: attribution,
                                         firstContact: r.outcome.firstContact))
                rulesState = result.nextState
                if winningShotCount == nil, rulesState.winner != nil { winningShotCount = shots.count }
                if result.turnPasses { passTurn() }
            case .shotLost(let id, _):
                shots.append(SessionShot(id: id, index: shots.count, shooter: shooter, team: shootingTeam, rating: nil))
                needsShooter = true
                lostAt = i
            case .nextShooter(let team, _):
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

    /// The finished rack to save, or nil while the folded rules state has no winner (D40).
    /// Shots up to the winning one keep their folded index; D38 gaps and D31 guesses are left out (plan 012 saves
    /// guesses). Shots committed after the win are not part of the rack.
    /// nil too when the teams fit no `GameFormat` (setup forbids uneven or over-four teams).
    func finishedGame() -> FinishedGame? {
        guard let winner, let first = shots.first,
              let format = GameFormat.allCases.first(where: { $0.playersPerTeam == config.playersPerTeam }),
              config.teams.allSatisfy({ $0.count == format.playersPerTeam }) else { return nil }
        let teams = config.teams.map { t in StoredTeam(memberIDs: t.map(\.id), shootingOrder: t.map(\.id)) }
        return FinishedGame(id: first.id, ruleSet: config.ruleSet, tableSize: config.tableSize, format: format,
                            teams: teams, winnerTeam: winner, winProbSeries: [], startedAt: startedAt,
                            endedAt: wonAt ?? Date(),
                            shots: shots.prefix(winningShotCount ?? shots.count)
                                .compactMap { RecordedShot($0, tableSize: config.tableSize) })
    }

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

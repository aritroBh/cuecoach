import CoreGraphics
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
    /// Plan 013a/013b: an island merge kept one of two disagreeing views; `alternateOutcome` carries the other view (D47).
    var needsTap = false
    var alternateOutcome: ShotOutcome? = nil
    /// Engine / Highlight enrichments (D55).
    var outcome: ShotOutcome = ShotOutcome()
    var executionRating: ExecutionRating? = nil
    var wpaDelta: Double = 0
    var isClutch = false
    var clipRef: String? = nil
    var alternative: EngineAlternative? = nil
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
            oldValue?.onClipReceived = nil
            if let oldValue, mesh == nil {
                wasJoinerAtEnd = oldValue.isJoiner
                wasHostAtEnd = oldValue.isHost
                hadQuorumAtEnd = oldValue.hasGameQuorum
                wasIslandAtEnd = oldValue.isIsland
            } else if mesh != nil {
                hadMeshSession = true
                wasJoinerAtEnd = false
                wasHostAtEnd = false
                hadQuorumAtEnd = false
                wasIslandAtEnd = false
            }
            mesh?.onCommittedLog = { [weak self] log, seq in self?.ingest(log: log, commitSeq: seq) }
            mesh?.onClipReceived = { [weak self] shotID, data in
                guard let self else { return }
                let base = self.clipRecorder?.baseDirectory ?? ShotClipStore.defaultBaseDirectory
                if let rel = try? ShotClipStore.saveReceivedClip(shotID: shotID, data: data, baseDirectory: base) {
                    self.attachClip(shotID: shotID, relativePath: rel)
                    self.onReviewRefreshed?(self.reviewData())
                }
            }
        }
    }
    /// Preserves mesh role/quorum/island state after `endGame` tears down `mesh` (D39, D51, plan 013b/015).
    @ObservationIgnored private var hadMeshSession = false
    @ObservationIgnored private var wasJoinerAtEnd = false
    @ObservationIgnored private var wasHostAtEnd = false
    @ObservationIgnored private var hadQuorumAtEnd = false
    @ObservationIgnored private var wasIslandAtEnd = false
    @ObservationIgnored private var manuallyDeletedRack = false
    @ObservationIgnored private(set) var isAimingOrMoving = false
    var isJoinerSession: Bool { mesh?.isJoiner ?? wasJoinerAtEnd }
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
    /// Shots whose confirmed badge already fired: once per shot id, across re-folds.
    @ObservationIgnored private var badged: Set<UUID> = []
    /// Shots whose provisional island badge already fired (D48); a confirmed commit after heal still replaces it.
    @ObservationIgnored private var provisionalBadged: Set<UUID> = []
    /// D38: an aim answered the ask once this many events were folded (the current shooter keeps the turn).
    @ObservationIgnored private var askAnsweredAt = -1
    /// Plan 013a: the stroke clock (`MultipeerMeshSession.hostNow()`, seconds); a settle's stroke is the last aim end.
    @ObservationIgnored var now: () -> Double = { MultipeerMeshSession.hostNow() }
    /// The last aim end (the stroke), consumed by the next settle or lost shot.
    @ObservationIgnored private var strokeAt: Double?
    /// Saves the finished rack (plan 011). nil = nothing is saved.
    @ObservationIgnored var recorder: (any GameRecorder)?
    @ObservationIgnored private let startedAt = Date()
    /// When the fold first gave the rack a winner (the saved `endedAt`).
    @ObservationIgnored private var wonAt: Date?
    /// This phone saved the rack; corrections in Review can still update or remove it (D49, D54).
    @ObservationIgnored private var saved = false
    @ObservationIgnored private var savedGameID: UUID?
    @ObservationIgnored private var lastSaved: FinishedGame?
    /// Folded shots up to and including the one that gave the rack its winner (the saved rack's boundary).
    @ObservationIgnored private var winningShotCount: Int?
    /// Background `CueCore/Engine.ShotEngine` evaluator (wired by `AppRouter.startGame` or tests).
    @ObservationIgnored var engineEvaluator: SessionEngineEvaluator?
    @ObservationIgnored private var engineSummary: SessionEngineSummary?
    @ObservationIgnored private var engineTask: Task<Void, Never>?
    @ObservationIgnored private var engineGeneration = 0
    /// Relative clip file paths by `shotID`, recorded locally or received over mesh.
    @ObservationIgnored private(set) var shotClipFiles: [UUID: String] = [:]
    /// Rolling SotG video clip recorder + opt-in shooter attribution session (D55).
    @ObservationIgnored var clipRecorder: ShotClipRecorder?
    @ObservationIgnored var identitySession: IdentitySession?
    @ObservationIgnored var shooterIdentifier: (any ShooterIdentifier)?
    @ObservationIgnored var onReviewRefreshed: (@MainActor (GameReviewData) -> Void)?
    @ObservationIgnored private var shotStrokeTimes: [UUID: Double] = [:]
    @ObservationIgnored private var shotSettledTimes: [UUID: Double] = [:]
    @ObservationIgnored private var lastLocalStrokeAt: Double?
    @ObservationIgnored private var localClosedShotCount = 0
    @ObservationIgnored private var openPhysicalTokens: Set<UUID> = []
    @ObservationIgnored private var recentIdentityFrames: [(timestamp: Double, frame: IdentityFrame)] = []
    @ObservationIgnored private var latchedStrokeFrames: [IdentityFrame]?
    @ObservationIgnored private var latchedStrokeTime: Double?
    @ObservationIgnored private var autoAttributions: [UUID: UUID] = [:]
    @ObservationIgnored private var unknownGuestShots: Set<UUID> = []
    @ObservationIgnored private var hasUncommittedLogEntries = false

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

    /// The balls settled and Live rated the shot. Solo logs it at once. In a mesh every phone hands it to
    /// `mesh.settled` with its stroke (plan 013a): the host logs it, a client keeps it for a re-run after a host loss
    /// (D39: the host rates; the client re-pushes the committed legality over what Live published locally). An island
    /// shows its own rating as a provisional badge (D48). Shot, badge and turn come from the fold. Returns the badge
    /// signal when the shot folded at once (solo), else nil.
    @discardableResult
    func shotSettled(_ shot: SettledShot) -> PostShotRating? {
        let id = UUID()
        let strokeTime = takeStroke()
        let settledTime = now()
        let closedIndex = localClosedShotCount
        localClosedShotCount += 1
        shotStrokeTimes[id] = strokeTime
        shotSettledTimes[id] = settledTime
        isAimingOrMoving = false
        if let token = shot.clipToken {
            openPhysicalTokens.remove(token)
            if writesLog, let recorder = clipRecorder {
                Task { @MainActor [weak self] in
                    if await recorder.bindToken(token, to: id, boundIndex: closedIndex) {
                        self?.scheduleEngineEvaluation()
                    }
                }
            }
        } else if !shot.isGuess, let recorder = clipRecorder {
            if writesLog {
                Task { await recorder.sealShot(shotID: id, strokeAt: strokeTime, settledAt: settledTime, boundIndex: closedIndex) }
            } else {
                Task { @MainActor [weak self] in
                    if await recorder.sealPendingLocalIndex(closedIndex, strokeAt: strokeTime, settledAt: settledTime) != nil {
                        self?.scheduleEngineEvaluation()
                    }
                }
            }
        }
        let event = GameEvent.shot(MeshShotRecord(shotID: id, shooterTeam: shootingTeam, outcome: shot.outcome,
                                                  postState: table(shot.after), preState: table(shot.before),
                                                  decisionRating: shot.rating, isGuess: shot.isGuess))
        if let mesh {
            mesh.setPhase(rulesState.winner != nil ? .gameOver : .settled)
            mesh.settled(event, strokeAt: strokeTime)
            guard writesLog else { pushLegal(); return nil }
            if mesh.isIsland, provisionalBadged.insert(id).inserted {
                badge.receive(.rated(PostShotRating(shotID: id, rating: shot.rating, shooterName: shooter.name,
                                                    team: shootingTeam, isProvisional: true)))
            }
        } else {
            append(event)
        }
        if identitySession != nil, shooterIdentifier != nil {
            let frames = latchedStrokeFrames ?? recentIdentityFrames
                .filter { abs($0.timestamp - strokeTime) <= 0.75 }
                .map(\.frame)
            latchedStrokeFrames = nil
            latchedStrokeTime = nil
            let window = StrokeWindow(frames: frames)
            Task { @MainActor [weak self] in
                _ = await self?.attributeStroke(shotID: id, window: window)
            }
        } else {
            latchedStrokeFrames = nil
            latchedStrokeTime = nil
        }
        guard let s = shots.last(where: { $0.id == id }), let rating = s.rating else { return nil }
        return PostShotRating(shotID: s.id, rating: rating, shooterName: s.shooter.name, team: s.team)
    }

    /// D38: a game shot was lost with no guess. Solo logs a gap for the current shooter, which asks who shoots next;
    /// the shooter stays until a disc tap or the next aim. In a mesh it goes to `mesh.settled` like a settle.
    func shotLost() {
        isAimingOrMoving = false
        localClosedShotCount += 1
        let event = GameEvent.shotLost(shotID: UUID(), shooterTeam: shootingTeam)
        if let mesh {
            mesh.setPhase(.settled)
            mesh.settled(event, strokeAt: takeStroke())
            if !writesLog { pushLegal() }
        } else {
            append(event)
        }
    }

    /// A new shot starting answers the ask: the current shooter keeps the turn (D38: never block play).
    func aimStarted() {
        isAimingOrMoving = true
        askAnsweredAt = events.count
        needsShooter = false
        badge.receive(.aimStarted)
        mesh?.setPhase(.aiming)
    }

    /// Seals `[start - 1.0, end + 2.0]` on the camera clock immediately when `ShotSegmenter` ends the physical shot
    /// (`LiveModel.enqueue`), BEFORE any pocket-confirmation prompt can delay `shotSettled`.
    func notePhysicalShotEnd(token: UUID, aheadInFIFO: Int, start: Double, end: Double) {
        openPhysicalTokens.insert(token)
        let ordinal = localClosedShotCount + aheadInFIFO
        if let recorder = clipRecorder {
            if writesLog {
                Task { await recorder.sealToken(token, strokeAt: start, settledAt: end) }
            } else {
                Task { @MainActor [weak self] in
                    if await recorder.sealPendingLocalIndex(ordinal, strokeAt: start, settledAt: end) != nil {
                        self?.scheduleEngineEvaluation()
                    }
                }
            }
        }
    }

    func notePhysicalShotsReset() {
        openPhysicalTokens.removeAll()
    }

    func aimEnded() {
        if openPhysicalTokens.isEmpty {
            localClosedShotCount = max(localClosedShotCount, shots.count)
        }
        let t = now()
        strokeAt = t
        lastLocalStrokeAt = t
        latchedStrokeTime = t
        latchedStrokeFrames = recentIdentityFrames
            .filter { abs($0.timestamp - t) <= 0.75 }
            .map(\.frame)
        badge.receive(.aimEnded)
        mesh?.setPhase(.inMotion)
    }

    func noteTableQuiet(_ quiet: Bool) {
        if !quiet { isAimingOrMoving = true }
    }

    func noteCameraFrame(_ image: CGImage, timestamp: Double, cueBall: CGPoint) {
        if let recorder = clipRecorder {
            Task { await recorder.pushFrame(image, timestamp: timestamp) }
        }
        let idFrame = IdentityFrame(image: image, cueBall: cueBall)
        recentIdentityFrames.append((timestamp, idFrame))
        if let st = latchedStrokeTime, abs(timestamp - st) <= 0.75 {
            var latched = latchedStrokeFrames ?? []
            if latched.count < 16 {
                latched.append(idFrame)
                latchedStrokeFrames = latched
            }
        }
        let cutoff = timestamp - 2.5
        recentIdentityFrames.removeAll { $0.timestamp < cutoff }
        if recentIdentityFrames.count > 24 {
            recentIdentityFrames.removeFirst(recentIdentityFrames.count - 24)
        }
    }

    /// The stroke of the shot that just settled: the last aim end, else now.
    private func takeStroke() -> Double {
        defer { strokeAt = nil }
        return strokeAt ?? now()
    }

    // MARK: The log

    /// Solo, the host, or a phone whose role is unresolved (the link buffers it; a joiner then drops its shots).
    private var writesLog: Bool { !(mesh?.isJoiner ?? false) }

    /// Solo: commits at once. Mesh: the host appends (a client proposes); the commit comes back through `ingest`.
    private func append(_ event: GameEvent) {
        if let mesh { mesh.append(event) } else { apply(events + [event]) }
    }

    /// The mesh's log changed: fold its committed prefix, or while an island host (`mesh.isIsland && mesh.isHost`)
    /// fold the full log (committed prefix + provisional island tail) so play, turn, rings and unconfirmed saves work (D44, D51).
    func ingest(log: [LogEntry], commitSeq: UInt64) {
        hasUncommittedLogEntries = log.contains { $0.seq > commitSeq }
        let visible = (mesh?.isIsland == true && mesh?.isHost == true) ? log : log.filter { $0.seq <= commitSeq }
        apply(visible.sorted { $0.seq < $1.seq }.map(\.event))
    }

    private func apply(_ committed: [GameEvent]) {
        let changed = committed != events   // by content: an island merge can rewrite without growing (Codex P2-9)
        events = committed
        fold()
        if let recorder = clipRecorder {
            for s in shots {
                let idx = s.index
                let sid = s.id
                Task { @MainActor [weak self] in
                    if await recorder.bindPendingLocalIndexIfPresent(idx, to: sid) {
                        self?.scheduleEngineEvaluation()
                    }
                }
            }
        }
        applyCachedEnrichments()
        if mesh?.isIsland == true {
            let unseen = shots.filter { !provisionalBadged.contains($0.id) && !badged.contains($0.id) }
            provisionalBadged.formUnion(unseen.map(\.id))
            if let s = unseen.last(where: { $0.rating != nil }), let rating = s.rating {
                badge.receive(.rated(PostShotRating(shotID: s.id, rating: rating, shooterName: s.shooter.name,
                                                    team: s.team, isProvisional: true)))
            }
        } else {
            // Confirmed commit: replaces any provisional island badge even when the winning view kept the same shotID (D48).
            let unseen = shots.filter { !badged.contains($0.id) }
            badged.formUnion(unseen.map(\.id))
            if let s = unseen.last(where: { $0.rating != nil }), let rating = s.rating {
                badge.receive(.rated(PostShotRating(shotID: s.id, rating: rating, shooterName: s.shooter.name,
                                                    team: s.team, isProvisional: false)))
            }
        }
        // Any newly committed event can move the rules state or the shooter: Live's rings follow the fold.
        if changed { pushLegal() }
        saveIfWon()
        if changed { scheduleEngineEvaluation() }
    }

    /// D45: the commit that gives the rack its winner saves it, on the one writer: solo, or the host with game quorum.
    /// D51 (plan 013b): an island host (`mesh.isHost && mesh.isIsland`) also saves its finished rack flagged
    /// `isUnconfirmed = true`; if it later reconnects with quorum, `record` upgrades that row to `isUnconfirmed = false`.
    /// D49/D54 (plan 015): if a correction changes a saved rack's shots or winner, `record` updates it in place; if the
    /// rack is no longer finished (`winner == nil`), `deleteGame` removes it so unfinished racks never stay saved.
    private func saveIfWon() {
        guard !manuallyDeletedRack, let recorder else { return }
        let healInFlight = (mesh?.hasPendingCommits == true) || hasUncommittedLogEntries

        // D53: if this phone was an island host that saved an unconfirmed rack and then lost host election on heal
        // (becoming a joiner), reconcile and keep updating that existing local row once quorum commits settle — while
        // still never creating a brand-new rack from scratch as a joiner (D45).
        if isJoinerSession {
            let quorumReady: Bool
            if let mesh {
                quorumReady = mesh.hasGameQuorum && !mesh.isIsland && !healInFlight
            } else if hadMeshSession {
                quorumReady = hadQuorumAtEnd && !wasIslandAtEnd
            } else {
                quorumReady = false
            }
            guard saved, quorumReady else { return }
            if winner != nil {
                guard let game = finishedGame(isUnconfirmed: false), lastSaved != game else { return }
                if let oldID = savedGameID, oldID != game.id {
                    pruneAndPreserveClips(replacing: oldID, with: game, recorder: recorder)
                }
                try? recorder.record(game)
                savedGameID = game.id
                lastSaved = game
            } else if let id = savedGameID {
                try? recorder.deleteGame(id: id)
                saved = false
                savedGameID = nil
                lastSaved = nil
            }
            return
        }

        let confirmedWriter: Bool
        let islandWriter: Bool
        if let mesh {
            confirmedWriter = mesh.isHost && mesh.hasGameQuorum && !mesh.isIsland
            islandWriter = mesh.isHost && mesh.isIsland
        } else if hadMeshSession {
            confirmedWriter = wasHostAtEnd && hadQuorumAtEnd && !wasIslandAtEnd
            islandWriter = wasHostAtEnd && wasIslandAtEnd
        } else {
            confirmedWriter = true
            islandWriter = false
        }
        guard confirmedWriter || islandWriter else { return }
        guard winner != nil else {
            // Heal 1-RTT guard: while uncommitted log entries or proposals are still in flight after island heal,
            // keep the already-saved unconfirmed rack intact instead of deleting it prematurely.
            if saved, lastSaved?.isUnconfirmed == true, let mesh, !mesh.isIsland, healInFlight {
                return
            }
            wonAt = nil
            if saved, let id = savedGameID {
                do {
                    try recorder.deleteGame(id: id)
                    saved = false
                    savedGameID = nil
                    lastSaved = nil
                } catch {
                    StackGameRecorder.log.error("deleting un-finished rack failed: \(String(describing: error), privacy: .public)")
                }
            }
            return
        }
        if wonAt == nil { wonAt = Date() }
        if mesh != nil { mesh?.setPhase(.gameOver) }
        guard let game = finishedGame(isUnconfirmed: !confirmedWriter), !saved || lastSaved != game else { return }
        do {
            if saved, let oldID = savedGameID, oldID != game.id {
                pruneAndPreserveClips(replacing: oldID, with: game, recorder: recorder)
            }
            try recorder.record(game)
            saved = true
            savedGameID = game.id
            lastSaved = game
        } catch {
            StackGameRecorder.log.error("saving the finished rack failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func pruneAndPreserveClips(replacing oldID: UUID, with game: FinishedGame, recorder: any GameRecorder) {
        let activeIDs = Set(shots.map(\.id))
        let base = clipRecorder?.baseDirectory ?? ShotClipStore.defaultBaseDirectory
        for (sid, rel) in Array(shotClipFiles) where !activeIDs.contains(sid) {
            shotClipFiles.removeValue(forKey: sid)
            ShotClipStore.deleteClips(relativePaths: [rel], baseDirectory: base)
        }
        let keepClips = Set(shotClipFiles.values)
            .union(game.shots.compactMap(\.clipRef))
            .union([game.shotOfGame?.clipFile].compactMap { $0 })
        try? recorder.deleteGame(id: oldID, preservingClips: keepClips)
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
        var corrected: [UUID: (team: Int, shooter: UUID?)] = [:]
        var resolvedOutcomes: [UUID: ShotOutcome] = [:]
        for e in events {
            switch e {
            case .shooterCorrection(let id, let team, let shooterID, _): corrected[id] = (team, shooterID)
            case .outcomeResolution(let id, let outcome, _): resolvedOutcomes[id] = outcome
            default: break
            }
        }
        let hasGuestAtTable = config.teams.flatMap { $0 }.contains(where: \.isGuest)
        func resolveShooter(for id: UUID) -> (ShellPlayer, AttributionSource) {
            if let corr = corrected[id] {
                if hasLineup, teams.indices.contains(corr.team), !teams[corr.team].isEmpty {
                    if corr.team != currentTeam {
                        hand(to: corr.team)
                    }
                    if let sid = corr.shooter, let slot = teams[corr.team].firstIndex(where: { $0.id == sid }) {
                        currentSlot = slot
                        return (teams[corr.team][slot], .tap)
                    }
                }
                return (shooter, .tap)
            }
            if let autoID = autoAttributions[id],
               let teamIdx = teams.firstIndex(where: { $0.contains { $0.id == autoID } }),
               let slot = teams[teamIdx].firstIndex(where: { $0.id == autoID }) {
                if teamIdx != currentTeam { hand(to: teamIdx) }
                currentSlot = slot
                return (teams[teamIdx][slot], .auto)
            }
            return (shooter, .turnOrder)
        }
        var lostAt = -1
        var stateDiverged = false
        for i in 0...events.count {
            for w in swaps where w.afterEvent == i { applySwap(w.team, w.a, w.b) }
            guard i < events.count else { break }
            switch events[i] {
            case .ruleSetChosen, .shooterCorrection, .outcomeResolution:
                break
            case .shot(let r) where shots.contains { $0.id == r.shotID }:
                // Plan 013a/013b: a repeated shotID is a merge's amendment of a committed shot: a flag, never a new shot.
                if resolvedOutcomes[r.shotID] == nil, r.needsTap, let k = shots.firstIndex(where: { $0.id == r.shotID }) {
                    shots[k].needsTap = true
                    if let alt = r.alternateOutcome { shots[k].alternateOutcome = alt }
                }
            case .shot(let r):
                needsShooter = false
                if corrected[r.shotID] != nil { stateDiverged = true }
                let (who, attribution) = resolveShooter(for: r.shotID)
                let chosenOutcome = resolvedOutcomes[r.shotID] ?? r.outcome
                let outcomeChanged = resolvedOutcomes[r.shotID] != nil && chosenOutcome != r.outcome
                if outcomeChanged { stateDiverged = true }
                var state = rulesState
                state.shooter = shootingTeam
                let result = rulesEngine.apply(chosenOutcome, to: state)
                let rating = (!stateDiverged ? r.decisionRating : nil) ?? RuleRating.classify(
                    result, shooter: state.shooter, pocketedObjectBall: chosenOutcome.pocketed.keys.contains { $0 != .cue })
                let stillDisputed = resolvedOutcomes[r.shotID] == nil && r.needsTap
                // D28: when recognition is active and a guest is at the table, a registered player's shot without `.tap`
                // or `.auto` confirmation is never silently credited to their competitive stats.
                let unconfirmedGuestTable = identitySession != nil && hasGuestAtTable && !who.isGuest
                    && attribution == .turnOrder
                if unconfirmedGuestTable || unknownGuestShots.contains(r.shotID) {
                    needsShooter = true
                    lostAt = i
                }
                shots.append(SessionShot(id: r.shotID, index: shots.count, shooter: who, team: shootingTeam,
                                         rating: rating, pocketed: chosenOutcome.pocketed, fouls: result.fouls,
                                         isGuess: r.isGuess || unconfirmedGuestTable, before: Self.positions(r.preState),
                                         after: Self.positions(r.postState), attribution: attribution,
                                         firstContact: chosenOutcome.firstContact, needsTap: stillDisputed,
                                         alternateOutcome: stillDisputed ? r.alternateOutcome : nil,
                                         outcome: chosenOutcome))
                rulesState = result.nextState
                if winningShotCount == nil, rulesState.winner != nil { winningShotCount = shots.count }
                if result.turnPasses { passTurn() }
            case .shotLost(let id, _, _):
                let (who, attribution) = resolveShooter(for: id)
                shots.append(SessionShot(id: id, index: shots.count, shooter: who, team: shootingTeam, rating: nil,
                                         attribution: attribution))
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
    /// Shots up to the winning one keep their folded index; D38 gaps are left out, D31 guesses are saved flagged
    /// (D43). Shots committed after the win are not part of the rack.
    /// nil too when the teams fit no `GameFormat` (setup forbids uneven or over-four teams).
    func finishedGame(isUnconfirmed: Bool = false) -> FinishedGame? {
        guard let winner, let first = shots.first,
              let format = GameFormat.allCases.first(where: { $0.playersPerTeam == config.playersPerTeam }),
              config.teams.allSatisfy({ $0.count == format.playersPerTeam }) else { return nil }
        let teams = config.teams.map { t in StoredTeam(memberIDs: t.map(\.id), shootingOrder: t.map(\.id)) }
        var sotg = engineSummary?.shotOfGame
        if let sid = sotg?.shotID, let clip = shotClipFiles[sid] { sotg?.clipFile = clip }
        return FinishedGame(id: first.id, ruleSet: config.ruleSet, tableSize: config.tableSize, format: format,
                            teams: teams, winnerTeam: winner, winProbSeries: engineSummary?.winProbSeries ?? [],
                            startedAt: startedAt, endedAt: wonAt ?? Date(),
                            shots: shots.prefix(winningShotCount ?? shots.count)
                                .compactMap { RecordedShot($0, tableSize: config.tableSize) },
                            isUnconfirmed: isUnconfirmed, shotOfGame: sotg)
    }

    private func applyCachedEnrichments() {
        for i in shots.indices {
            let sid = shots[i].id
            if let clip = shotClipFiles[sid] { shots[i].clipRef = clip }
            if let e = engineSummary?.byShotID[sid], shots[i].rating != nil {
                shots[i].rating = e.rating
                shots[i].executionRating = e.executionRating
                shots[i].wpaDelta = e.wpaDelta
                shots[i].isClutch = e.isClutch
                shots[i].alternative = e.alternative
            }
        }
    }

    private func scheduleEngineEvaluation() {
        guard let evaluator = engineEvaluator,
              shots.contains(where: { !$0.isGuess && $0.rating != nil && $0.before[.cue] != nil }) else {
            engineTask?.cancel()
            engineTask = nil
            engineSummary = nil
            return
        }
        engineGeneration += 1
        let gen = engineGeneration
        engineTask?.cancel()
        let rackShots = Array(shots.prefix(winningShotCount ?? shots.count))
        let ruleSet = config.ruleSet
        let tableSize = config.tableSize
        let teamsCount = config.teams.count
        engineTask = Task { @MainActor [weak self] in
            defer {
                if let self, self.engineGeneration == gen {
                    self.engineTask = nil
                }
            }
            let summary = await evaluator.evaluateRack(
                ruleSet: ruleSet, tableSize: tableSize, teamsCount: teamsCount, shots: rackShots)
            guard !Task.isCancelled, let self, self.engineGeneration == gen else { return }
            self.engineSummary = summary
            self.applyCachedEnrichments()
            self.saveIfWon()
            self.onReviewRefreshed?(self.reviewData())
            // Export SotG clip only once the rack is finished (`winner != nil`), preventing mid-rack orphan `.mp4` leaks.
            if self.winner != nil,
               let sotg = summary.shotOfGame,
               self.shotClipFiles[sotg.shotID] == nil,
               let recorder = self.clipRecorder,
               let s = self.shots.first(where: { $0.id == sotg.shotID }) {
                await recorder.waitForPostSettleIfStreaming(shotID: sotg.shotID)
                guard !Task.isCancelled, self.engineGeneration == gen, !self.manuallyDeletedRack else { return }
                let realFrames = await recorder.capturedFrameCount(for: sotg.shotID)
                // Joiners without real camera footage skip generating a redundant synthetic fallback over the host's.
                if self.isJoinerSession && realFrames == 0 { return }
                let strokeTime = self.shotStrokeTimes[sotg.shotID]
                let settledTime = self.shotSettledTimes[sotg.shotID]
                if let (rel, url) = try? await recorder.exportClip(
                    shotID: sotg.shotID, strokeAt: strokeTime, settledAt: settledTime, tableSize: tableSize,
                    before: s.before, after: s.after, pocketed: s.pocketed) {
                    guard !Task.isCancelled, self.engineGeneration == gen, !self.manuallyDeletedRack else {
                        ShotClipStore.deleteClips(relativePaths: [rel], baseDirectory: recorder.baseDirectory)
                        return
                    }
                    self.attachClip(shotID: sotg.shotID, relativePath: rel)
                    self.onReviewRefreshed?(self.reviewData())
                    // D3: never offer bulk clips while anyone is aiming or balls are moving.
                    // Real camera footage scores > 1.0 so peer angles beat a synthetic fallback (0.25) in MeshNode's auction.
                    if !self.isAimingOrMoving, let data = try? Data(contentsOf: url) {
                        let viewScore = realFrames > 0 ? (1.0 + Double(realFrames) * 0.01) : 0.25
                        self.mesh?.offerClip(shotID: sotg.shotID, data: data, viewScore: viewScore)
                    }
                }
            }
        }
    }

    func awaitEngineEvaluation() async {
        while !Task.isCancelled, engineTask != nil {
            try? await Task.sleep(for: .milliseconds(15))
        }
        if Task.isCancelled {
            engineGeneration += 1
            engineTask?.cancel()
            engineTask = nil
        }
    }

    func attachClip(shotID: UUID, relativePath: String) {
        guard ShotClipStore.isValidRelativeClipPath(relativePath) else { return }
        shotClipFiles[shotID] = relativePath
        if let idx = shots.firstIndex(where: { $0.id == shotID }) {
            shots[idx].clipRef = relativePath
        }
        saveIfWon()
    }

    func confirmSavedRack() -> GameReviewData? {
        guard let gid = savedGameID else { return nil }
        try? recorder?.confirmGame(id: gid)
        wasIslandAtEnd = false
        hadQuorumAtEnd = true
        lastSaved?.isUnconfirmed = false
        return reviewData()
    }

    func deleteSavedRack() {
        manuallyDeletedRack = true
        engineGeneration += 1
        engineTask?.cancel()
        engineTask = nil
        if let gid = savedGameID {
            try? recorder?.deleteGame(id: gid)
        }
        let base = clipRecorder?.baseDirectory ?? ShotClipStore.defaultBaseDirectory
        ShotClipStore.deleteClips(relativePaths: Array(shotClipFiles.values), baseDirectory: base)
        shotClipFiles.removeAll()
        saved = false
        savedGameID = nil
        lastSaved = nil
    }

    /// D49 (plan 015): fix a recorded shot's shooter from Game Review. Appends `.shooterCorrection`, replays the fold,
    /// updates/deletes the saved rack (D54), and returns the updated review data. Joiners cannot correct (D39).
    @discardableResult
    func correctShooter(shotID: UUID, to player: ReviewPlayer) -> GameReviewData? {
        guard !isJoinerSession,
              shots.contains(where: { $0.id == shotID }),
              let team = teams.firstIndex(where: { $0.contains { $0.id == player.id } }) else { return nil }
        unknownGuestShots.remove(shotID)
        engineSummary = nil
        _ = identitySession?.correct(shot: shotID, to: player.id)
        append(.shooterCorrection(shotID: shotID, team: team, shooter: player.id))
        return reviewData()
    }

    /// Event-driven stroke attribution via `IdentitySession` (D28: never auto-credits when a guest lacks a template).
    @discardableResult
    func attributeStroke(shotID: UUID, window: StrokeWindow) async -> Attribution? {
        guard !isJoinerSession,
              let identitySession,
              let identifier = shooterIdentifier,
              let target = shots.first(where: { $0.id == shotID }) else { return nil }
        let teamSet = teams.indices.contains(target.team) ? Set(teams[target.team].map(\.id)) : nil
        let attr = await identitySession.identifyShot(
            shotID, window: window, expectedShooter: target.shooter.id,
            teamInTurn: teamSet, using: identifier)
        if attr.source == .auto, let pid = attr.playerID,
           teams.contains(where: { $0.contains { $0.id == pid } }) {
            autoAttributions[shotID] = pid
            unknownGuestShots.remove(shotID)
            fold()
            applyCachedEnrichments()
            pushLegal()
            saveIfWon()
            scheduleEngineEvaluation()
        } else if attr.source == .unknown {
            unknownGuestShots.insert(shotID)
            fold()
            applyCachedEnrichments()
            needsShooter = true
            saveIfWon()
        }
        return attr
    }

    /// D47/D52 (plan 013b): first unresolved disputed shot (`needsTap == true` with an `alternateOutcome`).
    var pendingDispute: SessionShot? { shots.first { $0.needsTap && $0.alternateOutcome != nil } }

    /// D47/D52 (plan 013b): resolve a disputed merged shot by picking one of the two outcomes. Any phone may propose it
    /// in Live; in post-game Review after `mesh` stops, solo/host applies locally.
    @discardableResult
    func resolveOutcome(shotID: UUID, outcome: ShotOutcome) -> GameReviewData? {
        guard shots.contains(where: { $0.id == shotID }) else { return nil }
        if mesh == nil, isJoinerSession { return nil }
        engineSummary = nil
        append(.outcomeResolution(shotID: shotID, outcome: outcome))
        return reviewData()
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
                              alternative: s.alternative, wpaDelta: s.wpaDelta, pathsAreTraced: false,
                              isGuess: s.isGuess, needsTap: s.needsTap, outcome: s.outcome,
                              alternateOutcome: s.alternateOutcome)
        }
        let winner = rulesState.winner.flatMap { teams.indices.contains($0) ? $0 : nil }
        var score = [Int](repeating: 0, count: teams.count)
        if let winner { score[winner] += 1 }
        let islandState = (mesh?.isIsland == true) || (mesh == nil && hadMeshSession && wasIslandAtEnd)
        let unconfirmed = winner != nil && (islandState || lastSaved?.isUnconfirmed == true)
        let sotg = engineSummary?.shotOfGame.map { h in
            let hasClip = !(shotClipFiles[h.shotID] ?? h.clipFile).isEmpty
            return ReviewHighlight(shotID: h.shotID, label: h.label, hasClip: hasClip)
        }
        return GameReviewData(gameIndex: 0, teams: teams, score: score, winnerTeam: winner, isFinished: winner != nil,
                              winProb: engineSummary?.winProbSeries ?? [], shots: reviewShots, shotOfGame: sotg,
                              tableSize: config.tableSize, isUnconfirmed: unconfirmed)
    }
}

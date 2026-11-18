import Foundation
import Geometry
import Rules
import Engine
import Testing
import Training
@testable import CueCoach

@Suite struct LiveAdapterTests {
    @Test func trainingModeCarriesTheAssistLevelNumber() {
        #expect(ShellLiveMode.training(.none) == .training(level: 4))
        #expect(ShellLiveMode.training(.full) == .training(level: 1))
    }

    @Test func onlyGameModeShowsTeamChrome() {
        #expect(ShellLiveMode.game.showsTurnChrome)
        #expect(!ShellLiveMode.training(level: 2).showsTurnChrome)
    }
}

/// Integration: the shell's LiveScreenAdapter drives LiveScreen(mode:drill:hooks:onClose:) with real hooks, so
/// the badge, turn and menu work in real play, and the shell injects its game via `LiveHooks.currentGame`.
@MainActor
@Suite struct LiveAdapterHooksTests {
    let a = ShellPlayer(id: UUID(), name: "Ari", symbol: "hare.fill", colorName: "teal")
    let b = ShellPlayer(id: UUID(), name: "Bo", symbol: "bolt.fill", colorName: "orange")

    func gameSession(_ rules: RuleSetID = .wpaNine) -> LiveSession {
        let g = GameSessionModel(config: GameConfig(ruleSet: rules, tableSize: .sevenFoot, teams: [[a], [b]]))
        return LiveSession(mode: .game, game: g, drill: nil)
    }

    /// The 1 pocketed legally: the shooter keeps the table (bar-8: team A takes solids; 9-ball: lowest ball).
    static let potOne = SettledShot(rating: .good, turnPasses: false,
                                    outcome: ShotOutcome(firstContact: BallID(1)!, pocketed: [BallID(1)!: .footLeft]))

    @Test func modesMapOntoLive() {
        #expect(ShellLiveMode.game.liveMode == .game)
        #expect(ShellLiveMode.training(level: 2).liveMode == .training(level: 2))
    }

    @Test func aimHooksCloseTheMenuAndSilenceTheBadge() {
        let s = gameSession()
        let h = LiveScreenAdapter.hooks(for: s)
        #expect(h.shellShowsBadge)
        s.game?.shotSettled(Self.potOne)
        #expect(s.game?.badge.current != nil)
        s.isMenuOpen = true
        h.aimStarted()
        #expect(!s.menuAvailable && !s.isMenuOpen)
        #expect(s.game?.badge.current == nil)
        h.aimEnded()
        #expect(!s.menuAvailable)
        h.settledShot(SettledShot(rating: .mistake, turnPasses: true,
                                  outcome: ShotOutcome(firstContact: BallID(2)!)))   // a legal miss on the 2
        #expect(s.menuAvailable)
        #expect(s.game?.shots.count == 2)
        #expect(s.game?.shootingTeam == 1)       // the turn passed
        #expect(s.game?.badge.current?.rating == .mistake)
        h.aimStarted(); h.aimCancelled()
        #expect(s.menuAvailable)
    }

    @Test func currentGameIsTheShellsRulesAndShooter() throws {
        let s = gameSession(.wpaNine)
        let h = LiveScreenAdapter.hooks(for: s)
        let (engine, state) = try #require(h.currentGame())
        #expect(engine.ruleSet == .wpaNine)
        #expect(state.ruleSet == .wpaNine)
        #expect(state.shooter == 0)
        // One-tap turn correction moves the rules shooter too.
        s.game?.handTurn(toTeam: 1)
        #expect(h.currentGame()?.1.shooter == 1)
    }

    // Fix round (review finding 1): no turn hand-over while a shot is live (aim open or balls moving).
    @Test func handTurnDuringAShotIsIgnored() {
        let s = gameSession()
        let h = LiveScreenAdapter.hooks(for: s)
        h.aimStarted()
        s.handTurn(toTeam: 1)
        #expect(s.game?.shootingTeam == 0)
        h.aimEnded()                              // stroke taken, balls moving
        s.handTurn(toTeam: 1)
        #expect(s.game?.shootingTeam == 0)
        h.settledShot(Self.potOne)                // at rest again; A keeps the table
        s.handTurn(toTeam: 1)
        #expect(s.game?.shootingTeam == 1)
    }

    @Test func handTurnBetweenShotsPushesTheNewTeamsLegalTargets() throws {
        let s = gameSession(.barEight)
        let h = LiveScreenAdapter.hooks(for: s)
        s.settled(Self.potOne)                    // A takes solids, B stripes
        var pushed: [Set<BallID>] = []
        s.game?.legalChanged = { pushed.append($0) }
        s.handTurn(toTeam: 1)
        let (engine, state) = try #require(h.currentGame())
        #expect(state.shooter == 1)
        #expect(pushed == [engine.legalTargets(state)])
        #expect(pushed.first?.isEmpty == false)
        #expect(pushed.first?.allSatisfy { $0.group == .stripes } == true)
        h.aimStarted()
        s.handTurn(toTeam: 0)                     // ignored mid-shot: nothing pushed
        #expect(pushed.count == 1)
    }

    /// Grok 4.7 BLOCKER on fix 1: production wiring. The view binds only `LiveModel.legalChanged` to its pipeline
    /// (`setLegal`); a between-shots hand-over must reach that same sink through the adapter's hooks, with nothing
    /// assigned to `GameSessionModel.legalChanged` by the test.
    @Test func handTurnReachesThePipelineSinkLiveBinds() throws {
        let s = gameSession(.barEight)
        let m = LiveModel(mode: .game)
        m.hooks = LiveScreenAdapter.hooks(for: s)                 // LiveScreenAdapter → LiveScreen.init
        @MainActor final class Sink { var pushed: [Set<BallID>] = [] }
        let sink = Sink()
        m.bindLegal { sink.pushed.append($0) }                   // what ARLiveView.attach / LiveScreen.task do
        m.hooks.settledShot(Self.potOne)                          // A takes solids, B stripes
        let afterShot = sink.pushed.count
        s.handTurn(toTeam: 1)                                     // tap B's disc between shots
        let (engine, state) = try #require(m.hooks.currentGame())
        #expect(sink.pushed.count == afterShot + 1)
        #expect(sink.pushed.last == engine.legalTargets(state))
        #expect(sink.pushed.last?.isEmpty == false)
        #expect(sink.pushed.last?.allSatisfy { $0.group == .stripes } == true)
        let rebound = Sink()
        m.bindLegal { rebound.pushed.append($0) }                 // a rebind (new pipeline) gets later pushes
        s.handTurn(toTeam: 0)
        #expect(rebound.pushed.count == 1)
        #expect(rebound.pushed.last?.allSatisfy { $0.group == .solids } == true)
    }

    /// Grok 4.7 re-review BLOCKER on 8eecfc0: SwiftUI re-runs `LiveScreen.init` on every shell body rebuild; `@State`
    /// keeps the first model and drops the rest. A throwaway model must not steal the game's legality sink.
    @Test func throwawayLiveScreenInitDoesNotStealTheMountedSink() throws {
        let s = gameSession(.barEight)
        let hooks = LiveScreenAdapter.hooks(for: s)
        let mounted = LiveModel(mode: .game)
        mounted.hooks = hooks                                     // first LiveScreen.init: kept by @State
        do {
            let throwaway = LiveModel(mode: .game)
            throwaway.hooks = hooks                               // body rebuild: second init, model discarded
        }
        @MainActor final class Sink { var pushed: [Set<BallID>] = [] }
        let sink = Sink()
        mounted.bindLegal { sink.pushed.append($0) }              // ARLiveView.attach / LiveScreen .task on mount
        hooks.settledShot(Self.potOne)                            // A takes solids, B stripes (pushed by the fold)
        #expect(sink.pushed.count == 1)
        s.handTurn(toTeam: 1)
        #expect(sink.pushed.count == 2)
        #expect(sink.pushed.last?.allSatisfy { $0.group == .stripes } == true)
        do {
            let another = LiveModel(mode: .game)
            another.hooks = hooks                                 // yet another rebuild after mount
        }
        s.handTurn(toTeam: 0)
        #expect(sink.pushed.count == 3)
        #expect(sink.pushed.last?.allSatisfy { $0.group == .solids } == true)
    }

    /// Plan 009: the fold owns the shell's rules state; Live's own next state never writes it.
    @Test func liveAdvanceNoLongerWritesTheShellsRulesState() throws {
        let s = gameSession(.barEight)
        let h = LiveScreenAdapter.hooks(for: s)
        let start = try #require(h.currentGame()).1
        var next = start
        next.groups = [0: .solids, 1: .stripes]
        next.phase = .inPlay
        h.gameAdvanced(next)
        #expect(try #require(h.currentGame()).1 == start)
        h.settledShot(Self.potOne)
        let now = try #require(h.currentGame()).1
        #expect(now.groups?[0] == .solids)
        #expect(now.phase == .inPlay)
    }

    /// Codex review of plan 009: a joiner's rings follow the host's committed shot, never its own camera's result.
    @Test func joinerRingsFollowTheHostsCommittedGroups() throws {
        let s = gameSession(.barEight)
        let game = try #require(s.game)
        let link = FakeGameMeshLink(isHost: false)
        game.mesh = link
        let m = LiveModel(mode: .game)
        m.hooks = LiveScreenAdapter.hooks(for: s)
        @MainActor final class Sink { var pushed: [Set<BallID>] = [] }
        let sink = Sink()
        m.bindLegal { sink.pushed.append($0) }
        let openTable = game.rulesEngine.legalTargets(game.rules.1)
        // The joiner's camera misreads the 1 as the 9: locally A would take stripes.
        let rec = ShotRecord(start: 0, end: 1, preState: [1: Vec2(0.5, 0.5), 2: Vec2(1, 0.5)], finalState: [1: Vec2(0.9, 0.5)],
                             cueID: 1, firstContact: 2, rails: [], pocketed: [2: .footLeft])
        m.shotSettled(rec, ids: [1: .cue, 2: BallID(9)!])
        #expect(game.shots.isEmpty)
        #expect(sink.pushed.last == openTable, "the dropped local result is overridden by the committed state")
        // The host's committed shot: A potted the 1 and takes solids.
        link.receive([LogEntry(seq: 1, term: 1, event: .shot(MeshShotRecord(
            shotID: UUID(), shooterTeam: 0, outcome: ShotOutcome(firstContact: BallID(1)!, pocketed: [BallID(1)!: .footLeft]),
            postState: nil, decisionRating: .good)))], commitSeq: 1)
        let rings = try #require(sink.pushed.last)
        #expect(rings == game.rulesEngine.legalTargets(game.rules.1))
        #expect(!rings.isEmpty && rings.allSatisfy { $0.group == .solids })
    }

    /// Plan 009 STOP check: for the same shot, the fold's rules state equals Live's own `result.nextState`.
    @Test func foldedRulesStateMatchesLivesOwnNextState() throws {
        for rules in [RuleSetID.barEight, .wpaNine] {
            let s = gameSession(rules)
            let m = LiveModel(mode: .game)
            var h = LiveScreenAdapter.hooks(for: s)
            @MainActor final class Box { var states: [GameState] = [] }
            let box = Box()
            h.gameAdvanced = { box.states.append($0) }
            m.hooks = h
            // 1. The cue ball pots the 1 (kept table). 2. It hits the 3 and scratches (foul, turn passes).
            // 3. It hits nothing seen and stops (turn passes).
            let shots = [
                ShotRecord(start: 0, end: 1, preState: [1: Vec2(0.5, 0.5), 2: Vec2(1, 0.5)], finalState: [1: Vec2(1.2, 0.6)],
                           cueID: 1, firstContact: 2, rails: [], pocketed: [2: .footLeft]),
                ShotRecord(start: 2, end: 3, preState: [1: Vec2(0.5, 0.5), 3: Vec2(1, 0.5)], finalState: [3: Vec2(1.1, 0.5)],
                           cueID: 1, firstContact: 3, rails: [], pocketed: [1: .sideRight]),
                ShotRecord(start: 4, end: 5, preState: [1: Vec2(0.5, 0.5)], finalState: [1: Vec2(0.6, 0.5)],
                           cueID: 1, firstContact: nil, rails: [], pocketed: [:]),
            ]
            for (i, rec) in shots.enumerated() {
                m.shotSettled(rec, ids: [1: .cue, 2: BallID(1)!, 3: BallID(3)!])
                let live = try #require(box.states.last)
                #expect(try #require(h.currentGame()).1 == live, "\(rules) shot \(i + 1): the fold and Live disagree")
            }
            #expect(s.game?.shots.count == 3)
        }
    }

    @Test func trainingHasNoGameAndSettlesTheAim() {
        let s = LiveSession(mode: .training(level: 2), game: nil, drill: .straightIn)
        let h = LiveScreenAdapter.hooks(for: s)
        #expect(h.currentGame() == nil)
        h.aimStarted()
        #expect(!s.menuAvailable)
        h.ballsSettled()
        #expect(s.menuAvailable)
    }
}

/// Live reports the rules state it advanced to, so the shell's copy follows real play.
@MainActor
@Suite struct LiveGameAdvanceTests {
    @Test func shotSettledHandsTheNextRulesStateToTheShell() {
        let m = LiveModel(mode: .game)
        var seen: GameState?
        var hooks = LiveHooks(aimStarted: {}, aimEnded: {}, aimCancelled: {}, ballsSettled: {}, settled: { _, _ in })
        let (engine, base) = TargetLegality.defaultGame()
        hooks.currentGame = { (engine, base) }
        @MainActor final class Box { var s: GameState? }
        let box = Box()
        hooks.gameAdvanced = { box.s = $0 }
        m.hooks = hooks
        // The cue ball pots the 3 on an open table.
        let rec = ShotRecord(start: 0, end: 2, preState: [1: Vec2(0.5, 0.5), 2: Vec2(1, 0.5)], finalState: [1: Vec2(1.2, 0.6)],
                             cueID: 1, firstContact: 2, rails: [], pocketed: [2: .footLeft])
        m.shotSettled(rec, ids: [1: .cue, 2: BallID(3)!])
        seen = box.s
        #expect(seen != nil)
        #expect(seen?.onTable.contains(BallID(3)!) == false)
    }
}

/// GPT-5.3 re-review BLOCKER (K2): with a shot held for D30, the shell must still see every aim (badge silenced,
/// menu closed), and the held shot's settle lands later, outside any aim, without unbalancing the shell.
@MainActor
@Suite struct HeldShotShellTests {
    let a = ShellPlayer(id: UUID(), name: "Ari", symbol: "hare.fill", colorName: "teal")
    let b = ShellPlayer(id: UUID(), name: "Bo", symbol: "bolt.fill", colorName: "orange")
    @MainActor final class Count { var start = 0, end = 0, cancel = 0, settled = 0 }

    func frame(_ t: Double, moving: Bool = false, started: Bool = false, addressing: Bool = false,
               shot: ShotRecord? = nil, inView: Set<Pocket> = Set(Pocket.allCases)) -> PerceptionResult {
        let cue = TrackedBall(id: 1, position: Vec2(1.2, 0.6), velocity: moving ? Vec2(0.8, 0) : .zero, kind: .cue,
                              tentativeNumber: 0, confirmed: true)
        var r = PerceptionResult(timestamp: t, detections: [], tracks: [cue], marks: [1: .cue], atRest: !moving, aim: nil,
                                 detectMs: 0)
        r.shotStarted = started; r.shooterAddressing = addressing; r.shot = shot
        r.ballIDs = [1: .cue, 2: BallID(3)!]
        r.pocketsInView = inView
        return r
    }

    @Test func shellSeesEveryAimWhileAShotIsHeldAndTheLateSettleStaysBalanced() {
        let session = LiveSession(mode: .game, game: GameSessionModel(config: GameConfig(ruleSet: .barEight, tableSize: .sevenFoot,
                                                                                         teams: [[a], [b]])), drill: nil)
        let game = session.game!
        let m = LiveModel(mode: .game)
        let c = Count()
        var h = LiveScreenAdapter.hooks(for: session)
        let (s0, e0, x0, d0) = (h.aimStarted, h.aimEnded, h.aimCancelled, h.settledShot)
        h.aimStarted = { c.start += 1; s0() }; h.aimEnded = { c.end += 1; e0() }
        h.aimCancelled = { c.cancel += 1; x0() }; h.settledShot = { c.settled += 1; d0($0) }
        m.hooks = h
        var t = 0.0
        func tick(_ r: PerceptionResult) { m.drive(r); t = r.timestamp }

        // Shot A: a plain miss, settles at once; the shell shows its badge.
        tick(frame(1, moving: true, started: true))
        let shotA = ShotRecord(start: 1, end: 2, preState: [:], finalState: [:], cueID: 1, firstContact: 2, rails: [], pocketed: [:])
        tick(frame(2, shot: shotA))
        #expect(game.badge.current != nil && session.menuAvailable)

        // Shot B: a slow make into an occluded pocket: held, Live asks.
        tick(frame(3, moving: true, started: true))
        #expect(game.badge.current == nil, "B's aim silenced A's badge")
        var shotB = ShotRecord(start: 3, end: 4, preState: [:], finalState: [:], cueID: 1, firstContact: 2, rails: [], pocketed: [:])
        shotB.uncertainPockets = [2: .footLeft]
        let occluded = Set(Pocket.allCases).subtracting([.footLeft])
        tick(frame(4, shot: shotB, inView: occluded))
        while t < 5.5 { tick(frame(t + 1.0 / 15, inView: occluded)) }
        #expect(m.pocketConfirm != nil && c.settled == 1)

        // The next shooter addresses the cue ball: the shell sees the aim although B is held.
        while t < 6.5 { tick(frame(t + 1.0 / 15, addressing: true, inView: occluded)) }
        #expect(c.start == 3, "A, B and this aim all reached the shell")
        #expect(!session.menuAvailable && !session.isMenuOpen)
        #expect(game.badge.current == nil)
        #expect(!m.showsPocketConfirm)

        // They step away (aim cancelled), then answer: B settles outside any aim.
        while t < 8.0 { tick(frame(t + 1.0 / 15, inView: occluded)) }
        #expect(c.cancel == 1 && c.settled == 1)
        m.answerPocket(dropped: true)
        #expect(c.settled == 2)
        #expect(game.shots.count == 2)
        #expect(game.badge.current != nil, "B's badge shows: nobody is aiming")
        #expect(session.menuAvailable)
        // Balanced: every aim was opened and closed exactly once (ended by a stroke or cancelled).
        #expect(c.start == c.end + c.cancel)
    }
}

/// Review data (CHECKLIST open item): a settled game shot's result (what the rules engine saw: balls pocketed with their
/// pocket, and fouls) reaches the shell, so Game Review's shot cards aren't empty.
@MainActor
@Suite struct LiveShotOutcomeReviewTests {
    let a = ShellPlayer(id: UUID(), name: "Ari", symbol: "hare.fill", colorName: "teal")
    let b = ShellPlayer(id: UUID(), name: "Bo", symbol: "bolt.fill", colorName: "orange")

    @Test func aSettledShotsPocketedBallsAndFoulsShowInReview() throws {
        let game = GameSessionModel(config: GameConfig(ruleSet: .barEight, tableSize: .eightFoot, teams: [[a], [b]]))
        let session = LiveSession(mode: .game, game: game, drill: nil)
        let m = LiveModel(mode: .game)
        m.hooks = LiveScreenAdapter.hooks(for: session)
        // The cue ball hits the 3, which drops in the foot-left corner; the cue ball follows into the right side: scratch.
        let rec = ShotRecord(start: 0, end: 2, preState: [1: Vec2(0.5, 0.5), 2: Vec2(1, 0.5)], finalState: [:],
                             cueID: 1, firstContact: 2, rails: [], pocketed: [2: .footLeft, 1: .sideRight])
        m.shotSettled(rec, ids: [1: .cue, 2: BallID(3)!])
        let shot = try #require(game.reviewData().shots.first)
        #expect(shot.pocketed == [BallID(3)!: .footLeft, .cue: .sideRight])
        #expect(shot.fouls.contains(.scratch))
        #expect(!shot.isGuess, "a camera-seen shot is not a guess")
    }

    /// Plan 002: a live shot's ball positions reach review as pre/post table states, so its rating and replay show.
    @Test func aSettledShotsBallPositionsReachReview() throws {
        let game = GameSessionModel(config: GameConfig(ruleSet: .barEight, tableSize: .eightFoot, teams: [[a], [b]]))
        let session = LiveSession(mode: .game, game: game, drill: nil)
        let m = LiveModel(mode: .game)
        m.hooks = LiveScreenAdapter.hooks(for: session)
        // Track 9 has no identity yet (D29): it never reaches review.
        let rec = ShotRecord(start: 0, end: 2, preState: [1: Vec2(0.5, 0.5), 2: Vec2(1, 0.5), 9: Vec2(1.5, 0.6)],
                             finalState: [1: Vec2(0.7, 0.5)], cueID: 1, firstContact: 2, rails: [],
                             pocketed: [2: .footLeft])
        m.shotSettled(rec, ids: [1: .cue, 2: BallID(3)!])
        let data = game.reviewData()
        let shot = try #require(data.shots.first)
        #expect(shot.pre.map { Set($0.balls.keys) } == [.cue, BallID(3)!])
        #expect(shot.post?.balls[BallID(3)!]?.motion == .pocketed)
        #expect(shot.post?.balls[BallID(3)!]?.position == Vec2(1, 0.5), "a pocketed ball sits at its before position")
        #expect(shot.post?.balls[.cue]?.position == Vec2(0.7, 0.5))
        #expect(shot.pre?.spec == TableSpec(size: .eightFoot))
        #expect(!shot.paths.isEmpty)
        #expect(!shot.pathsAreTraced)
        #expect(GameReviewModel(data: data).timelineStyle(shot) == .of(shot.rating), "rated, not dashed")
    }

    @Test func aShotWithNoKnownPositionsStaysWithoutStates() throws {
        let game = GameSessionModel(config: GameConfig(ruleSet: .barEight, tableSize: .eightFoot, teams: [[a], [b]]))
        let session = LiveSession(mode: .game, game: game, drill: nil)
        let m = LiveModel(mode: .game)
        m.hooks = LiveScreenAdapter.hooks(for: session)
        let rec = ShotRecord(start: 0, end: 2, preState: [:], finalState: [:], cueID: 1, firstContact: nil, rails: [],
                             pocketed: [:])
        m.shotSettled(rec, ids: [1: .cue])
        let shot = try #require(game.reviewData().shots.first)
        #expect(shot.pre == nil)
        #expect(shot.post == nil)
        #expect(shot.paths.isEmpty)
    }

    /// Grok 4.7 review: a D31 guess knows the pre-shot table but has no after table (finalState is empty); it must not
    /// open a replay whose after diagram drops every ball still on the felt.
    @Test func aGuessedShotHasNoReplay() throws {
        let game = GameSessionModel(config: GameConfig(ruleSet: .barEight, tableSize: .eightFoot, teams: [[a], [b]]))
        let session = LiveSession(mode: .game, game: game, drill: nil)
        let m = LiveModel(mode: .game)
        m.hooks = LiveScreenAdapter.hooks(for: session)
        let rec = ShotRecord(start: 0, end: 2, preState: [1: Vec2(0.5, 0.5), 2: Vec2(1, 0.5), 3: Vec2(1.2, 0.4)],
                             finalState: [:], cueID: 1, firstContact: nil, rails: [], pocketed: [2: .footLeft])
        m.shotSettled(rec, ids: [1: .cue, 2: BallID(3)!, 3: BallID(5)!], guessed: true)
        let shot = try #require(game.reviewData().shots.first)
        #expect(shot.isGuess)
        #expect(shot.pre == nil)
        #expect(shot.post == nil)
        #expect(shot.paths.isEmpty)
    }

    @Test func anUnratedCloseRecordsNoShot() {
        let game = GameSessionModel(config: GameConfig(ruleSet: .barEight, tableSize: .eightFoot, teams: [[a], [b]]))
        let session = LiveSession(mode: .game, game: game, drill: nil)
        LiveScreenAdapter.hooks(for: session).ballsSettled()   // e.g. a D31 lost shot with no guess
        #expect(game.reviewData().shots.isEmpty)
    }
}

/// D36 (C): the table size chosen in game setup (or, in Training, the Settings manual size) is the locator's prior.
@MainActor
@Suite struct LiveTablePriorTests {
    let a = ShellPlayer(id: UUID(), name: "Ari", symbol: "hare.fill", colorName: "teal")
    let b = ShellPlayer(id: UUID(), name: "Bo", symbol: "bolt.fill", colorName: "orange")

    func defaults(manual: TableSize?) -> UserDefaults {
        let d = UserDefaults(suiteName: "prior-\(UUID().uuidString)")!
        d.set(manual?.rawValue, forKey: SettingsKeys.tableSize)
        return d
    }

    @Test func aGameUsesItsSetupSize() {
        let g = GameSessionModel(config: GameConfig(ruleSet: .wpaNine, tableSize: .eightFoot, teams: [[a], [b]]))
        let s = LiveSession(mode: .game, game: g, drill: nil)
        #expect(LiveScreenAdapter.tablePrior(for: s, defaults: defaults(manual: .nineFoot)) == .eightFoot)
    }

    @Test func trainingUsesTheSettingsSizeOrNone() {
        let s = LiveSession(mode: .training(level: 2), game: nil, drill: .straightIn)
        #expect(LiveScreenAdapter.tablePrior(for: s, defaults: defaults(manual: .nineFoot)) == .nineFoot)
        #expect(LiveScreenAdapter.tablePrior(for: s, defaults: defaults(manual: nil)) == nil)
    }

    @Test func theLocatorFusesWithThePrior() {
        #expect(AutoTableLocating(keypoints: NoKeypoints(), prior: .eightFoot).prior == .eightFoot)
        #expect(AutoTableLocating(keypoints: NoKeypoints()).prior == nil)
        // The prior must reach the fusion config, not only the stored property (Grok 4.7).
        #expect(AutoTableLocating(keypoints: NoKeypoints(), prior: .nineFoot).auto.config.fusion.prior == .nineFoot)
        #expect(AutoTableLocating(keypoints: NoKeypoints()).auto.config.fusion.prior == nil)
    }
}

/// D37: ✕ in a game asks "End game?"; on confirm an open shot finishes settling before review opens (never dropped).
@MainActor
@Suite struct CloseSettlesOpenShotTests {
    let a = ShellPlayer(id: UUID(), name: "Ari", symbol: "hare.fill", colorName: "teal")
    let b = ShellPlayer(id: UUID(), name: "Bo", symbol: "bolt.fill", colorName: "orange")
    @MainActor final class Log { var events: [String] = []; var shots: [SettledShot] = [] }

    func frame(_ t: Double, moving: Bool = false, started: Bool = false, shot: ShotRecord? = nil) -> PerceptionResult {
        let cue = TrackedBall(id: 1, position: Vec2(1.2, 0.6), velocity: moving ? Vec2(0.8, 0) : .zero, kind: .cue,
                              tentativeNumber: 0, confirmed: true)
        var r = PerceptionResult(timestamp: t, detections: [], tracks: [cue], marks: [1: .cue], atRest: !moving, aim: nil,
                                 detectMs: 0)
        r.shotStarted = started; r.shot = shot
        r.ballIDs = [1: .cue, 2: BallID(3)!]
        r.pocketsInView = Set(Pocket.allCases)
        return r
    }

    func setup() -> (GameSessionModel, LiveModel, Log) {
        let game = GameSessionModel(config: GameConfig(ruleSet: .barEight, tableSize: .sevenFoot, teams: [[a], [b]]))
        let session = LiveSession(mode: .game, game: game, drill: nil)
        let m = LiveModel(mode: .game)
        let log = Log()
        var h = LiveScreenAdapter.hooks(for: session)
        let d0 = h.settledShot
        h.settledShot = { s in log.events.append("settled"); log.shots.append(s); d0(s) }
        let b0 = h.ballsSettled
        h.ballsSettled = { log.events.append("unrated"); b0() }
        let l0 = h.shotLost
        h.shotLost = { log.events.append("lost"); l0?() }
        m.hooks = h
        return (game, m, log)
    }

    @Test func closingAGameWithAnOpenShotWaitsForItToSettle() {
        let (game, m, log) = setup()
        m.drive(frame(1, moving: true, started: true))
        let rec = ShotRecord(start: 1, end: 2, preState: [:], finalState: [:], cueID: 1, firstContact: 2, rails: [], pocketed: [:])
        m.drive(frame(2, moving: true, shot: rec))         // the shot ended, the table is not quiet yet
        #expect(m.hasOpenShot, "\(m.lifecycleDebugDescription)")
        m.requestEnd { log.events.append("end") }
        #expect(m.isFinishing)
        #expect(log.events.isEmpty, "the end waits for the open shot")
        m.drive(frame(2.1, moving: true))                  // still rolling
        #expect(log.events.isEmpty)
        m.drive(frame(2.2))                                // quiet: the shot closes, then the end fires
        #expect(log.events == ["settled", "end"])
        #expect(!m.hasOpenShot)
        #expect(game.reviewData().shots.count == 1, "the shot reached the review")
        m.drive(frame(2.3))
        #expect(log.events == ["settled", "end"], "the end fires once")
    }

    @Test func closingWithNoOpenShotEndsAtOnce() {
        let (_, m, log) = setup()
        #expect(!m.hasOpenShot)
        m.requestEnd { log.events.append("end") }
        #expect(log.events == ["end"])
    }

    @Test func aSecondCloseWhileFinishingDoesNotEndTwice() {
        let (_, m, log) = setup()
        m.drive(frame(1, moving: true, started: true))
        let rec = ShotRecord(start: 1, end: 2, preState: [:], finalState: [:], cueID: 1, firstContact: 2, rails: [], pocketed: [:])
        m.drive(frame(2, moving: true, shot: rec))
        m.requestEnd { log.events.append("end") }
        m.requestEnd { log.events.append("end2") }      // D42: a second ✕ while finishing forces the end now
        #expect(log.events == ["settled", "end"], "the open shot closes with what is known, then the end fires once")
        #expect(!m.hasOpenShot)
        m.drive(frame(2.2))
        #expect(log.events == ["settled", "end"])
    }

    /// D42: the ~5 s give-up (and the second ✕) close a shot that never goes quiet; it still reaches the review.
    @Test func forcingTheEndClosesAShotThatNeverGoesQuiet() {
        let (game, m, log) = setup()
        m.drive(frame(1, moving: true, started: true))
        let rec = ShotRecord(start: 1, end: 2, preState: [:], finalState: [:], cueID: 1, firstContact: 2, rails: [], pocketed: [:])
        m.drive(frame(2, moving: true, shot: rec))
        m.requestEnd { log.events.append("end") }
        m.drive(frame(2.1, moving: true))                  // never quiet
        #expect(log.events.isEmpty)
        m.forceEnd()
        #expect(log.events == ["settled", "end"])
        #expect(game.reviewData().shots.count == 1, "the forced shot reached the review")
        m.forceEnd()
        #expect(log.events == ["settled", "end"], "forcing again does nothing")
    }

    /// Grok 4.7 review of D42: forcing never turns an unseen uncertain pocket into a confident miss. The ball doesn't
    /// count (D31: uncertain never pocketed) and the shot is flagged as a guess.
    @Test func forcingARunningLookWithAnUncertainPocketClosesItAsAGuess() throws {
        let (_, m, log) = setup()
        m.drive(frame(1, moving: true, started: true))
        var rec = ShotRecord(start: 1, end: 2, preState: [1: Vec2(1.2, 0.6), 2: Vec2(1.6, 0.4)], finalState: [1: Vec2(1.2, 0.6)],
                             cueID: 1, firstContact: 2, rails: [], pocketed: [:])
        rec.uncertainPockets = [2: .footLeft]
        m.drive(frame(2, shot: rec))                       // still: the post-settle look starts (Codex review)
        #expect(m.lifecycleDebugDescription.contains("looking"), "\(m.lifecycleDebugDescription)")
        m.requestEnd { log.events.append("end") }
        m.forceEnd()
        #expect(log.events == ["settled", "end"])
        let shot = try #require(log.shots.first)
        #expect(shot.isGuess, "an unresolved pocket makes the forced close a guess")
        #expect(shot.pocketed[BallID(3)!] == nil, "an uncertain ball is never counted pocketed")
    }

    /// A shot whose every pocket is known is not a guess when forced.
    @Test func forcingAShotWithNoUncertaintyIsNotAGuess() throws {
        let (_, m, log) = setup()
        m.drive(frame(1, moving: true, started: true))
        let rec = ShotRecord(start: 1, end: 2, preState: [:], finalState: [:], cueID: 1, firstContact: 2, rails: [], pocketed: [:])
        m.drive(frame(2, moving: true, shot: rec))
        m.requestEnd { log.events.append("end") }
        m.forceEnd()
        #expect(try #require(log.shots.first).isGuess == false)
    }

    /// Forced with lost shots open: a relock loses every unclosed shot (and the one in flight); with no pre-shot table
    /// each closes unrated, one close per shot, then the end fires.
    @Test func forcingClosesEveryLostShot() {
        let (_, m, log) = setup()
        m.drive(frame(1, moving: true, started: true))
        let rec = ShotRecord(start: 1, end: 2, preState: [:], finalState: [:], cueID: 1, firstContact: 2, rails: [], pocketed: [:])
        m.drive(frame(2, moving: true, shot: rec))
        m.drive(frame(3, moving: true, started: true))     // the next shot is in flight
        m.perceptionReset()                                // ... and lost
        m.requestEnd { log.events.append("end") }
        m.forceEnd()
        #expect(log.events == ["lost", "lost", "end"], "D38: in a game each lost shot with no guess is a gap")
        #expect(!m.hasOpenShot)
    }

    /// Grok 4.7 review of D42: once Live is gone (menu "End game", dismissal) a late give-up does nothing.
    @Test func anAbandonedEndIsNeverForcedLater() {
        let (_, m, log) = setup()
        m.drive(frame(1, moving: true, started: true))
        let rec = ShotRecord(start: 1, end: 2, preState: [:], finalState: [:], cueID: 1, firstContact: 2, rails: [], pocketed: [:])
        m.drive(frame(2, moving: true, shot: rec))
        m.requestEnd { log.events.append("end") }
        m.abandonEnd()
        m.forceEnd()
        #expect(log.events.isEmpty)
        #expect(!m.isFinishing)
    }

    /// Codex review: "End game" while the balls still roll (shot started, no record yet) must wait for that shot.
    @Test func endingWhileAShotIsInFlightWaitsForIt() {
        let (game, m, log) = setup()
        m.drive(frame(1, moving: true, started: true))     // in flight: the segmenter hasn't emitted the record yet
        #expect(m.hasOpenShot)
        m.requestEnd { log.events.append("end") }
        #expect(log.events.isEmpty, "the end waits for the shot in flight")
        let rec = ShotRecord(start: 1, end: 2, preState: [:], finalState: [:], cueID: 1, firstContact: 2, rails: [], pocketed: [:])
        m.drive(frame(2, moving: true, shot: rec))
        #expect(log.events.isEmpty)
        m.drive(frame(2.2))
        #expect(log.events == ["settled", "end"])
        #expect(game.reviewData().shots.count == 1)
    }

    /// Codex review: forcing while a shot is still in flight closes it like a shot lost to a relock (one close), then ends.
    @Test func forcingWhileAShotIsInFlightClosesItOnce() {
        let (_, m, log) = setup()
        m.drive(frame(1, moving: true, started: true))
        m.requestEnd { log.events.append("end") }
        m.forceEnd()
        #expect(log.events.count == 2 && log.events.last == "end", "\(log.events)")
        #expect(!m.hasOpenShot)
    }

    /// Codex review: once the end has fired, a late frame (even one carrying the in-flight shot's record) changes nothing.
    @Test func framesAfterTheEndAreIgnored() {
        let (game, m, log) = setup()
        m.drive(frame(1, moving: true, started: true))
        m.requestEnd { log.events.append("end") }
        m.forceEnd()
        let closes = log.events
        let rec = ShotRecord(start: 1, end: 2, preState: [:], finalState: [:], cueID: 1, firstContact: 2, rails: [], pocketed: [:])
        m.drive(frame(2, shot: rec))
        m.drive(frame(2.2))
        #expect(log.events == closes, "the same shot never closes twice")
        #expect(game.reviewData().shots.count <= 1)
    }

    @Test func forcingBeforeAnyEndRequestDoesNothing() {
        let (_, m, log) = setup()
        m.drive(frame(1, moving: true, started: true))
        let rec = ShotRecord(start: 1, end: 2, preState: [:], finalState: [:], cueID: 1, firstContact: 2, rails: [], pocketed: [:])
        m.drive(frame(2, moving: true, shot: rec))
        m.forceEnd()
        #expect(log.events.isEmpty)
        #expect(m.hasOpenShot)
    }

    @Test func trainingCloseNeverAsks() {
        #expect(!LiveModel(mode: .training(level: 2)).asksBeforeClosing)
        #expect(LiveModel(mode: .game).asksBeforeClosing)
    }
}

/// D38 / D41 (plan 008): in a game, a lost shot with no guess records a gap and asks who shoots next.
@MainActor
@Suite struct LostShotAsksForShooterTests {
    let a = ShellPlayer(id: UUID(), name: "Ari", symbol: "hare.fill", colorName: "teal")
    let b = ShellPlayer(id: UUID(), name: "Bo", symbol: "bolt.fill", colorName: "orange")
    @MainActor final class Log { var events: [String] = [] }

    func frame(_ t: Double, moving: Bool = false, started: Bool = false) -> PerceptionResult {
        let cue = TrackedBall(id: 1, position: Vec2(1.2, 0.6), velocity: moving ? Vec2(0.8, 0) : .zero, kind: .cue,
                              tentativeNumber: 0, confirmed: true)
        var r = PerceptionResult(timestamp: t, detections: [], tracks: [cue], marks: [1: .cue], atRest: !moving, aim: nil,
                                 detectMs: 0)
        r.shotStarted = started
        r.ballIDs = [1: .cue]
        r.pocketsInView = Set(Pocket.allCases)
        return r
    }

    /// A shot in flight is lost by a relock before any quiet pre-shot table: no D31 guess.
    func loseAShot(_ m: LiveModel) {
        m.drive(frame(1, moving: true, started: true))
        m.perceptionReset()
        m.drive(frame(2))
    }

    @Test func aLostShotWithNoGuessRecordsAGapAndAsksForTheShooter() throws {
        let game = GameSessionModel(config: GameConfig(ruleSet: .barEight, tableSize: .sevenFoot, teams: [[a], [b]]))
        let session = LiveSession(mode: .game, game: game, drill: nil)
        let m = LiveModel(mode: .game)
        let log = Log()
        var h = LiveScreenAdapter.hooks(for: session)
        let b0 = h.ballsSettled
        h.ballsSettled = { log.events.append("unrated"); b0() }
        let l0 = h.shotLost
        h.shotLost = { log.events.append("lost"); l0?() }
        m.hooks = h
        loseAShot(m)
        #expect(log.events == ["lost"], "\(m.lifecycleDebugDescription)")
        #expect(game.needsShooter)
        #expect(session.menuAvailable, "aiming is cleared")
        let gap = try #require(game.shots.first)
        #expect(game.shots.count == 1)
        #expect(gap.rating == nil)
        #expect(gap.shooter == a && gap.team == 0)
        #expect(gap.pocketed.isEmpty && gap.fouls.isEmpty)
        #expect(game.shooter == a, "the shooter waits for a tap")
        let review = try #require(game.reviewData().shots.first)
        #expect(review.rating == nil, "review shows an unknown gap")
    }

    @Test func trainingLostShotStillJustSettles() {
        let m = LiveModel(mode: .training(level: 2))
        let log = Log()
        var h = LiveHooks()
        h.ballsSettled = { log.events.append("unrated") }
        h.shotLost = { log.events.append("lost") }
        m.hooks = h
        loseAShot(m)
        #expect(log.events == ["unrated"], "\(m.lifecycleDebugDescription)")
    }
}

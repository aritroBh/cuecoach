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

    @Test func modesMapOntoLive() {
        #expect(ShellLiveMode.game.liveMode == .game)
        #expect(ShellLiveMode.training(level: 2).liveMode == .training(level: 2))
    }

    @Test func aimHooksCloseTheMenuAndSilenceTheBadge() {
        let s = gameSession()
        let h = LiveScreenAdapter.hooks(for: s)
        #expect(h.shellShowsBadge)
        s.game?.shotSettled(rating: .good, turnPasses: false)
        #expect(s.game?.badge.current != nil)
        s.isMenuOpen = true
        h.aimStarted()
        #expect(!s.menuAvailable && !s.isMenuOpen)
        #expect(s.game?.badge.current == nil)
        h.aimEnded()
        #expect(!s.menuAvailable)
        h.settled(.mistake, true)
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
        h.settled(.good, false)                   // at rest again
        s.handTurn(toTeam: 1)
        #expect(s.game?.shootingTeam == 1)
    }

    @Test func handTurnBetweenShotsPushesTheNewTeamsLegalTargets() throws {
        let s = gameSession(.barEight)
        let h = LiveScreenAdapter.hooks(for: s)
        var next = try #require(h.currentGame()).1
        next.groups = [0: .solids, 1: .stripes]
        next.phase = .inPlay
        h.gameAdvanced(next)
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
        var next = try #require(m.hooks.currentGame()).1
        next.groups = [0: .solids, 1: .stripes]
        next.phase = .inPlay
        m.hooks.gameAdvanced(next)
        s.handTurn(toTeam: 1)                                     // tap B's disc between shots
        let (engine, state) = try #require(m.hooks.currentGame())
        #expect(sink.pushed == [engine.legalTargets(state)])
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
        var next = try #require(hooks.currentGame()).1
        next.groups = [0: .solids, 1: .stripes]
        next.phase = .inPlay
        hooks.gameAdvanced(next)
        s.handTurn(toTeam: 1)
        #expect(sink.pushed.count == 1)
        #expect(sink.pushed.last?.allSatisfy { $0.group == .stripes } == true)
        do {
            let another = LiveModel(mode: .game)
            another.hooks = hooks                                 // yet another rebuild after mount
        }
        s.handTurn(toTeam: 0)
        #expect(sink.pushed.count == 2)
        #expect(sink.pushed.last?.allSatisfy { $0.group == .solids } == true)
    }

    @Test func liveAdvancesTheShellsRulesState() throws {
        let s = gameSession(.barEight)
        let h = LiveScreenAdapter.hooks(for: s)
        var next = try #require(h.currentGame()).1
        next.groups = [0: .solids, 1: .stripes]
        next.phase = .inPlay
        h.gameAdvanced(next)
        let now = try #require(h.currentGame()).1
        #expect(now.groups?[0] == .solids)
        #expect(now.phase == .inPlay)
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
        let (s0, e0, x0, d0) = (h.aimStarted, h.aimEnded, h.aimCancelled, h.settled)
        h.aimStarted = { c.start += 1; s0() }; h.aimEnded = { c.end += 1; e0() }
        h.aimCancelled = { c.cancel += 1; x0() }; h.settled = { r, p in c.settled += 1; d0(r, p) }
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

    @Test func anUnratedCloseRecordsNoShot() {
        let game = GameSessionModel(config: GameConfig(ruleSet: .barEight, tableSize: .eightFoot, teams: [[a], [b]]))
        let session = LiveSession(mode: .game, game: game, drill: nil)
        LiveScreenAdapter.hooks(for: session).ballsSettled()   // e.g. a D31 lost shot with no guess
        #expect(game.reviewData().shots.isEmpty)
    }
}

/// D37: ✕ in a game asks "End game?"; on confirm an open shot finishes settling before review opens (never dropped).
@MainActor
@Suite struct CloseSettlesOpenShotTests {
    let a = ShellPlayer(id: UUID(), name: "Ari", symbol: "hare.fill", colorName: "teal")
    let b = ShellPlayer(id: UUID(), name: "Bo", symbol: "bolt.fill", colorName: "orange")
    @MainActor final class Log { var events: [String] = [] }

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
        let d0 = h.settled
        h.settled = { r, p in log.events.append("settled"); d0(r, p) }
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
        m.requestEnd { log.events.append("end2") }
        m.drive(frame(2.2))
        #expect(log.events == ["settled", "end"])
    }

    @Test func trainingCloseNeverAsks() {
        #expect(!LiveModel(mode: .training(level: 2)).asksBeforeClosing)
        #expect(LiveModel(mode: .game).asksBeforeClosing)
    }
}

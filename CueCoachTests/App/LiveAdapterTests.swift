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

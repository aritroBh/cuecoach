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

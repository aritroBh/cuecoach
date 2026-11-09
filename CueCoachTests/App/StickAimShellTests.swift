import Foundation
import Geometry
import Rules
import Engine
import Testing
@testable import CueCoach

/// Grok 4.7 review finding 3 (MAJOR), at the LiveSession level with the real shell hooks (shellShowsBadge = true):
/// a stick put down by the cue ball while it is still creeping after a settle is an aim. The shell's badge text and
/// menu hide at once (no text while aiming, D33).
@MainActor
@Suite struct StickAimShellTests {
    let a = ShellPlayer(id: UUID(), name: "Ari", symbol: "hare.fill", colorName: "teal")
    let b = ShellPlayer(id: UUID(), name: "Bo", symbol: "bolt.fill", colorName: "orange")

    func frame(_ t: Double, cueSpeed: Double = 0, started: Bool = false, stick: Bool = false, shot: ShotRecord? = nil) -> PerceptionResult {
        let cue = TrackedBall(id: 1, position: Vec2(1.2, 0.6), velocity: Vec2(cueSpeed, 0), kind: .cue, tentativeNumber: 0,
                              confirmed: true)
        var r = PerceptionResult(timestamp: t, detections: [], tracks: [cue], marks: [1: .cue], atRest: cueSpeed < 0.3 && !started,
                                 aim: nil, detectMs: 0)
        r.shotStarted = started; r.stickNearCue = stick; r.shot = shot
        r.ballIDs = [1: .cue]
        return r
    }

    @Test func aStickDownWhileTheCueBallCreepsHidesTheBadgeAndMenu() {
        let session = LiveSession(mode: .game, game: GameSessionModel(config: GameConfig(ruleSet: .barEight, tableSize: .sevenFoot,
                                                                                         teams: [[a], [b]])), drill: nil)
        let game = session.game!
        let m = LiveModel(mode: .game)
        m.hooks = LiveScreenAdapter.hooks(for: session)
        #expect(m.hooks.shellShowsBadge)
        // Shot A: a plain miss that settles at once; the shell shows its badge, the menu is available.
        m.drive(frame(1, cueSpeed: 1, started: true))
        let shotA = ShotRecord(start: 1, end: 2, preState: [:], finalState: [:], cueID: 1, firstContact: nil, rails: [], pocketed: [:])
        m.drive(frame(2, shot: shotA))
        #expect(game.badge.current != nil && session.menuAvailable)
        // The cue ball still creeps (5 cm/s: motion, not at rest) and the next shooter's stick goes down by it.
        var t = 2.0
        for _ in 0..<5 {
            t += 1.0 / 15
            m.drive(frame(t, cueSpeed: 0.05, stick: true))
        }
        #expect(game.badge.current == nil, "no badge text while the stick is down")
        #expect(!session.menuAvailable && !session.isMenuOpen, "no menu while the stick is down")
    }
}

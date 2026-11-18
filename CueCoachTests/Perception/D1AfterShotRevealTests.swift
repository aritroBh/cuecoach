import Foundation
import Geometry
import Rules
import Engine
import Testing
import Training
@testable import CueCoach

/// D1 (MAJOR, coordinator review): Training level 4 hides everything while aiming and reveals the full overlay once
/// the balls have settled with no aim open; a new aim hides it again. Badge rules are unchanged.
@MainActor
struct D1AfterShotRevealTests {
    let cue = TrackedBall(id: 1, position: Vec2(1.2, 0.6), velocity: .zero, kind: .cue, tentativeNumber: 0, confirmed: true)

    func frame(_ t: Double, addressing: Bool = false, moving: Bool = false, started: Bool = false,
               shot: ShotRecord? = nil) -> PerceptionResult {
        var r = PerceptionResult(timestamp: t, detections: [], tracks: [cue], marks: [1: .cue], atRest: !moving, aim: nil,
                                 detectMs: 0)
        r.shooterAddressing = addressing
        r.motionOnset = moving
        r.shotStarted = started
        r.shot = shot
        r.ballIDs = [1: .cue]
        return r
    }

    static let nothing = OverlayVisibility.of(.training(level: AssistLevel.none.rawValue))

    @Test func levelFourRevealsTheFullOverlayAfterTheShotAndHidesItForTheNextAim() {
        let m = LiveModel(mode: .training(level: AssistLevel.none.rawValue))
        @MainActor final class Count { var settled = 0 }
        let c = Count()
        m.hooks = LiveHooks(aimStarted: {}, aimEnded: {}, aimCancelled: {}, ballsSettled: { c.settled += 1 },
                            settled: { _, _ in })
        // Aiming: nothing at all (D1).
        m.drive(frame(0, addressing: true))
        #expect(!m.visibility.line1 && !m.visibility.line2 && !m.visibility.suggestedGhost && !m.visibility.liveCueLine
                && !m.visibility.shotDock)
        // The shot, then the balls settle with nobody aiming.
        m.drive(frame(0.1, moving: true, started: true))
        #expect(!m.visibility.line1, "nothing while the balls roll")
        let shot = ShotRecord(start: 0.1, end: 2, preState: [:], finalState: [:], cueID: 1, firstContact: nil, rails: [],
                              pocketed: [:])
        m.drive(frame(2, shot: shot))
        #expect(c.settled == 1)
        let after = OverlayVisibility.of(.training(level: AssistLevel.none.rawValue), afterShot: true)
        #expect(after.line1 && after.line2 && after.suggestedGhost, "the after-shot set is the full overlay")
        #expect(m.visibility == after, "revealed once settled, no aim open")
        #expect(!m.visibility.ratingBadge, "badge rules unchanged in Training")
        // The next aim hides it again.
        m.drive(frame(2.1, addressing: true))
        #expect(m.visibility == Self.nothing)
    }

    @Test func aimingLevelsAndGameModeAreUnchangedAfterAShot() {
        #expect(OverlayVisibility.of(.game, afterShot: true) == OverlayVisibility.of(.game))
        // Levels 1-3 reveal the full set after the shot too (AssistLevel.visibleAfterShot), never the badge.
        #expect(OverlayVisibility.of(.training(level: 2), afterShot: true).line1)
    }
}

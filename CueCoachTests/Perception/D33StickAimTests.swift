import Foundation
import Geometry
import Rules
import Engine
import Testing
@testable import CueCoach

/// D33 (user, 2026-11-09): a cue stick seen near the cue ball counts as aiming even without a stroke: nothing closes,
/// settles or shows (badge, confirm, menu) until it is lifted away.
@MainActor
struct D33StickAimTests {
    @MainActor final class Spy {
        var aim: [String] = []
        var settled = 0
        var ballsSettled = 0
    }

    func model(_ spy: Spy) -> LiveModel {
        let m = LiveModel(mode: .game)
        var h = LiveHooks(aimStarted: { spy.aim.append("start") }, aimEnded: { spy.aim.append("end") },
                          aimCancelled: { spy.aim.append("cancel") }, ballsSettled: { spy.ballsSettled += 1 },
                          settled: { _, _ in spy.settled += 1 })
        h.shellShowsBadge = false
        let game = TargetLegality.startingGame(.barEight)
        h.currentGame = { game }
        m.hooks = h
        return m
    }

    let cue = TrackedBall(id: 1, position: Vec2(1.2, 0.6), velocity: .zero, kind: .cue, tentativeNumber: 0, confirmed: true)

    /// Only the stick: no live cue line (e.g. the cue ball is hidden under the bridge hand this frame), no wrists.
    func result(_ t: Double, stick: Bool, shot: ShotRecord? = nil) -> PerceptionResult {
        var r = PerceptionResult(timestamp: t, detections: [], tracks: [cue], marks: [1: .cue], atRest: true, aim: nil,
                                 detectMs: 0)
        r.stickNearCue = stick
        r.shot = shot
        r.ballIDs = [1: .cue]
        return r
    }

    func plainShot(end: Double) -> ShotRecord {
        ShotRecord(start: end - 2, end: end, preState: [1: Vec2(0.5, 0.5)], finalState: [1: Vec2(1.2, 0.6)], cueID: 1,
                   firstContact: nil, rails: [], pocketed: [:])
    }

    @Test func aStickNearTheCueBallIsAimingWithoutAStroke() {
        let spy = Spy(), m = model(spy)
        m.drive(result(0, stick: true))
        #expect(spy.aim == ["start"], "the stick alone opens the aim (menu hidden)")
        // A shot that ended earlier must not close (no badge, no settle) while the stick stays near the cue ball.
        m.perceptionReset()
        spy.aim = []
        var t = 0.0
        for _ in 0..<60 { t += 1.0 / 15; m.drive(result(t, stick: true)) }
        #expect(spy.aim == ["start"], "re-opened after the relock, never cancelled while the stick stays")
        #expect(m.badge == nil)
    }

    @Test func nothingSettlesOrShowsUntilTheStickIsLiftedAway() {
        let spy = Spy(), m = model(spy)
        // The shot ends with the next shooter's stick already down by the cue ball.
        var t = 3.0
        m.drive(result(t, stick: false))
        // A shot in flight: start it through the segmenter flag, then end it.
        var start = result(t + 0.05, stick: false); start.shotStarted = true; start.motionOnset = true; start.atRest = false
        m.drive(start)
        t += 2
        m.drive(result(t, stick: true, shot: plainShot(end: t)))
        for _ in 0..<45 {
            t += 1.0 / 15
            m.drive(result(t, stick: true))
            #expect(spy.settled == 0 && spy.ballsSettled == 0, "no close while the stick is near the cue ball")
            #expect(m.badge == nil)
            #expect(!m.showsPocketConfirm)
        }
        // Lifted away: closes once the aim grace has run out (aim cancelled, table quiet).
        for _ in 0..<30 { t += 1.0 / 15; m.drive(result(t, stick: false)) }
        #expect(spy.settled == 1)
        #expect(spy.aim.last == "cancel")
    }

    /// The pipeline reports the stick near the cue ball (no stroke, balls still) and nothing without one.
    @Test func pipelineReportsTheStickNearTheCueBall() async throws {
        var s = SyntheticTableScene.demo()
        let W = s.frame.spec.width
        s.balls = [.init(position: Vec2(0.6, W / 2), color: (240, 240, 236)),
                   .init(position: Vec2(1.4, W / 2 + 0.1), color: (200, 32, 30))]
        let bare = try Stress.image(s)
        let u = Vec2(1, 0)
        s.stick = .init(tip: s.balls[0].position - u * (Stress.R + 0.05), direction: u, length: 1.0)
        let withStick = try Stress.image(s)
        let p = PerceptionPipeline()
        await p.setTable(s.frame)
        var last: PerceptionResult?
        for i in 0..<20 { last = await p.process(PerceptionFrame(image: bare, camera: s.camera, timestamp: Double(i) / 30)) }
        #expect(last?.stickNearCue == false)
        for i in 20..<40 { last = await p.process(PerceptionFrame(image: withStick, camera: s.camera, timestamp: Double(i) / 30)) }
        let r = try #require(last)
        #expect(r.stickNearCue, "a still stick by the cue ball is aim evidence")
        #expect(r.shot == nil && !r.shotStarted, "no stroke, no shot")
    }
}

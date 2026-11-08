import Foundation
import Geometry
import Rules
import Testing
@testable import CueCoach

/// Codex integ-capture-r8 findings, fixed at integration.
struct CaptureR8SegmenterTests {
    let spec = TableSpec(size: .sevenFoot)
    func ball(_ id: Int, _ p: Vec2, _ v: Vec2 = .zero) -> TrackedBall {
        TrackedBall(id: id, position: p, velocity: v, kind: id == 1 ? .cue : .solid, tentativeNumber: nil, confirmed: true)
    }

    /// MAJOR: the record keeps when each ball dropped, so Rules gets the observed pocket order.
    @Test func recordCarriesPocketTimes() throws {
        var s = ShotSegmenter(spec: spec)
        var t = 0.0
        let corner = spec.pocketCenter(.footRight)
        let obj0 = corner - Vec2(0.3, 0.3)
        _ = s.update(tracks: [ball(1, Vec2(0.5, 0.5)), ball(2, obj0)], cueID: 1, atRest: true, at: t, strokeRecent: true)
        for i in 1...3 {
            t += 1 / 30
            _ = s.update(tracks: [ball(1, Vec2(0.5 + 0.05 * Double(i), 0.5), Vec2(1.5, 0)), ball(2, obj0)], cueID: 1,
                         atRest: false, at: t, strokeRecent: true)
        }
        let u = (corner - obj0).normalized
        t += 1 / 30
        _ = s.update(tracks: [ball(1, Vec2(0.8, 0.5)), ball(2, corner - u * 0.09, u * 1.2)], cueID: 1, atRest: false, at: t)
        t += 1 / 30
        let dropT = t
        _ = s.update(tracks: [ball(1, Vec2(0.8, 0.5))], cueID: 1, atRest: false, at: t)
        var rec: ShotRecord?
        for _ in 0..<40 {
            t += 1 / 30
            rec = rec ?? s.update(tracks: [ball(1, Vec2(0.8, 0.5))], cueID: 1, atRest: true, at: t)
        }
        let r = try #require(rec)
        #expect(r.pocketed[2] == .footRight)
        #expect(r.pocketTimes[2] == dropT)
    }
}

/// BLOCKER: a ball pocketed mid-shot loses its track; its rule id must survive to settlement.
struct ShotIdentityTests {
    @Test func idsSeenBeforeAndDuringTheShotSurviveToTheEnd() {
        var s = ShotIdentities()
        _ = s.update(known: [1: .cue, 2: BallID(3)!, 3: BallID(11)!], inShot: false)
        _ = s.update(known: [1: .cue, 3: BallID(11)!], inShot: true)            // the 3 dropped, track gone
        let end = s.update(known: [1: .cue], inShot: true, ended: true)        // the 11 dropped too
        #expect(end[2] == BallID(3)! && end[3] == BallID(11)! && end[1] == .cue)
        // After the shot the map is the live one again.
        #expect(s.update(known: [1: .cue], inShot: false) == [1: .cue])
    }

    @Test func aReusedTrackIdNeverGetsTwoBalls() {
        var s = ShotIdentities()
        _ = s.update(known: [2: BallID(3)!], inShot: false)
        let m = s.update(known: [5: BallID(3)!], inShot: true)                   // same ball, new track
        #expect(m.values.filter { $0 == BallID(3)! }.count == 1)
    }
}

@MainActor
struct CaptureR8LiveTests {
    @MainActor final class Log { var events: [String] = [] }

    func hooks(_ log: Log) -> LiveHooks {
        LiveHooks(aimStarted: { log.events.append("start") }, aimEnded: { log.events.append("end") },
                  aimCancelled: { log.events.append("cancel") }, ballsSettled: {}, settled: { _, _ in })
    }

    func result(_ t: Double, addressing: Bool) -> PerceptionResult {
        var r = PerceptionResult(timestamp: t, detections: [], tracks: [], marks: [:], atRest: true, aim: nil, detectMs: 0)
        r.shooterAddressing = addressing
        return r
    }

    /// BLOCKER: the shooter stepping up (wrists at the cue ball) starts the aim for the shell even when the
    /// stick is missed, so its badge and menu go away; walking off cancels it.
    @Test func addressingStartsTheShellAim() {
        let m = LiveModel(mode: .game)
        let log = Log()
        m.hooks = hooks(log)
        m.drive(result(0, addressing: true))
        #expect(log.events == ["start"])
        m.drive(result(0.5, addressing: false))
        m.drive(result(2.0, addressing: false))
        #expect(log.events == ["start", "cancel"])
    }

    /// MAJOR: a perception reset (revalidation / recalibration) mid-aim or mid-shot closes the shell's aim.
    @Test func perceptionResetCancelsAnOpenAim() {
        let m = LiveModel(mode: .game)
        let log = Log()
        m.hooks = hooks(log)
        m.drive(result(0, addressing: true))
        m.perceptionReset()
        #expect(log.events == ["start", "cancel"])
        m.perceptionReset()   // idle: nothing more
        #expect(log.events == ["start", "cancel"])
    }

    /// MAJOR: Live passes the observed pocket times to Rules.
    @Test func settlementUsesThePocketOrder() {
        let m = LiveModel(mode: .game)
        @MainActor final class Box { var s: GameState? }
        let box = Box()
        var h = LiveHooks(aimStarted: {}, aimEnded: {}, aimCancelled: {}, ballsSettled: {}, settled: { _, _ in })
        let (engine, base) = TargetLegality.defaultGame()
        h.currentGame = { (engine, base) }
        h.gameAdvanced = { box.s = $0 }
        m.hooks = h
        var rec = ShotRecord(start: 0, end: 2, preState: [1: Vec2(0.5, 0.5), 2: Vec2(1, 0.5), 3: Vec2(1.2, 0.4)],
                             finalState: [1: Vec2(1.2, 0.6)], cueID: 1, firstContact: 2, rails: [],
                             pocketed: [2: .footLeft, 3: .footRight])
        rec.pocketTimes = [2: 1.0, 3: 1.5]
        let ids: [Int: BallID] = [1: .cue, 2: BallID(3)!, 3: BallID(11)!]
        m.shotSettled(rec, ids: ids)
        let expected = engine.apply(RuleRating.outcome(rec, ids: ids, pocketTimes: rec.pocketTimes), to: base).nextState
        #expect(box.s == expected)
    }
}

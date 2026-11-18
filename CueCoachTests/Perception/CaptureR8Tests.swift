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
        // tracker-r2 estimates the drop as the last sighting plus the time to roll to the pocket centre
        // (9 cm here, at the speed its positions show): after the last sighting, well inside the shot.
        let drop = try #require(r.pocketTimes[2])
        let lastSeen = dropT - 1.0 / 30
        #expect(drop >= lastSeen - 1e-9 && drop <= lastSeen + 0.5)
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

    /// Superseded by the rerun's alias rule: a retired track and its successor may both map to the ball; two
    /// *live* tracks never do (see `reacquiredTrackAliasesTheRetiredOne`).
    @Test func aReusedTrackIdNeverGetsTwoBalls() {
        var s = ShotIdentities()
        _ = s.update(known: [2: BallID(3)!], inShot: false)
        let m = s.update(known: [5: BallID(3)!], inShot: true)                   // same ball, new track
        #expect(m[5] == BallID(3)!)
        let live = s.update(known: [5: BallID(3)!, 6: BallID(3)!], inShot: true)
        #expect(live[6] == nil)
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

    /// Lead: the record's pocket times give Rules the observed order (and a tie stays unknown).
    @Test func pocketTimesBecomeThePocketOrder() {
        var rec = ShotRecord(start: 0, end: 2, preState: [:], finalState: [:], cueID: 1, firstContact: 2, rails: [],
                             pocketed: [2: .footLeft, 3: .footRight])
        let ids: [Int: BallID] = [1: .cue, 2: BallID(3)!, 3: BallID(11)!]
        rec.pocketTimes = [2: 1.5, 3: 1.0]
        #expect(RuleRating.outcome(rec, ids: ids, pocketTimes: rec.pocketTimes).pocketOrder == [BallID(11)!, BallID(3)!])
        rec.pocketTimes = [2: 1.0, 3: 1.0]
        #expect(RuleRating.outcome(rec, ids: ids, pocketTimes: rec.pocketTimes).pocketOrder.isEmpty)
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

/// Codex reruns (capture-r8 / wiring) MAJORs.
struct ShotIdentityRerunTests {
    /// A ball re-acquired under a new track id mid-shot (occlusion) keeps reaching Rules under the new id.
    @Test func reacquiredTrackAliasesTheRetiredOne() {
        var s = ShotIdentities()
        _ = s.update(known: [1: .cue, 2: BallID(3)!], inShot: false)
        _ = s.update(known: [1: .cue], inShot: true)                       // track 2 lost
        let m = s.update(known: [1: .cue, 5: BallID(3)!], inShot: true)    // same ball, track 5
        #expect(m[5] == BallID(3)! && m[2] == BallID(3)!)
        // Two *live* tracks never share a ball.
        let n = s.update(known: [1: .cue, 5: BallID(3)!, 7: BallID(3)!], inShot: true)
        #expect(n[7] == nil)
    }

    /// D29: an unsettled identity has no rules consequences: it never enters the rule-id map.
    @Test func unstableVotesAreNotKnownIdentities() {
        func t(_ id: Int, _ n: Int, kind: Double = 1, number: Double = 1) -> TrackedBall {
            TrackedBall(id: id, position: .zero, velocity: .zero, kind: n == 8 ? .eight : .solid, tentativeNumber: n,
                        confirmed: true, kindShare: kind, numberShare: number)
        }
        let known = BallIdentity.known([t(2, 8, number: 0.67), t(3, 4, kind: 0.6), t(4, 5)], cueID: nil)
        #expect(known[2] == nil && known[3] == nil)
        #expect(known[4] == BallID(5)!)
    }
}

@MainActor
struct CaptureR8RerunLiveTests {
    @MainActor final class Log { var events: [String] = [] }

    /// A perception reset during a *moving* shot is not an abandoned aim: the shell stays gated (no aimCancelled)
    /// until perception sees the balls at rest again, then the shot closes unrated (ballsSettled).
    @Test func lostMovingShotKeepsTheShellGatedUntilRest() {
        let m = LiveModel(mode: .game)
        let log = Log()
        m.hooks = LiveHooks(aimStarted: { log.events.append("start") }, aimEnded: { log.events.append("end") },
                            aimCancelled: { log.events.append("cancel") }, ballsSettled: { log.events.append("settled") },
                            settled: { _, _ in log.events.append("rated") })
        var moving = PerceptionResult(timestamp: 0, detections: [], tracks: [], marks: [:], atRest: false, aim: nil, detectMs: 0)
        moving.shotStarted = true
        m.drive(moving)
        #expect(log.events == ["start", "end"])
        m.perceptionReset()
        #expect(!log.events.contains("cancel"))
        let ball = TrackedBall(id: 1, position: Vec2(0.5, 0.5), velocity: .zero, kind: .cue, tentativeNumber: 0, confirmed: true)
        m.drive(PerceptionResult(timestamp: 1, detections: [], tracks: [ball], marks: [:], atRest: false, aim: nil, detectMs: 0))
        #expect(!log.events.contains("settled"))
        m.drive(PerceptionResult(timestamp: 2, detections: [], tracks: [ball], marks: [:], atRest: true, aim: nil, detectMs: 0))
        #expect(log.events == ["start", "end", "settled"])
    }
}

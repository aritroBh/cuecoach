import Foundation
import Geometry
import Rules
import Engine
import Testing
@testable import CueCoach

/// D30 "look, then ask" (user, 2026-11-08): a pocket the segmenter isn't sure of (a slow make) is resolved by
/// looking after the balls settle; only if that's still ambiguous does Live ask with a one-tap, icon-only confirm.
/// Rules, the badge and the turn wait on it; nobody answering leaves the shot pending (never a guess).
@MainActor
struct D30PocketTests {
    @MainActor final class Spy {
        var settled: [(DecisionRating, Bool)] = []
        var advanced: GameState?
    }

    /// Bar 8, groups set, the shooter (solids) has only the 3 left.
    func lastSolidGame() -> (RulesEngine, GameState) {
        let (engine, base) = TargetLegality.startingGame(.barEight)
        var g = base
        g.groups = [0: .solids, 1: .stripes]
        g.phase = .inPlay
        g.shooter = 0
        g.onTable = Set([BallID.cue, BallID(3)!, .eight] + (9...15).map { BallID($0)! })
        return (engine, g)
    }

    func model(_ spy: Spy) -> LiveModel {
        let m = LiveModel(mode: .game)
        var h = LiveHooks(aimStarted: {}, aimEnded: {}, aimCancelled: {}, ballsSettled: {},
                          settled: { r, p in spy.settled.append((r, p)) })
        let game = lastSolidGame()
        h.currentGame = { game }
        h.gameAdvanced = { spy.advanced = $0 }
        m.hooks = h
        return m
    }

    let cue = TrackedBall(id: 1, position: Vec2(1.2, 0.6), velocity: .zero, kind: .cue, tentativeNumber: 0, confirmed: true)

    /// The 3 died into the foot-left corner at 0.12 m/s: recorded as an uncertain pocket.
    func slowMake() -> ShotRecord {
        var r = ShotRecord(start: 0, end: 3, preState: [1: Vec2(0.5, 0.5), 2: Vec2(0.3, 0.2)], finalState: [1: Vec2(1.2, 0.6)],
                           cueID: 1, firstContact: 2, rails: [], pocketed: [:])
        r.uncertainPockets = [2: .footLeft]
        return r
    }

    func result(_ t: Double, shot: ShotRecord? = nil, inView: Set<Pocket> = Set(Pocket.allCases),
                occupied: Set<Pocket> = [], extra: [TrackedBall] = [], liveAim: Bool = false) -> PerceptionResult {
        var r = PerceptionResult(timestamp: t, detections: [], tracks: [cue] + extra, marks: [1: .cue], atRest: true, aim: nil,
                                 detectMs: 0)
        r.shot = shot
        r.ballIDs = [1: .cue, 2: BallID(3)!]
        r.pocketsInView = inView
        r.pocketsOccupied = occupied
        if liveAim { r.liveAim = LiveAimTrace(cue: .zero, end: Vec2(1, 0), hitIndex: nil, ghost: nil, objectDirection: nil) }
        return r
    }

    func play(_ m: LiveModel, from t0: Double, seconds: Double, inView: Set<Pocket> = Set(Pocket.allCases),
              occupied: Set<Pocket> = []) {
        var t = t0
        while t < t0 + seconds { t += 1.0 / 15; m.drive(result(t, inView: inView, occupied: occupied)) }
    }

    @Test func slowMakeOfTheLastSolidIsSeenGoneAndTheShooterIsOnTheEight() {
        let spy = Spy(), m = model(spy)
        m.drive(result(3, shot: slowMake()))
        #expect(spy.settled.isEmpty, "Rules wait for the look")
        play(m, from: 3, seconds: 1.5)
        #expect(spy.settled.count == 1)
        #expect(spy.settled.first?.1 == false, "a made ball of the shooter's group keeps the turn")
        let next = try? #require(spy.advanced)
        #expect(next?.onTable.contains(BallID(3)!) == false)
        let (engine, _) = lastSolidGame()
        #expect(next.map { engine.legalTargets($0).contains(.eight) } == true, "on the 8: no red ring on it")
    }

    @Test func ballSeenInTheJawsStaysOnTheTable() {
        let spy = Spy(), m = model(spy)
        m.drive(result(3, shot: slowMake()))
        play(m, from: 3, seconds: 1.5, occupied: [.footLeft])
        #expect(spy.settled.count == 1)
        #expect(spy.settled.first?.1 == true, "nothing dropped: the turn passes")
        #expect(spy.advanced?.onTable.contains(BallID(3)!) == true)
        #expect(m.pocketConfirm == nil)
    }

    @Test func ballSeenElsewhereOnTheTableStaysOnTheTable() {
        let spy = Spy(), m = model(spy)
        m.drive(result(3, shot: slowMake()))
        let three = TrackedBall(id: 7, position: Vec2(0.4, 0.4), velocity: .zero, kind: .solid, tentativeNumber: 3, confirmed: true)
        var t = 3.0
        while t < 4.5 {
            t += 1.0 / 15
            var r = result(t, extra: [three]); r.ballIDs[7] = BallID(3)!
            m.drive(r)
        }
        #expect(spy.settled.first?.1 == true)
    }

    @Test func occludedPocketAsksAndCheckMeansDropped() {
        let spy = Spy(), m = model(spy)
        m.drive(result(3, shot: slowMake()))
        let others = Set(Pocket.allCases).subtracting([.footLeft])
        play(m, from: 3, seconds: 1.5, inView: others)
        #expect(spy.settled.isEmpty)
        let ask = try? #require(m.pocketConfirm)
        #expect(ask?.pocket == .footLeft && ask?.ball == BallID(3)!)
        #expect(m.showsPocketConfirm)
        // Never a guess: nobody answers, it stays pending.
        play(m, from: 4.5, seconds: 10, inView: others)
        #expect(spy.settled.isEmpty && m.pocketConfirm != nil)
        // Hidden while anyone aims.
        m.drive(result(15, inView: others, liveAim: true))
        #expect(!m.showsPocketConfirm)
        // The aim ends (stick gone > 1 s); the confirm is back and the answer settles the shot.
        play(m, from: 15, seconds: 2, inView: others)
        #expect(m.showsPocketConfirm)
        m.answerPocket(dropped: true)
        #expect(spy.settled.count == 1 && spy.settled.first?.1 == false)
        #expect(spy.advanced?.onTable.contains(BallID(3)!) == false)
        #expect(m.pocketConfirm == nil)
    }

    @Test func occludedPocketCrossMeansItStayed() {
        let spy = Spy(), m = model(spy)
        m.drive(result(3, shot: slowMake()))
        play(m, from: 3, seconds: 1.5, inView: Set(Pocket.allCases).subtracting([.footLeft]))
        m.answerPocket(dropped: false)
        #expect(spy.settled.count == 1 && spy.settled.first?.1 == true)
        #expect(spy.advanced?.onTable.contains(BallID(3)!) == true)
    }

    // MARK: Cross-vendor review round (GPT-5.3)

    /// d.M4: a "certain" pocket (fast into the mouth) that is then seen hanging in the jaws stays on the table;
    /// the turn and the rules follow what was seen, and a certain pocket never prompts.
    @Test func certainPocketSeenInTheJawsStays() {
        let spy = Spy(), m = model(spy)
        var rec = slowMake()
        rec.uncertainPockets = [:]
        rec.pocketed = [2: .footLeft]
        m.drive(result(3, shot: rec))
        #expect(spy.settled.isEmpty, "every pocketed ball gets the look")
        play(m, from: 3, seconds: 1.5, occupied: [.footLeft])
        #expect(m.pocketConfirm == nil)
        #expect(spy.settled.count == 1 && spy.settled.first?.1 == true, "nothing dropped: the turn passes")
        #expect(spy.advanced?.onTable.contains(BallID(3)!) == true)
    }

    /// A certain pocket with nothing contrary stays pocketed after the window, and even an occluded pocket doesn't ask.
    @Test func certainPocketWithNoContrarySightingStaysPocketedWithoutAsking() {
        let spy = Spy(), m = model(spy)
        var rec = slowMake()
        rec.uncertainPockets = [:]
        rec.pocketed = [2: .footLeft]
        m.drive(result(3, shot: rec))
        play(m, from: 3, seconds: 1.5, inView: Set(Pocket.allCases).subtracting([.footLeft]))
        #expect(m.pocketConfirm == nil)
        #expect(spy.settled.count == 1 && spy.settled.first?.1 == false)
        #expect(spy.advanced?.onTable.contains(BallID(3)!) == false)
    }

    /// "Gone" must be observed: frames where the detector measured nothing (a dropout) don't count as seeing the
    /// pocket empty, so an uncertain pocket in view during a dropout is asked, not called pocketed.
    @Test func detectionDropoutIsNotObservedGone() {
        let spy = Spy(), m = model(spy)
        m.drive(result(3, shot: slowMake()))
        var t = 3.0
        while t < 4.5 {
            t += 1.0 / 15
            var r = result(t)
            r.tracks = r.tracks.map { var b = $0; b.measured = false; return b }   // nothing measured this frame
            m.drive(r)
        }
        #expect(spy.settled.isEmpty)
        #expect(m.pocketConfirm?.pocket == .footLeft)
    }

    // MARK: Kimi K3 review round

    /// MAJOR: a relock while a shot is held drops it (closed unrated for the shell) and its look never resolves
    /// against the next shot: exactly one gameAdvanced, for the new shot.
    @Test func relockDropsTheHeldShotAndOnlyTheNewShotAdvances() {
        let spy = Spy(), m = model(spy)
        @MainActor final class Count { var advanced = 0; var settledUnrated = 0 }
        let c = Count()
        var h = m.hooks
        h.gameAdvanced = { spy.advanced = $0; c.advanced += 1 }
        h.ballsSettled = { c.settledUnrated += 1 }
        m.hooks = h
        m.drive(result(3, shot: slowMake()))
        play(m, from: 3, seconds: 1.5, inView: Set(Pocket.allCases).subtracting([.footLeft]))
        #expect(m.pocketConfirm != nil)
        m.perceptionReset()
        #expect(m.pocketConfirm == nil && !m.showsPocketConfirm)
        // GPT-5.6 BLOCKER 2: the close waits for a fresh post-relock frame proving no aim and no motion.
        #expect(c.settledUnrated == 0)
        m.drive(result(5))
        #expect(c.settledUnrated == 1, "the shell's gate is released")
        // The next shot: a plain miss, no pockets.
        let miss = ShotRecord(start: 10, end: 12, preState: [1: Vec2(0.5, 0.5)], finalState: [1: Vec2(1, 0.6)], cueID: 1,
                              firstContact: 2, rails: [], pocketed: [:])
        m.drive(result(12, shot: miss))
        play(m, from: 12, seconds: 2)
        #expect(c.advanced == 1)
        #expect(spy.advanced?.onTable.contains(BallID(3)!) == true, "the dropped held shot never applied")
    }

    /// GPT-5.6 final re-review: a relock with a held shot AND a live aim cancels the aim for the shell (its menu
    /// re-gates) and closes the held shot unrated, after the cancel, so the lifecycle stays balanced.
    @Test func relockWithAHeldShotDuringAnAimCancelsTheAimThenClosesTheHeldShot() {
        let m = LiveModel(mode: .game)
        @MainActor final class Log { var e: [String] = [] }
        let log = Log()
        var h = LiveHooks(aimStarted: { log.e.append("start") }, aimEnded: { log.e.append("end") },
                          aimCancelled: { log.e.append("cancel") }, ballsSettled: { log.e.append("unrated") },
                          settled: { _, _ in log.e.append("rated") })
        let game = lastSolidGame()
        h.currentGame = { game }
        m.hooks = h
        var moving = result(1); moving.atRest = false; moving.shotStarted = true
        m.drive(moving)
        m.drive(result(3, shot: slowMake()))
        var t = 3.0
        while t < 5.0 { t += 1.0 / 15; var r = result(t, inView: Set(Pocket.allCases).subtracting([.footLeft])); r.shooterAddressing = true; m.drive(r) }
        #expect(log.e == ["start", "end", "start"])
        m.perceptionReset()
        // GPT-5.6 BLOCKER 2: the shooter was still addressing on the last frame; the dropped shot closes only once a
        // post-relock frame shows no aim and no motion.
        #expect(log.e == ["start", "end", "start", "cancel"])
        play(m, from: 5, seconds: 2)
        #expect(log.e == ["start", "end", "start", "cancel", "unrated"])
        #expect(log.e == ["start", "end", "start", "cancel", "unrated"], "nothing else lands for the dropped shot")
    }

    /// GPT-5.6 final re-review: a relock with a held shot while the next shot's balls are still moving never reports
    /// a settle during motion: both the held shot and the lost moving shot close once the balls are at rest.
    @Test func relockWithAHeldShotDuringMotionClosesBothShotsOnlyAtRest() {
        let m = LiveModel(mode: .game)
        @MainActor final class Log { var e: [String] = [] }
        let log = Log()
        var h = LiveHooks(aimStarted: { log.e.append("start") }, aimEnded: { log.e.append("end") },
                          aimCancelled: { log.e.append("cancel") }, ballsSettled: { log.e.append("unrated") },
                          settled: { _, _ in log.e.append("rated") })
        let game = lastSolidGame()
        h.currentGame = { game }
        m.hooks = h
        var moving = result(1); moving.atRest = false; moving.shotStarted = true
        m.drive(moving)
        m.drive(result(3, shot: slowMake()))
        play(m, from: 3, seconds: 1.5, inView: Set(Pocket.allCases).subtracting([.footLeft]))
        #expect(m.pocketConfirm != nil)
        // The next shot is played (the confirm was ignored) and its balls are rolling when the table relocks.
        var next = result(6); next.atRest = false; next.shotStarted = true
        m.drive(next)
        #expect(log.e == ["start", "end", "start", "end"])
        m.perceptionReset()
        #expect(log.e == ["start", "end", "start", "end"], "no settle while the balls move")
        var rolling = result(6.5); rolling.atRest = false
        m.drive(rolling)
        #expect(log.e == ["start", "end", "start", "end"])
        m.drive(result(8))
        // The held shot (already ended) closes unrated; the shot in flight is a D31 best guess: its look needs 1 s.
        #expect(log.e == ["start", "end", "start", "end", "unrated"], "one close per shot, at rest")
        play(m, from: 8, seconds: 1.5)
        #expect(log.e == ["start", "end", "start", "end", "unrated", "rated"], "D31: the lost shot closes rated on its guess")
    }

    func relockedDuringMotion(_ log: @escaping @MainActor (String) -> Void) -> LiveModel {
        let m = LiveModel(mode: .game)
        var h = LiveHooks(aimStarted: { log("start") }, aimEnded: { log("end") }, aimCancelled: { log("cancel") },
                          ballsSettled: { log("unrated") }, settled: { _, _ in log("rated") })
        let game = lastSolidGame()
        h.currentGame = { game }
        m.hooks = h
        var moving = result(1); moving.atRest = false; moving.shotStarted = true
        m.drive(moving)
        m.drive(result(3, shot: slowMake()))
        play(m, from: 3, seconds: 1.5, inView: Set(Pocket.allCases).subtracting([.footLeft]))
        var next = result(6); next.atRest = false; next.shotStarted = true
        m.drive(next)
        m.perceptionReset()
        return m
    }

    /// GPT-5.6 re-review of 8ede140: the first rest frame after a relock may already carry the next aim. The aim
    /// reaches the shell, and the lost shots close only once that aim is over: never during it.
    @Test func lostShotsNeverCloseDuringTheNextAim() {
        @MainActor final class Log { var e: [String] = [] }
        let log = Log()
        let m = relockedDuringMotion { log.e.append($0) }
        let before = log.e
        var t = 8.0
        while t < 9.0 { t += 1.0 / 15; var r = result(t); r.shooterAddressing = true; m.drive(r) }
        #expect(Array(log.e.dropFirst(before.count)) == ["start"], "the aim is forwarded; nothing closes during it")
        play(m, from: 9, seconds: 3)
        // The held shot closes unrated; the shot in flight closes on its D31 best guess after its 1 s look.
        #expect(Array(log.e.dropFirst(before.count)) == ["start", "cancel", "unrated", "rated"])
    }

    /// …and when that aim becomes a shot, both lost shots close before the new shot's result, never during motion.
    @Test func lostShotsCloseBeforeTheNextShotsResultAndNeverDuringMotion() {
        @MainActor final class Log { var e: [String] = [] }
        let log = Log()
        let m = relockedDuringMotion { log.e.append($0) }
        let before = log.e
        var a = result(8); a.shooterAddressing = true
        m.drive(a)
        var go = result(8.5); go.atRest = false; go.shotStarted = true
        m.drive(go)
        var rolling = result(9); rolling.atRest = false
        m.drive(rolling)
        #expect(Array(log.e.dropFirst(before.count)) == ["start", "end"], "no close during the new shot's motion")
        let miss = ShotRecord(start: 8.5, end: 10, preState: [1: Vec2(0.5, 0.5)], finalState: [1: Vec2(1, 0.6)], cueID: 1,
                              firstContact: 2, rails: [], pocketed: [:])
        m.drive(result(10, shot: miss))
        play(m, from: 10, seconds: 2)
        #expect(Array(log.e.dropFirst(before.count)) == ["start", "end", "unrated", "unrated", "rated"])
    }

    /// GPT-5.6 re-review of f046ff8: a D29 impulsive launch (no aim seen) right after a motion relock still opens and
    /// closes the shell's aim; the lost shots close before its result, never during its motion.
    @Test func noAimLaunchAfterAMotionRelockKeepsTheShellBalanced() {
        @MainActor final class Log { var e: [String] = [] }
        let log = Log()
        let m = relockedDuringMotion { log.e.append($0) }
        let before = log.e
        var go = result(7); go.atRest = false; go.shotStarted = true
        m.drive(go)
        var rolling = result(7.5); rolling.atRest = false
        m.drive(rolling)
        #expect(Array(log.e.dropFirst(before.count)) == ["start", "end"], "the launch reaches the shell; no close in motion")
        let miss = ShotRecord(start: 7, end: 9, preState: [1: Vec2(0.5, 0.5)], finalState: [1: Vec2(1, 0.6)], cueID: 1,
                              firstContact: 2, rails: [], pocketed: [:])
        m.drive(result(9, shot: miss))
        play(m, from: 9, seconds: 2)
        #expect(Array(log.e.dropFirst(before.count)) == ["start", "end", "unrated", "unrated", "rated"])
    }

    // MARK: GPT-5.6 holistic audit: one state machine

    func logModel(_ log: @escaping @MainActor (String) -> Void) -> LiveModel {
        let m = LiveModel(mode: .game)
        var h = LiveHooks(aimStarted: { log("start") }, aimEnded: { log("end") }, aimCancelled: { log("cancel") },
                          ballsSettled: { log("unrated") }, settled: { _, _ in log("rated") })
        let game = lastSolidGame()
        h.currentGame = { game }
        m.hooks = h
        return m
    }

    /// MAJOR 1a: A's look is cut short by B's launch: B's frames never decide A (A is asked, not "seen gone").
    @Test func aLaterLaunchFreezesAnUnfinishedLookAsAQuestion() {
        let spy = Spy(), m = model(spy)
        m.drive(result(3, shot: slowMake()))
        play(m, from: 3, seconds: 0.4)                          // A's look has started, not finished
        var go = result(3.5); go.atRest = false; go.shotStarted = true
        m.drive(go)
        play(m, from: 3.5, seconds: 2)                          // (B rolling then resting: none of it is A's look)
        #expect(m.pocketConfirm?.pocket == .footLeft, "A asks")
        #expect(spy.settled.isEmpty)
    }

    /// MAJOR 1b: a shot queued behind an unanswered question still gets its own look in its own window.
    @Test func aQueuedShotGetsItsOwnLookBehindAQuestion() {
        let spy = Spy(), m = model(spy)
        @MainActor final class States { var all: [GameState] = [] }
        let states = States()
        var h = m.hooks
        h.gameAdvanced = { spy.advanced = $0; states.all.append($0) }
        m.hooks = h
        m.drive(result(3, shot: slowMake()))
        play(m, from: 3, seconds: 1.5, inView: Set(Pocket.allCases).subtracting([.footLeft]))
        #expect(m.pocketConfirm != nil)                          // A asks
        var go = result(5); go.atRest = false; go.shotStarted = true
        m.drive(go)
        // B: the 11 (track 3) into the foot right, certain; during B's own window it is seen in the jaws: stays.
        var b = ShotRecord(start: 5, end: 6, preState: [:], finalState: [:], cueID: 1, firstContact: 3, rails: [], pocketed: [3: .footRight])
        b.uncertainPockets = [:]
        var endB = result(6, shot: b); endB.ballIDs[3] = BallID(11)!
        m.drive(endB)
        var t = 6.0
        while t < 7.5 { t += 1.0 / 15; var r = result(t, occupied: [.footRight]); r.ballIDs[3] = BallID(11)!; m.drive(r) }
        // Later frames (C's world) show nothing in the jaws; B's verdict was already made in its own window.
        play(m, from: 7.5, seconds: 2)
        m.answerPocket(dropped: true)                           // A: dropped
        #expect(spy.settled.count == 2)
        // (The spy's currentGame is fixed, so each state is that shot's own result.)
        #expect(states.all.first?.onTable.contains(BallID(3)!) == false, "A's answer applied to A")
        #expect(states.all.last?.onTable.contains(BallID(11)!) == true, "B's ball stayed, from B's own look")
    }

    /// MAJOR 2: the first launch frame (moving, before shotStarted) hides the confirm and defers a tap's settle.
    @Test func motionBeforeShotStartedGatesTheConfirmAndTheSettle() {
        let spy = Spy(), m = model(spy)
        m.drive(result(3, shot: slowMake()))
        play(m, from: 3, seconds: 1.5, inView: Set(Pocket.allCases).subtracting([.footLeft]))
        #expect(m.showsPocketConfirm)
        var launch = result(4.6); launch.atRest = false        // no shotStarted yet (the segmenter needs 2 frames)
        m.drive(launch)
        #expect(!m.showsPocketConfirm)
        m.answerPocket(dropped: true)
        #expect(spy.settled.isEmpty, "nothing settles while a ball moves")
        m.drive(result(5))
        #expect(spy.settled.count == 1)
    }

    /// MAJOR 3: a shot-end frame that already shows the next shooter opens that aim; a reset then cancels it before
    /// closing the shot.
    @Test func shotEndWithAddressingOpensTheAimAndAResetCancelsItFirst() {
        @MainActor final class Log { var e: [String] = [] }
        let log = Log()
        let m = logModel { log.e.append($0) }
        var go = result(1); go.atRest = false; go.shotStarted = true
        m.drive(go)
        let miss = ShotRecord(start: 1, end: 2, preState: [:], finalState: [:], cueID: 1, firstContact: 2, rails: [], pocketed: [:])
        var end = result(2, shot: miss); end.shooterAddressing = true
        m.drive(end)
        #expect(log.e == ["start", "end", "start"], "the next aim opened on the shot-end frame; nothing closed in it")
        m.perceptionReset()
        #expect(log.e == ["start", "end", "start", "cancel"], "cancel first; the shooter is still there")
        m.drive(result(3))
        #expect(log.e == ["start", "end", "start", "cancel", "unrated"])
    }

    /// MAJOR 4: every close goes through one FIFO: a shot lost in a moving relock closes before a later shot dropped
    /// by a second relock.
    @Test func twoRelocksCloseInShotOrder() {
        @MainActor final class Log { var e: [String] = []; var ids: [Int] = [] }
        let log = Log()
        let m = logModel { log.e.append($0) }
        m.onCloseForTesting = { id, _, _ in log.ids.append(id) }
        var go = result(1); go.atRest = false; go.shotStarted = true
        m.drive(go)
        m.perceptionReset()                                     // A lost while moving (id 0)
        var rolling = result(1.5); rolling.atRest = false
        m.drive(rolling)
        var go2 = result(2); go2.atRest = false; go2.shotStarted = true
        m.drive(go2)
        // B (id 1) ends with the next shooter already addressing: no quiet frame for A to close in.
        var endB = result(3, shot: slowMake(), inView: Set(Pocket.allCases).subtracting([.footLeft])); endB.shooterAddressing = true
        m.drive(endB)
        var t = 3.0
        while t < 4.5 { t += 1.0 / 15; var r = result(t, inView: Set(Pocket.allCases).subtracting([.footLeft])); r.shooterAddressing = true; m.drive(r) }
        #expect(log.ids.isEmpty, "nothing closes during the aim")
        m.perceptionReset()
        #expect(log.ids.isEmpty, "nothing closes before a fresh quiet frame")
        m.drive(result(5))
        #expect(log.ids == [0, 1], "A before B")
        #expect(log.e.filter { $0 == "start" }.count == log.e.filter { $0 == "end" || $0 == "cancel" }.count)
    }

    // MARK: GPT-5.6 review of dc5f5bd

    /// BLOCKER 1: B's onset frame can still read at rest with zero filtered velocity; the raw onset alone hides A's
    /// confirm, freezes nothing new, and a tap waits: A settles only once B is truly quiet.
    @Test func rawMotionOnsetGatesTheConfirmTapAndSettle() {
        let spy = Spy(), m = model(spy)
        m.drive(result(3, shot: slowMake()))
        play(m, from: 3, seconds: 1.5, inView: Set(Pocket.allCases).subtracting([.footLeft]))
        #expect(m.showsPocketConfirm)
        var onset = result(4.6); onset.motionOnset = true      // atRest still true, velocities zero
        m.drive(onset)
        #expect(!m.showsPocketConfirm)
        m.answerPocket(dropped: true)
        #expect(spy.settled.isEmpty, "no settle while B moves")
        var rolling = result(4.7); rolling.atRest = false
        m.drive(rolling)
        #expect(spy.settled.isEmpty)
        m.drive(result(5.5))
        #expect(spy.settled.count == 1)
    }

    /// BLOCKER 2: the segmenter holds shot A open (.moving) while the next shooter addresses; a relock then must not
    /// close A during that aim. After the relock the aim opens for the shell; A closes once the aim is over.
    @Test func relockWhileTheNextShooterAddressesAHeldOpenShotWaitsForTheAimToEnd() {
        @MainActor final class Log { var e: [String] = [] }
        let log = Log()
        let m = logModel { log.e.append($0) }
        var go = result(1); go.atRest = false; go.shotStarted = true
        m.drive(go)
        var t = 1.0
        // Balls at rest, A still open (a ball missing), the next shooter addresses.
        while t < 2.5 { t += 1.0 / 15; var r = result(t); r.shooterAddressing = true; m.drive(r) }
        #expect(log.e == ["start", "end"], "no shell aim while the segmenter holds A open")
        m.perceptionReset()
        #expect(log.e == ["start", "end"], "nothing closes on the relock: the shooter is still there")
        while t < 3.5 { t += 1.0 / 15; var r = result(t); r.shooterAddressing = true; m.drive(r) }
        #expect(log.e == ["start", "end", "start"], "the aim opens for the shell after the relock; A still waits")
        play(m, from: 3.5, seconds: 2)
        #expect(log.e == ["start", "end", "start", "cancel", "unrated"])
    }

    // MARK: GPT-5.6 review of 71b0253

    /// BLOCKER: B's launch frame with the cue ball missed (its track coasts unmeasured, atRest still true, no onset,
    /// a static ball measured) is not quiet: A's confirm hides and a tap can't settle it.
    @Test func partialDropoutAtLaunchIsNotQuiet() {
        let spy = Spy(), m = model(spy)
        m.drive(result(3, shot: slowMake()))
        play(m, from: 3, seconds: 1.5, inView: Set(Pocket.allCases).subtracting([.footLeft]))
        #expect(m.showsPocketConfirm)
        let obj = TrackedBall(id: 9, position: Vec2(0.4, 0.4), velocity: .zero, kind: .solid, tentativeNumber: 2, confirmed: true)
        var miss = result(4.6, extra: [obj])
        miss.tracks = miss.tracks.map { var b = $0; if b.id == 1 { b.measured = false }; return b }
        m.drive(miss)
        #expect(!m.showsPocketConfirm)
        m.answerPocket(dropped: true)
        #expect(spy.settled.isEmpty, "no settle while the launching ball is unseen")
        m.drive(result(5.5, extra: [obj]))
        #expect(spy.settled.count == 1)
    }

    /// f12 MAJOR: the continuity gate covers every frame of a dropout run within 0.3 s of the last measurement (not
    /// only the first missed frame), and only those: once the window is past the table can be quiet again.
    @Test func multiFrameDropoutIsNotQuietThroughTheWindow() {
        let spy = Spy(), m = model(spy)
        m.drive(result(3, shot: slowMake()))
        play(m, from: 3, seconds: 1.5, inView: Set(Pocket.allCases).subtracting([.footLeft]))
        let obj = TrackedBall(id: 9, position: Vec2(0.4, 0.4), velocity: .zero, kind: .solid, tentativeNumber: 2, confirmed: true)
        m.drive(result(4.6, extra: [obj]))                                       // cue last measured at 4.6
        #expect(m.showsPocketConfirm)
        for k in 1...4 {                                                          // 4.67 … 4.87: all within 0.3 s
            var miss = result(4.6 + Double(k) / 15, extra: [obj])
            miss.tracks = miss.tracks.map { var b = $0; if b.id == 1 { b.measured = false }; return b }
            m.drive(miss)
            #expect(!m.showsPocketConfirm, "missed frame \(k) is still within the window")
            m.answerPocket(dropped: true)
            #expect(spy.settled.isEmpty, "no settle on missed frame \(k)")
        }
        var past = result(4.6 + 6.0 / 15, extra: [obj])                          // 0.4 s since the last measurement
        past.tracks = past.tracks.map { var b = $0; if b.id == 1 { b.measured = false }; return b }
        m.drive(past)
        #expect(spy.settled.count == 1, "the answer lands once the window is past")
    }

    /// MAJOR: a frame that carries A's shot end AND B's raw onset is not A's look: a ball in A's pocket on that frame
    /// doesn't count, A's look is frozen at once (its uncertain ball is asked).
    @Test func shotEndFrameWithOnsetIsNotTheNewShotsLook() {
        let spy = Spy(), m = model(spy)
        var end = result(3, shot: slowMake(), occupied: [.footLeft]); end.motionOnset = true
        m.drive(end)
        play(m, from: 3, seconds: 1.5)
        #expect(m.pocketConfirm?.pocket == .footLeft, "frozen at once: asked, not 'seen in the jaws'")
        #expect(spy.settled.isEmpty)
    }

    /// MINOR: while a shot is held the shell's aim lifecycle stays balanced, and nothing settles or shows a badge
    /// while anyone aims; the held result lands once the aim is over.
    @Test func heldShotNeverSettlesDuringAnAimAndTheShellStaysBalanced() {
        let m = LiveModel(mode: .game)
        @MainActor final class Log { var e: [String] = [] }
        let log = Log()
        var h = LiveHooks(aimStarted: { log.e.append("start") }, aimEnded: { log.e.append("end") },
                          aimCancelled: { log.e.append("cancel") }, ballsSettled: { log.e.append("unrated") },
                          settled: { _, _ in log.e.append("rated") })
        let game = lastSolidGame()
        h.currentGame = { game }
        m.hooks = h
        var moving = result(1); moving.atRest = false; moving.shotStarted = true
        m.drive(moving)
        #expect(log.e == ["start", "end"])
        m.drive(result(3, shot: slowMake()))
        // The next shooter addresses the cue ball during the look window and stays there past it.
        var t = 3.0
        while t < 5.0 { t += 1.0 / 15; var r = result(t); r.shooterAddressing = true; m.drive(r) }
        #expect(log.e == ["start", "end", "start"], "the aim reaches the shell; nothing settles during it")
        #expect(m.badge == nil)
        // They step away: the aim is over, the held shot settles once.
        play(m, from: 5, seconds: 2)
        #expect(log.e == ["start", "end", "start", "cancel", "rated"])
    }

    /// The confirm is icon-only: its view source has no text (the aiming-path lint covers Live; this pins it).
    @Test func confirmHasNoText() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let src = try String(contentsOf: root.appendingPathComponent("CueCoach/Live/PocketConfirmView.swift"), encoding: .utf8)
        for token in ["Text(", "Label(", ".alert("] { #expect(!src.contains(token), "\(token)") }
        #expect(src.contains("checkmark") && src.contains("xmark"))
        #expect(src.contains("minWidth: 56") || src.contains("width: 56"))
    }
}

/// The pipeline reports which pockets it can see (in frame, no hand over them) and which hold a ball.
struct D30PipelineTests {
    @Test func pocketsInViewAndOccupied() async throws {
        let scene = SyntheticTableScene.demo()
        let cg = try #require(scene.render())
        let px = try #require(PixelImage(cgImage: cg))
        let p = PerceptionPipeline()
        await p.setTable(scene.frame)
        let r = try #require(await p.process(PerceptionFrame(image: px, camera: scene.camera, timestamp: 0)))
        #expect(r.pocketsInView == Set(Pocket.allCases))
        // A hand over the foot-left pocket hides it.
        let geo = FrameGeometry(frame: scene.frame, camera: scene.camera)
        let pk = try #require(geo.cloth.apply(scene.frame.spec.pocketCenter(.footLeft)))
        let r2 = try #require(await p.process(PerceptionFrame(image: px, camera: scene.camera, timestamp: 0.1, wristsByPerson: [[pk]])))
        #expect(!r2.pocketsInView.contains(.footLeft))
        // A tracked ball 5 cm from a pocket occupies it.
        let near = PerceptionPipeline.occupiedPockets([TrackedBall(id: 3, position: scene.frame.spec.pocketCenter(.headRight) + Vec2(0.05, -0.03),
                                                                   velocity: .zero, kind: .solid, tentativeNumber: 3, confirmed: true)],
                                                      spec: scene.frame.spec)
        #expect(near == [.headRight])
    }
}

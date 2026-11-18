import Foundation
import Geometry
import Rules
import Engine
import Testing
@testable import CueCoach

/// Grok 4.7 review of wt/d31-d33 at 7d77e5b (REJECT): findings 1 and 2 (D31) and 3 (D33), directed tests.
@MainActor
struct D31D33ReviewTests {
    @MainActor final class Spy {
        var settled: [(DecisionRating, Bool)] = []
        var ballsSettled = 0
        var advanced: [GameState] = []
        var closes: [(Int, ShotRecord?, Bool)] = []
        var aim: [String] = []
    }

    /// Bar 8, groups set, the shooter (solids) has the 3 and the 5 left.
    func game() -> (RulesEngine, GameState) {
        let (engine, base) = TargetLegality.startingGame(.barEight)
        var g = base
        g.groups = [0: .solids, 1: .stripes]
        g.phase = .inPlay
        g.shooter = 0
        g.onTable = Set([BallID.cue, BallID(3)!, BallID(5)!, .eight] + (9...15).map { BallID($0)! })
        return (engine, g)
    }

    func model(_ spy: Spy) -> LiveModel {
        let m = LiveModel(mode: .game)
        var h = LiveHooks(aimStarted: { spy.aim.append("start") }, aimEnded: { spy.aim.append("end") },
                          aimCancelled: { spy.aim.append("cancel") }, ballsSettled: { spy.ballsSettled += 1 },
                          settled: { r, p in spy.settled.append((r, p)) })
        let g = game()
        h.currentGame = { g }
        h.gameAdvanced = { spy.advanced.append($0) }
        h.shellShowsBadge = false
        m.hooks = h
        m.onCloseForTesting = { spy.closes.append(($0, $1, $2)) }
        return m
    }

    func ball(_ id: Int, _ p: Vec2, kind: BallKind = .solid, n: Int? = nil) -> TrackedBall {
        TrackedBall(id: id, position: p, velocity: .zero, kind: kind, tentativeNumber: n, confirmed: true)
    }

    func frame(_ t: Double, _ balls: [(TrackedBall, BallID?)], moving: Bool = false, started: Bool = false,
               stick: Bool = false, inView: Set<Pocket> = Set(Pocket.allCases), shot: ShotRecord? = nil) -> PerceptionResult {
        var r = PerceptionResult(timestamp: t, detections: [], tracks: balls.map(\.0), marks: [:], atRest: !moving, aim: nil,
                                 detectMs: 0)
        r.motionOnset = moving
        r.shotStarted = started
        r.stickNearCue = stick
        r.pocketsInView = inView
        r.shot = shot
        for (b, id) in balls { if let id { r.ballIDs[b.id] = id } }
        return r
    }

    let cueAt = Vec2(1.2, 0.6), threeAt = Vec2(1.9, 0.08), fiveAt = Vec2(0.5, 0.5), eightAt = Vec2(1.0, 0.95)

    /// Pre-shot table (cue, 3, 5, 8 identified), a shot starts, tracking is lost mid-shot, balls roll on.
    func loseAShot(_ m: LiveModel) -> Double {
        var t = 0.0
        let before: [(TrackedBall, BallID?)] = [(ball(1, cueAt, kind: .cue, n: 0), .cue), (ball(2, threeAt, n: 3), BallID(3)!),
                                                (ball(3, fiveAt, n: 5), BallID(5)!), (ball(4, eightAt, kind: .eight, n: 8), .eight)]
        for _ in 0..<10 { t += 1.0 / 15; m.drive(frame(t, before)) }
        t += 1.0 / 15; m.drive(frame(t, before, moving: true, started: true))
        t += 1.0 / 15; m.drive(frame(t, before, moving: true))
        m.perceptionReset()
        for _ in 0..<8 { t += 1.0 / 15; m.drive(frame(t, [(ball(11, cueAt, kind: .cue, n: 0), .cue)], moving: true)) }
        return t
    }

    /// Finding 1 (BLOCKER): the balls stop with the next shooter's stick already on the cue ball. The look still runs
    /// (at rest, a ball measured) although nothing may close during the aim; the stroke must not throw it away.
    @Test func aLostShotsLookRunsDuringAnAimAndSurvivesTheNextStroke() throws {
        let spy = Spy(), m = model(spy)
        var t = loseAShot(m)
        let after: [(TrackedBall, BallID?)] = [(ball(11, cueAt, kind: .cue, n: 0), .cue), (ball(13, fiveAt, n: 5), BallID(5)!),
                                               (ball(14, eightAt, kind: .eight, n: 8), .eight)]
        for _ in 0..<25 {
            t += 1.0 / 15; m.drive(frame(t, after, stick: true))
            #expect(spy.settled.isEmpty && spy.ballsSettled == 0, "nothing closes during the aim")
        }
        // The stroke, the next shot rolls and ends, the table goes quiet.
        t += 1.0 / 15; m.drive(frame(t, after, moving: true, started: true))
        t += 1.0 / 15; m.drive(frame(t, after, moving: true))
        let next = ShotRecord(start: t - 0.1, end: t + 1, preState: [:], finalState: [:], cueID: 11, firstContact: nil,
                              rails: [], pocketed: [:])
        t += 1; m.drive(frame(t, after, shot: next))
        for _ in 0..<20 { t += 1.0 / 15; m.drive(frame(t, after)) }
        try #require(spy.closes.count == 2, "\(spy.closes.map { ($0.0, $0.2) })")
        #expect(spy.closes[0].2 == true, "the lost shot closes on its guess, rated")
        #expect(spy.closes[0].1?.pocketed.keys.sorted() == [3])
        #expect(spy.advanced.first.map { !$0.onTable.contains(BallID(3)!) } == true, "the pocketed 3 leaves the game")
    }

    /// Finding 2 (BLOCKER): the 8 is not seen after the relock, but where it was (its pocket) was never in view:
    /// it is not confidently gone, so it is not pocketed (and the game doesn't end on a guess).
    @Test func aBallNeverCoveredByTheCameraIsNotPocketed() throws {
        let spy = Spy(), m = model(spy)
        var t = loseAShot(m)
        let after: [(TrackedBall, BallID?)] = [(ball(11, cueAt, kind: .cue, n: 0), .cue), (ball(12, threeAt, n: 3), BallID(3)!),
                                               (ball(13, fiveAt, n: 5), BallID(5)!)]
        // The 8 sat by the right side pocket; that part of the table is out of frame for the whole look.
        let notThere = Set(Pocket.allCases).subtracting([.sideRight])
        for _ in 0..<25 { t += 1.0 / 15; m.drive(frame(t, after, inView: notThere)) }
        try #require(spy.settled.count == 1)
        #expect(spy.closes.first?.1?.pocketed.isEmpty == true, "the 8 is not guessed pocketed")
        let next = try #require(spy.advanced.first)
        #expect(next.onTable.contains(.eight))
        var over = false
        if case .over = next.phase { over = true }
        #expect(!over, "no game decided on a guess")
    }

    /// Finding 2: covered in fewer than 80 % of the look's frames is not enough either.
    @Test func aBallCoveredInUnder80PercentOfTheLookIsNotPocketed() throws {
        let spy = Spy(), m = model(spy)
        var t = loseAShot(m)
        let after: [(TrackedBall, BallID?)] = [(ball(11, cueAt, kind: .cue, n: 0), .cue), (ball(13, fiveAt, n: 5), BallID(5)!),
                                               (ball(14, eightAt, kind: .eight, n: 8), .eight)]
        var k = 0
        let noFoot = Set(Pocket.allCases).subtracting([.footLeft])
        for _ in 0..<25 { t += 1.0 / 15; k += 1; m.drive(frame(t, after, inView: k % 2 == 0 ? noFoot : Set(Pocket.allCases))) }
        try #require(spy.settled.count == 1)
        #expect(spy.closes.first?.1?.pocketed.isEmpty == true, "the 3's pocket was in view only half the time")
    }

    /// Finding 2, boundary: in view on exactly 80 % of the look's frames (12 of 15) is enough (D30's ≥ 80 % bar).
    @Test func exactlyEightyPercentCoverageCounts() {
        var g = LostShotGuess(before: [.cue: cueAt, BallID(3)!: threeAt], lastSeen: [:], start: 0, spec: TableSpec(size: .sevenFoot))
        g.window = 1.4
        for i in 0..<15 {
            let inView = i < 12 ? Set(Pocket.allCases) : Set(Pocket.allCases).subtracting([.footLeft])
            g.observe(frame(Double(i) * 0.1, [(ball(1, cueAt, kind: .cue, n: 0), .cue)], inView: inView))
        }
        #expect(g.done)
        #expect(g.record()?.record.pocketed == [3: .footLeft])
    }

    /// Finding 3 (MAJOR): the stick goes down while the cue ball is still creeping after a settle: that is an aim.
    @Test func aimEventsOpenOnEvidenceEvenBeforeRest() {
        var a = AimEvents()
        #expect(a.update(cueVisible: true, atRest: false, shotStarted: false, shotEnded: false, at: 0) == [.aimStarted])
        var b = AimEvents()
        #expect(b.update(cueVisible: true, atRest: false, shotStarted: true, shotEnded: false, at: 0) == [.aimStarted, .aimEnded],
                "a shot start keeps priority")
    }
}

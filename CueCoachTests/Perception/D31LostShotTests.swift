import Foundation
import Geometry
import Rules
import Engine
import Testing
@testable import CueCoach

/// D31 (user, 2026-11-09): a shot lost to a relock (tracking lost mid-shot) is a best guess, no prompt. Once the balls
/// are quiet after the relock, balls that were on the table before the shot and are now confidently absent (identity
/// votes settled, not seen anywhere over the look window) count as pocketed; the shot closes rated through the normal
/// settled path. An uncertain identity never counts as pocketed; nothing known about the pre-shot table = unrated.
@MainActor
struct D31LostShotTests {
    @MainActor final class Spy {
        var settled: [(DecisionRating, Bool)] = []
        var ballsSettled = 0
        var advanced: GameState?
        var closes: [(Int, ShotRecord?, Bool)] = []
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
        var h = LiveHooks(aimStarted: {}, aimEnded: {}, aimCancelled: {}, ballsSettled: { spy.ballsSettled += 1 },
                          settled: { r, p in spy.settled.append((r, p)) })
        let g = game()
        h.currentGame = { g }
        h.gameAdvanced = { spy.advanced = $0 }
        h.shellShowsBadge = false
        m.hooks = h
        m.onCloseForTesting = { spy.closes.append(($0, $1, $2)) }
        return m
    }

    func ball(_ id: Int, _ p: Vec2, kind: BallKind = .solid, n: Int? = nil) -> TrackedBall {
        TrackedBall(id: id, position: p, velocity: .zero, kind: kind, tentativeNumber: n, confirmed: true)
    }

    /// A table frame: tracks with their rule ids (nil = identity not settled).
    func frame(_ t: Double, _ balls: [(TrackedBall, BallID?)], moving: Bool = false, started: Bool = false) -> PerceptionResult {
        var r = PerceptionResult(timestamp: t, detections: [], tracks: balls.map(\.0),
                                 marks: [:], atRest: !moving, aim: nil, detectMs: 0)
        r.motionOnset = moving
        r.shotStarted = started
        for (b, id) in balls { if let id { r.ballIDs[b.id] = id } }
        return r
    }

    let cueAt = Vec2(1.2, 0.6), threeAt = Vec2(1.9, 0.08), fiveAt = Vec2(0.5, 0.5), eightAt = Vec2(1.0, 0.3)

    /// Pre-shot table (cue, 3, 5, 8 all identified), a shot starts, tracking is lost mid-shot.
    func loseAShot(_ m: LiveModel) -> Double {
        var t = 0.0
        let before: [(TrackedBall, BallID?)] = [(ball(1, cueAt, kind: .cue, n: 0), .cue), (ball(2, threeAt, n: 3), BallID(3)!),
                                                (ball(3, fiveAt, n: 5), BallID(5)!), (ball(4, eightAt, kind: .eight, n: 8), .eight)]
        for _ in 0..<10 { t += 1.0 / 15; m.drive(frame(t, before)) }
        t += 1.0 / 15; m.drive(frame(t, before, moving: true, started: true))
        t += 1.0 / 15; m.drive(frame(t, before, moving: true))
        m.perceptionReset()
        // Post-relock: new tracker, new track ids, balls still rolling for a while.
        for _ in 0..<8 { t += 1.0 / 15; m.drive(frame(t, [(ball(11, cueAt, kind: .cue, n: 0), .cue)], moving: true)) }
        return t
    }

    @Test func aBallClearlyGoneIsPocketedAndTheShotIsRated() throws {
        let spy = Spy(), m = model(spy)
        var t = loseAShot(m)
        // Quiet: the 3 is gone, the cue, the 5 and the 8 are back (new track ids).
        let after: [(TrackedBall, BallID?)] = [(ball(11, cueAt, kind: .cue, n: 0), .cue), (ball(13, fiveAt, n: 5), BallID(5)!),
                                               (ball(14, eightAt, kind: .eight, n: 8), .eight)]
        for _ in 0..<5 { t += 1.0 / 15; m.drive(frame(t, after)) }
        #expect(spy.settled.isEmpty && spy.ballsSettled == 0, "waits for the look window")
        for _ in 0..<20 { t += 1.0 / 15; m.drive(frame(t, after)) }
        #expect(spy.ballsSettled == 0, "not an unrated close")
        try #require(spy.settled.count == 1, "rated once, no prompt")
        #expect(spy.settled[0].1 == false, "made own-group ball: the shooter stays at the table")
        let next = try #require(spy.advanced)
        #expect(!next.onTable.contains(BallID(3)!))
        #expect(next.onTable.contains(BallID(5)!) && next.onTable.contains(.eight))
        let rec = try #require(spy.closes.first?.1)
        #expect(spy.closes.first?.2 == true)
        #expect(rec.pocketed.keys.sorted() == [3], "keyed by ball number")
        #expect(rec.pocketed[3] == .footLeft, "nearest pocket to where the 3 was last seen")
        #expect(!m.showsPocketConfirm)
    }

    @Test func aGuessedShotIsFlaggedAsAGuessForReview() throws {
        let spy = Spy(), m = model(spy)
        var results: [SettledShot] = []
        let forward = m.hooks.settledShot
        m.hooks.settledShot = { results.append($0); forward($0) }
        var t = loseAShot(m)
        let after: [(TrackedBall, BallID?)] = [(ball(11, cueAt, kind: .cue, n: 0), .cue), (ball(13, fiveAt, n: 5), BallID(5)!),
                                               (ball(14, eightAt, kind: .eight, n: 8), .eight)]
        for _ in 0..<25 { t += 1.0 / 15; m.drive(frame(t, after)) }
        let r = try #require(results.first)
        #expect(results.count == 1 && spy.settled.count == 1, "one close, still seen by the two-value view")
        #expect(r.isGuess, "lost to a relock: a best guess, not camera-confirmed")
        #expect(r.pocketed == [BallID(3)!: .footLeft])
        #expect(r.fouls.isEmpty)
    }

    @Test func aGuessedShotReachesReviewAsAGuess() throws {
        let p = ShellPlayer(id: UUID(), name: "Ari", symbol: "hare.fill", colorName: "teal")
        let q = ShellPlayer(id: UUID(), name: "Bo", symbol: "bolt.fill", colorName: "orange")
        let game = GameSessionModel(config: GameConfig(ruleSet: .barEight, tableSize: .eightFoot, teams: [[p], [q]]))
        let m = LiveModel(mode: .game)
        var h = LiveScreenAdapter.hooks(for: LiveSession(mode: .game, game: game, drill: nil))
        let g = self.game()
        h.currentGame = { g }   // the scripted table (groups set, the 3 and 5 left for solids)
        m.hooks = h
        var t = loseAShot(m)
        let after: [(TrackedBall, BallID?)] = [(ball(11, cueAt, kind: .cue, n: 0), .cue), (ball(13, fiveAt, n: 5), BallID(5)!),
                                               (ball(14, eightAt, kind: .eight, n: 8), .eight)]
        for _ in 0..<25 { t += 1.0 / 15; m.drive(frame(t, after)) }
        let shot = try #require(game.reviewData().shots.first)
        #expect(shot.isGuess)
        #expect(shot.pocketed == [BallID(3)!: .footLeft])
    }

    @Test func anUncertainIdentityNeverCountsAsPocketed() throws {
        let spy = Spy(), m = model(spy)
        var t = loseAShot(m)
        // The 3's spot shows a ball whose identity votes haven't settled: it could be the 3.
        let after: [(TrackedBall, BallID?)] = [(ball(11, cueAt, kind: .cue, n: 0), .cue), (ball(12, Vec2(1.7, 0.2), n: 3), nil),
                                               (ball(13, fiveAt, n: 5), BallID(5)!), (ball(14, eightAt, kind: .eight, n: 8), .eight)]
        for _ in 0..<25 { t += 1.0 / 15; m.drive(frame(t, after)) }
        try #require(spy.settled.count == 1, "still a rated best guess")
        #expect(spy.settled[0].1 == true, "nothing made: the turn passes")
        let next = try #require(spy.advanced)
        #expect(next.onTable.contains(BallID(3)!), "the uncertain ball is not pocketed")
        #expect(spy.closes.first?.1?.pocketed.isEmpty == true)
    }

    @Test func noPriorTableStateClosesUnrated() {
        let spy = Spy(), m = model(spy)
        // The very first frame is already a launch: no quiet pre-shot table was ever seen.
        var t = 0.0
        m.drive(frame(t, [(ball(1, cueAt, kind: .cue, n: 0), .cue)], moving: true, started: true))
        t += 1.0 / 15; m.drive(frame(t, [(ball(1, cueAt, kind: .cue, n: 0), .cue)], moving: true))
        m.perceptionReset()
        for _ in 0..<25 { t += 1.0 / 15; m.drive(frame(t, [(ball(11, cueAt, kind: .cue, n: 0), .cue)])) }
        #expect(spy.settled.isEmpty)
        #expect(spy.ballsSettled == 1, "unrated, once")
        #expect(spy.closes.count == 1 && spy.closes[0].1 == nil && spy.closes[0].2 == false)
    }

    @Test func aGuessNeverClosesWhileAnyoneAims() {
        let spy = Spy(), m = model(spy)
        var t = loseAShot(m)
        let after: [(TrackedBall, BallID?)] = [(ball(11, cueAt, kind: .cue, n: 0), .cue), (ball(13, fiveAt, n: 5), BallID(5)!)]
        for _ in 0..<30 {
            t += 1.0 / 15
            var r = frame(t, after)
            r.shooterAddressing = true
            m.drive(r)
        }
        #expect(spy.settled.isEmpty && spy.ballsSettled == 0, "a shooter at the table holds the close")
    }
}

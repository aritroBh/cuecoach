import Foundation
import Geometry
import Rules
import Engine
import simd
import Testing
@testable import CueCoach

/// Codex r6 (fd6f15c).
struct R6EvidenceTests {
    /// 1: nose-corner keypoints (a rug's corners look like that) are not pocket evidence; mouths are.
    @Test func onlyMouthKeypointsCountAsPockets() {
        var d = AutoFrameDiagnostics()
        d.keypointsUsed = 10
        #expect(!AutoTableLocating.hasPocketEvidence(d, mouthKeypoints: 0))
        #expect(AutoTableLocating.hasPocketEvidence(d, mouthKeypoints: 2))
        var dark = AutoFrameDiagnostics()
        dark.pocketScores = [.headLeft: 0.8, .headRight: 0.7, .footLeft: 0.9, .footRight: 0.6]
        #expect(AutoTableLocating.hasPocketEvidence(dark, mouthKeypoints: 0))
    }

    @Test func mouthCounterSeesOnlyMouths() {
        let kps = [AutoTableKeypoint(kind: .noseCorner, pixel: .zero, confidence: 0.9),
                   AutoTableKeypoint(kind: .noseCorner, pixel: .zero, confidence: 0.9),
                   AutoTableKeypoint(kind: .cornerMouth, pixel: .zero, confidence: 0.9),
                   AutoTableKeypoint(kind: .sideMouth, pixel: .zero, confidence: 0.2)]
        #expect(MouthCountingProvider.mouths(in: kps) == 1)
    }
}

struct R6TrackingLatchTests {
    /// 2: a limited spell entirely between two status ticks still triggers revalidation.
    @Test func shortLimitedSpellIsLatched() {
        var l = LimitedLatch()
        l.note(trackingNormal: true)
        l.note(trackingNormal: false)   // one frame of relocalization…
        l.note(trackingNormal: true)    // …already over before the next tick
        let first = l.take()
        let again = l.take()            // consumed
        l.note(trackingNormal: true)
        let normal = l.take()
        #expect(first && !again && !normal)
    }
}

struct R6RuleOutcomeTests {
    let ids: [Int: BallID] = [1: .cue, 2: BallID(3)!, 3: BallID(5)!, 4: BallID(11)!]

    func record(first: Int?, pocketed: [Int: Pocket]) -> ShotRecord {
        ShotRecord(start: 0, end: 1, preState: [:], finalState: [:], cueID: 1, firstContact: first,
                   rails: [(id: 1, rail: .left)], pocketed: pocketed)
    }

    /// 3: "no contact seen" is unknown, not an observed no-contact; rail-after-contact needs observed ordering.
    @Test func unseenContactStaysUnknown() {
        let o = RuleRating.outcome(record(first: nil, pocketed: [:]), ids: ids)
        #expect(o.noContact == false)
        #expect(o.firstContact == nil)
        #expect(o.anyRailAfterContact == nil)
    }

    /// 4: pocket order follows observed drop times; unknown times → empty (unknown), never ID order.
    @Test func pocketOrderIsByTime() {
        let r = record(first: 4, pocketed: [2: .footLeft, 4: .sideRight])
        let timed = RuleRating.outcome(r, ids: ids, pocketTimes: [2: 1.4, 4: 0.9])
        #expect(timed.pocketOrder == [BallID(11)!, BallID(3)!])
        #expect(RuleRating.outcome(r, ids: ids).pocketOrder.isEmpty)
    }

    /// 5: unknown identities stay unknown (no arbitrary numbers for rules).
    @Test func unknownBallsAreNotNumbered() {
        let t = { (id: Int, n: Int?) in
            TrackedBall(id: id, position: .zero, velocity: .zero, kind: .solid, tentativeNumber: n, confirmed: true)
        }
        let ids = BallIdentity.known([t(1, 0), t(2, 3), t(3, nil), t(4, 3)], cueID: 1)
        #expect(ids[1] == .cue)
        #expect(ids[3] == nil)                  // no guess → unknown
        #expect(ids[2] == nil && ids[4] == nil) // duplicate guess → unknown
        let sim = BallIdentity.assign([t(1, 0), t(2, 3), t(3, nil)], cueID: 1)
        #expect(sim.count == 3)                 // physics still gets every ball
    }
}

@MainActor
struct R6ModelTests {
    func result(liveAim: Bool = false, shooterNear: Bool = false, shot: ShotRecord? = nil, started: Bool = false,
                cueSpeed: Double = 0, atRest: Bool = true, t: Double = 0) -> PerceptionResult {
        let cue = TrackedBall(id: 1, position: Vec2(0.5, 0.5), velocity: Vec2(cueSpeed, 0), kind: .cue,
                              tentativeNumber: 0, confirmed: true)
        var r = PerceptionResult(timestamp: t, detections: [], tracks: [cue], marks: [1: .cue], atRest: atRest, aim: nil, detectMs: 0)
        r.shot = shot; r.shotStarted = started; r.shooterAddressing = shooterNear
        if liveAim { r.liveAim = LiveAimTrace(cue: Vec2(0.5, 0.5), end: Vec2(1, 0.5), hitIndex: nil, ghost: nil, objectDirection: nil) }
        r.ballIDs = [1: .cue, 2: BallID(3)!]
        return r
    }

    /// 5: the shell's game state is what ratings use (here: groups assigned, so the other group's ball is a foul).
    @Test func injectedGameStateDrivesTheRating() {
        let m = LiveModel(mode: .game)
        let engine = RulesEngine(ruleSet: .barEight)
        var g = engine.newGame(); g.phase = .inPlay; g.groups = [0: .stripes, 1: .solids]; g.ballInHand = .none
        var got: DecisionRating?
        var h = LiveHooks(aimStarted: {}, aimEnded: {}, aimCancelled: {}, ballsSettled: {}, settled: { r, _ in got = r })
        h.currentGame = { (engine, g) }
        m.hooks = h
        // Shooter (stripes) hits and pots the 3 (a solid) first: wrong ball first.
        let shot = ShotRecord(start: 0, end: 1, preState: [:], finalState: [:], cueID: 1, firstContact: 2,
                              rails: [], pocketed: [2: .footLeft])
        m.noteResult(result(shot: shot))
        #expect(got == .mistake || got == .blunder)
    }

    /// 6: aimEnded never arrives without aimStarted first.
    @Test func hookSequenceStaysBalanced() {
        var a = AimEvents()
        let e = a.update(cueVisible: false, atRest: false, shotStarted: true, shotEnded: false, at: 0)
        #expect(e == [.aimStarted, .aimEnded])
    }

    /// 7: the badge goes when the shooter steps up even if the cue detector misses the aim, and on cue-ball motion.
    @Test func badgeHidesOnPreShotSignalsWithoutCueDetection() {
        let m = LiveModel(mode: .game)
        m.showBadge(BadgeStyle.of(.good))
        m.noteResult(result(shooterNear: true))
        #expect(m.badge == nil, "shooter addressing the cue ball")
        m.showBadge(BadgeStyle.of(.good))
        m.noteResult(result(cueSpeed: 0.06, atRest: false))
        #expect(m.badge == nil, "cue ball creeping")
    }
}

/// Codex r7 follow-ups.
struct R7Tests {
    /// Mouth count belongs to one frame: reset before each process, so a frame that skipped inference counts 0.
    @Test func mouthCountDoesNotCarryOver() {
        struct Fixed: TableKeypointProvider {
            func keypoints(in image: AutoRGBImage, intrinsics: AutoIntrinsics) -> [AutoTableKeypoint] {
                [AutoTableKeypoint(kind: .cornerMouth, pixel: .zero, confidence: 0.9),
                 AutoTableKeypoint(kind: .sideMouth, pixel: .zero, confidence: 0.9)]
            }
        }
        let c = MouthCountingProvider(wrapping: Fixed())
        _ = c.keypoints(in: AutoRGBImage(width: 1, height: 1, rgb: [0, 0, 0]),
                        intrinsics: AutoIntrinsics(fx: 1, fy: 1, cx: 0, cy: 0, width: 1, height: 1))
        #expect(c.lastMouths == 2)
        c.beginFrame()
        #expect(c.lastMouths == 0)   // this frame never called the model
    }

    /// The latch is only taken by frames that actually deliver a callback to the controller.
    @Test func latchTakenOnlyWhenSomethingIsDelivered() {
        #expect(FrameDelivery.delivers(statusTick: true, active: false, trackingNormal: false))
        #expect(FrameDelivery.delivers(statusTick: false, active: true, trackingNormal: true))
        #expect(!FrameDelivery.delivers(statusTick: false, active: true, trackingNormal: false))   // dropped frame
        #expect(!FrameDelivery.delivers(statusTick: false, active: false, trackingNormal: true))
    }

    /// Order is only claimed when every pocketed (known) ball has a distinct time.
    @Test func partialOrTiedTimesStayUnknown() {
        let ids: [Int: BallID] = [1: .cue, 2: BallID(3)!, 4: BallID(11)!]
        let r = ShotRecord(start: 0, end: 1, preState: [:], finalState: [:], cueID: 1, firstContact: 2,
                           rails: [], pocketed: [2: .footLeft, 4: .sideRight])
        #expect(RuleRating.outcome(r, ids: ids, pocketTimes: [2: 1.0]).pocketOrder.isEmpty)
        #expect(RuleRating.outcome(r, ids: ids, pocketTimes: [2: 1.0, 4: 1.0]).pocketOrder.isEmpty)
        #expect(RuleRating.outcome(r, ids: ids, pocketTimes: [2: 1.0, 4: 0.5]).pocketOrder == [BallID(11)!, BallID(3)!])
    }

    /// An injected game seeds ring legality before the first shot.
    @MainActor @Test func injectedGameSeedsLegality() {
        let m = LiveModel(mode: .game)
        let engine = RulesEngine(ruleSet: .barEight)
        var g = engine.newGame(); g.phase = .inPlay; g.groups = [0: .stripes, 1: .solids]; g.ballInHand = .none
        var h = LiveHooks()
        h.currentGame = { (engine, g) }
        m.hooks = h
        let legal = m.initialLegalTargets()
        #expect(legal.contains(BallID(11)!) && !legal.contains(BallID(3)!))
    }
}

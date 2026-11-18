import Foundation
import Geometry
import Testing
@testable import CueCoach

/// Unit tests for the tracker / segmenter / pipeline review fixes (Codex r5 M3, M6, M7; A0 zero-length).
struct TrackerFixTests {
    let spec = TableSpec(size: .sevenFoot)

    func ball(_ id: Int, _ p: Vec2, _ v: Vec2 = .zero, measured: Bool = true) -> TrackedBall {
        TrackedBall(id: id, position: p, velocity: v, kind: id == 1 ? .cue : .solid, tentativeNumber: nil, confirmed: true,
                    measured: measured)
    }

    /// M3: a ball heading into a pocket that is hidden for one frame and then seen again is not pocketed.
    @Test func oneFrameOcclusionNearAPocketIsNotAPocket() throws {
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
        #expect(s.inShot)
        let u = (corner - obj0).normalized
        let near = corner - u * 0.09
        t += 1 / 30
        _ = s.update(tracks: [ball(1, Vec2(0.8, 0.5)), ball(2, near, u * 1.0)], cueID: 1, atRest: false, at: t)
        t += 1 / 30   // hidden (coasting) one frame, right at the pocket
        _ = s.update(tracks: [ball(1, Vec2(0.8, 0.5)), ball(2, near + u * 0.03, u * 1.0, measured: false)], cueID: 1, atRest: false, at: t)
        // Seen again: it stopped in the jaws.
        var rec: ShotRecord?
        for _ in 0..<30 {
            t += 1 / 30
            rec = rec ?? s.update(tracks: [ball(1, Vec2(0.8, 0.5)), ball(2, near)], cueID: 1, atRest: true, at: t)
        }
        let r = try #require(rec)
        #expect(r.pocketed.isEmpty)
        #expect(r.finalState[2] == near)
    }

    /// Codex review F4: once a pocket is confirmed, a ball that turns up with that id far from the pocket (another
    /// ball or a false positive inheriting the id) does not un-pocket it.
    @Test func confirmedPocketSurvivesAFarReappearance() throws {
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
        t += 1 / 30   // gone, and the tracker dropped it: pocket confirmed
        _ = s.update(tracks: [ball(1, Vec2(0.8, 0.5))], cueID: 1, atRest: false, at: t)
        var rec: ShotRecord?
        for _ in 0..<40 {
            t += 1 / 30
            rec = rec ?? s.update(tracks: [ball(1, Vec2(0.8, 0.5)), ball(2, Vec2(1.0, 0.3))], cueID: 1, atRest: true, at: t)
        }
        let r = try #require(rec)
        #expect(r.pocketed[2] == .footRight)
    }

    /// Codex review F7: with no cue stick in view, a hand slowly pushing the (continuously tracked) cue ball
    /// is not a shot: a stroke leaves rest impulsively.
    @Test func slowHandPushIsNotAShot() {
        var tracker = KalmanBallTracker()
        var s = ShotSegmenter(spec: spec)
        var rng = SplitMix(seed: 4)
        var starts = 0
        var x = 0.5, v = 0.0
        for f in 0..<150 {
            let t = Double(f) / 30
            if t > 1.5 && t < 2.5 { v = min(0.2, v + 0.2 / 30) } else if t >= 2.5 { v = max(0, v - 0.4 / 30) }
            x += v / 30
            let dets = [Stress.det(Vec2(x, 0.5) + Vec2(rng.gauss(), rng.gauss()) * 0.002, .cue, 0),
                        Stress.det(Vec2(1.5, 0.6), .solid, 2)]
            let tr = tracker.update(dets, at: t)
            let was = s.inShot
            _ = s.update(tracks: tr, cueID: tr.first { $0.kind == .cue && $0.confirmed }?.id, atRest: tracker.isAtRest, at: t, strokeRecent: nil)
            if !was && s.inShot { starts += 1 }
        }
        #expect(x > 0.6)   // it really moved > 2R
        #expect(starts == 0)
    }

    /// A0: whatever the inputs, a shot never ends on the update that started it (no zero-length records).
    @Test func noZeroLengthShotEvenWhenAtRestStaysTrue() {
        var s = ShotSegmenter(spec: spec)
        var records: [ShotRecord] = []
        _ = s.update(tracks: [ball(1, Vec2(0.5, 0.5))], cueID: 1, atRest: true, at: 0)
        for i in 1...60 {
            // The tracker's at-rest lags: still true while the cue ball has already left its spot.
            let p = Vec2(0.5 + min(0.1, 0.02 * Double(i)), 0.5)
            let v = i <= 5 ? Vec2(0.6, 0) : .zero
            if let r = s.update(tracks: [ball(1, p, v)], cueID: 1, atRest: true, at: Double(i) / 30) { records.append(r) }
        }
        #expect(records.count == 1)
        #expect(records.allSatisfy { $0.end > $0.start })
    }
}

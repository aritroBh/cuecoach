import Foundation
import Geometry
import Physics
import simd
import Testing
@testable import CueCoach

/// Round-2 residuals from the Codex r2 review of wt/tracker (items 1-8 of the r2 brief).
struct TrackerR2Tests {
    let spec = TableSpec(size: .sevenFoot)

    func ball(_ id: Int, _ p: Vec2, _ v: Vec2 = .zero, measured: Bool = true) -> TrackedBall {
        TrackedBall(id: id, position: p, velocity: v, kind: id == 1 ? .cue : .solid, tentativeNumber: nil, confirmed: true,
                    measured: measured)
    }

    static func det(_ p: Vec2, _ k: BallKind, _ n: Int?, cueScore: Double?) -> BallDetection {
        BallDetection(imagePoint: .zero, tablePoint: p, radiusPx: 10, confidence: 1, kind: k, tentativeNumber: n, cueScore: cueScore)
    }

    // MARK: 1. Cue choice uses the detector's cue evidence, not continuity alone

    /// A white false positive (weak cue evidence) is on the table before the real cue ball (strong evidence)
    /// shows up. The real cue ball must take over.
    @Test func strongerCueEvidenceTakesOverFromAnEarlierWhiteFalsePositive() async throws {
        let d = ScriptedDetector()
        let p = PerceptionPipeline(detector: d)
        let scene = SyntheticTableScene.demo()
        await p.setTable(scene.frame)
        let cue = Vec2(0.5, 0.5), white = Vec2(1.9, 0.08)
        let objs = [Stress.det(Vec2(1.2, 0.45), .solid, 3), Stress.det(Vec2(1.5, 0.7), .solid, 1)]
        var last: PerceptionResult?
        for i in 0..<120 {
            var f = objs + [Self.det(white, .cue, 0, cueScore: 0.4)]
            if i >= 30 { f.insert(Self.det(cue, .cue, 0, cueScore: 0.95), at: 0) }
            d.push(f)
            last = await p.process(PerceptionFrame(image: Stress.blankImage(), camera: scene.camera, timestamp: Double(i) / 30))
        }
        let r = try #require(last)
        #expect(r.confirmed.filter { r.marks[$0.id] == .cue }.count == 1)
        let aim = try #require(r.aim)
        #expect(aim.cue.distance(to: cue) < 0.02, "aim from \(aim.cue)")
    }

    // MARK: 2. A lone ball's relocalization jump

    /// The tracker is told the frame moved (camera-pose jump): a lone ball shifted 10 cm is re-anchored, no shot.
    @Test func loneBallFrameShiftIsNotAShot() {
        var tracker = KalmanBallTracker()
        var seg = ShotSegmenter(spec: spec)
        var rng = SplitMix(seed: 2)
        var starts = 0
        for f in 0..<150 {
            let t = Double(f) / 30
            let p = Vec2(0.6, 0.5) + (f >= 60 ? Vec2(0.1, 0.03) : .zero)
            if f == 60 { tracker.noteFrameShift() }
            let tr = tracker.update([Stress.det(p + Vec2(rng.gauss(), rng.gauss()) * 0.002, .cue, 0)], at: t)
            let was = seg.inShot
            _ = seg.update(tracks: tr, cueID: tr.first { $0.confirmed }?.id, atRest: tracker.isAtRest, at: t, strokeRecent: nil)
            if !was && seg.inShot { starts += 1 }
        }
        #expect(starts == 0)
    }

    /// End to end: the pipeline sees the camera pose jump (relocalization) in the same frame as the lone ball.
    @Test func pipelineCameraPoseJumpIsNotAShot() async {
        let d = ScriptedDetector()
        let p = PerceptionPipeline(detector: d)
        let scene = SyntheticTableScene.demo()
        await p.setTable(scene.frame)
        var starts = 0
        for i in 0..<120 {
            var cam = scene.camera
            let jumped = i >= 60
            if jumped { cam.cameraToWorld.columns.3 += SIMD4(0.12, 0, 0.04, 0) }   // ARKit relocalized
            d.push([Stress.det(Vec2(0.6, 0.5) + (jumped ? Vec2(0.1, 0.03) : .zero), .cue, 0)])
            if let r = await p.process(PerceptionFrame(image: Stress.blankImage(), camera: cam, timestamp: Double(i) / 30)),
               r.shotStarted { starts += 1 }
        }
        #expect(starts == 0)
    }

    // MARK: 3. Graveyard inheritance

    /// A dead solid (number 3) does not hand its id to a different-looking solid born 40 cm away (no number);
    /// a detection that reads as the same number does inherit it.
    @Test func graveyardNeedsTheSameNumberToInheritFromAfar() {
        func run(_ born: BallDetection) -> (old: Int, new: Int) {
            var tr = KalmanBallTracker()
            var old = -1, new = -1
            for f in 0..<30 { old = tr.update([Stress.det(Vec2(1.0, 0.5), .solid, 3)], at: Double(f) / 30).first!.id }
            for f in 30..<45 { _ = tr.update([], at: Double(f) / 30) }            // hidden: the track dies
            for f in 45..<50 { new = tr.update([born], at: Double(f) / 30).first!.id }
            return (old, new)
        }
        let a = run(Stress.det(Vec2(1.4, 0.5), .solid, nil))
        #expect(a.old != a.new, "a numberless solid 40 cm away inherited id \(a.old)")
        let b = run(Stress.det(Vec2(1.4, 0.5), .solid, 7))
        #expect(b.old != b.new)
        let c = run(Stress.det(Vec2(1.4, 0.5), .solid, 3))
        #expect(c.old == c.new)
        let d = run(Stress.det(Vec2(1.005, 0.5), .solid, nil))                 // back where it was
        #expect(d.old == d.new)
    }

    // MARK: 4. A false positive near a pocket

    /// A confirmed pocket is not undone by a short-lived detection with the id near the pocket.
    @Test func briefNearPocketReappearanceDoesNotUndoAPocket() throws {
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
        _ = s.update(tracks: [ball(1, Vec2(0.8, 0.5))], cueID: 1, atRest: false, at: t)   // dropped: confirmed
        for _ in 0..<3 {   // a reflection in the jaws, 8 cm from the pocket, for 3 frames
            t += 1 / 30
            _ = s.update(tracks: [ball(1, Vec2(0.8, 0.5)), ball(2, corner - u * 0.08)], cueID: 1, atRest: false, at: t)
        }
        var rec: ShotRecord?
        for _ in 0..<40 {
            t += 1 / 30
            rec = rec ?? s.update(tracks: [ball(1, Vec2(0.8, 0.5))], cueID: 1, atRest: true, at: t)
        }
        let r = try #require(rec)
        #expect(r.pocketed[2] == .footRight)
    }

    // MARK: 5. Depth-found balls get the cloth white balance

    @Test func depthMergedCueBallIsWhiteUnderColouredLight() throws {
        let scene = SyntheticTableScene.demo()
        let geo = FrameGeometry(frame: scene.frame, camera: scene.camera)
        let neutral = try Stress.image(scene)
        let lockFelt = try #require(ClassicalBallDetector().feltColor(in: neutral, geometry: geo))
        let tinted = Stress.mapPixels(neutral) { ($0 * 1.0, $1 * 0.45, $2 * 1.1) }   // magenta bar light
        let cue = scene.balls[0].position
        let out = DepthFusion.merge([], depthBalls: [cue], image: tinted, geometry: geo, feltReference: lockFelt)
        #expect(out.first?.kind == .cue, "depth ball classified \(out.first?.kind.rawValue ?? "none")")
    }

    // MARK: 6. A slow ball that may be hanging in the jaws

    /// 0.6 m/s toward a corner: the physics says the ball stays on the table (it dies in the jaws, where the
    /// detector cannot see it). That is "uncertain", not pocketed; at 1-3 m/s it is pocketed.
    @Test func slowBallLostInTheJawsIsUncertainNotPocketed() throws {
        for v in [0.6, 1.0, 2.0, 3.0] {
            let cue = Vec2(1.2, 0.6), obj = Vec2(0.4, 0.75)
            let toPocket = (Stress.spec.pocketCenter(.footLeft) - cue).normalized
            let (r, trace) = TrackerStressTests.run([.cue: cue, BallID(2)!: obj], stroke: Stroke(direction: toPocket, speed: v))
            let truth = TrackerStressTests.pocketed(trace)[.cue] != nil
            let rec = try #require(r.records.first)
            Stress.metric("jaws.v\(v)", "truth=\(truth) pocketed=\(rec.pocketed[rec.cueID] != nil) uncertain=\(rec.uncertainPockets[rec.cueID] != nil)")
            if truth {
                #expect(rec.pocketed[rec.cueID] == .footLeft, "v \(v)")
            } else {
                #expect(rec.pocketed[rec.cueID] == nil, "v \(v): a ball that stayed on the table was recorded pocketed")
                #expect(rec.uncertainPockets[rec.cueID] == .footLeft, "v \(v)")
            }
        }
    }

    // MARK: 8. Pocket drop times

    @Test func recordCarriesPocketDropTimesInOrder() throws {
        var s = ShotSegmenter(spec: spec)
        var t = 0.0
        let fr = spec.pocketCenter(.footRight), fl = spec.pocketCenter(.footLeft)
        let a0 = fr - Vec2(0.3, 0.3), b0 = fl - Vec2(0.4, -0.4)
        _ = s.update(tracks: [ball(1, Vec2(0.5, 0.5)), ball(2, a0), ball(3, b0)], cueID: 1, atRest: true, at: t, strokeRecent: true)
        for i in 1...3 {
            t += 1 / 30
            _ = s.update(tracks: [ball(1, Vec2(0.5 + 0.05 * Double(i), 0.5), Vec2(1.5, 0)), ball(2, a0), ball(3, b0)], cueID: 1,
                         atRest: false, at: t, strokeRecent: true)
        }
        let ua = (fr - a0).normalized, ub = (fl - b0).normalized
        // Ball 3 drops first (t ≈ 0.17), ball 2 about 0.5 s later.
        t += 1 / 30
        _ = s.update(tracks: [ball(1, Vec2(0.8, 0.5)), ball(2, a0 + ua * 0.05, ua * 1.5), ball(3, fl - ub * 0.09, ub * 1.5)], cueID: 1, atRest: false, at: t)
        let tb = t
        for k in 0..<15 {
            t += 1 / 30
            _ = s.update(tracks: [ball(1, Vec2(0.8, 0.5)), ball(2, fr - ua * (0.09 + 0.05 * Double(14 - k)), ua * 1.5)], cueID: 1, atRest: false, at: t)
        }
        let ta = t
        var rec: ShotRecord?
        for _ in 0..<40 {
            t += 1 / 30
            rec = rec ?? s.update(tracks: [ball(1, Vec2(0.8, 0.5))], cueID: 1, atRest: true, at: t)
        }
        let r = try #require(rec)
        #expect(r.pocketed[2] == .footRight && r.pocketed[3] == .footLeft)
        let p2 = try #require(r.pocketTimes[2]), p3 = try #require(r.pocketTimes[3])
        #expect(p3 < p2)
        #expect(abs(p3 - tb) < 0.15 && abs(p2 - ta) < 0.15, "times \(p3) \(p2) vs \(tb) \(ta)")
    }
}

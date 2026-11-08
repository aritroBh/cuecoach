import Foundation
import Geometry
import Physics
import Testing
@testable import CueCoach

/// Tracker + segmenter driven by CueCore Physics ground truth (what the camera would see at 30 Hz).
struct TrackerStressTests {
    struct Run {
        var ledger = Stress.IDLedger()
        var records: [ShotRecord] = []
        var starts = 0
        var preIDs: [BallID: Int] = [:]   // track id sitting on each truth ball before the shot
        var maxSpeedAtRest = 0.0
        var phantoms = 0
    }

    /// 1 s at rest, the shot, then the tail; same wiring as PerceptionPipeline (strokeRecent nil = no cue seen).
    static func run(_ balls: [BallID: Vec2], stroke: Stroke, noise: Double = 0.002, seed: UInt64 = 1, fps: Double = 30,
                    hidden: @escaping (Double, Vec2) -> Bool = { _, _ in false }) -> (Run, ShotTrace) {
        var rng = SplitMix(seed: seed)
        var tracker = KalmanBallTracker()
        var seg = ShotSegmenter(spec: Stress.spec)
        var out = Run()
        let (trace, frames) = Stress.simulate(balls, stroke: stroke, fps: fps, tail: 2.0)
        func step(_ truth: [BallID: Vec2], _ t: Double, ledger: Bool) {
            let dets = Stress.detections(truth, noise: noise, rng: &rng, hidden: { hidden(t, $0) })
            let tracks = tracker.update(dets, at: t)
            let cue = tracks.filter(\.confirmed).first { $0.kind == .cue }
            let wasIn = seg.inShot
            if let r = seg.update(tracks: tracks, cueID: cue?.id, atRest: tracker.isAtRest, at: t, strokeRecent: nil) {
                // Zero-length records (start == end) are the A0 phantom; counted apart so other findings stay isolated.
                if r.end == r.start { out.phantoms += 1 } else { out.records.append(r) }
            }
            if !wasIn && seg.inShot { out.starts += 1 }
            if ledger { out.ledger.observe(truth: truth.filter { !hidden(t, $0.value) }, tracks: tracks) }
        }
        let t0 = -1.0
        for i in 0..<Int(fps) { step(balls, t0 + Double(i) / fps, ledger: false) }
        let tracks = tracker.update(Stress.detections(balls, noise: noise, rng: &rng), at: -0.0001)
        for (id, p) in balls {
            if let tr = tracks.min(by: { $0.position.distance(to: p) < $1.position.distance(to: p) }) { out.preIDs[id] = tr.id }
        }
        for f in frames { step(f.balls, f.t, ledger: true) }
        return (out, trace)
    }

    static func pocketed(_ trace: ShotTrace) -> [BallID: Pocket] {
        var out: [BallID: Pocket] = [:]
        for e in trace.events { if case let .pocket(id, p) = e.event { out[id] = p } }
        return out
    }

    // MARK: Speed

    /// 1 m/s cue ball from rest into a lone object ball: one id per ball, a shot recorded with the right first contact.
    @Test func oneMetrePerSecondFromRestKeepsIdentity() throws {
        let cue = Vec2(0.6, 0.5), obj = Vec2(1.4, 0.55)
        let balls: [BallID: Vec2] = [.cue: cue, BallID(3)!: obj]
        let (r, _) = Self.run(balls, stroke: Stroke(direction: (obj - cue).normalized, speed: 1.0))
        Stress.metric("speed1.idChanges", r.ledger.changes)
        Stress.metric("speed1.swaps", r.ledger.swaps)
        Stress.metric("speed1.lostFrames", "\(r.ledger.lostFrames)/\(r.ledger.ballFrames)")
        #expect(r.ledger.swaps == 0)
        #expect(r.ledger.changes == 0, "cue ids \(r.ledger.seen[.cue] ?? [])")
        #expect(r.starts == 1)
        let rec = try #require(r.records.first)
        #expect(rec.firstContact == r.preIDs[BallID(3)!])
    }

    /// Break speed: the cue ball leaves rest at 3.8 m/s (12.7 cm per 30 Hz frame).
    @Test(.disabled("STRESS-FINDING A1: a ball launched from rest at >= 3 m/s leaves the Kalman gate; the cue track is replaced and the shot starts 0.3 s late"))
    func breakSpeedFromRestKeepsTheCueTrack() throws {
        let cue = Vec2(0.5, 0.48), obj = Vec2(1.6, 0.5)
        let balls: [BallID: Vec2] = [.cue: cue, BallID(3)!: obj]
        let (r, _) = Self.run(balls, stroke: Stroke(direction: (obj - cue).normalized, speed: 3.8))
        Stress.metric("speed3.8.cueIDs", r.ledger.seen[.cue] ?? [])
        Stress.metric("speed3.8.lostFrames", "\(r.ledger.lostFrames)/\(r.ledger.ballFrames)")
        Stress.metric("speed3.8.starts", r.starts)
        Stress.metric("speed3.8.cuePreID", r.preIDs[.cue] ?? -1)
        Stress.metric("speed3.8.shotStartLatency", r.records.first { $0.end > $0.start }.map { String(format: "%.2f s", $0.start) } ?? "none")
        #expect(r.ledger.seen[.cue]?.first == r.preIDs[.cue], "pre-shot cue id \(r.preIDs[.cue] ?? -1), during shot \(r.ledger.seen[.cue] ?? [])")
        #expect(r.ledger.changes == 0, "cue ids \(r.ledger.seen[.cue] ?? [])")
        #expect(r.starts == 1)
    }

    /// Sweep of launch speeds: where does the from-rest track break?
    @Test func launchSpeedSweep() {
        var firstBroken: Double?
        for v in [0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0] {
            let cue = Vec2(0.5, 0.48), obj = Vec2(1.7, 0.5)
            let (r, _) = Self.run([.cue: cue, BallID(3)!: obj], stroke: Stroke(direction: (obj - cue).normalized, speed: v))
            let kept = r.ledger.seen[.cue]?.first == r.preIDs[.cue]
            let ids = (r.ledger.seen[.cue]?.count ?? 0) + (kept ? 0 : 1)
            Stress.metric("sweep.v\(v).cueTrackIDs", ids)
            Stress.metric("sweep.v\(v).startLatency", r.records.first { $0.end > $0.start }.map { String(format: "%.2f", $0.start) } ?? "none")
            Stress.metric("sweep.v\(v).shotStarts", r.starts)
            if firstBroken == nil && (ids != 1 || r.starts != 1) { firstBroken = v }
        }
        Stress.metric("sweep.firstBrokenSpeed", firstBroken.map { "\($0)" } ?? "none")
    }

    /// Full 16-ball break from the physics engine: ID-swap rate and the shot record.
    @Test
    func breakShotIdentityAndRecord() throws {
        var balls: [BallID: Vec2] = [.cue: Stress.spec.headSpot]
        for (i, p) in Stress.rack().enumerated() { balls[BallID(Stress.rackNumbers[i])!] = p }
        let apex = Stress.rack()[0]
        let (r, trace) = Self.run(balls, stroke: Stroke(direction: (apex - Stress.spec.headSpot).normalized, speed: 3.8))
        let rate = Double(r.ledger.changes) / Double(max(1, r.ledger.ballFrames))
        Stress.metric("break.idChanges", r.ledger.changes)
        Stress.metric("break.swaps", r.ledger.swaps)
        Stress.metric("break.idChangeRatePerBallFrame", String(format: "%.4f", rate))
        Stress.metric("break.lostFrames", "\(r.ledger.lostFrames)/\(r.ledger.ballFrames)")
        Stress.metric("break.starts", r.starts)
        Stress.metric("break.records", r.records.count)
        Stress.metric("break.truthPocketed", Self.pocketed(trace).keys.map(\.number).sorted())
        #expect(r.ledger.swaps == 0)
        #expect(r.starts == 1)
        let rec = try #require(r.records.first)
        #expect(rec.firstContact == r.preIDs[BallID(1)!])
        #expect(rec.pocketed.count == Self.pocketed(trace).count)
    }

    /// Same break, measured (always runs) so the numbers stay visible.
    @Test func breakShotMeasurements() {
        var balls: [BallID: Vec2] = [.cue: Stress.spec.headSpot]
        for (i, p) in Stress.rack().enumerated() { balls[BallID(Stress.rackNumbers[i])!] = p }
        let apex = Stress.rack()[0]
        for v in [1.5, 2.5, 3.8] {
            var swaps = 0, changes = 0, frames = 0, starts = 0, recs = 0
            for seed in UInt64(1)...5 {
                let (r, _) = Self.run(balls, stroke: Stroke(direction: (apex - Stress.spec.headSpot).normalized, speed: v), seed: seed)
                swaps += r.ledger.swaps; changes += r.ledger.changes; frames += r.ledger.ballFrames
                starts += r.starts; recs += r.records.count
            }
            Stress.metric("breakV\(v).swapsPer1000BallFrames", String(format: "%.2f", 1000 * Double(swaps) / Double(frames)))
            Stress.metric("breakV\(v).idChangesPer1000BallFrames", String(format: "%.2f", 1000 * Double(changes) / Double(frames)))
            Stress.metric("breakV\(v).shotStartsOf5", starts)
            Stress.metric("breakV\(v).recordsOf5", recs)
        }
    }

    /// Two balls exchanging motion in a head-on collision at 1.5 m/s, many noise seeds: swap rate.
    @Test(.disabled("STRESS-FINDING A2: head-on collision from rest at 1.5 m/s: the coasting cue track captures the departing object ball (ID swap)")) func collisionSwapRate() {
        var swaps = 0, frames = 0
        for seed in UInt64(1)...40 {
            let cue = Vec2(0.6, 0.5), obj = Vec2(1.0, 0.5 + Double(seed % 5) * 0.004)
            let (r, _) = Self.run([.cue: cue, BallID(5)!: obj], stroke: Stroke(direction: (obj - cue).normalized, speed: 1.5),
                                  noise: 0.003, seed: seed)
            swaps += r.ledger.swaps; frames += r.ledger.ballFrames
        }
        Stress.metric("collision1.5.swapsPer1000BallFrames", String(format: "%.2f", 1000 * Double(swaps) / Double(frames)))
        #expect(swaps == 0)
    }

    // MARK: Pocketing

    /// The cue ball rolls into a corner at 2 m/s: the record must say the cue ball was pocketed (a scratch).
    @Test(.disabled("STRESS-FINDING A3: pocketed balls are never recorded: the tracker coasts a vanished track past the pocket, so last-seen is outside the 7 cm capture zone"))
    func fastPocketedCueBallIsRecorded() throws {
        let cue = Vec2(1.2, 0.6), obj = Vec2(0.4, 0.75)
        let toPocket = (Stress.spec.pocketCenter(.footLeft) - cue).normalized
        let (r, trace) = Self.run([.cue: cue, BallID(2)!: obj], stroke: Stroke(direction: toPocket, speed: 2.0))
        #expect(Self.pocketed(trace)[.cue] == .footLeft)
        let rec = try #require(r.records.first)
        Stress.metric("pocket2.0.recordPocketed", rec.pocketed)
        #expect(rec.pocketed[rec.cueID] == .footLeft)
    }

    @Test func pocketedRecordSpeedSweep() {
        for v in [0.6, 1.0, 1.5, 2.0, 3.0] {
            let cue = Vec2(1.2, 0.6), obj = Vec2(0.4, 0.75)
            let toPocket = (Stress.spec.pocketCenter(.footLeft) - cue).normalized
            let (r, trace) = Self.run([.cue: cue, BallID(2)!: obj], stroke: Stroke(direction: toPocket, speed: v))
            let truth = Self.pocketed(trace)[.cue] != nil
            let rec = r.records.first
            Stress.metric("pocketSweep.v\(v)", "truthPocketed=\(truth) recorded=\(rec.map { $0.pocketed[$0.cueID] != nil } ?? false) records=\(r.records.count)")
        }
    }

    // MARK: Occlusion

    /// A person walks in front, hiding 40 % of the table (the head end) for 2 s while 16 balls are at rest.
    @Test(.disabled("STRESS-FINDING A4: a person hiding 40% of the table for 2 s at rest: the cue ball comes back as a new track and a real (non-zero-length) false shot starts")) func personHidingFortyPercentAtRestNoFalseShot() {
        var balls: [BallID: Vec2] = [.cue: Vec2(0.4, 0.5)]
        for (i, p) in Stress.rack().enumerated() { balls[BallID(Stress.rackNumbers[i])!] = p }
        balls[BallID(3)!] = Vec2(0.6, 0.3)   // a couple of balls in the hidden zone
        balls[BallID(11)!] = Vec2(0.7, 0.8)
        var rng = SplitMix(seed: 9)
        var tracker = KalmanBallTracker()
        var seg = ShotSegmenter(spec: Stress.spec)
        let L = Stress.spec.length
        var starts = 0, restFalse = 0, phantoms = 0
        var before: [Int] = [], after: [Int] = []
        for f in 0..<240 {
            let t = Double(f) / 30
            let hide = t >= 2 && t < 4
            let dets = Stress.detections(balls, noise: 0.002, rng: &rng, hidden: { hide && $0.x < 0.4 * L })
            let tracks = tracker.update(dets, at: t)
            let cue = tracks.filter(\.confirmed).first { $0.kind == .cue }
            let was = seg.inShot
            if let r = seg.update(tracks: tracks, cueID: cue?.id, atRest: tracker.isAtRest, at: t, strokeRecent: nil), r.end == r.start { phantoms += 1 }
            if !was && seg.inShot { starts += 1 }
            if f > 60 && !tracker.isAtRest { restFalse += 1 }
            if f == 59 { before = tracks.filter(\.confirmed).map(\.id).sorted() }
            if f == 239 { after = tracks.filter(\.confirmed).map(\.id).sorted() }
        }
        let reIDs = Set(after).subtracting(before).count
        Stress.metric("occlusion40.falseShots", starts)
        Stress.metric("occlusion40.phantomRecords", phantoms)
        Stress.metric("occlusion40.framesNotAtRest", restFalse)
        Stress.metric("occlusion40.reassignedIDs", reIDs)
        #expect(starts == 0)
    }

    /// Same occlusion while balls are still rolling after a 1.5 m/s shot: the shot must not end while hidden
    /// balls are still moving, and the record's final state must cover every ball still on the table.
    @Test(.disabled("STRESS-FINDING A5: 2 s occlusion mid-shot ends the shot while hidden balls still roll; finalState carries new ids not in preState"))
    func personHidingFortyPercentMidShot() throws {
        let cue = Vec2(0.5, 0.5), obj = Vec2(1.2, 0.52)
        let L = Stress.spec.length
        let (r, trace) = Self.run([.cue: cue, BallID(4)!: obj, BallID(12)!: Vec2(1.8, 0.2)],
                                  stroke: Stroke(direction: (obj - cue).normalized, speed: 2.2),
                                  hidden: { t, p in t > 0.3 && t < 2.3 && p.x < 0.4 * L || (t > 0.3 && t < 2.3 && p.x > 0.6 * L) })
        Stress.metric("occludedShot.records", r.records.count)
        Stress.metric("occludedShot.starts", r.starts)
        Stress.metric("occludedShot.duration", trace.duration)
        let rec = try #require(r.records.first)
        Stress.metric("occludedShot.endedAt", rec.end)
        #expect(r.records.count == 1)
        #expect(rec.end >= trace.duration - 0.1, "ended at \(rec.end) while balls rolled until \(trace.duration)")
        #expect(Set(rec.finalState.keys).isSubset(of: Set(rec.preState.keys)))
    }

    // MARK: Hand / still cue / false shots

    /// Jittered static balls with no cue visible (strokeRecent nil), 10 minutes per noise level: false starts.
    @Test(.disabled("STRESS-FINDING A0: with 2-4 mm detector jitter at rest the segmenter emits ~20k zero-length shot records per hour (Kalman speed noise > startSpeed, then atRest still true in the same update)")) func falseShotRateFromJitter() {
        for sigma in [0.002, 0.004, 0.006, 0.008, 0.012] {
            var rng = SplitMix(seed: 77)
            var tracker = KalmanBallTracker()
            var seg = ShotSegmenter(spec: Stress.spec)
            let balls: [BallID: Vec2] = [.cue: Vec2(0.6, 0.5), BallID(1)!: Vec2(1.3, 0.4), BallID(8)!: Vec2(1.6, 0.7)]
            var starts = 0, zeroLength = 0, restFrames = 0
            var speeds: [Double] = []
            let n = 30 * 600
            for f in 0..<n {
                let t = Double(f) / 30
                // Coherent AR pose jitter (all balls shift together) + per-ball detector noise.
                let shift = Vec2(rng.gauss(), rng.gauss()) * (sigma * 0.5)
                let dets = Stress.detections(balls.mapValues { $0 + shift }, noise: sigma, rng: &rng)
                let tracks = tracker.update(dets, at: t)
                let cue = tracks.filter(\.confirmed).first { $0.kind == .cue }
                if f > 60, let c = cue { speeds.append(c.speed) }
                if tracker.isAtRest { restFrames += 1 }
                let was = seg.inShot
                if let r = seg.update(tracks: tracks, cueID: cue?.id, atRest: tracker.isAtRest, at: t, strokeRecent: nil),
                   !was { starts += 1; if r.start == r.end { zeroLength += 1 } }
                if !was && seg.inShot { starts += 1 }
            }
            Stress.metric("falseShot.sigma\(sigma * 1000)mm.perHour", starts * 6)
            Stress.metric("falseShot.sigma\(sigma * 1000)mm.zeroLengthPerHour", zeroLength * 6)
            Stress.metric("falseShot.sigma\(sigma * 1000)mm.atRestFraction", String(format: "%.3f", Double(restFrames) / Double(n)))
            Stress.metric("falseShot.sigma\(sigma * 1000)mm.cueSpeedP99", String(format: "%.3f", Stress.percentile(speeds, 0.99)))
            if sigma <= 0.004 { #expect(starts == 0, "σ \(sigma): \(starts) false shots in 10 min") }
        }
    }

    /// End to end: still balls with 2 mm detector jitter for 3 min through PerceptionPipeline. Every
    /// `r.shot` fires a haptic in ARLiveController.handle and is a shot record downstream.
    @Test(.disabled("STRESS-FINDING A0: PerceptionPipeline returns r.shot (haptic + record) for phantom zero-length shots while balls are at rest"))
    func phantomShotsAtRestThroughPipeline() async {
        let d = ScriptedDetector()
        let p = PerceptionPipeline(detector: d)
        let scene = SyntheticTableScene.demo()
        await p.setTable(scene.frame)
        let gen = JitterGen(sigma: 0.002)
        d.setGenerator { gen.next() }
        var shots = 0, starts = 0, aimFrames = 0
        let img = Stress.blankImage()
        let n = 30 * 180   // 3 minutes
        for f in 0..<n {
            guard let r = await p.process(PerceptionFrame(image: img, camera: scene.camera, timestamp: Double(f) / 30)) else { continue }
            if r.shot != nil { shots += 1 }
            if r.shotStarted { starts += 1 }
            if r.aim != nil { aimFrames += 1 }
        }
        Stress.metric("phantom.pipeline.shotRecordsPerHour", shots * 20)
        Stress.metric("phantom.pipeline.shotStartedFlagsPerHour", starts * 20)
        Stress.metric("phantom.pipeline.aimFrameFraction", String(format: "%.3f", Double(aimFrames) / Double(n)))
        #expect(shots == 0)
    }

    /// A hand carries the cue ball (ball in hand): lifted for 1 s, set down 0.4 m away and rolled into place at
    /// 0.4 m/s for 0.4 s. No cue stick is in view. This must not be a shot.
    @Test(.disabled("STRESS-FINDING A7: hand-placing the cue ball with no cue stick in view starts a real shot (strokeRecent nil passes the gate; the re-born cue track has noisy velocity)"))
    func handPlacingTheCueBallIsNotAShot() {
        let r = Self.handPlacement()
        Stress.metric("handPlacement.falseShots", r.starts)
        #expect(r.starts == 0)
    }

    @Test func handPlacementMeasurement() {
        Stress.metric("handPlacement.measuredStarts", Self.handPlacement().starts)
    }

    static func handPlacement() -> (starts: Int, records: Int) {
        var rng = SplitMix(seed: 5)
        var tracker = KalmanBallTracker()
        var seg = ShotSegmenter(spec: Stress.spec)
        var cuePos: Vec2? = Vec2(0.5, 0.5)
        let others: [BallID: Vec2] = [BallID(2)!: Vec2(1.4, 0.3), BallID(9)!: Vec2(1.5, 0.8)]
        var starts = 0, recs = 0, phantoms = 0
        for f in 0..<240 {
            let t = Double(f) / 30
            if t >= 2 && t < 3 { cuePos = nil }                                  // in the hand
            else if t >= 3 && t < 3.4 { cuePos = Vec2(0.9 + (t - 3) * 0.4, 0.45) } // rolled into place
            else if t >= 3.4 { cuePos = Vec2(0.9 + 0.16, 0.45) }
            var truth = others
            if let c = cuePos { truth[.cue] = c }
            let tracks = tracker.update(Stress.detections(truth, noise: 0.002, rng: &rng), at: t)
            let cue = tracks.filter(\.confirmed).first { $0.kind == .cue }
            let was = seg.inShot
            if let r = seg.update(tracks: tracks, cueID: cue?.id, atRest: tracker.isAtRest, at: t, strokeRecent: nil) { if r.end > r.start { recs += 1 } else { phantoms += 1 } }
            if !was && seg.inShot { starts += 1 }
        }
        Stress.metric("handPlacement.phantomRecords", phantoms)
        return (starts, recs)
    }

    /// A cue stick held still behind the cue ball for 10 s: tip-distance jitter from the line fit must not
    /// read as a stroke, and with the ball still there is no shot.
    @Test func cueHeldStillTenSecondsTipJitter() {
        for sigma in [0.002, 0.005, 0.01, 0.02] {
            var rng = SplitMix(seed: 11)
            var cueT = CueAimTracker()
            var strokes = 0
            for f in 0..<300 {
                let t = Double(f) / 30
                let o = CueObservation(direction: Vec2(1, 0).rotated(by: rng.gauss() * 0.01),
                                       tipDistance: max(0.03, 0.06 + rng.gauss() * sigma), confidence: 0.8)
                if cueT.update(o, at: t) { strokes += 1 }
            }
            Stress.metric("stillCue.tipSigma\(sigma * 1000)mm.falseStrokesPer10s", strokes)
            // The real line fit measured 2.3 mm tip SD on rendered frames (PerceptionStressTests); assert there.
            if sigma <= 0.002 { #expect(strokes == 0) }
        }
    }

    // MARK: Tracking gaps, relocalization

    /// Tracking lost for 1.5 s mid-shot (no frames), then frames resume with the balls stopped elsewhere.
    @Test func trackingGapMidShot() {
        var rng = SplitMix(seed: 3)
        var tracker = KalmanBallTracker()
        var seg = ShotSegmenter(spec: Stress.spec)
        let cue = Vec2(0.5, 0.5), obj = Vec2(1.2, 0.52)
        let (_, frames) = Stress.simulate([.cue: cue, BallID(6)!: obj], stroke: Stroke(direction: (obj - cue).normalized, speed: 1.8),
                                          tail: 2)
        var recs: [ShotRecord] = []
        var starts = 0
        func step(_ b: [BallID: Vec2], _ t: Double) {
            let tracks = tracker.update(Stress.detections(b, noise: 0.002, rng: &rng), at: t)
            let c = tracks.filter(\.confirmed).first { $0.kind == .cue }
            let was = seg.inShot
            if let r = seg.update(tracks: tracks, cueID: c?.id, atRest: tracker.isAtRest, at: t, strokeRecent: nil) { if r.end > r.start { recs.append(r) } }
            if !was && seg.inShot { starts += 1 }
        }
        for i in 0..<30 { step([.cue: cue, BallID(6)!: obj], -1 + Double(i) / 30) }
        for f in frames where f.t < 0.4 || f.t > 1.9 { step(f.balls, f.t) }
        Stress.metric("trackingGap.starts", starts)
        Stress.metric("trackingGap.records", recs.count)
        Stress.metric("trackingGap.finalKeysSubsetOfPre", recs.first.map { Set($0.finalState.keys).isSubset(of: Set($0.preState.keys)) } ?? false)
        #expect(starts == 1)
        #expect(recs.count == 1)
    }

    /// Relocalization lands the old table frame 0.5 m off: every detection shifts by 0.5 m at once. Tracks
    /// must not be read as balls moving at 15 m/s (a false shot) — they should be dropped and rebuilt.
    @Test(.disabled("STRESS-FINDING A8: a 0.5 m relocalization jump re-creates every track and the new cue track starts a false shot")) func relocalizationJumpIsNotAShot() {
        var rng = SplitMix(seed: 8)
        var tracker = KalmanBallTracker()
        var seg = ShotSegmenter(spec: Stress.spec)
        let balls: [BallID: Vec2] = [.cue: Vec2(0.5, 0.5), BallID(1)!: Vec2(1.2, 0.4), BallID(8)!: Vec2(1.5, 0.7)]
        var starts = 0, phantoms = 0
        for f in 0..<180 {
            let t = Double(f) / 30
            let off = t >= 2 ? Vec2(0.5, 0) : .zero
            let tracks = tracker.update(Stress.detections(balls.mapValues { $0 + off }, noise: 0.002, rng: &rng), at: t)
            let c = tracks.filter(\.confirmed).first { $0.kind == .cue }
            let was = seg.inShot
            if let r = seg.update(tracks: tracks, cueID: c?.id, atRest: tracker.isAtRest, at: t, strokeRecent: nil), r.end == r.start { phantoms += 1 }
            if !was && seg.inShot { starts += 1 }
        }
        Stress.metric("reloc0.5m.falseShots", starts)
        Stress.metric("reloc0.5m.phantomRecords", phantoms)
        #expect(starts == 0)
    }

    // MARK: Ordering, NaN, empty

    @Test func frameOrderingUnderShuffleAndDuplicates() {
        var rng = SplitMix(seed: 21)
        var order = FrameOrdering()
        var applied: [Int] = []
        var epoch = 0
        var stream: [(seq: Int, epoch: Int)] = []
        for s in 1...2000 {
            if s % 250 == 0 { epoch += 1 }
            stream.append((s, epoch))
            if rng.uniform() < 0.1 { stream.append((s, epoch)) }   // duplicate
        }
        // Local shuffles (results finish out of order).
        for i in stride(from: 0, to: stream.count - 3, by: 3) where rng.uniform() < 0.5 { stream.swapAt(i, i + 2) }
        var current = 0
        for (s, e) in stream {
            current = max(current, e)
            if order.accept(seq: s, epoch: e, currentEpoch: current) { applied.append(s) }
        }
        #expect(applied == applied.sorted())
        #expect(Set(applied).count == applied.count)
        Stress.metric("ordering.appliedOf2000", applied.count)
    }

    /// Out-of-order and duplicate timestamps straight into the tracker (dt clamps): no velocity spike.
    @Test func trackerOutOfOrderAndDuplicateTimestamps() {
        var tracker = KalmanBallTracker()
        var peak = 0.0
        var ts: [Double] = (0..<120).map { Double($0) / 30 }
        ts.swapAt(40, 41); ts.swapAt(80, 81)
        ts.insert(ts[60], at: 61)
        for t in ts {
            let out = tracker.update([Stress.det(Vec2(1.0, 0.5), .cue, 0)], at: t)
            if t > 0.5 { peak = max(peak, out.map(\.speed).max() ?? 0) }
        }
        Stress.metric("outOfOrder.staticPeakSpeed", peak)
        #expect(peak < 0.1)
        #expect(tracker.isAtRest)
    }

    /// A moving ball whose frames arrive swapped: the velocity estimate must stay sane (no 30 m/s spike).
    @Test
    func trackerOutOfOrderMovingBall() {
        var tracker = KalmanBallTracker()
        var ts: [Double] = (0..<60).map { Double($0) / 30 }
        ts.swapAt(30, 31)
        var peak = 0.0
        for t in ts {
            let out = tracker.update([Stress.det(Vec2(0.3 + 0.8 * t, 0.5), .cue, 0)], at: t)
            if t > 0.3 { peak = max(peak, out.map(\.speed).max() ?? 0) }
        }
        Stress.metric("outOfOrder.movingPeakSpeed", peak)
        #expect(peak < 1.6)
    }

    @Test func nanAndInfiniteDetectionsDoNotPoisonTracks() {
        var tracker = KalmanBallTracker()
        var ok = true
        for f in 0..<120 {
            var dets = [Stress.det(Vec2(1.0, 0.5), .cue, 0), Stress.det(Vec2(1.4, 0.6), .solid, 2)]
            if f % 3 == 0 { dets.append(Stress.det(Vec2(.nan, 0.4))) }
            if f % 5 == 0 { dets.append(Stress.det(Vec2(.infinity, -.infinity))) }
            let out = tracker.update(dets, at: Double(f) / 30)
            if out.filter(\.confirmed).contains(where: { !$0.position.x.isFinite || !$0.position.y.isFinite }) { ok = false }
        }
        #expect(ok)
        #expect(tracker.isAtRest)
    }

    @Test func emptyFramesThenBallsReturn() {
        var tracker = KalmanBallTracker()
        for f in 0..<300 { #expect(tracker.update([], at: Double(f) / 30).isEmpty) }
        var restAt: Int?
        for f in 300..<400 {
            _ = tracker.update([Stress.det(Vec2(1.0, 0.5), .cue, 0)], at: Double(f) / 30)
            if restAt == nil && tracker.isAtRest { restAt = f - 300 }
        }
        Stress.metric("empty.framesToRestAfterReturn", restAt ?? -1)
        #expect(restAt != nil)
    }

    // MARK: Rack / clusters at the tracker

    @Test func sixteenBallRackTrackedAsSixteen() {
        var balls: [BallID: Vec2] = [.cue: Stress.spec.headSpot]
        for (i, p) in Stress.rack(gap: 0).enumerated() { balls[BallID(Stress.rackNumbers[i])!] = p }
        var rng = SplitMix(seed: 4)
        var tracker = KalmanBallTracker()
        var out: [TrackedBall] = []
        for f in 0..<60 { out = tracker.update(Stress.detections(balls, noise: 0.002, rng: &rng), at: Double(f) / 30) }
        #expect(out.filter(\.confirmed).count == 16)
        #expect(tracker.isAtRest)
    }

    // MARK: Segmenter end condition

    /// One confirmed spurious track that keeps jittering (a reflection, a hand on the rail) after the shot.
    @Test(.disabled("STRESS-FINDING A6: one jittery confirmed false positive keeps tracker.isAtRest false forever: the shot never ends, no aim, record.rails grows"))
    func jitteryFalsePositiveBlocksShotEnd() {
        let r = Self.jitteryRun()
        Stress.metric("jitteryFP.recordsIn60s", r.records)
        #expect(r.records == 1)
    }

    @Test func jitteryFalsePositiveMeasurement() {
        let r = Self.jitteryRun()
        Stress.metric("jitteryFP.measuredRecords", r.records)
        Stress.metric("jitteryFP.segmenterSizesAfter60s", r.sizes)
    }

    static func jitteryRun() -> (records: Int, sizes: [String: Int]) {
        var rng = SplitMix(seed: 31)
        var tracker = KalmanBallTracker()
        var seg = ShotSegmenter(spec: Stress.spec)
        let cue = Vec2(0.5, 0.5), obj = Vec2(1.1, 0.5)
        let (_, frames) = Stress.simulate([.cue: cue, BallID(7)!: obj], stroke: Stroke(direction: Vec2(1, 0), speed: 1.2), tail: 60)
        var recs = 0
        for i in 0..<30 {
            let t = -1 + Double(i) / 30
            let tracks = tracker.update(Stress.detections([.cue: cue, BallID(7)!: obj], noise: 0.002, rng: &rng), at: t)
            _ = seg.update(tracks: tracks, cueID: tracks.first { $0.kind == .cue && $0.confirmed }?.id,
                           atRest: tracker.isAtRest, at: t, strokeRecent: nil)
        }
        for f in frames {
            var dets = Stress.detections(f.balls, noise: 0.002, rng: &rng)
            if f.t > 0.5 { dets.append(Stress.det(Vec2(1.9, 0.05) + Vec2(rng.gauss(), rng.gauss()) * 0.012, .unknown)) }
            let tracks = tracker.update(dets, at: f.t)
            if seg.update(tracks: tracks, cueID: tracks.first { $0.kind == .cue && $0.confirmed }?.id,
                          atRest: tracker.isAtRest, at: f.t, strokeRecent: nil) != nil { recs += 1 }
        }
        return (recs, Stress.collectionSizes(seg))
    }
}

final class JitterGen: @unchecked Sendable {
    private let lock = NSLock()
    private var rng = SplitMix(seed: 99)
    let sigma: Double
    init(sigma: Double) { self.sigma = sigma }
    func next() -> [BallDetection] {
        lock.lock(); defer { lock.unlock() }
        let balls: [(Int, Vec2)] = [(0, Vec2(0.6, 0.5)), (1, Vec2(1.3, 0.4)), (11, Vec2(1.6, 0.7)), (8, Vec2(1.1, 0.8))]
        return balls.map { Stress.det($0.1 + Vec2(rng.gauss(), rng.gauss()) * sigma, Stress.kind(for: $0.0), $0.0) }
    }
}

/// Diagnostics: what the records of one break look like.
struct SegmenterDiagnostics {
    @Test func breakRecordTimeline() {
        var balls: [BallID: Vec2] = [.cue: Stress.spec.headSpot]
        for (i, p) in Stress.rack().enumerated() { balls[BallID(Stress.rackNumbers[i])!] = p }
        let apex = Stress.rack()[0]
        let (r, trace) = TrackerStressTests.run(balls, stroke: Stroke(direction: (apex - Stress.spec.headSpot).normalized, speed: 3.8))
        Stress.metric("diag.break.traceDuration", String(format: "%.2f", trace.duration))
        Stress.metric("diag.break.records", r.records.map { String(format: "[%.2f-%.2f fc=%@]", $0.start, $0.end, $0.firstContact.map(String.init) ?? "nil") })
        Stress.metric("diag.break.zeroLengthRecords", r.records.filter { $0.end == $0.start }.count)
        Stress.metric("diag.break.cuePreID", r.preIDs[.cue] ?? -1)
        Stress.metric("diag.break.cueIDsDuringShot", r.ledger.seen[.cue] ?? [])
    }
}

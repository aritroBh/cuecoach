import Foundation
import Geometry
import Physics
import Rules
import simd
import Testing
@testable import CueCoach

/// Pipeline harness with scripted detections: aim lines vs Physics, legality, cue identity, live line.
struct AimStressTests {
    static let scene = SyntheticTableScene.demo()
    static let solids: Set<BallID> = Set((1...7).compactMap { BallID($0) })

    static func frame(_ i: Int) -> PerceptionFrame {
        PerceptionFrame(image: Stress.blankImage(), camera: scene.camera, timestamp: Double(i) / 30)
    }

    static func dets(_ balls: [(Int, Vec2)]) -> [BallDetection] {
        balls.map { Stress.det($0.1, Stress.kind(for: $0.0), $0.0) }
    }

    static func settle(_ p: PerceptionPipeline, _ d: ScriptedDetector, _ balls: [(Int, Vec2)], frames: Int = 30,
                       start: Int = 0) async -> [PerceptionResult] {
        var out: [PerceptionResult] = []
        for i in start..<(start + frames) {
            d.push(dets(balls))
            if let r = await p.process(frame(i)) { out.append(r) }
        }
        return out
    }

    // MARK: Overlay == Simulator.simulate

    @Test func aimLinesEqualTheSimulatorOutput() async throws {
        var rng = SplitMix(seed: 12)
        var checked = 0, maxObjErr = 0.0, maxCueErr = 0.0, outcomeMismatch = 0, line3Truncated = 0
        var maxLine2Dev = 0.0
        for trial in 0..<12 {
            let d = ScriptedDetector()
            let p = PerceptionPipeline(detector: d)
            await p.setTable(Self.scene.frame)
            var balls: [(Int, Vec2)] = [(0, Vec2(0.4 + rng.uniform() * 0.5, 0.2 + rng.uniform() * 0.6))]
            for n in [1, 3, 9, 12] {
                balls.append((n, Vec2(0.9 + rng.uniform() * 0.9, 0.12 + rng.uniform() * 0.8)))
            }
            let rs = await Self.settle(p, d, balls, frames: 40)
            guard let r = rs.last, let aim = r.aim, aim.outcome != nil else { continue }
            checked += 1
            // Rebuild the stroke the overlay implies and simulate it.
            let ids = BallIdentity.assign(r.confirmed, cueID: r.confirmed.first { r.marks[$0.id] == .cue }?.id)
            var state: [BallID: Vec2] = [:]
            for t in r.confirmed { if let id = ids[t.id] { state[id] = t.position } }
            let objTrack = try #require(r.confirmed.min { $0.position.distance(to: aim.object) < $1.position.distance(to: aim.object) })
            let objID = try #require(ids[objTrack.id])
            let dir = (aim.ghost - aim.cue).normalized
            let speed = PhysicsShotPreview.speeds[aim.power - 1]
            let tr = Simulator().simulate(TableState(spec: Self.scene.frame.spec, balls: state.mapValues { BallState(position: $0) }),
                                          stroke: Stroke(direction: dir, speed: speed, tipOffset: aim.spin.tip))
            let simObj = tr.path(of: objID, sampleDT: 0.02)
            let n = min(simObj.count, aim.objectPath.count)
            for i in 0..<n { maxObjErr = max(maxObjErr, simObj[i].distance(to: aim.objectPath[i])) }
            if simObj.count != aim.objectPath.count { maxObjErr = max(maxObjErr, 1) }
            let simCue = tr.path(of: .cue, sampleDT: 0.02)
            if let last = aim.cuePath.last, let simLast = simCue.last { maxCueErr = max(maxCueErr, last.distance(to: simLast)) }
            var made = false
            for e in tr.events { if case let .pocket(id, pk) = e.event, id == objID, pk == aim.pocket { made = true } }
            if (aim.outcome == .make) != made { outcomeMismatch += 1 }
            // What the overlay actually draws.
            let line2 = OverlayPath.segments(aim.objectPath, max: 16)
            for q in aim.objectPath {
                let dmin = line2.map { seg -> Double in
                    let ab = seg.1 - seg.0, l2 = ab.lengthSquared
                    let t = l2 > 0 ? max(0, min(1, (q - seg.0).dot(ab) / l2)) : 0
                    return (seg.0 + ab * t).distance(to: q)
                }.min() ?? .infinity
                maxLine2Dev = max(maxLine2Dev, dmin)
            }
            let dashes = OverlayPath.dashes(aim.cuePath, dash: 0.04, gap: 0.03, skip: Stress.R, max: 14)
            let pathLen = zip(aim.cuePath, aim.cuePath.dropFirst()).map { $0.distance(to: $1) }.reduce(0, +)
            if let lastDash = dashes.last, let end = aim.cuePath.last, lastDash.1.distance(to: end) > 0.1, pathLen > 1.0 {
                line3Truncated += 1
            }
            _ = trial
        }
        Stress.metric("aimSim.layoutsChecked", checked)
        Stress.metric("aimSim.maxObjectPathErrMm", maxObjErr * 1000)
        Stress.metric("aimSim.maxCueEndErrMm", maxCueErr * 1000)
        Stress.metric("aimSim.outcomeMismatches", outcomeMismatch)
        Stress.metric("aimSim.line2MaxDeviationMm", maxLine2Dev * 1000)
        Stress.metric("aimSim.line3TruncatedLayouts", line3Truncated)
        #expect(checked >= 6)
        #expect(maxObjErr < 0.005)
        #expect(maxCueErr < 0.005)
        #expect(outcomeMismatch == 0)
        #expect(maxLine2Dev < 0.01)
    }

    /// Line 3 is drawn with at most 14 dashes (~1 m): a long simulated cue path is cut off.
    @Test
    func line3CoversTheWholeSimulatedPath() {
        let path = [Vec2(0.5, 0.5), Vec2(1.9, 0.5), Vec2(1.9, 0.9), Vec2(1.0, 0.9)]
        let dashes = OverlayPath.dashes(path, dash: 0.04, gap: 0.03, skip: Stress.R, max: 14)
        let covered = dashes.last.map { d in path.last!.distance(to: d.1) } ?? .infinity
        Stress.metric("line3.dashes", dashes.count)
        Stress.metric("line3.gapToPathEndM", covered)
        #expect(covered < 0.1)
    }

    // MARK: Legality

    @Test func suggestedLineNeverTargetsAnIllegalBall() async throws {
        var rng = SplitMix(seed: 41)
        var aims = 0, illegal = 0
        for _ in 0..<40 {
            let d = ScriptedDetector()
            let p = PerceptionPipeline(detector: d)
            await p.setTable(Self.scene.frame)
            await p.setLegal(Self.solids)
            var balls: [(Int, Vec2)] = [(0, Vec2(0.3 + rng.uniform() * 0.6, 0.15 + rng.uniform() * 0.7))]
            for n in [2, 5, 8, 10, 13, 15] {
                balls.append((n, Vec2(0.4 + rng.uniform() * 1.5, 0.1 + rng.uniform() * 0.82)))
            }
            let rs = await Self.settle(p, d, balls, frames: 25)
            for r in rs {
                guard let aim = r.aim else { continue }
                aims += 1
                let target = balls.min { $0.1.distance(to: aim.object) < $1.1.distance(to: aim.object) }!.0
                if !Self.solids.contains(BallID(target)!) { illegal += 1 }
            }
        }
        Stress.metric("legality.aimFrames", aims)
        Stress.metric("legality.illegalTargets", illegal)
        #expect(aims > 0)
        #expect(illegal == 0)
    }

    /// Dim light: the only legal balls read as "unknown" and so does the 8. The fallback targets unknowns,
    /// which can be the 8 on an open table.
    @Test func unknownFallbackCanTargetTheEight() async throws {
        let d = ScriptedDetector()
        let p = PerceptionPipeline(detector: d)
        await p.setTable(Self.scene.frame)
        let eight = Vec2(1.7, 0.2)
        var out: [PerceptionResult] = []
        for i in 0..<30 {
            d.push([Stress.det(Vec2(1.2, 0.5), .cue, 0), Stress.det(eight, .unknown, nil)])
            if let r = await p.process(Self.frame(i)) { out.append(r) }
        }
        let aimed = out.last?.aim.map { $0.object.distance(to: eight) < 0.01 } ?? false
        Stress.metric("unknownFallback.aimsAtUnidentifiedBall", aimed)
        // An unidentified ball may be the 8: with no ball known to be legal there is no suggestion.
        #expect(out.last?.aim == nil)
    }

    @Test func liveLineTurnsRedOnTheEight() async throws {
        var s = Self.scene
        let W = s.frame.spec.width
        s.balls = [.init(position: Vec2(0.5, W / 2), color: (240, 240, 236)),
                   .init(position: Vec2(1.3, W / 2), color: (18, 18, 20)),
                   .init(position: Vec2(1.1, 0.22), color: (200, 32, 30))]
        let u = Vec2(1, 0)
        s.stick = .init(tip: s.balls[0].position - u * (Stress.R + 0.04), direction: u, length: 1.0)
        let img = try Stress.image(s)
        let p = PerceptionPipeline()
        await p.setTable(s.frame)
        var last: PerceptionResult?
        var redFrames = 0
        for i in 0..<30 {
            last = await p.process(PerceptionFrame(image: img, camera: s.camera, timestamp: Double(i) / 30))
            if let r = last, LiveAimStyle.of(hitTrackID: r.liveAim == nil ? nil : r.liveTargetID, marks: r.marks, merged: false) == .illegal {
                redFrames += 1
            }
        }
        let r = try #require(last)
        let eightID = r.confirmed.min { $0.position.distance(to: s.balls[1].position) < $1.position.distance(to: s.balls[1].position) }?.id
        Stress.metric("liveRed.redFramesOf30", redFrames)
        #expect(r.liveTargetID == eightID)
        #expect(LiveAimStyle.of(hitTrackID: r.liveTargetID, marks: r.marks, merged: false) == .illegal)
    }

    /// Cue ball frozen to the 8 (detections put them 1 mm closer than 2R): aiming straight into it.
    @Test
    func frozenBallIsStillHit() {
        let cue = Vec2(1.0, 0.5)
        for gap in [0.0005, 0.0, -0.001, -0.003] {
            let b = cue + Vec2(2 * Stress.R + gap, 0)
            let tr = LiveAimTrace.trace(cue: cue, direction: Vec2(1, 0), balls: [b, Vec2(1.6, 0.5)], spec: Stress.spec)
            Stress.metric("frozen.gap\(gap * 1000)mm.hitIndex", tr.hitIndex.map(String.init) ?? "nil")
            #expect(tr.hitIndex == 0, "gap \(gap)")
        }
    }

    // MARK: Cue identity

    /// A white glass reflection / chalk smudge is classified as "cue" and its track is older than the cue ball's
    /// (the real cue ball was hidden by the shooter's body for 1 s). The aim must still start at the real cue ball.
    @Test
    func secondWhiteObjectDoesNotStealTheCueBall() async throws {
        let d = ScriptedDetector()
        let p = PerceptionPipeline(detector: d)
        await p.setTable(Self.scene.frame)
        let cue = Vec2(0.5, 0.5), white = Vec2(1.9, 0.08)
        let objs: [BallDetection] = [Stress.det(Vec2(1.2, 0.45), .solid, 3), Stress.det(Vec2(1.5, 0.7), .solid, 1)]
        var last: PerceptionResult?
        for i in 0..<120 {
            var f = objs + [Stress.det(white, .cue, 0)]
            if i < 20 || i >= 60 { f.insert(Stress.det(cue, .cue, 0), at: 0) }   // hidden 20..<60
            d.push(f)
            last = await p.process(Self.frame(i))
        }
        let r = try #require(last)
        let cueMarked = r.confirmed.filter { r.marks[$0.id] == .cue }
        Stress.metric("cueSteal.cueMarkedTracks", cueMarked.count)
        Stress.metric("cueSteal.aimFrom", r.aim.map { "(\(String(format: "%.2f", $0.cue.x)),\(String(format: "%.2f", $0.cue.y)))" } ?? "nil")
        let aim = try #require(r.aim)
        #expect(aim.cue.distance(to: cue) < 0.02)
    }

    // MARK: Settle flicker

    /// From the first at-rest frame, how often does the suggestion change while previews fill in (budget 1/frame)?
    @Test func suggestionFlickerWhilePreviewsFillIn() async {
        var rng = SplitMix(seed: 5)
        var changes = 0, layouts = 0, maxChanges = 0
        for _ in 0..<15 {
            let d = ScriptedDetector()
            let p = PerceptionPipeline(detector: d)
            await p.setTable(Self.scene.frame)
            var balls: [(Int, Vec2)] = [(0, Vec2(0.4 + rng.uniform() * 0.5, 0.2 + rng.uniform() * 0.6))]
            for n in [1, 2, 3, 4] { balls.append((n, Vec2(0.9 + rng.uniform() * 0.9, 0.12 + rng.uniform() * 0.8))) }
            let rs = await Self.settle(p, d, balls, frames: 40)
            var prev: (Vec2, Pocket)?
            var c = 0
            for r in rs { if let a = r.aim { if let pv = prev, pv.0 != a.object || pv.1 != a.pocket { c += 1 }; prev = (a.object, a.pocket) } }
            if prev != nil { layouts += 1; changes += c; maxChanges = max(maxChanges, c) }
        }
        Stress.metric("flicker.layouts", layouts)
        Stress.metric("flicker.targetChangesTotal", changes)
        Stress.metric("flicker.maxChangesInOneLayout", maxChanges)
    }

    // MARK: Hysteresis under tremor

    @Test func convergenceLatchUnderTremor() {
        var rng = SplitMix(seed: 2)
        var latch = ConvergenceLatch()
        var haptics = 0, flips = 0
        var last = false
        for f in 0..<(30 * 60) {
            let raw = max(0, min(1, 0.8 + rng.gauss() * 0.12))   // hovering right at the threshold
            if latch.update(raw, at: Double(f) / 30) { haptics += 1 }
            if latch.merged != last { flips += 1; last = latch.merged }
        }
        Stress.metric("latch.hapticsPerMinute", haptics)
        Stress.metric("latch.styleFlipsPerMinute", flips)
        #expect(haptics <= 30)
    }
}

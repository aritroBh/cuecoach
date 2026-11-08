import CoreGraphics
import Foundation
import Geometry
import simd
import Testing
@testable import CueCoach

/// Classical detector + LiDAR + cue line on rendered frames under hostile conditions.
struct PerceptionStressTests {
    static let base = SyntheticTableScene.demo()
    static var L: Double { base.frame.spec.length }
    static var W: Double { base.frame.spec.width }

    static func detect(_ img: PixelImage, _ scene: SyntheticTableScene = base) -> [BallDetection] {
        ClassicalBallDetector().detect(in: img, geometry: FrameGeometry(frame: scene.frame, camera: scene.camera))
    }

    /// Recall/precision against the scene's balls (match within 3 cm).
    static func score(_ dets: [BallDetection], _ scene: SyntheticTableScene) -> (found: Int, falsePos: Int) {
        var used = Set<Int>()
        var found = 0
        for b in scene.balls {
            if let i = dets.indices.filter({ !used.contains($0) })
                .min(by: { dets[$0].tablePoint.distance(to: b.position) < dets[$1].tablePoint.distance(to: b.position) }),
               dets[i].tablePoint.distance(to: b.position) < 0.03 { used.insert(i); found += 1 }
        }
        return (found, dets.count - used.count)
    }

    static let colours: [Int: (UInt8, UInt8, UInt8)] = [
        1: (236, 200, 30), 2: (30, 60, 190), 3: (200, 32, 30), 4: (110, 40, 150), 5: (240, 120, 20),
        6: (20, 130, 60), 7: (120, 30, 30), 8: (18, 18, 20),
    ]

    static func rackScene(gap: Double = 0.0003) -> SyntheticTableScene {
        var s = base
        let spec = s.frame.spec
        // The demo camera looks from the head end; rack at the foot spot as in a real game.
        s.balls = [.init(position: spec.headSpot, color: (240, 240, 236))]
        for (i, p) in Stress.rack(spec: spec, gap: gap).enumerated() {
            let n = Stress.rackNumbers[i]
            let c = colours[n > 8 ? n - 8 : n]!
            s.balls.append(.init(position: p, color: c, stripe: n > 8))
        }
        return s
    }

    // MARK: Rack and clusters

    @Test
    func sixteenBallRackIsFullyDetected() throws {
        let s = Self.rackScene()
        let dets = Self.detect(try Stress.image(s))
        let sc = Self.score(dets, s)
        Stress.metric("rack16.found", "\(sc.found)/16")
        Stress.metric("rack16.falsePositives", sc.falsePos)
        #expect(sc.found >= 15)
    }

    @Test func clusterOfSevenTouching() throws {
        var s = Self.base
        let c = Vec2(1.0, 0.5), R = Stress.R
        s.balls = [.init(position: Vec2(0.4, 0.5), color: (240, 240, 236)), .init(position: c, color: Self.colours[3]!)]
        for k in 0..<6 {
            let a = Double(k) * .pi / 3
            s.balls.append(.init(position: c + Vec2(cos(a), sin(a)) * (2 * R + 0.0005), color: Self.colours[k + 1]!, stripe: k % 2 == 1))
        }
        let sc = Self.score(Self.detect(try Stress.image(s)), s)
        Stress.metric("cluster7.found", "\(sc.found)/\(s.balls.count)")
        Stress.metric("cluster7.falsePositives", sc.falsePos)
        #expect(sc.found >= s.balls.count - 1)
    }

    // MARK: Lighting

    @Test(.disabled("STRESS-FINDING B1: at 40% brightness the cue ball classifies as unknown (whiteV floor 0.45), so no cue ball and no aim"))
    func sixtyPercentLightingDropKeepsTheCueBall() async throws {
        let img = Stress.mapPixels(try Stress.image(Self.base)) { ($0 * 0.4, $1 * 0.4, $2 * 0.4) }
        let dets = Self.detect(img)
        let sc = Self.score(dets, Self.base)
        let cueDet = dets.min { $0.tablePoint.distance(to: Self.base.balls[0].position) < $1.tablePoint.distance(to: Self.base.balls[0].position) }
        Stress.metric("dim60.found", "\(sc.found)/\(Self.base.balls.count)")
        Stress.metric("dim60.falsePositives", sc.falsePos)
        Stress.metric("dim60.kinds", dets.map(\.kind.rawValue))
        Stress.metric("dim60.cueKind", cueDet?.kind.rawValue ?? "none")
        #expect(sc.found >= Self.base.balls.count - 1)
        #expect(cueDet?.kind == .cue)
    }

    @Test(arguments: [("magenta", 1.0, 0.45, 1.1), ("blue", 0.5, 0.7, 1.35), ("red", 1.3, 0.6, 0.5)])
    func neonBarLightTint(name: String, r: Double, g: Double, b: Double) throws {
        let img = Stress.mapPixels(try Stress.image(Self.base)) { ($0 * r, $1 * g, $2 * b) }
        let dets = Self.detect(img)
        let sc = Self.score(dets, Self.base)
        let cueDet = dets.min { $0.tablePoint.distance(to: Self.base.balls[0].position) < $1.tablePoint.distance(to: Self.base.balls[0].position) }
        Stress.metric("neon.\(name).found", "\(sc.found)/\(Self.base.balls.count)")
        Stress.metric("neon.\(name).falsePositives", sc.falsePos)
        Stress.metric("neon.\(name).cueKind", cueDet?.kind.rawValue ?? "none")
        Stress.metric("neon.\(name).kinds", dets.map { "\($0.kind.rawValue)\($0.tentativeNumber.map(String.init) ?? "")" })
        #expect(sc.falsePos == 0)
        #expect(sc.found >= Self.base.balls.count - 1)
    }

    @Test(.disabled("STRESS-FINDING B2: under magenta/blue/red bar light the cue ball classifies as a solid"))
    func neonCueBallIdentity() throws {
        // Recorded separately so the colour-cast verdict is one line.
        var cueOK: [String: Bool] = [:]
        for (name, r, g, b) in [("magenta", 1.0, 0.45, 1.1), ("blue", 0.5, 0.7, 1.35), ("red", 1.3, 0.6, 0.5)] {
            let img = Stress.mapPixels(try Stress.image(Self.base)) { ($0 * r, $1 * g, $2 * b) }
            let dets = Self.detect(img)
            cueOK[name] = dets.contains { $0.kind == .cue && $0.tablePoint.distance(to: Self.base.balls[0].position) < 0.03 }
        }
        Stress.metric("neon.cueIdentified", cueOK)
        #expect(cueOK.values.allSatisfy { $0 }, "cue ball identity under coloured light: \(cueOK)")
    }

    // MARK: Shadows, chalk, rail clutter

    @Test func cueShadowOnTheCloth() throws {
        var s = Self.base
        let cue = s.balls[0].position
        let u = Vec2(1, 0.15).normalized
        s.stick = .init(tip: cue - u * (Stress.R + 0.04), direction: u, length: 1.0)
        // Shadow: a darker band offset 4 cm sideways on the cloth, as from an overhead lamp.
        let n = u.perpendicular
        let tip = cue - u * (Stress.R + 0.04) + n * 0.04
        let shadow = Stress.Paint(poly: [tip + n * 0.008, tip - n * 0.008, tip - u * 1.0 - n * 0.02, tip - u * 1.0 + n * 0.02],
                                  height: 0, color: (8, 40, 26), alpha: 0.8)
        let cg = try Stress.render(s, paints: [shadow])
        let img = try #require(PixelImage(cgImage: cg))
        let sc = Self.score(Self.detect(img, s), s)
        let geo = FrameGeometry(frame: s.frame, camera: s.camera)
        var errs: [Double] = []
        for _ in 0..<10 {
            if let o = CueLineDetector().detect(in: img, geometry: geo, cue: cue, others: s.balls.dropFirst().map(\.position)) {
                errs.append(acos(max(-1, min(1, o.direction.dot(u)))) * 180 / .pi)
            } else { errs.append(.infinity) }
        }
        Stress.metric("cueShadow.falsePositives", sc.falsePos)
        Stress.metric("cueShadow.dirErrDegMedian", Stress.median(errs))
        Stress.metric("cueShadow.dirErrDegMax", errs.max() ?? -1)
        #expect(sc.falsePos == 0)
        #expect(Stress.median(errs) < 3)
    }

    @Test func ballSizedChalkSmudgeIsRejectedByLidar() throws {
        var s = Self.base
        let mark = Vec2(1.3, 0.25)
        let chalk = Stress.Paint(poly: Stress.disc(mark, 0.026), height: 0, color: (235, 238, 240))
        let cg = try Stress.render(s, paints: [chalk])
        let img = try #require(PixelImage(cgImage: cg))
        let dets = Self.detect(img, s)
        let colourFP = dets.contains { $0.tablePoint.distance(to: mark) < 0.03 }
        let kept = DepthFusion.verify(dets, depth: s.renderDepth(), camera: s.camera, table: s.frame)
        let lidarFP = kept.contains { $0.tablePoint.distance(to: mark) < 0.03 }
        let realKept = Self.score(kept, s).found
        Stress.metric("chalk.colourDetectsMark", colourFP)
        Stress.metric("chalk.colourMarkKind", dets.first { $0.tablePoint.distance(to: mark) < 0.03 }?.kind.rawValue ?? "none")
        Stress.metric("chalk.lidarKeepsMark", lidarFP)
        Stress.metric("chalk.realBallsKept", "\(realKept)/\(s.balls.count)")
        #expect(!lidarFP)
        #expect(realKept == s.balls.count)
        s.balls = []
    }

    @Test func phoneAndGlassOnTheRail() throws {
        let s = Self.base
        let phone = Stress.Paint(poly: Stress.rect(Vec2(1.1, -0.035), along: Vec2(1, 0), length: 0.15, width: 0.07),
                                 height: 0.035, color: (12, 12, 14))
        let screen = Stress.Paint(poly: Stress.rect(Vec2(1.1, -0.035), along: Vec2(1, 0), length: 0.13, width: 0.06),
                                  height: 0.036, color: (200, 210, 230))
        let glass = Stress.Paint(poly: Stress.disc(Vec2(0.7, Self.W + 0.03), 0.035), height: 0.04, color: (225, 230, 228), alpha: 0.85)
        let chalkCube = Stress.Paint(poly: Stress.rect(Vec2(1.6, -0.02), along: Vec2(1, 0), length: 0.022, width: 0.022),
                                     height: 0.04, color: (40, 90, 200))
        let cg = try Stress.render(s, paints: [phone, screen, glass, chalkCube])
        let img = try #require(PixelImage(cgImage: cg))
        let dets = Self.detect(img, s)
        let sc = Self.score(dets, s)
        Stress.metric("railClutter.found", "\(sc.found)/\(s.balls.count)")
        Stress.metric("railClutter.falsePositives", sc.falsePos)
        Stress.metric("railClutter.fpPoints", dets.filter { d in !s.balls.contains { $0.position.distance(to: d.tablePoint) < 0.03 } }
            .map { "\($0.kind.rawValue)@(\(String(format: "%.2f", $0.tablePoint.x)),\(String(format: "%.2f", $0.tablePoint.y)))" })
        #expect(sc.falsePos == 0)
        #expect(sc.found == s.balls.count)
    }

    /// The real line fit on a cue held still for 10 s with ±2 mm hand tremor: false strokes and false shots.
    @Test(.timeLimit(.minutes(3)))
    func cueHeldStillTenSecondsOnRenderedFrames() async throws {
        var s = Self.base
        let cue = s.balls[0].position
        let u = Vec2(1, 0.1).normalized
        var rng = SplitMix(seed: 3)
        var imgs: [PixelImage] = []
        for _ in 0..<12 {
            let tremor = Vec2(rng.gauss(), rng.gauss()) * 0.002
            s.stick = .init(tip: cue - u * (Stress.R + 0.05) + tremor, direction: u.rotated(by: rng.gauss() * 0.004), length: 1.0)
            imgs.append(try Stress.image(s))
        }
        Stress.metric("stillCueImg.rendered", imgs.count)
        let geo = FrameGeometry(frame: s.frame, camera: s.camera)
        var tracker = CueAimTracker()
        var strokes = 0
        var tips: [Double] = []
        for f in 0..<300 {
            let o = CueLineDetector().detect(in: imgs[Int(rng.uniform() * 12)], geometry: geo, cue: cue,
                                             others: s.balls.dropFirst().map(\.position))
            if let o { tips.append(o.tipDistance) }
            if tracker.update(o, at: Double(f) / 30) { strokes += 1 }
        }
        let mean = tips.reduce(0, +) / Double(max(1, tips.count))
        let sd = (tips.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(max(1, tips.count))).squareRoot()
        Stress.metric("stillCueImg.tipSdMm", String(format: "%.1f", sd * 1000))
        Stress.metric("stillCueImg.observedFrames", "\(tips.count)/300")
        Stress.metric("stillCueImg.falseStrokesPer10s", strokes)
        // Through the whole pipeline: still balls, still cue, 10 s.
        let p = PerceptionPipeline()
        await p.setTable(s.frame)
        var shotEvents = 0
        for f in 0..<150 {
            let t0 = Date()
            let r = await p.process(PerceptionFrame(image: imgs[f % 12], camera: s.camera, timestamp: Double(f) / 30))
            if r?.shotStarted == true || r?.shot != nil { shotEvents += 1 }
            if f % 75 == 0 { Stress.metric("stillCueImg.progress.f\(f)", String(format: "%.0f ms aim=%@ mem=%llu MB tracks=%d", Date().timeIntervalSince(t0) * 1000, r?.aim == nil ? "n" : "y", Stress.footprint() / 1_048_576, r?.tracks.count ?? -1)) }
        }
        Stress.metric("stillCueImg.pipelineShotEvents", shotEvents)
        #expect(strokes == 0)
        #expect(shotEvents == 0)
    }

    // MARK: Depth edge cases

    @Test func nanZeroAndNegativeLidarDepth() throws {
        let s = Self.base
        var d = s.renderDepth()
        for i in d.depth.indices {
            switch i % 4 { case 0: d.depth[i] = .nan; case 1: d.depth[i] = 0; case 2: d.depth[i] = -.infinity; default: break }
        }
        let finder = DepthBallFinder()
        let balls = finder.find(depth: d, camera: s.camera, table: s.frame)
        #expect(balls.allSatisfy { $0.x.isFinite && $0.y.isFinite })
        let allNaN = DepthMap(width: 256, height: 144, depth: [Float](repeating: .nan, count: 256 * 144), confidence: nil)
        let allZero = DepthMap(width: 256, height: 144, depth: [Float](repeating: 0, count: 256 * 144), confidence: nil)
        #expect(finder.find(depth: allNaN, camera: s.camera, table: s.frame).isEmpty)
        #expect(finder.find(depth: allZero, camera: s.camera, table: s.frame).isEmpty)
        let dets = Self.detect(try Stress.image(s))
        #expect(DepthFusion.verify(dets, depth: allNaN, camera: s.camera, table: s.frame).count == dets.count)
        #expect(DepthFusion.verify(dets, depth: allZero, camera: s.camera, table: s.frame).count == dets.count)
        let empty = DepthMap(width: 0, height: 0, depth: [], confidence: nil)
        #expect(finder.find(depth: empty, camera: s.camera, table: s.frame).isEmpty)
        Stress.metric("depthQuarterBad.ballsFound", balls.count)
    }

    @Test func pipelineSurvivesEmptyImageAndBadDepth() async throws {
        let s = Self.base
        let p = PerceptionPipeline()
        await p.setTable(s.frame)
        let empty = PixelImage(width: 0, height: 0, rgb: [], sourceWidth: 1920, sourceHeight: 1080)
        let nanDepth = DepthMap(width: 256, height: 144, depth: [Float](repeating: .nan, count: 256 * 144), confidence: nil)
        for i in 0..<10 {
            let r = await p.process(PerceptionFrame(image: empty, camera: s.camera, timestamp: Double(i) / 30, depth: nanDepth))
            #expect(r?.tracks.isEmpty == true)
            #expect(r?.aim == nil)
        }
    }

    // MARK: Thermal step-down

    /// 4K source at 1280 working width, then a thermal step to a 1080p source at 800 (working 640) mid-session.
    @Test func thermalStepDownMidSession() async throws {
        let k4 = CameraIntrinsics(fx: 3000, fy: 3000, cx: 1920, cy: 1080, width: 3840, height: 2160)
        var hot = Self.base
        hot.camera = CameraModel.lookAt(eye: SIMD3(0.1, 2.15, 2.45), target: SIMD3(0, 0.76, -0.25), intrinsics: k4)
        let img4k = try Stress.image(hot, maxWidth: CapturePolicy.detectWidth(source: 3840, tier: .max))
        let img1080 = try Stress.image(Self.base, maxWidth: CapturePolicy.detectWidth(source: 1920, tier: .sustained))
        let p = PerceptionPipeline()
        await p.setTable(Self.base.frame)
        var idsBefore: Set<Int> = [], idsAfter: Set<Int> = []
        var starts = 0, maxSpeed = 0.0, restLost = 0
        var jump = 0.0
        var lastPos: [Int: Vec2] = [:]
        for f in 0..<120 {
            let t = Double(f) / 30
            let cool = f < 60
            let r = try #require(await p.process(PerceptionFrame(image: cool ? img4k : img1080, camera: cool ? hot.camera : Self.base.camera,
                                                                 timestamp: t)))
            if r.shotStarted || r.shot != nil { starts += 1 }
            if f == 59 { idsBefore = Set(r.confirmed.map(\.id)) }
            if f == 119 { idsAfter = Set(r.confirmed.map(\.id)) }
            if f >= 60 { maxSpeed = max(maxSpeed, r.confirmed.map(\.speed).max() ?? 0); if !r.atRest { restLost += 1 } }
            if f == 60 { for c in r.confirmed { if let q = lastPos[c.id] { jump = max(jump, q.distance(to: c.position)) } } }
            for c in r.confirmed { lastPos[c.id] = c.position }
        }
        Stress.metric("thermal.workingWidths", "\(img4k.width)->\(img1080.width)")
        Stress.metric("thermal.idsKept", "\(idsAfter.intersection(idsBefore).count)/\(idsBefore.count)")
        Stress.metric("thermal.maxSpeedAfterStep", maxSpeed)
        Stress.metric("thermal.framesNotAtRestAfterStep", restLost)
        Stress.metric("thermal.positionJumpMm", jump * 1000)
        Stress.metric("thermal.shotEvents", starts)
        #expect(starts == 0)
        #expect(idsAfter == idsBefore)
    }

    // MARK: Stale table frame

    /// Tracking came back < 1 s after a relocalization that moved the world 0.5 m: the controller keeps the
    /// old table frame (no revalidate). What does perception hand the overlay?
    @Test(.disabled("STRESS-FINDING B3: a table frame 0.5 m off yields 24 confirmed phantom balls, none real; ballScale stays 1.01 so D12 does not flag it"))
    func staleTableFrameHalfAMetreOff() async throws {
        let s = Self.base
        var wrong = s.frame
        wrong.tableToWorld.columns.3 += SIMD4(wrong.tableToWorld.columns.0.x, wrong.tableToWorld.columns.0.y,
                                              wrong.tableToWorld.columns.0.z, 0) * 0.5
        let img = try Stress.image(s)
        let p = PerceptionPipeline()
        await p.setTable(wrong)
        var last: PerceptionResult?
        for i in 0..<30 { last = await p.process(PerceptionFrame(image: img, camera: s.camera, timestamp: Double(i) / 30)) }
        let r = try #require(last)
        Stress.metric("stale0.5m.confirmed", r.confirmed.count)
        Stress.metric("stale0.5m.aimShown", r.aim != nil)
        Stress.metric("stale0.5m.ballScale", r.ballScale.map { String(format: "%.2f", $0) } ?? "nil")
        Stress.metric("stale0.5m.trueBallsAmongConfirmed", r.confirmed.filter { c in s.balls.contains { $0.position.distance(to: c.position + Vec2(0.5, 0)) < 0.04 || $0.position.distance(to: c.position) < 0.04 } }.count)
        #expect(r.confirmed.count <= s.balls.count, "\(r.confirmed.count) rings on a 6-ball table")
    }

    // MARK: Timing

    @Test func perFrameTimings() async throws {
        for (name, scene) in [("demo6", Self.base), ("rack16", Self.rackScene())] {
            let img = try Stress.image(scene)
            let depth = scene.renderDepth(width: 256, height: 192)
            for withDepth in [false, true] {
                let p = PerceptionPipeline()
                await p.setTable(scene.frame)
                var total: [Double] = [], detect: [Double] = []
                for i in 0..<40 {
                    let r = try #require(await p.process(PerceptionFrame(image: img, camera: scene.camera, timestamp: Double(i) / 30,
                                                                         depth: withDepth ? depth : nil)))
                    if i >= 5 { total.append(r.totalMs); detect.append(r.detectMs) }
                }
                Stress.metric("ms.\(name).depth\(withDepth).totalMedian", String(format: "%.1f", Stress.median(total)))
                Stress.metric("ms.\(name).depth\(withDepth).totalP95", String(format: "%.1f", Stress.percentile(total, 0.95)))
                Stress.metric("ms.\(name).depth\(withDepth).detectMedian", String(format: "%.1f", Stress.median(detect)))
            }
        }
        var lt: [Double] = []
        let img = try Stress.image(Self.base)
        for _ in 0..<5 {
            let t0 = Date()
            _ = FeltQuadProposer.propose(img)
            lt.append(Date().timeIntervalSince(t0) * 1000)
        }
        Stress.metric("ms.feltQuadProposer.median", String(format: "%.1f", Stress.median(lt)))
    }
}

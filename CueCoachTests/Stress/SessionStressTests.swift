import Foundation
import Geometry
import simd
import Testing
@testable import CueCoach

// MARK: Table locator

struct LocatorStressTests {
    static let scene = SyntheticTableScene.demo()
    static let bg: (UInt8, UInt8, UInt8) = (44, 40, 38)

    static func planes() -> [LocatorPlane] {
        let s = scene
        return [LocatorPlane(center: SIMD3(0, 0, 0), extent: SIMD2(6, 6), isTable: false),
                LocatorPlane(center: s.frame.world(Vec2(s.frame.spec.length / 2, s.frame.spec.width / 2)),
                             extent: SIMD2(1.0, 0.6), isTable: true)]
    }

    /// Runs the locator for 3 s of samples; returns (locked, worst corner error vs truth in metres).
    static func lockOn(_ img: PixelImage, planes: [LocatorPlane] = planes()) async -> (Bool, Double) {
        let loc = FeltQuadLocator()
        var last: TableEstimate?
        for i in 0..<14 { last = await loc.ingest(LocatorFrame(image: img, camera: scene.camera, planes: planes, timestamp: Double(i) * 0.25)) }
        guard let e = last else { return (false, .infinity) }
        let truth = scene.frame.corners.map { scene.frame.world($0) }
        let err = e.corners.map { c in truth.map { simd_distance($0, c) }.min()! }.max() ?? .infinity
        return (e.locked, err)
    }

    static func composite(_ a: PixelImage, under b: PixelImage) -> PixelImage {
        var rgb = a.rgb
        for i in 0..<(a.width * a.height) where rgb[i * 3] == bg.0 && rgb[i * 3 + 1] == bg.1 && rgb[i * 3 + 2] == bg.2 {
            rgb[i * 3] = b.rgb[i * 3]; rgb[i * 3 + 1] = b.rgb[i * 3 + 1]; rgb[i * 3 + 2] = b.rgb[i * 3 + 2]
        }
        return PixelImage(width: a.width, height: a.height, rgb: rgb, scale: a.scale, sourceWidth: a.sourceWidth, sourceHeight: a.sourceHeight)
    }

    @Test func secondPoolTableInView() async throws {
        let a = try Stress.image(Self.scene)
        var far = Self.scene
        // Another table 1.2 m behind the foot rail and offset sideways (a bar with two tables).
        far.frame.tableToWorld.columns.3 += SIMD4(0.9, 0, -3.3, 0)
        let b = try Stress.image(far)
        let (locked, err) = await Self.lockOn(Self.composite(a, under: b))
        Stress.metric("locator.secondTable.locked", locked)
        Stress.metric("locator.secondTable.worstCornerErrM", String(format: "%.3f", err))
        #expect(!locked || err < 0.05, "locked onto a wrong quad (err \(err) m)")
    }

    @Test func secondTableTouchingInImage() async throws {
        let a = try Stress.image(Self.scene)
        var far = Self.scene
        far.frame.tableToWorld.columns.3 += SIMD4(0, 0, -2.4, 0)   // directly behind: felt regions touch in the image
        let b = try Stress.image(far)
        let (locked, err) = await Self.lockOn(Self.composite(a, under: b))
        Stress.metric("locator.touchingTable.locked", locked)
        Stress.metric("locator.touchingTable.worstCornerErrM", String(format: "%.3f", err))
        #expect(!locked || err < 0.05, "locked onto a wrong quad (err \(err) m)")
    }

    @Test func greenCarpetFloor() async throws {
        let a = Stress.mapPixels(try Stress.image(Self.scene)) { r, g, b in
            (r == 44 && g == 40 && b == 38) ? (28, 98, 62) : (r, g, b)
        }
        let (locked, err) = await Self.lockOn(a)
        Stress.metric("locator.greenFloor.locked", locked)
        Stress.metric("locator.greenFloor.worstCornerErrM", String(format: "%.3f", err))
        #expect(!locked || err < 0.05)
    }

    /// ARKit classifies a 0.6 m side/coffee table behind the pool table as `.table`, the pool cloth is unclassified.
    /// The centre ray meets the pool cloth first; the coffee table must not win.
    @Test
    func classifiedCoffeeTableBehindDoesNotWin() throws {
        let s = Self.scene
        let floor = LocatorPlane(center: SIMD3(0, 0, 0), extent: SIMD2(6, 6), isTable: false)
        let pool = LocatorPlane(center: s.frame.world(Vec2(s.frame.spec.length / 2, s.frame.spec.width / 2)),
                                extent: SIMD2(0.9, 0.6), isTable: false)
        let coffee = LocatorPlane(center: SIMD3(0, 0.6, -0.95), extent: SIMD2(0.8, 0.6), isTable: true)
        let centre = try #require(s.camera.project(s.frame.world(Vec2(s.frame.spec.length / 2, s.frame.spec.width / 2))))
        let p = try #require(LocatorMath.plane(for: centre, camera: s.camera, planes: [floor, coffee, pool]))
        Stress.metric("locator.coffeeTable.pickedY", p.point.y)
        #expect(abs(p.point.y - 0.76) < 0.01)
    }

    @Test func onlyACoffeeTableKnown() {
        let s = Self.scene
        let floor = LocatorPlane(center: SIMD3(0, 0, 0), extent: SIMD2(6, 6), isTable: false)
        let coffee = LocatorPlane(center: SIMD3(0, 0.45, -0.3), extent: SIMD2(1.0, 0.6), isTable: true)
        let p = LocatorMath.plane(for: Vec2(960, 560), camera: s.camera, planes: [floor, coffee])
        #expect(p == nil)
    }
}

// MARK: Long session

extension PerceptionPipeline {
    /// Test-only: element counts of the actor's collections (and its components').
    func stressSizes() -> [String: Int] {
        var out: [String: Int] = [:]
        for c in Mirror(reflecting: self).children {
            guard let l = c.label else { continue }
            for (k, v) in Stress.collectionSizes(c.value) { out["\(l).\(k)"] = v }
            let m = Mirror(reflecting: c.value)
            if m.displayStyle == .optional, let inner = m.children.first {
                for (k, v) in Stress.collectionSizes(inner.value) { out["\(l).\(k)"] = v }
            }
        }
        return out
    }
}

/// Random-but-plausible frame generator: rest layouts, chaos, empty frames, flickering false positives.
final class SessionGenerator: @unchecked Sendable {
    private let lock = NSLock()
    private var rng = SplitMix(seed: 2026)
    private var frame = 0
    private var mode = 0
    private var layout: [(Int, Vec2)] = []
    func next() -> [BallDetection] {
        lock.lock(); defer { lock.unlock() }
        if frame % 90 == 0 {
            mode = Int(rng.uniform() * 4)
            layout = [(0, Vec2(0.2 + rng.uniform() * 1.6, 0.1 + rng.uniform() * 0.8))]
            for _ in 0..<(1 + Int(rng.uniform() * 15)) {
                let n = 1 + Int(rng.uniform() * 15)
                layout.append((n, Vec2(0.1 + rng.uniform() * 1.8, 0.08 + rng.uniform() * 0.85)))
            }
        }
        frame += 1
        switch mode {
        case 0, 1:   // at rest with jitter
            return layout.map { Stress.det($0.1 + Vec2(rng.gauss(), rng.gauss()) * 0.002, Stress.kind(for: $0.0), $0.0) }
        case 2:      // chaos: random detections anywhere
            return (0..<Int(rng.uniform() * 25)).map { _ in
                Stress.det(Vec2(rng.uniform() * 2.03, rng.uniform() * 1.02), BallKind.allCases[Int(rng.uniform() * 5)],
                           Int(rng.uniform() * 16))
            }
        default:     // empty
            return []
        }
    }
}

struct SessionStressTests {
    /// One hour at 30 Hz of random frames through the pipeline's pure-logic chain (tracker → marks → cue tracker →
    /// segmenter → latches → preview cache keys), wired exactly like PerceptionPipeline.process, minus images/physics.
    @Test(.timeLimit(.minutes(20)))
    func oneHourSessionStaysBounded() {
        let gen = SessionGenerator()
        var tracker = KalmanBallTracker()
        var seg = ShotSegmenter(spec: Stress.spec)
        var cueT = CueAimTracker()
        var cache = PreviewCache()
        var latch = ConvergenceLatch(), entry = EntryLatch()
        var order = FrameOrdering()
        var rng = SplitMix(seed: 1)
        var peak: [String: Int] = [:]
        var maxTracks = 0, records = 0, zeroLength = 0
        var mem: [UInt64] = []
        let frames = 30 * 3600
        let t0 = Date()
        for i in 0..<frames {
            let t = Double(i) / 30
            let tracks = tracker.update(gen.next(), at: t)
            let confirmed = tracks.filter(\.confirmed)
            let cue = confirmed.first { $0.kind == .cue }
            let obs: CueObservation? = rng.uniform() < 0.3
                ? CueObservation(direction: Vec2(1, 0).rotated(by: rng.gauss()), tipDistance: 0.05 + rng.uniform() * 0.2, confidence: rng.uniform())
                : nil
            _ = cueT.update(obs, at: t)
            let gate: Bool? = cueT.cueVisible(at: t) ? cueT.strokeRecent(at: t) : nil
            if let r = seg.update(tracks: tracks, cueID: cue?.id, atRest: tracker.isAtRest, at: t, strokeRecent: gate) {
                records += 1; if r.end == r.start { zeroLength += 1 }
            }
            if tracker.isAtRest, let c = cue {
                let ids = BallIdentity.assign(confirmed, cueID: c.id)
                var balls: [BallID: Vec2] = [:]
                for tr in confirmed { if let id = ids[tr.id] { balls[id] = tr.position } }
                let k = PreviewCache.key(cue: c.position, object: BallID(1)!, pocket: .footLeft, balls: balls)
                if cache.get(k) == nil { cache.put(k, nil) }
            }
            _ = order.accept(seq: i, epoch: i / 9000, currentEpoch: i / 9000)
            _ = latch.update(rng.uniform(), at: t)
            _ = entry.update(rng.uniform() < 0.5, at: t)
            maxTracks = max(maxTracks, tracks.count)
            if i % 900 == 0 {
                for (k, v) in Stress.collectionSizes(seg) { peak["segmenter.\(k)"] = max(peak["segmenter.\(k)"] ?? 0, v) }
                for (k, v) in Stress.collectionSizes(tracker) { peak["tracker.\(k)"] = max(peak["tracker.\(k)"] ?? 0, v) }
                for (k, v) in Stress.collectionSizes(cache) { peak["cache.\(k)"] = max(peak["cache.\(k)"] ?? 0, v) }
            }
            if i % 18000 == 0 { mem.append(Stress.footprint()) }
        }
        mem.append(Stress.footprint())
        let wall = Date().timeIntervalSince(t0)
        let growth = Double(Int64(mem.last!) - Int64(mem[min(1, mem.count - 1)])) / 1_048_576
        Stress.metric("soak1h.frames", frames)
        Stress.metric("soak1h.wallSeconds", String(format: "%.1f", wall))
        Stress.metric("soak1h.maxTracks", maxTracks)
        Stress.metric("soak1h.records", records)
        Stress.metric("soak1h.zeroLengthRecords", zeroLength)
        Stress.metric("soak1h.peakCollectionSizes", peak.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" })
        Stress.metric("soak1h.footprintMB", mem.map { $0 / 1_048_576 })
        Stress.metric("soak1h.memGrowthMBAfterWarmup", String(format: "%.1f", growth))
        #expect(maxTracks <= 24 * 4 + 16)   // ≤ 24 detections/frame; unconfirmed tracks die after 3 misses
        #expect((peak["cache.store"] ?? 0) <= 32)
        for (k, v) in peak { #expect(v < 500, "\(k) grew to \(v)") }
        #expect(growth < 20)
    }

    /// 5 minutes at 30 Hz through the real PerceptionPipeline actor (scripted detections, physics previews on).
    @Test(.timeLimit(.minutes(20)))
    func pipelineFiveMinuteSoak() async throws {
        let gen = SessionGenerator()
        let d = ScriptedDetector()
        d.setGenerator { gen.next() }
        let p = PerceptionPipeline(detector: d)
        let scene = SyntheticTableScene.demo()
        await p.setTable(scene.frame)
        let img = Stress.blankImage()
        var peak: [String: Int] = [:]
        var mem: [UInt64] = []
        var ms: [Double] = []
        var maxTracks = 0, aims = 0
        let frames = 30 * 300
        for i in 0..<frames {
            guard let r = await p.process(PerceptionFrame(image: img, camera: scene.camera, timestamp: Double(i) / 30)) else { continue }
            ms.append(r.totalMs)
            maxTracks = max(maxTracks, r.tracks.count)
            if r.aim != nil { aims += 1 }
            if i % 300 == 0 { for (k, v) in await p.stressSizes() { peak[k] = max(peak[k] ?? 0, v) } }
            if i % 1800 == 0 { mem.append(Stress.footprint()) }
        }
        mem.append(Stress.footprint())
        Stress.metric("soakPipe.frames", frames)
        Stress.metric("soakPipe.totalMsMedian", String(format: "%.2f", Stress.median(ms)))
        Stress.metric("soakPipe.totalMsP99", String(format: "%.2f", Stress.percentile(ms, 0.99)))
        Stress.metric("soakPipe.maxTracks", maxTracks)
        Stress.metric("soakPipe.aimFrames", aims)
        Stress.metric("soakPipe.peakCollectionSizes", peak.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" })
        Stress.metric("soakPipe.footprintMB", mem.map { $0 / 1_048_576 })
        #expect(!peak.isEmpty, "Mirror could not see the actor's stored properties")
        #expect((peak["previewCache.store"] ?? 0) <= 32)
        #expect(maxTracks <= 24 * 4 + 16)   // ≤ 24 detections/frame; unconfirmed tracks die after 3 misses
    }

    /// Segmenter internals over a long shot that never ends (balls keep moving): bounded?
    @Test(.disabled("STRESS-FINDING E1: while a shot stays open, ShotSegmenter lastSeen/lastVel/moved/vanishedAt and record.rails grow without bound"))
    func neverEndingShotKeepsSegmenterBounded() {
        var rng = SplitMix(seed: 6)
        var tracker = KalmanBallTracker()
        var seg = ShotSegmenter(spec: Stress.spec)
        let cue0 = Vec2(0.5, 0.5)
        for i in 0..<30 { let tr = tracker.update([Stress.det(cue0, .cue, 0)], at: -1 + Double(i) / 30)
            _ = seg.update(tracks: tr, cueID: tr.first?.id, atRest: tracker.isAtRest, at: -1 + Double(i) / 30, strokeRecent: nil) }
        var peak: [String: Int] = [:]
        for f in 0..<(30 * 600) {
            let t = Double(f) / 30
            // The cue ball rolls around; a stream of short-lived false positives comes and goes.
            let cue = Vec2(1.0 + 0.8 * cos(t), 0.5 + 0.4 * sin(t))
            var dets = [Stress.det(cue, .cue, 0)]
            for _ in 0..<3 { dets.append(Stress.det(Vec2(rng.uniform() * 2, rng.uniform()), .unknown)) }
            let tr = tracker.update(dets, at: t)
            _ = seg.update(tracks: tr, cueID: tr.first { $0.kind == .cue && $0.confirmed }?.id, atRest: tracker.isAtRest, at: t, strokeRecent: nil)
            if f % 1800 == 0 { for (k, v) in Stress.collectionSizes(seg) { peak[k] = max(peak[k] ?? 0, v) } }
        }
        for (k, v) in Stress.collectionSizes(seg) { peak[k] = max(peak[k] ?? 0, v) }
        Stress.metric("openShot10min.segmenterSizes", peak.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" })
        for (k, v) in peak { #expect(v < 500, "\(k) = \(v)") }
    }
}

// MARK: No text / audio while aiming

struct NoTextNoAudioTests {
    static var repo: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    static func sources(_ dirs: [String]) -> [(String, String)] {
        dirs.flatMap { dir -> [(String, String)] in
            let url = repo.appendingPathComponent(dir)
            let files = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
            return files.filter { $0.hasSuffix(".swift") }.compactMap { f in
                (try? String(contentsOf: url.appendingPathComponent(f), encoding: .utf8)).map { ("\(dir)/\(f)", $0) }
            }
        }
    }

    @Test func aimingPathHasNoAudioAPIs() throws {
        let files = Self.sources(["CueCoach/Live", "CueCoach/Perception", "CueCoach/Calibration", "CueCoach/Capture"])
        try #require(!files.isEmpty, "could not read sources from \(Self.repo.path)")
        let banned = ["AVSpeechSynthesizer", "AVAudioPlayer", "AVAudioEngine", "AudioServicesPlay", "SystemSoundID",
                      "AVPlayer", "UIAccessibility.post", "AccessibilityNotification.Announcement", "NSSound", "playSound"]
        var hits: [String] = []
        for (name, text) in files { for b in banned where text.contains(b) { hits.append("\(name): \(b)") } }
        Stress.metric("noAudio.filesScanned", files.count)
        #expect(hits.isEmpty, "\(hits)")
    }

    /// The only `Text(` on the live screen is the dev-only DebugHUD; nothing in the AR overlay or perception.
    @Test func aimingPathHasNoTextOutsideTheDevHUD() throws {
        let files = Self.sources(["CueCoach/Live", "CueCoach/Perception", "CueCoach/Calibration"])
        try #require(!files.isEmpty)
        var hits: [String] = []
        for (name, text) in files {
            var inHUD = false, depth = 0
            for (n, line) in text.components(separatedBy: "\n").enumerated() {
                if line.contains("struct DebugHUD") { inHUD = true; depth = 0 }
                if inHUD {
                    depth += line.filter { $0 == "{" }.count - line.filter { $0 == "}" }.count
                    if depth <= 0 && line.contains("}") { inHUD = false }
                    continue
                }
                let code = line.components(separatedBy: "//").first ?? ""
                for token in ["Text(", "Label(", ".navigationTitle(", "TextField(", ".alert(", "UILabel", "SCNText", "MeshResource.generateText"]
                where code.contains(token) { hits.append("\(name):\(n + 1) \(token)") }
            }
        }
        Stress.metric("noText.hits", hits)
        #expect(hits.isEmpty, "\(hits)")
    }

    /// Shot events are signalled by haptics only; the HUD is behind a 3-finger long press dev toggle.
    @Test func hudIsDevToggleOnly() throws {
        let files = Self.sources(["CueCoach/Live"])
        let screen = try #require(files.first { $0.0.hasSuffix("LiveScreen.swift") }?.1)
        let uses = screen.components(separatedBy: "DebugHUD(").count - 1
        Stress.metric("noText.debugHUDUses", uses)
        #expect(screen.contains("dev.hud"))
    }
}

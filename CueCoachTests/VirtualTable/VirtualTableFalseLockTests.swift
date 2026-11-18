import Foundation
import Geometry
import simd
import Synchronization
import Testing
@testable import CueCoach

/// Known false-lock sessions from the VirtualTable matrix, replayed one by one (fast regression guards).
struct VirtualTableFalseLockTests {
    static func condition(_ name: String) throws -> VTCondition {
        try #require(VTCondition.matrix.first { $0.name == name })
    }

    /// r5 matrix: under the cue shadow the shipped locator fused a 9 ft table as a confident 8 ft (22 cm off).
    /// Ambiguous size evidence must make it wait, never lock the wrong size.
    @Test func cueShadowSeed12DoesNotLockTheWrongSize() async throws {
        let s = VTSetup.make(try Self.condition("light-cueShadow"), seed: 12)
        var cache: [Int: VTFrame] = [:]
        var thumb: VTFrame?
        let (r, corners) = await VTHarness.run(s, kind: .app, cache: &cache, thumb: &thumb)
        print("[virtual-qa] cueShadow seed 12: locked \(r.locked) err \(r.cornerErr.map { $0 * 100 } ?? -1) cm size ok \(String(describing: r.sizeOK)) reason \(r.reason ?? "-")")
        #expect(!r.falseLock, "false lock: corner error \((r.cornerErr ?? 0) * 100) cm")
        if r.locked, corners != nil { #expect((r.cornerErr ?? 1) <= 0.05) }
    }
}

extension VirtualTableFalseLockTests {
    /// r3 development matrix: a 1.4 × 0.7 m 2:1 patch in the bar scene locked 1.8 m away once a three-rail
    /// refit was allowed. Too small for any table, and three-rail fits must land on a preset.
    /// Seed 5 (size-lock work): 7 ft corner guesses centred a 9 ft pose 28 cm off once size came only from measured frames.
    @Test(arguments: [UInt64(12), 19, 5])
    func barComboSmallPatchIsNoTable(seed: UInt64) async throws {
        let s = VTSetup.make(try Self.condition("bar-rive-combo"), seed: seed)
        var cache: [Int: VTFrame] = [:]
        var thumb: VTFrame?
        let (r, _) = await VTHarness.run(s, kind: .app, cache: &cache, thumb: &thumb)
        #expect(!r.falseLock, "seed \(seed): false lock, corner error \((r.cornerErr ?? 0) * 100) cm")
        if r.locked { #expect(r.accurate && r.sizeOK == true, "seed \(seed): locked \((r.cornerErr ?? 0) * 100) cm off") }
    }
}

extension VirtualTableFalseLockTests {
    /// r3 development matrix: a three-rail fit sized a 7 ft table from a width measured 13 % long along the view
    /// rays and fused it as 8 ft (34 cm off).
    @Test func lampSeed6DoesNotSizeFromTheIllConditionedAxis() async throws {
        let s = VTSetup.make(try Self.condition("light-lamp"), seed: 6)
        var cache: [Int: VTFrame] = [:]
        var thumb: VTFrame?
        let (r, _) = await VTHarness.run(s, kind: .app, cache: &cache, thumb: &thumb)
        #expect(!r.falseLock, "false lock, corner error \((r.cornerErr ?? 0) * 100) cm")
        if r.locked { #expect(r.accurate && r.sizeOK == true, "locked \((r.cornerErr ?? 0) * 100) cm off") }
    }
}

/// Per-frame Auto dump for one session (opt-in: VQA_TRACE=cond:seed).
struct VirtualTableTrace {
    @Test func trace() async throws {
        guard let spec = ProcessInfo.processInfo.environment["VQA_TRACE"] else { return }
        let outDir = ProcessInfo.processInfo.environment["VQA_OUT"]
        let box = Mutex<(AutoMask, AutoMask)?>(nil)
        ClassicalAutoTableLocator.debugMaskSink.withLock { $0 = { r, c, m in
            box.withLock { $0 = (r, c) }
            print("[trace] model m1 \(m.m1) m2 \(m.m2) s1 \(m.s1) s2 \(m.s2) mI \(m.mI) neutral \(m.neutral)")
        } }
        defer { ClassicalAutoTableLocator.debugMaskSink.withLock { $0 = nil } }
        let p = spec.split(separator: ":").map(String.init)
        let s = VTSetup.make(try VirtualTableFalseLockTests.condition(p[0]), seed: UInt64(p[1])!)
        // 1. The shipped path (the harness prints a [trace] line per frame for this cond:seed).
        var cache: [Int: VTFrame] = [:]
        var thumb: VTFrame?
        let (r, _) = await VTHarness.run(s, kind: .app, cache: &cache, thumb: &thumb)
        print("[trace] app result: locked \(r.locked) accurate \(r.accurate) err \(r.cornerErr.map { $0 * 100 } ?? -1) cm ttl \(r.ttlStart ?? -1)")
        if ProcessInfo.processInfo.environment["VQA_TRACE_KP"] == "1", let kp = try? CoreMLTableKeypointProvider() {
            // What the keypoint model sees, every second, against the true pocket pixels.
            kp.minInterval = 0; kp.minDetectionConfidence = Double(ProcessInfo.processInfo.environment["VQA_KP_CONF"] ?? "") ?? 0.35
            var pl = VTPlaneSim(truths: s.planeTruths, seed: s.seed ^ 0x51, trackingReady: s.trackingReady)
            var jt = VTRandom(seed: s.seed ^ 0x77)
            var t = s.trackingReady, i = 0
            while t < 10 {
                if t - pl.lastUpdate >= 0.1 { pl.update(t: t, renderer: VTRenderer(scene: s.scene.at(time: t), camera: s.camera(t))) }
                if i % 15 == 0 {
                    let f = VTHarness.render(s, t: t, index: i, planes: pl.planes(t: t, jitter: &jt))
                    let k = f.camera.intrinsics
                    let pts = kp.keypoints(in: AutoRGBImage(width: f.pixel.width, height: f.pixel.height, rgb: f.pixel.rgb),
                                           intrinsics: AutoIntrinsics(fx: k.fx / 2, fy: k.fy / 2, cx: k.cx / 2, cy: k.cy / 2, width: 960, height: 720))
                    let L = s.truth.spec.length, W = s.truth.spec.width
                    let truthPx = [(0.0, 0.0), (L / 2, 0), (L, 0), (L, W), (L / 2, W), (0, W)].compactMap { x, y -> String? in
                        f.camera.project(s.truth.world(x, y, 0.0365)).map { "(\(Int($0.x / 2)),\(Int($0.y / 2)))" } }
                    print("[kp] t \(String(format: "%.1f", t)) n \(pts.count): \(pts.map { "\($0.kind.rawValue.prefix(5))(\(Int($0.pixel.x)),\(Int($0.pixel.y)) \(String(format: "%.2f", $0.confidence)))" }.joined(separator: " ")) | truth noses/sides \(truthPx.joined(separator: " "))")
                }
                t += 1.0 / 15; i += 1
            }
        }
        guard ProcessInfo.processInfo.environment["VQA_TRACE_IMAGES"] == "1" else { return }
        // 2. Raw Auto over the same session with mask images.
        let auto = ClassicalAutoTableLocator(keypoints: TableKeypointModel.provider())
        var planes = VTPlaneSim(truths: s.planeTruths, seed: s.seed ^ 0x51, trackingReady: s.trackingReady)
        var jitter = VTRandom(seed: s.seed ^ 0x77)
        print("[trace] truth \(s.truth.size) L \(s.truth.spec.length) elev \(s.elevationDeg) path \(s.trajectory.kind)")
        var t = s.trackingReady
        var i = 0
        while t < 10 {
            if t - planes.lastUpdate >= 0.1 { planes.update(t: t, renderer: VTRenderer(scene: s.scene.at(time: t), camera: s.camera(t))) }
            let f = VTHarness.render(s, t: t, index: i, planes: planes.planes(t: t, jitter: &jitter))
            let k = f.camera.intrinsics
            let hint = LocatorMath.plane(for: Vec2(k.cx, k.cy), camera: f.camera, planes: f.planes)
            let e = auto.process(AutoTableFrame(
                image: AutoRGBImage(width: f.pixel.width, height: f.pixel.height, rgb: f.pixel.rgb),
                intrinsics: AutoIntrinsics(fx: k.fx / 2, fy: k.fy / 2, cx: k.cx / 2, cy: k.cy / 2, width: 960, height: 720),
                cameraToWorld: f.camera.cameraToWorld, depth: f.depth,
                plane: hint.map { AutoPlaneHint(point: $0.point, normal: $0.normal) }, timestamp: s.timestampBase + t))
            let d = e.frame
            let err = e.pose.map { VTHarness.cornerError($0.corners, s.truth.corners) * 100 }
            if let dir = outDir, i % 15 == 0 {
                // Frame with the raw cloth mask (blue tint), the kept component (green) and the truth corners.
                var rgb = f.pixel.rgb
                let W = f.pixel.width, H = f.pixel.height
                if let (raw, comp) = box.withLock({ $0 }) {
                    let st = W / raw.width
                    for y in 0..<H { for x in 0..<W {
                        let gx = min(raw.width - 1, x / st), gy = min(raw.height - 1, y / st), o = (y * W + x) * 3
                        if comp.bits[gy * comp.width + gx] != 0 { rgb[o + 1] = UInt8(min(255, Int(rgb[o + 1]) + 90)) }
                        else if raw.bits[gy * raw.width + gx] != 0 { rgb[o + 2] = UInt8(min(255, Int(rgb[o + 2]) + 90)) }
                    } }
                }
                for c in s.truth.corners { if let v = f.camera.project(c) {
                    let x = Int(v.x / 2), y = Int(v.y / 2)
                    for dy in -3...3 { for dx in -3...3 where x + dx >= 0 && x + dx < W && y + dy >= 0 && y + dy < H {
                        let o = ((y + dy) * W + x + dx) * 3; rgb[o] = 255; rgb[o + 1] = 0; rgb[o + 2] = 255 } }
                } }
                if let img = VTImageIO.cgImage(rgb: rgb, width: W, height: H) {
                    VTHarness.writePNG(img, to: URL(fileURLWithPath: dir).appendingPathComponent("trace-\(p[0])-\(p[1])-\(i).png"))
                }
                box.withLock { $0 = nil }
            }
            print(String(format: "[trace] t %.2f %@ path %@ L %.3f W %.3f snap %@ kp %d vis %@ rej %@ | fused %@ err %@ cm",
                         t, "\(e.state)", "\(d.path)", d.measuredLength ?? 0, d.measuredWidth ?? 0, "\(d.snappedSize.map { "\($0)" } ?? "-")",
                         d.keypointsUsed, d.visibleLengthFraction.map { String(format: "%.2f", $0) } ?? "-", d.rejection ?? "-",
                         e.pose.map { "\($0.snappedSize.map { "\($0)" } ?? "m") \(String(format: "%.3f", $0.spec.length))" } ?? "-",
                         err.map { String(format: "%.1f", $0) } ?? "-"))
            t += 1.0 / 15; i += 1
            if e.state == .locked && t > 4 { break }
        }
    }
}
extension VirtualTableFalseLockTests {
    /// Integration matrix (-O): felt-tan seed 10 (an 8 ft table whose tan cloth matches its maple rails) locked as
    /// 9 ft, 16 cm off. The cloth mask runs over the rail caps, so the corner-anchored partial fit picks the preset
    /// whose outline fills the mask best — one size up — and reported it as a measured size. Replayed here without
    /// the harness's CPU-time gating (which made the matrix case timing-dependent): the 9 ft partial-fit frames,
    /// each fed several times as a phone held still would, must never lock a size.
    @Test func feltTanSeed10PartialFitsNeverLockAGuessedSize() async throws {
        let s = VTSetup.make(try Self.condition("felt-tan"), seed: 10)
        #expect(s.truth.size == .eightFoot)
        let app = AutoTableLocating()
        var planes = VTPlaneSim(truths: s.planeTruths, seed: s.seed ^ 0x51, trackingReady: s.trackingReady)
        var jitter = VTRandom(seed: s.seed ^ 0x77)
        var ts = s.timestampBase + s.trackingReady
        var locked: TableEstimate?
        var planeT = s.trackingReady
        // Times where the trace shows the 9 ft corner-anchored partial fit (full search fails: no quad).
        for t0 in [1.40, 1.73, 2.40, 3.60, 4.33, 5.27, 5.40, 7.60, 7.73, 8.20, 9.20, 9.67] {
            let i = Int((t0 * Double(s.fps)).rounded()), t = Double(i) / Double(s.fps)   // the harness's frame numbering
            while planeT <= t {   // ARKit plane updates every 0.1 s, as in the harness
                planes.update(t: planeT, renderer: VTRenderer(scene: s.scene.at(time: planeT), camera: s.camera(planeT)))
                planeT += 0.1
            }
            let f = VTHarness.render(s, t: t, index: i, planes: planes.planes(t: t, jitter: &jitter))
            for _ in 0..<6 {
                ts += 1.0 / 15
                let d = f.depth
                let e = await app.ingest(LocatorFrame(image: f.pixel, camera: f.camera, planes: f.planes, timestamp: ts,
                                                      depth: DepthMap(width: d.width, height: d.height, depth: d.depth,
                                                                      confidence: d.confidence)))
                if let e, e.locked { locked = e; break }
            }
            if locked != nil { break }
        }
        if let l = locked {
            let err = VTHarness.cornerError(l.corners, s.truth.corners)
            #expect(l.size == s.truth.size, "locked \(String(describing: l.size)) on an 8 ft table, \(err * 100) cm off")
            #expect(err <= 0.05)
        }
    }
}


extension VirtualTableFalseLockTests {
    /// Lock matrix (-O, baseline and GPT-5.3 round): a 7 ft table locked at a measured 2.19 m, 18.8 cm off. Full fits
    /// said 7 ft; fits tracked from the fused pose ran ~10 cm long on both axes, between 7 and 8 ft (6.4–7.6 % from
    /// each, so unsnapped). With no preset majority fusion took the median, a size between two presets, and an
    /// unsnapped size was trusted unconditionally. Reproduces alone through the shipped path.
    @Test func dist2mSeed3NeverLocksASizeBetweenPresets() async throws {
        let s = VTSetup.make(try Self.condition("dist-2.0m"), seed: 3)
        var cache: [Int: VTFrame] = [:]
        var thumb: VTFrame?
        // Ungated: under full-suite load the CPU-gated run saw too few frames to lock in its window (QA 17 Pro Max).
        let (r, _) = await VTHarness.run(s, kind: .app, cache: &cache, thumb: &thumb, cpuGating: false)
        #expect(!(r.locked && r.sizeOK == false), "locked the wrong size, corner error \((r.cornerErr ?? 0) * 100) cm")
        #expect(!r.falseLock)
        // Full fits measure 7 ft: the table must lock, accurately (Grok 4.7: never locking is a failure too).
        #expect(r.locked && r.accurate, "locked \(r.locked), \((r.cornerErr ?? 0) * 100) cm off, reason \(r.reason ?? "-")")
    }
}

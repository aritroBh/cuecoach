import Foundation
import Geometry
import simd
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
    @Test(arguments: [UInt64(12), 19])
    func barComboSmallPatchIsNoTable(seed: UInt64) async throws {
        let s = VTSetup.make(try Self.condition("bar-rive-combo"), seed: seed)
        var cache: [Int: VTFrame] = [:]
        var thumb: VTFrame?
        let (r, _) = await VTHarness.run(s, kind: .app, cache: &cache, thumb: &thumb)
        #expect(!r.falseLock, "seed \(seed): false lock, corner error \((r.cornerErr ?? 0) * 100) cm")
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
    }
}

/// Per-frame Auto dump for one session (opt-in: VQA_TRACE=cond:seed).
struct VirtualTableTrace {
    @Test func trace() async throws {
        guard let spec = ProcessInfo.processInfo.environment["VQA_TRACE"] else { return }
        let outDir = ProcessInfo.processInfo.environment["VQA_OUT"]
        nonisolated(unsafe) var lastMask: (AutoMask, AutoMask)?
        ClassicalAutoTableLocator.debugMaskSink = { lastMask = ($0, $1); print("[trace] model m1 \($2.m1) m2 \($2.m2) s1 \($2.s1) s2 \($2.s2) mI \($2.mI) neutral \($2.neutral)") }
        defer { ClassicalAutoTableLocator.debugMaskSink = nil }
        let p = spec.split(separator: ":").map(String.init)
        let s = VTSetup.make(try VirtualTableFalseLockTests.condition(p[0]), seed: UInt64(p[1])!)
        // 1. The shipped path (the harness prints a [trace] line per frame for this cond:seed).
        var cache: [Int: VTFrame] = [:]
        var thumb: VTFrame?
        let (r, _) = await VTHarness.run(s, kind: .app, cache: &cache, thumb: &thumb)
        print("[trace] app result: locked \(r.locked) accurate \(r.accurate) err \(r.cornerErr.map { $0 * 100 } ?? -1) cm ttl \(r.ttlStart ?? -1)")
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
                if let (raw, comp) = lastMask {
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
                lastMask = nil
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

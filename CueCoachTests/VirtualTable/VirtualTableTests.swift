import CoreGraphics
import Foundation
import Geometry
import simd
import Testing
@testable import CueCoach

/// Virtual table simulator: self-checks of the synthetic world, then the lock matrix (opt-in, long).
/// Run the matrix with `TEST_RUNNER_VQA_MATRIX=1 TEST_RUNNER_VQA_OUT=<dir> xcodebuild test … -only-testing:CueCoachTests/VirtualTableTests`.
struct VirtualTableTests {
    let setup = VTSetup.make(.baseline, seed: 3)
    /// A baseline session whose whole table is in view at some point.
    static func inViewSetup() -> (VTSetup, Double)? {
        for seed in UInt64(0)..<40 {
            let s = VTSetup.make(.baseline, seed: seed)
            if let t = stride(from: 0.0, to: 4, by: 0.25).first(where: { VTHarness.tableInView(s, t: $0) }) { return (s, t) }
        }
        return nil
    }

    @Test func renderedFeltSitsWhereTheCameraModelProjectsTheTable() throws {
        // Pick a time when the whole table is in view.
        let (setup, t) = try #require(Self.inViewSetup())
        let cam = setup.camera(t)
        let r = VTRenderer(scene: setup.scene.at(time: t), camera: cam)
        let rgb = r.renderRGB(seed: 1)
        // A point on the bare cloth near the table centre, off any ball.
        let L = setup.truth.spec.length, W = setup.truth.spec.width
        var checked = 0
        for (fx, fy) in [(0.4, 0.3), (0.6, 0.7), (0.35, 0.65)] {
            let p = setup.truth.world(L * fx, W * fy, 0)
            guard setup.scene.spheres.allSatisfy({ simd_distance($0.center, p) > 0.06 }), let px = cam.project(p) else { continue }
            let x = Int(px.x / 2), y = Int(px.y / 2)
            let i = (y * 960 + x) * 3
            let (rr, g, b) = (Int(rgb[i]), Int(rgb[i + 1]), Int(rgb[i + 2]))
            #expect(g > rr + 20 && g > b + 10, "felt should be green at \(x),\(y): \(rr),\(g),\(b)")
            checked += 1
        }
        #expect(checked > 0)
        // Outside the outer rail: not felt-green (floor/rail/wall).
        let out = setup.truth.world(-0.6, W / 2, -setup.truth.clothHeight)
        if let px = cam.project(out), px.x > 0, px.x < 1920, px.y > 0, px.y < 1440 {
            let i = (Int(px.y / 2) * 960 + Int(px.x / 2)) * 3
            #expect(!(Int(rgb[i + 1]) > Int(rgb[i]) + 30 && Int(rgb[i + 1]) > Int(rgb[i + 2]) + 20))
        }
    }

    @Test func depthAgreesWithTheClothPlane() throws {
        let t = 2.0
        let cam = setup.camera(t)
        let r = VTRenderer(scene: setup.scene.at(time: t), camera: cam)
        let d = r.renderDepth(seed: 2)
        let k = cam.intrinsics
        let plane = Plane3(point: setup.truth.center, normal: SIMD3(0, 1, 0))
        var good = 0, total = 0
        for v in stride(from: 10, to: 190, by: 12) {
            for u in stride(from: 10, to: 250, by: 12) {
                let sx = (Double(u) + 0.5) * k.width / 256 - 0.5, sy = (Double(v) + 0.5) * k.height / 192 - 0.5
                let (surf, _) = r.surface(atSourceX: sx, sourceY: sy)
                guard surf == .cloth(0), d.confidence?[v * 256 + u] == 2,
                      let hit = cam.intersect(pixel: Vec2(sx, sy), with: plane) else { continue }
                let c = cam.worldToCamera * SIMD4(hit, 1)
                total += 1
                if abs(Double(d.depth[v * 256 + u]) - -c.z) < 0.04 { good += 1 }
            }
        }
        #expect(total > 20)
        #expect(Double(good) >= Double(total) * 0.95)
    }

    @Test func frameTapGateAt60fpsRunsEvery11thFrame() {
        // FrameTap admits a frame after interval × 0.9 = 0.18 s; at 60 fps that is every 11 frames (0.183 s),
        // which is *less* than FeltQuadLocator's own 0.2 s minInterval.
        var g = VTFrameTapGate()
        var admitted: [Int] = []
        for i in 0..<120 where g.offer(timestamp: 500 + Double(i) / 60, planeFound: true) { admitted.append(i) }
        let gaps = zip(admitted.dropFirst(), admitted).map { $0 - $1 }
        #expect(Set(gaps) == [11])
    }

    @Test func feltQuadDropsEveryOtherFrameTapSampleAt60fps() async {
        // Same frame stream, count how often FeltQuadLocator's 0.2 s throttle accepts what FrameTap admitted.
        // Uses a blank image so only the throttle matters (proposer returns nil but `lastT` still advances).
        let loc = FeltQuadLocator()
        let img = PixelImage(width: 32, height: 24, rgb: [UInt8](repeating: 0, count: 32 * 24 * 3))
        let cam = setup.camera(0)
        var g = VTFrameTapGate()
        var admitted = 0
        var accepted = 0
        var lastAcceptedT = -Double.infinity
        for i in 0..<600 {
            let ts = 500 + Double(i) / 60
            guard g.offer(timestamp: ts, planeFound: true) else { continue }
            admitted += 1
            _ = await loc.ingest(LocatorFrame(image: img, camera: cam, planes: [], timestamp: ts))
            if ts - lastAcceptedT >= 0.2 { accepted += 1; lastAcceptedT = ts }   // mirrors FeltQuadLocator.minInterval
        }
        #expect(admitted >= 50)
        #expect(accepted * 2 <= admitted + 1, "effective FeltQuad sample period at 60 fps is ~0.37 s, not 0.2 s")
    }

    @Test func savesSampleFrames() throws {
        guard let dir = ProcessInfo.processInfo.environment["VQA_OUT"] else { return }
        let out = URL(fileURLWithPath: dir).appendingPathComponent("frames")
        for (i, c) in VTCondition.matrix.enumerated() {
            let s = VTSetup.make(c, seed: 1)
            let t = 2.0
            let r = VTRenderer(scene: s.scene.at(time: t), camera: s.camera(t))
            let rgb = r.renderRGB(seed: 9)
            if let img = VTImageIO.cgImage(rgb: rgb, width: 960, height: 720) {
                VTHarness.writePNG(img, to: out.appendingPathComponent("\(c.name)-seed1.png"))
            }
            if i == 0 {
                let d = r.renderDepth(seed: 1)
                var g = [UInt8](repeating: 0, count: 256 * 192 * 3)
                for j in 0..<(256 * 192) {
                    let z = d.depth[j], conf = d.confidence?[j] ?? 2
                    let v = z <= 0 ? 0 : UInt8(max(0, min(255, 255 - (z - 0.5) * 70)))
                    g[j * 3] = conf == 0 ? 255 : v; g[j * 3 + 1] = v; g[j * 3 + 2] = conf == 1 ? 255 : v
                }
                if let img = VTImageIO.cgImage(rgb: g, width: 256, height: 192) {
                    VTHarness.writePNG(img, to: out.appendingPathComponent("baseline-seed1-depth.png"))
                }
            }
        }
    }

    @Test(.timeLimit(.minutes(30))) func lockMatrix() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["VQA_MATRIX"] == "1" else { return }
        let out = URL(fileURLWithPath: env["VQA_OUT"] ?? NSTemporaryDirectory() + "virtual-qa")
        let seeds = Int(env["VQA_SEEDS"] ?? "") ?? 20
        var conds = VTCondition.matrix
        if let only = env["VQA_ONLY"], !only.isEmpty { let names = only.split(separator: ",").map(String.init); conds = conds.filter { names.contains($0.name) } }
        let t0 = Date()
        let results = await VTHarness.runMatrix(conditions: conds, seeds: seeds, outDir: out)
        print("[virtual-qa] \(results.count) runs in \(Int(Date().timeIntervalSince(t0))) s → \(out.path)")
        #expect(results.count == conds.count * seeds * VTLocatorKind.selected.count)
        LockGate.check(results)
    }
}

/// Debug dump of one session's frame with the FeltQuad proposal and plane anchors (opt-in: VQA_DEBUG=cond:seed:t).
struct VirtualTableDebug {
    @Test func dump() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let spec = env["VQA_DEBUG"], let dir = env["VQA_OUT"] else { return }
        for item in spec.split(separator: ";") {
            let p = item.split(separator: ":").map(String.init)
            guard p.count == 3, let cond = VTCondition.matrix.first(where: { $0.name == p[0] }),
                  let seed = UInt64(p[1]), let t = Double(p[2]) else { continue }
            let s = VTSetup.make(cond, seed: seed)
            var ps = VTPlaneSim(truths: s.planeTruths, seed: s.seed ^ 0x51, trackingReady: s.trackingReady)
            var tt = 0.0
            while tt <= t { ps.update(t: tt, renderer: VTRenderer(scene: s.scene.at(time: tt), camera: s.camera(tt))); tt += 0.1 }
            var j = VTRandom(seed: 1)
            let planes = ps.planes(t: t, jitter: &j)
            let f = VTHarness.render(s, t: t, index: 0, planes: planes)
            let quad = FeltQuadProposer.propose(f.pixel)
            print("[debug] \(cond.name) seed \(seed) t \(t): path \(s.trajectory.kind) portrait \(s.trajectory.portrait) size \(s.truth.size) elev \(s.elevationDeg)")
            print("[debug] truth centre \(s.truth.center) corners px \(s.truth.corners.map { f.camera.project($0).map { "(\(Int($0.x)),\(Int($0.y)))" } ?? "nil" })")
            print("[debug] planes \(planes)")
            print("[debug] quad \(quad?.map { "(\(Int($0.x)),\(Int($0.y)))" } ?? [])")
            if let q = quad {
                let centre = q.reduce(Vec2.zero, +) / 4
                let pl = LocatorMath.plane(for: centre, camera: f.camera, planes: planes)
                print("[debug] plane for quad centre \(String(describing: pl)) ray hit on true cloth \(String(describing: f.camera.intersect(pixel: centre, with: Plane3(point: s.truth.center, normal: SIMD3(0, 1, 0)))))")
            }
            var rgb = f.pixel.rgb
            func dot(_ v: Vec2, _ c: (UInt8, UInt8, UInt8)) {
                let x = Int(v.x / 2), y = Int(v.y / 2)
                for dy in -3...3 { for dx in -3...3 where x + dx >= 0 && x + dx < 960 && y + dy >= 0 && y + dy < 720 {
                    let i = ((y + dy) * 960 + x + dx) * 3; rgb[i] = c.0; rgb[i + 1] = c.1; rgb[i + 2] = c.2
                } }
            }
            for c in s.truth.corners { if let v = f.camera.project(c) { dot(v, (0, 255, 255)) } }
            for v in quad ?? [] { dot(v, (255, 220, 0)) }
            if let img = VTImageIO.cgImage(rgb: rgb, width: 960, height: 720) {
                VTHarness.writePNG(img, to: URL(fileURLWithPath: dir).appendingPathComponent("debug-\(cond.name)-\(seed)-\(t).png"))
            }
        }
    }
}

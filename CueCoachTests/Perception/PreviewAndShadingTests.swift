import Foundation
import Geometry
import Testing
@testable import CueCoach

/// Codex r5 M6 / M7, written so they fail on the pre-fix code (only APIs that existed then).
struct PreviewAndShadingTests {
    /// M7: a blob with fewer than 6 samples is rejected even when those few samples look shaded
    /// (a checkerboard patch: bright centre, dark neighbours). The old code waved it through.
    @Test func shadingFilterFailsClosedBelowSixSamples() {
        let w = 21, h = 21
        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        for y in 0..<h { for x in 0..<w where (x + y) % 2 == 0 { for c in 0..<3 { rgb[(y * w + x) * 3 + c] = 250 } } }
        let img = PixelImage(width: w, height: h, rgb: rgb, scale: 1, sourceWidth: w, sourceHeight: h)
        // r = 0.85 * 1.41 ≈ 1.2 px: the centre and its 4 neighbours (5 samples), spread 250.
        #expect(!ClassicalBallDetector.hasBallShading(img, sourcePoint: Vec2(10, 10), radiusPx: 1.41))
        // Control: the same pattern judged on enough samples has a big spread and passes.
        #expect(ClassicalBallDetector.hasBallShading(img, sourcePoint: Vec2(10, 10), radiusPx: 6))
    }

    /// M6: a tentative ball that is coasting this frame (seen once, not measured now) still blocks the
    /// physics preview. The first preview is held so the next request falls on the coasting frame.
    @Test func physicsPreviewSeesACoastingTentativeBall() async {
        let rec = GatedPreviewer()
        let d = ScriptedDetector()
        let p = PerceptionPipeline(detector: d, previewer: rec)
        let scene = SyntheticTableScene.demo()
        await p.setTable(scene.frame)
        let cue = Stress.det(Vec2(0.5, 0.5), .cue, 0), obj = Stress.det(Vec2(1.3, 0.5), .solid, 3)
        let flicker = Stress.det(Vec2(1.0, 0.85), .solid, 5)
        func frame(_ i: Int) -> PerceptionFrame { PerceptionFrame(image: Stress.blankImage(), camera: scene.camera, timestamp: Double(i) / 30) }
        for i in 0..<30 { d.push([cue, obj]); _ = await p.process(frame(i)) }   // at rest; first preview is held
        d.push([cue, obj, flicker]); _ = await p.process(frame(30))          // the ball shows up (tentative)
        rec.release()
        for _ in 0..<500 where !(await p.previewIdle) { try? await Task.sleep(nanoseconds: 2_000_000) }
        d.push([cue, obj]); _ = await p.process(frame(31))                   // not seen: coasting, still tentative
        for _ in 0..<500 where !(await p.previewIdle) { try? await Task.sleep(nanoseconds: 2_000_000) }
        Stress.metric("m6.coasting.previewBallCounts", rec.all())
        #expect(rec.all().contains(3), "previews saw \(rec.all()) balls")
    }
}

/// Records each preview's ball count; the first call blocks until `release()`.
final class GatedPreviewer: ShotPreviewing, @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [Int] = []
    private let gate = DispatchSemaphore(value: 0)
    private var first = true
    func preview(cue: Vec2, object: BallID, pocket: Pocket, balls: [BallID: Vec2], spec: TableSpec) -> ShotPreview? {
        lock.lock(); counts.append(balls.count); let wait = first; first = false; lock.unlock()
        if wait { _ = gate.wait(timeout: .now() + 20) }
        return nil
    }
    func release() { gate.signal() }
    func all() -> [Int] { lock.lock(); defer { lock.unlock() }; return counts }
}

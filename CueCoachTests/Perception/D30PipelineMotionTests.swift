import Foundation
import Geometry
import Testing
@testable import CueCoach

/// GPT-5.6 BLOCKER 1: a raw motion-onset signal, independent of the tracker's debounced at-rest (which lags onset)
/// and of filtered velocity (which can be zeroed): any measured ball whose raw position moved this frame.
struct MotionOnsetTests {
    let scene = SyntheticTableScene.demo()
    var blank: PixelImage { PixelImage(width: 64, height: 36, rgb: [UInt8](repeating: 0, count: 64 * 36 * 3), scale: 30,
                                       sourceWidth: 1920, sourceHeight: 1080) }

    @Test func onsetFrameReportsMotionEvenWhileStillAtRest() async throws {
        let W = scene.frame.spec.width
        let geo = FrameGeometry(frame: scene.frame, camera: scene.camera)
        @Sendable func det(_ p: Vec2) -> BallDetection {
            BallDetection(imagePoint: geo.ball.apply(p) ?? p, tablePoint: p, radiusPx: 12, confidence: 1, kind: .cue, tentativeNumber: 0)
        }
        let p = PerceptionPipeline(detector: ScriptedBallDetector { t in
            [det(Vec2(t < 1.0 ? 0.5 : 0.53, W / 2))]                 // still for 1 s, then a 3 cm jump
        })
        await p.setTable(scene.frame)
        var last: PerceptionResult?
        for i in 0...29 { last = await p.process(PerceptionFrame(image: blank, camera: scene.camera, timestamp: Double(i) / 30)) }
        let still = try #require(last)
        #expect(still.atRest && !still.motionOnset)
        let onset = try #require(await p.process(PerceptionFrame(image: blank, camera: scene.camera, timestamp: 1.0)))
        #expect(onset.motionOnset, "raw displacement this frame")
    }
}

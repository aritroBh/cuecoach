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

    /// GPT-5.6 review of 71b0253 (BLOCKER): the launching cue ball is missed for a frame while a static ball stays
    /// measured. The cue's track is then confirmed but unmeasured (Live counts that as motion), and when it is
    /// reacquired (often as a new tentative track while the old one coasts) the jump registers as onset.
    @Test func partialDropoutLaunchStillShowsMotion() async throws {
        let W = scene.frame.spec.width
        let geo = FrameGeometry(frame: scene.frame, camera: scene.camera)
        @Sendable func det(_ p: Vec2, _ k: BallKind, _ n: Int?) -> BallDetection {
            BallDetection(imagePoint: geo.ball.apply(p) ?? p, tablePoint: p, radiusPx: 12, confidence: 1, kind: k, tentativeNumber: n)
        }
        let p = PerceptionPipeline(detector: ScriptedBallDetector { t in
            let obj = det(Vec2(1.6, W / 3), .solid, 3)
            if t < 0.99 { return [det(Vec2(0.5, W / 2), .cue, 0), obj] }
            if t < 1.01 { return [obj] }                                          // the cue is missed at launch
            return [det(Vec2(0.53, W / 2), .cue, 0), obj]                         // reacquired 3 cm on
        })
        await p.setTable(scene.frame)
        for i in 0...29 { _ = await p.process(PerceptionFrame(image: blank, camera: scene.camera, timestamp: Double(i) / 30)) }
        let miss = try #require(await p.process(PerceptionFrame(image: blank, camera: scene.camera, timestamp: 1.0)))
        let cue = try #require(miss.confirmed.first { $0.kind == .cue })
        #expect(!cue.measured, "the cue track coasts, still confirmed")
        let back = try #require(await p.process(PerceptionFrame(image: blank, camera: scene.camera, timestamp: 1.0 + 1.0 / 30)))
        #expect(back.motionOnset, "displacement since its last measurement")
    }
}

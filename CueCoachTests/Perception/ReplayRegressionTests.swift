import Foundation
import Geometry
import Testing
@testable import CueCoach

/// UI QA regression (LiveReplayUITests.testPlayLocksTableWithoutTapsAndShowsBallsAndAim): after the replay locks,
/// the six demo balls must be tracked within 10 s of replay frames (15 Hz, no depth), with the app's detector.
struct ReplayRegressionTests {
    func confirmedAfterReplay(_ detector: any BallDetector, frames: Int = 30) async throws -> PerceptionResult {
        let scene = SyntheticTableScene.demo()
        let cg = try #require(scene.render())
        let px = try #require(PixelImage(cgImage: cg))
        let p = PerceptionPipeline(detector: detector)
        await p.setTable(scene.frame)
        var last: PerceptionResult?
        for i in 1...frames { last = await p.process(PerceptionFrame(image: px, camera: scene.camera, timestamp: Double(i) / 15)) }
        return try #require(last)
    }

    @Test func classicalReplaySeesAllSixBalls() async throws {
        let r = try await confirmedAfterReplay(ClassicalBallDetector())
        #expect(r.confirmed.count == 6, "confirmed \(r.confirmed.count), detections \(r.detections.count)")
        #expect(r.aim != nil)
    }

    @Test func appDetectorReplaySeesAllSixBalls() async throws {
        let detector = PerceptionPipeline.defaultDetector()
        let r = try await confirmedAfterReplay(detector)
        // The hybrid falls back to classical silently when inference returns nil (renamed or reshaped model
        // outputs), and classical alone also tracks all six: prove the model ran.
        #expect(DetectorChoice(of: detector) == .hybrid, "app detector isn't the hybrid with a model: \(type(of: detector))")
        #expect(!detector.needsShadingCheck, "the hybrid's last frame fell back to classical")
        #expect(r.confirmed.count == 6, "confirmed \(r.confirmed.count), detections \(r.detections.count) \(r.detections.map { "\($0.kind)\($0.tentativeNumber ?? -1)" })")
        #expect(r.aim != nil)
    }
}

extension ReplayRegressionTests {
    /// Root cause found here: the model does detect the cue on the (flat-shaded) replay render, but its cue failed
    /// the classical no-LiDAR shading check, which the hybrid applied to model frames too.
    @Test func modelSeesTheCueAndItSurvivesThePipeline() async throws {
        let scene = SyntheticTableScene.demo()
        let cg = try #require(scene.render())
        let px = try #require(PixelImage(cgImage: cg))
        let geo = FrameGeometry(frame: scene.frame, camera: scene.camera)
        let dets = HybridBallDetector().detect(in: px, geometry: geo, feltReference: nil, timestamp: 0)
        #expect(dets.contains { $0.kind == .cue }, "model output: \(dets.map { "\($0.kind)\($0.tentativeNumber ?? -1)" })")
        let p = PerceptionPipeline(detector: HybridBallDetector())
        await p.setTable(scene.frame)
        let r = await p.process(PerceptionFrame(image: px, camera: scene.camera, timestamp: 0))
        #expect(r?.detections.contains { $0.kind == .cue } == true)
    }
}

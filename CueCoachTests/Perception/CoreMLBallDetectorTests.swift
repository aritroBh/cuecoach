import Foundation
import Geometry
import Testing
@testable import CueCoach

/// Integration: the trained YOLO26n ball detector (`BallDetector.mlpackage`, wt/detector) behind `BallDetector`.
struct CoreMLBallDetectorTests {
    let scene = SyntheticTableScene.demo()

    /// One NMS row: `confidence` is padded to 80 columns by the Ultralytics export; only 0..<16 are classes.
    func row(_ scores: [Int: Float]) -> [Float] {
        var r = [Float](repeating: 0, count: 80)
        for (k, v) in scores { r[k] = v }
        return r
    }

    @Test func decodeReadsOnlyTheSixteenRealClasses() {
        let lb = AutoTableKeypointModel.Letterbox(imageWidth: 640, imageHeight: 640)
        let conf = row([3: 0.9]) + row([40: 0.99, 2: 0.1]) + row([79: 0.97])
        let coords: [Float] = [0.5, 0.5, 0.05, 0.05, 0.2, 0.2, 0.05, 0.05, 0.7, 0.7, 0.05, 0.05]
        let raws = BallDetectorOutput.decode(confidence: conf, columns: 80, coordinates: coords, count: 3,
                                             letterbox: lb, minConfidence: 0.35)
        #expect(raws.count == 1)
        #expect(raws.first?.cls == 3)
        #expect(abs((raws.first?.score ?? 0) - 0.9) < 1e-6)
    }

    @Test func decodeUndoesTheLetterbox() throws {
        // 960×720 working image → scale 2/3, 80 px grey bars top and bottom.
        let lb = AutoTableKeypointModel.Letterbox(imageWidth: 960, imageHeight: 720)
        let conf = row([0: 0.8])
        // Box centred in the model input, 32 px wide → working radius 32 / (2/3) / 2 = 24 px.
        let coords: [Float] = [0.5, 0.5, 32 / 640, 32 / 640]
        let r = try #require(BallDetectorOutput.decode(confidence: conf, columns: 80, coordinates: coords, count: 1,
                                                       letterbox: lb, minConfidence: 0.35).first)
        #expect(abs(r.center.x - 479.5) < 1 && abs(r.center.y - 359.5) < 1)
        #expect(abs(r.radius - 24) < 0.5)
    }

    @Test func classesMapToKindsAndNumbers() {
        func k(_ c: Int) -> (BallKind, Int?) { let r = BallDetectorOutput.kind(forClass: c); return (r.kind, r.number) }
        #expect(k(0).0 == .cue && k(0).1 == nil)
        #expect(k(3).0 == .solid && k(3).1 == 3)
        #expect(k(8).0 == .eight && k(8).1 == 8)
        #expect(k(12).0 == .stripe && k(12).1 == 12)
        #expect(k(16).0 == .unknown && k(16).1 == nil)
    }

    @Test func detectionsLandOnTheTableAndSkipPocketsAndRails() throws {
        let cg = try #require(scene.render())
        let img = try #require(PixelImage(cgImage: cg))
        let geo = FrameGeometry(frame: scene.frame, camera: scene.camera)
        let truth = scene.balls[1]   // the 3
        let p = try #require(scene.imagePoint(truth))
        let (wx, wy) = img.toWorking(p.x, p.y)
        let onBall = BallDetectorOutput.Raw(center: Vec2(wx, wy), radius: 10, cls: 3, score: 0.9)
        // Off the cloth (top-left corner of the image) and at a pocket.
        let offTable = BallDetectorOutput.Raw(center: Vec2(2, 2), radius: 10, cls: 5, score: 0.9)
        let pk = try #require(geo.ball.apply(scene.frame.spec.pocketCenter(.footLeft)))
        let (px, py) = img.toWorking(pk.x, pk.y)
        let inPocket = BallDetectorOutput.Raw(center: Vec2(px, py), radius: 10, cls: 8, score: 0.9)
        let d = BallDetectorOutput.detections([onBall, offTable, inPocket], image: img, geometry: geo)
        #expect(d.count == 1)
        let b = try #require(d.first)
        #expect(b.kind == .solid && b.tentativeNumber == 3)
        #expect(b.tablePoint.distance(to: truth.position) < 0.01)
        #expect(abs(b.imagePoint.x - p.x) < 1 && abs(b.imagePoint.y - p.y) < 1)
    }

    /// Fake inference: scripted per call (nil = not due / failed).
    final class ScriptedInference: BallInference, @unchecked Sendable {
        var script: [[BallDetectorOutput.Raw]?]
        var calls = 0
        init(_ s: [[BallDetectorOutput.Raw]?]) { script = s }
        func infer(_ image: PixelImage) -> [BallDetectorOutput.Raw]? {
            defer { calls += 1 }
            return calls < script.count ? script[calls] : nil
        }
    }

    @Test func hybridUsesTheModelAndFallsBackToClassicalBetweenRuns() throws {
        let cg = try #require(scene.render())
        let img = try #require(PixelImage(cgImage: cg))
        let geo = FrameGeometry(frame: scene.frame, camera: scene.camera)
        let p = try #require(scene.imagePoint(scene.balls[1]))
        let (wx, wy) = img.toWorking(p.x, p.y)
        let ml = ScriptedInference([[.init(center: Vec2(wx, wy), radius: 10, cls: 3, score: 0.9)], nil])
        let h = HybridBallDetector(model: ml, minInterval: 1.0 / 30)
        let first = h.detect(in: img, geometry: geo, feltReference: nil, timestamp: 0)
        #expect(first.count == 1 && first.first?.tentativeNumber == 3)
        // 10 ms later the model isn't due: the classical detector covers the frame (it sees all six balls).
        let between = h.detect(in: img, geometry: geo, feltReference: nil, timestamp: 0.01)
        #expect(ml.calls == 1)
        #expect(between.count >= 4)
        // Due again but the model fails: classical again, never an empty frame.
        let failed = h.detect(in: img, geometry: geo, feltReference: nil, timestamp: 0.1)
        #expect(ml.calls == 2 && failed.count >= 4)
    }

    /// UI QA regression: model frames vouch for their own detections (the protocol's contract for a learned
    /// detector); only frames the classical detector produced need the no-LiDAR shading check.
    @Test func shadingCheckFollowsTheFramesSource() throws {
        let cg = try #require(scene.render())
        let img = try #require(PixelImage(cgImage: cg))
        let geo = FrameGeometry(frame: scene.frame, camera: scene.camera)
        let ml = ScriptedInference([[.init(center: Vec2(100, 100), radius: 10, cls: 0, score: 0.9)], nil])
        let h = HybridBallDetector(model: ml, minInterval: 1.0 / 30)
        _ = h.detect(in: img, geometry: geo, feltReference: nil, timestamp: 0)
        #expect(!h.needsShadingCheck)
        _ = h.detect(in: img, geometry: geo, feltReference: nil, timestamp: 0.01)   // not due: classical
        #expect(h.needsShadingCheck)
    }

    @Test func hybridWithoutAModelIsTheClassicalDetector() throws {
        let cg = try #require(scene.render())
        let img = try #require(PixelImage(cgImage: cg))
        let geo = FrameGeometry(frame: scene.frame, camera: scene.camera)
        let h = HybridBallDetector(model: nil)
        let c = ClassicalBallDetector().detect(in: img, geometry: geo)
        #expect(h.detect(in: img, geometry: geo, feltReference: nil, timestamp: 0) == c)
        #expect(h.needsShadingCheck)
        #expect(h.feltColor(in: img, geometry: geo) != nil)
    }

    @Test func pipelineDefaultsToTheHybridDetector() {
        #expect(PerceptionPipeline.defaultDetector() is HybridBallDetector)
        // Both app call sites (AR and replay) construct the pipeline with it.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for f in ["CueCoach/Live/ARLiveView.swift", "CueCoach/Live/LiveScreen.swift"] {
            let src = (try? String(contentsOf: root.appendingPathComponent(f), encoding: .utf8)) ?? ""
            #expect(src.contains("PerceptionPipeline(detector: PerceptionPipeline.defaultDetector())"), "\(f)")
            #expect(!src.contains("PerceptionPipeline()"), "\(f)")
        }
        // The model ships in the app bundle and loads.
        #expect(CoreMLBallInference.shared != nil, "BallDetector.mlpackage missing from the bundle")
    }

    /// Stress: an empty or tiny frame (camera hiccup) must not reach the letterbox (0-size scale → crash).
    @Test func hybridSurvivesAnEmptyFrame() {
        let geo = FrameGeometry(frame: scene.frame, camera: scene.camera)
        let empty = PixelImage(width: 0, height: 0, rgb: [], sourceWidth: 1920, sourceHeight: 1080)
        #expect(CoreMLBallInference.shared?.infer(empty) == nil)
        #expect(HybridBallDetector().detect(in: empty, geometry: geo, feltReference: nil, timestamp: 0).isEmpty)
    }

    @Test func bundledModelRunsAndEveryDetectionIsOnTheTable() throws {
        let model = try #require(CoreMLBallInference.shared)
        let cg = try #require(scene.render())
        let img = try #require(PixelImage(cgImage: cg))
        let geo = FrameGeometry(frame: scene.frame, camera: scene.camera)
        let raws = try #require(model.infer(img))
        let d = BallDetectorOutput.detections(raws, image: img, geometry: geo)
        let s = scene.frame.spec
        for b in d { #expect(b.tablePoint.x >= 0 && b.tablePoint.x <= s.length && b.tablePoint.y >= 0 && b.tablePoint.y <= s.width) }
        print("[detector] synthetic demo: \(raws.count) raw, \(d.count) on table; ms \(model.lastInferenceMs)")
    }
}

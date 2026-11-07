import Foundation
import Geometry

/// One camera frame reduced to what perception needs (no CVPixelBuffer / ARFrame retained).
struct PerceptionFrame: Sendable {
    var image: PixelImage
    var camera: CameraModel   // intrinsics in source-image pixels
    var timestamp: Double
}

struct PerceptionResult: Sendable {
    var timestamp: Double
    var detections: [BallDetection]
    var tracks: [TrackedBall]
    var atRest: Bool
    var aim: AimSuggestion?
    var detectMs: Double
}

/// Detection + tracking + aim off the main actor.
actor PerceptionPipeline {
    private let detector: any BallDetector
    private var tracker = SimpleBallTracker()
    private var table: TableFrame?

    init(detector: any BallDetector = ClassicalBallDetector()) { self.detector = detector }

    func setTable(_ t: TableFrame?) {
        table = t
        tracker.reset()
    }

    func process(_ f: PerceptionFrame) -> PerceptionResult? {
        guard let table else { return nil }
        let t0 = Date()
        let geo = FrameGeometry(frame: table, camera: f.camera)
        let dets = detector.detect(in: f.image, geometry: geo)
        let ms = Date().timeIntervalSince(t0) * 1000
        let tracks = tracker.update(dets, at: f.timestamp)
        let rest = tracker.isAtRest
        var aim: AimSuggestion?
        let confirmed = tracks.filter(\.confirmed)
        if rest, let cue = confirmed.first(where: { $0.kind == .cue }) {
            let objects = confirmed.filter { $0.id != cue.id }.map(\.position)
            aim = AimPlanner.suggest(cue: cue.position, objects: objects, spec: table.spec)
        }
        return PerceptionResult(timestamp: f.timestamp, detections: dets, tracks: tracks, atRest: rest, aim: aim,
                                detectMs: ms)
    }
}

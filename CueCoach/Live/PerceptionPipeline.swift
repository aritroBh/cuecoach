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
    /// Ring colour per confirmed track id.
    var marks: [Int: TargetMark]
    var atRest: Bool
    var aim: AimSuggestion?
    var detectMs: Double
    /// Median observed/expected ball radius (D12 scale check from 57.15 mm balls).
    var ballScale: Double? = nil
    /// True on the update where the segmenter saw the shot start (cue-ball speed after rest).
    var shotStarted = false
    /// Emitted once when a shot ends.
    var shot: ShotRecord? = nil

    var confirmed: [TrackedBall] { tracks.filter(\.confirmed) }
}

/// Detection + tracking + aim off the main actor.
actor PerceptionPipeline {
    private let detector: any BallDetector
    private var tracker = SimpleBallTracker()
    private var table: TableFrame?
    private var legal: Set<BallID>
    private var segmenter: ShotSegmenter?

    init(detector: any BallDetector = ClassicalBallDetector()) {
        self.detector = detector
        let (engine, game) = TargetLegality.defaultGame()
        legal = engine.legalTargets(game)
    }

    func setTable(_ t: TableFrame?) {
        table = t
        tracker.reset()
        segmenter = t.map { ShotSegmenter(spec: $0.spec) }
    }

    func setLegal(_ l: Set<BallID>) { legal = l }

    func process(_ f: PerceptionFrame) -> PerceptionResult? {
        guard let table else { return nil }
        let t0 = Date()
        let geo = FrameGeometry(frame: table, camera: f.camera)
        let dets = detector.detect(in: f.image, geometry: geo)
        let ms = Date().timeIntervalSince(t0) * 1000
        let tracks = tracker.update(dets, at: f.timestamp)
        let rest = tracker.isAtRest
        let confirmed = tracks.filter(\.confirmed)
        var marks: [Int: TargetMark] = [:]
        for t in confirmed { marks[t.id] = TargetLegality.mark(kind: t.kind, number: t.tentativeNumber, legal: legal) }
        var aim: AimSuggestion?
        if rest, let cue = confirmed.first(where: { marks[$0.id] == .cue }) {
            let others = confirmed.filter { $0.id != cue.id }
            let targets = others.filter { marks[$0.id] == .legal || marks[$0.id] == .unknown }.map(\.position)
            // Blockers include every other ball; targets only legal-looking ones.
            aim = AimPlanner.suggest(cue: cue.position, objects: targets, spec: table.spec)
            if let a = aim {
                let blockers = others.map(\.position).filter { $0 != a.object }
                let R = TableSpec.ballRadius
                if !AimPlanner.clear(from: a.cue, to: a.ghost, of: blockers, radius: 2 * R)
                    || !AimPlanner.clear(from: a.object, to: a.pocketPoint, of: blockers, radius: 2 * R) {
                    aim = nil
                }
            }
        }
        let wasInShot = segmenter?.inShot ?? false
        let cueID = confirmed.first { marks[$0.id] == .cue }?.id
        let shot = segmenter?.update(tracks: tracks, cueID: cueID, atRest: rest, at: f.timestamp)
        let started = !wasInShot && (segmenter?.inShot ?? false)
        return PerceptionResult(timestamp: f.timestamp, detections: dets, tracks: tracks, marks: marks, atRest: rest,
                                aim: aim, detectMs: ms, ballScale: BallScale.median(dets, geometry: geo),
                                shotStarted: started, shot: shot)
    }
}

/// D12: the known 57.15 mm ball diameter as a scale reference. Ratio of observed to expected image radius;
/// a table measured at the wrong size shows up as a ratio away from 1.
enum BallScale {
    static func median(_ dets: [BallDetection], geometry geo: FrameGeometry) -> Double? {
        let r = dets.compactMap { d -> Double? in
            let e = TableSpec.ballRadius * geo.ball.maxScale(at: d.tablePoint)
            return e > 0 ? d.radiusPx / e : nil
        }.sorted()
        guard r.count >= 3 else { return nil }
        return r[r.count / 2]
    }
}

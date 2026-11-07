import Foundation
import Geometry

/// One camera frame reduced to what perception needs (no CVPixelBuffer / ARFrame retained).
struct PerceptionFrame: Sendable {
    var image: PixelImage
    var camera: CameraModel   // intrinsics in source-image pixels
    var timestamp: Double
    /// LiDAR depth aligned with the image (ARKit sceneDepth), when available.
    var depth: DepthMap? = nil
    /// Shooter wrists from Vision body pose, source pixels.
    var wrists: [Vec2] = []
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
    /// The player's live aim from the cue stick (SPEC §5.6), when the cue is visible.
    var liveAim: LiveAimTrace? = nil
    /// 0…1: live aim vs suggested ghost line; the overlay merges them as this approaches 1.
    var convergence: Double = 0
    var depthBalls = 0

    var confirmed: [TrackedBall] { tracks.filter(\.confirmed) }
}

/// Detection + tracking + aim off the main actor.
actor PerceptionPipeline {
    private let detector: any BallDetector
    private var tracker = KalmanBallTracker()
    private var table: TableFrame?
    private var legal: Set<BallID>
    private var segmenter: ShotSegmenter?
    private var cueTracker = CueAimTracker()
    private let cueDetector = CueLineDetector()
    private let depthFinder = DepthBallFinder()

    init(detector: any BallDetector = ClassicalBallDetector()) {
        self.detector = detector
        let (engine, game) = TargetLegality.defaultGame()
        legal = engine.legalTargets(game)
    }

    func setTable(_ t: TableFrame?) {
        table = t
        tracker.reset()
        segmenter = t.map { ShotSegmenter(spec: $0.spec) }
        cueTracker = CueAimTracker()
    }

    func setLegal(_ l: Set<BallID>) { legal = l }

    func process(_ f: PerceptionFrame) -> PerceptionResult? {
        guard let table else { return nil }
        let t0 = Date()
        let geo = FrameGeometry(frame: table, camera: f.camera)
        var dets = detector.detect(in: f.image, geometry: geo)
        var depthBalls: [Vec2] = []
        if let d = f.depth {
            depthBalls = depthFinder.find(depth: d, camera: f.camera, table: table)
            dets = DepthFusion.merge(dets, depthBalls: depthBalls, image: f.image, geometry: geo)
        }
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
        // Live aim from the cue stick (only while the balls are still: that's when the player aims).
        var live: LiveAimTrace?
        var convergence = 0.0
        let cueBall = confirmed.first { marks[$0.id] == .cue }
        if let cb = cueBall {
            let others = confirmed.filter { $0.id != cb.id }.map(\.position)
            let obs = cb.speed < 0.2 ? cueDetector.detect(in: f.image, geometry: geo, cue: cb.position, others: others,
                                                          wrists: f.wrists) : nil
            _ = cueTracker.update(obs, at: f.timestamp)
            if let d = cueTracker.direction, cueTracker.cueVisible(at: f.timestamp) {
                live = LiveAimTrace.trace(cue: cb.position, direction: d, balls: others, spec: table.spec)
                if let a = aim { convergence = LiveAimTrace.convergence(live: d, cue: cb.position, suggestedGhost: a.ghost) }
            }
        }
        let wasInShot = segmenter?.inShot ?? false
        let cueID = cueBall?.id
        let strokeGate: Bool? = cueTracker.cueVisible(at: f.timestamp) ? cueTracker.strokeRecent(at: f.timestamp) : nil
        let shot = segmenter?.update(tracks: tracks, cueID: cueID, atRest: rest, at: f.timestamp, strokeRecent: strokeGate)
        let started = !wasInShot && (segmenter?.inShot ?? false)
        return PerceptionResult(timestamp: f.timestamp, detections: dets, tracks: tracks, marks: marks, atRest: rest,
                                aim: aim, detectMs: ms, ballScale: BallScale.median(dets, geometry: geo),
                                shotStarted: started, shot: shot, liveAim: live, convergence: convergence,
                                depthBalls: depthBalls.count)
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

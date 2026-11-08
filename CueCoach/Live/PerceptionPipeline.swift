import Foundation
import Geometry

/// One camera frame reduced to what perception needs (no CVPixelBuffer / ARFrame retained).
struct PerceptionFrame: Sendable {
    var image: PixelImage
    var camera: CameraModel   // intrinsics in source-image pixels
    var timestamp: Double
    /// LiDAR depth aligned with the image (ARKit sceneDepth), when available.
    var depth: DepthMap? = nil
    /// Wrists per detected person from Vision body pose, source pixels.
    var wristsByPerson: [[Vec2]] = []
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
    /// Track id of the ball the live cue line hits first (for the illegal-aim warning).
    var liveTargetID: Int? = nil
    var depthBalls = 0
    /// Tracker id → rule ball id (cue = 0) for ratings and the shell.
    var ballIDs: [Int: BallID] = [:]
    /// Whole pipeline time for this frame (detect + depth + track + cue + aim), ms.
    var totalMs: Double = 0

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
    private let previewer: any ShotPreviewing
    private var previewCache = PreviewCache()
    private var previewInFlight: String?

    init(detector: any BallDetector = ClassicalBallDetector(), previewer: any ShotPreviewing = PhysicsShotPreview()) {
        self.detector = detector
        self.previewer = previewer
        let (engine, game) = TargetLegality.defaultGame()
        legal = engine.legalTargets(game)
    }

    func setTable(_ t: TableFrame?) {
        table = t
        tracker.reset()
        segmenter = t.map { ShotSegmenter(spec: $0.spec) }
        cueTracker = CueAimTracker()
        previewCache = PreviewCache()   // previews belong to one table
        previewInFlight = nil
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
            dets = DepthFusion.verify(dets, depth: d, camera: f.camera, table: table)
            dets = DepthFusion.merge(dets, depthBalls: depthBalls, image: f.image, geometry: geo)
        } else {
            // No LiDAR: a white blob must look like a lit sphere (shading), not a flat mark.
            dets = dets.filter { d in
                d.kind != .cue && d.kind != .unknown
                    || ClassicalBallDetector.hasBallShading(f.image, sourcePoint: d.imagePoint, radiusPx: d.radiusPx)
            }
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
            // Known-legal balls are the targets; unidentified ones only when nothing is identified as legal.
            let legalBalls = others.filter { marks[$0.id] == .legal }
            let targets = legalBalls.isEmpty ? others.filter { marks[$0.id] == .unknown } : legalBalls
            // Blockers: every other track, tentative ones included (a real ball not yet confirmed still blocks).
            let blockers = tracks.filter { t in t.id != cue.id && !targets.contains { $0.id == t.id } }.map(\.position)
            let cands = AimPlanner.candidates(cue: cue.position, objects: targets.map(\.position), blockers: blockers,
                                              spec: table.spec, limit: 3)
            // Physics sees every track (tentative ones too), so a not-yet-confirmed ball still blocks the path.
            aim = refineWithPhysics(cands, cue: cue, tracks: tracks, spec: table.spec) ?? cands.first
        }
        // Live aim from the cue stick (only while the balls are still: that's when the player aims).
        var live: LiveAimTrace?
        var convergence = 0.0
        var liveTargetID: Int?
        let cueBall = confirmed.first { marks[$0.id] == .cue }
        if let cb = cueBall {
            let otherTracks = confirmed.filter { $0.id != cb.id }
            let others = otherTracks.map(\.position)
            let wrists = ShooterPicker.wrists(of: f.wristsByPerson, nearestTo: cb.position, geometry: geo)
            let obs = cb.speed < 0.2 ? cueDetector.detect(in: f.image, geometry: geo, cue: cb.position, others: others,
                                                          wrists: wrists) : nil
            _ = cueTracker.update(obs, at: f.timestamp)
            if let d = cueTracker.direction, cueTracker.cueVisible(at: f.timestamp) {
                live = LiveAimTrace.trace(cue: cb.position, direction: d, balls: others, spec: table.spec)
                liveTargetID = live?.hitIndex.map { otherTracks[$0].id }
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
                                shotStarted: started, shot: shot, liveAim: live, convergence: convergence, liveTargetID: liveTargetID,
                                depthBalls: depthBalls.count, ballIDs: BallIdentity.assign(confirmed, cueID: cueID),
                                totalMs: Date().timeIntervalSince(t0) * 1000)
    }
}

extension PerceptionPipeline {
    /// Simulate the top candidates (cached by layout) and keep the first clean make; Lines 2/3 then come
    /// from CueCore Physics instead of geometry.
    func refineWithPhysics(_ cands: [AimSuggestion], cue: TrackedBall, tracks: [TrackedBall], spec: TableSpec) -> AimSuggestion? {
        let ids = BallIdentity.assign(tracks, cueID: cue.id)
        let balls = Dictionary(uniqueKeysWithValues: tracks.compactMap { t in ids[t.id].map { ($0, t.position) } })
        var firstPreviewed: AimSuggestion?
        var budget = 1   // at most one fresh simulation search per frame; the rest fill in on later frames
        for c in cands {
            guard let track = tracks.min(by: { $0.position.distance(to: c.object) < $1.position.distance(to: c.object) }),
                  let objectID = ids[track.id] else { continue }
            let key = PreviewCache.key(cue: cue.position, object: objectID, pocket: c.pocket, balls: balls, spec: spec)
            guard let cached = previewCache.get(key) else {
                // Miss: search off the perception actor, one at a time; geometry is shown meanwhile.
                if budget > 0 && previewInFlight == nil {
                    budget -= 1
                    previewInFlight = key
                    let previewer = previewer, cuePos = cue.position, pocket = c.pocket
                    Task.detached(priority: .utility) { [weak self] in
                        let p = previewer.preview(cue: cuePos, object: objectID, pocket: pocket, balls: balls, spec: spec)
                        await self?.storePreview(key, p)
                    }
                }
                continue
            }
            guard let p = cached else { continue }
            var a = c
            a.ghost = p.contact ?? c.ghost
            a.cuePath = p.cuePath
            a.objectPath = p.objectPath
            a.spin = p.spin
            a.power = p.power
            a.outcome = p.outcome
            a.ease = switch p.outcome { case .make: c.ease; case .miss: min(c.ease, 0.2); case .scratch: 0 }
            if p.outcome == .make { return a }
            if firstPreviewed == nil { firstPreviewed = a }
        }
        return firstPreviewed
    }

    func storePreview(_ key: String, _ p: ShotPreview?) {
        if previewInFlight == key { previewInFlight = nil }
        previewCache.put(key, p)
    }

    /// Test hook: no preview search running.
    var previewIdle: Bool { previewInFlight == nil }
}

/// Picks the shooter among everyone Vision sees: the person with a wrist nearest the cue ball (table coords).
enum ShooterPicker {
    static func wrists(of people: [[Vec2]], nearestTo cue: Vec2, geometry geo: FrameGeometry, maxDistance: Double = 1.2) -> [Vec2] {
        let inv = geo.ballInverse
        let scored = people.compactMap { w -> (Double, [Vec2])? in
            let d = w.compactMap { inv.apply($0)?.distance(to: cue) }.min()
            return d.map { ($0, w) }
        }
        guard let best = scored.min(by: { $0.0 < $1.0 }), best.0 <= maxDistance else { return [] }
        return best.1
    }
}

/// Maps tracks to rule-level ball ids: cue = 0; tentative numbers when unambiguous; the rest get unused numbers.
enum BallIdentity {
    static func assign(_ tracks: [TrackedBall], cueID: Int?) -> [Int: BallID] {
        var out: [Int: BallID] = [:]
        var used: Set<Int> = []
        if let c = cueID { out[c] = .cue; used.insert(0) }
        let counts = Dictionary(grouping: tracks.compactMap(\.tentativeNumber), by: { $0 }).mapValues(\.count)
        for t in tracks where out[t.id] == nil {
            if let n = t.tentativeNumber, n > 0, counts[n] == 1, !used.contains(n), let id = BallID(n) {
                out[t.id] = id; used.insert(n)
            }
        }
        var free = (1...15).filter { !used.contains($0) }
        for t in tracks.sorted(by: { $0.id < $1.id }) where out[t.id] == nil {
            guard !free.isEmpty, let id = BallID(free.removeFirst()) else { break }
            out[t.id] = id
        }
        return out
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

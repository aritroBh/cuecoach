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
    /// Tracker id → rule ball id (cue = 0) for ratings and the shell; unidentified balls are absent.
    var ballIDs: [Int: BallID] = [:]
    /// The shooter's wrist is near the cue ball (stepping up to shoot) — hides post-shot text.
    var shooterAddressing = false
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
    /// Cloth colour from the first frame after lock (white-balance reference).
    private var feltReference: (UInt8, UInt8, UInt8)?
    /// The established cue-ball track id, kept while it is briefly gone (it comes back with its id).
    private var cueID: Int?
    private var cueLostAt: Double?
    /// s a lost cue-ball id is waited for before another white track can take over for good.
    private let cueHoldSeconds = 10.0
    /// A target's class votes must agree at least this much.
    static let minTargetShare = 0.8
    /// Cloth colour samples from the first frames after lock; the reference is their per-channel median.
    private var feltSamples: [(UInt8, UInt8, UInt8)] = []
    private let feltSampleCount = 10

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
        feltReference = nil
        feltSamples = []
        cueID = nil
        cueLostAt = nil
    }

    func setLegal(_ l: Set<BallID>) { legal = l }

    func process(_ f: PerceptionFrame) -> PerceptionResult? {
        guard let table else { return nil }
        let t0 = Date()
        let geo = FrameGeometry(frame: table, camera: f.camera)
        if feltSamples.count < feltSampleCount, let c = detector.feltColor(in: f.image, geometry: geo) {
            // Median over the first frames after lock, so one odd frame (a hand, auto white balance settling)
            // does not bias the whole session.
            feltSamples.append(c)
            func med(_ k: ((UInt8, UInt8, UInt8)) -> UInt8) -> UInt8 { feltSamples.map(k).sorted()[feltSamples.count / 2] }
            feltReference = (med { $0.0 }, med { $0.1 }, med { $0.2 })
        }
        var dets = detector.detect(in: f.image, geometry: geo, feltReference: feltReference)
        var depthBalls: [Vec2] = []
        if let d = f.depth {
            depthBalls = depthFinder.find(depth: d, camera: f.camera, table: table)
            dets = DepthFusion.verify(dets, depth: d, camera: f.camera, table: table)
            dets = DepthFusion.merge(dets, depthBalls: depthBalls, image: f.image, geometry: geo)
        } else if detector.needsShadingCheck {
            // No LiDAR: a white blob must look like a lit sphere (shading), not a flat mark. Fails closed.
            dets = dets.filter { d in
                d.kind != .cue && d.kind != .unknown
                    || ClassicalBallDetector.hasBallShading(f.image, sourcePoint: d.imagePoint, radiusPx: d.radiusPx)
            }
        }
        let ms = Date().timeIntervalSince(t0) * 1000
        let tracks = tracker.update(dets, at: f.timestamp)
        let rest = tracker.isAtRest
        let confirmed = tracks.filter(\.confirmed)
        // At most one cue ball: continuity first, then the whitest steady track (C3).
        let cueBall = pickCue(confirmed, at: f.timestamp)
        var marks: [Int: TargetMark] = [:]
        for t in confirmed {
            let m = TargetLegality.mark(kind: t.kind, number: t.tentativeNumber, legal: legal)
            // A second "cue" (a reflection, chalk, a glass) is not the cue ball and is never a target.
            marks[t.id] = m == .cue && t.id != cueBall?.id ? .unknown : m
        }
        var aim: AimSuggestion?
        if rest, let cue = cueBall {
            let others = confirmed.filter { $0.id != cue.id }
            // Only known-legal balls are targets. An unidentified ball could be the 8: with no ball known to be
            // legal there is no suggestion at all.
            // A ball known only by group (no number) could be a misread 8 unless the 8 is seen elsewhere.
            let eightSeen = legal.contains(.eight) || others.contains { $0.kind == .eight && $0.kindShare >= Self.minTargetShare }
            let targets = others.filter { t in
                marks[t.id] == .legal && t.kindShare >= Self.minTargetShare && (t.tentativeNumber != nil || eightSeen)
            }
            // Blockers: every other track, tentative ones included (a real ball not yet confirmed still blocks).
            let blockers = tracks.filter { t in t.id != cue.id && !targets.contains { $0.id == t.id } }.map(\.position)
            if !targets.isEmpty {
                let cands = AimPlanner.candidates(cue: cue.position, objects: targets.map(\.position), blockers: blockers,
                                                  spec: table.spec, limit: 3)
                // Physics sees every track (tentative ones too), so a not-yet-confirmed ball still blocks the path.
                aim = refineWithPhysics(cands, cue: cue, tracks: tracks, spec: table.spec) ?? cands.first
            }
        }
        // Live aim from the cue stick (only while the balls are still: that's when the player aims).
        var live: LiveAimTrace?
        var convergence = 0.0
        var liveTargetID: Int?
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
        var addressing = false
        if let cb = cueBall {
            let w = ShooterPicker.wrists(of: f.wristsByPerson, nearestTo: cb.position, geometry: geo, maxDistance: 0.5)
            addressing = !w.isEmpty
        }
        let wasInShot = segmenter?.inShot ?? false
        let cueID = cueBall?.id
        let strokeGate: Bool? = cueTracker.cueVisible(at: f.timestamp) ? cueTracker.strokeRecent(at: f.timestamp) : nil
        let shot = segmenter?.update(tracks: tracks, cueID: cueID, atRest: rest, at: f.timestamp, strokeRecent: strokeGate)
        let started = !wasInShot && (segmenter?.inShot ?? false)
        return PerceptionResult(timestamp: f.timestamp, detections: dets, tracks: tracks, marks: marks, atRest: rest,
                                aim: aim, detectMs: ms, ballScale: BallScale.median(dets, geometry: geo),
                                shotStarted: started, shot: shot, liveAim: live, convergence: convergence, liveTargetID: liveTargetID,
                                depthBalls: depthBalls.count, ballIDs: BallIdentity.known(confirmed, cueID: cueID),
                                shooterAddressing: addressing,
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

    /// C3: at most one cue ball. The established cue id wins while it is confirmed; while it is gone the
    /// steadiest white track stands in, and the old id takes over again when the ball comes back.
    func pickCue(_ confirmed: [TrackedBall], at t: Double) -> TrackedBall? {
        let cands = confirmed.filter { TargetLegality.mark(kind: $0.kind, number: $0.tentativeNumber, legal: legal) == .cue }
        if let id = cueID, let c = cands.first(where: { $0.id == id }) { cueLostAt = nil; return c }
        if cueID != nil {
            if cueLostAt == nil { cueLostAt = t }
            // While the cue ball is briefly gone (behind the shooter) there is no cue ball rather than a stand-in.
            if let l = cueLostAt, t - l > cueHoldSeconds { cueID = nil; cueLostAt = nil } else { return nil }
        }
        let best = cands.max { a, b in
            let sa = a.kindShare * (a.measured ? 1 : 0.5), sb = b.kindShare * (b.measured ? 1 : 0.5)
            return sa != sb ? sa < sb : a.id > b.id
        }
        if cueID == nil, let b = best { cueID = b.id }
        return best
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

/// Maps tracks to rule-level ball ids.
/// - `known`: for rules — cue = 0 and unambiguous tentative numbers only; unidentified balls stay unknown.
/// - `assign`: for physics — every ball gets some number (identity doesn't matter to the simulation).
enum BallIdentity {
    static func known(_ tracks: [TrackedBall], cueID: Int?) -> [Int: BallID] {
        var out: [Int: BallID] = [:]
        if let c = cueID { out[c] = .cue }
        let counts = Dictionary(grouping: tracks.compactMap(\.tentativeNumber), by: { $0 }).mapValues(\.count)
        for t in tracks where out[t.id] == nil {
            if let n = t.tentativeNumber, n > 0, counts[n] == 1, let id = BallID(n) { out[t.id] = id }
        }
        return out
    }

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

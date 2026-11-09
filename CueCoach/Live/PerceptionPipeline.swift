import Foundation
import Geometry
import simd

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
    /// D30: pockets this frame can judge (in frame, no hand over them) and pockets with a ball in their jaws.
    var pocketsInView: Set<Pocket> = Set(Pocket.allCases)
    var pocketsOccupied: Set<Pocket> = []
    /// Raw motion this frame (a measured ball moved), independent of the debounced `atRest` and filtered velocity.
    var motionOnset = false

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
    /// Frames a rival white track has had clearly stronger detector cue evidence than the established cue.
    private var rivalFrames: (id: Int, n: Int)?
    /// Previous frame's camera pose: a jump between frames is ARKit relocalizing, i.e. the table frame moving.
    private var lastPose: (m: simd_double4x4, t: Double)?
    /// s a lost cue-ball id is waited for before another white track can take over for good.
    private let cueHoldSeconds = 10.0
    /// A target's class votes must agree at least this much.
    static let minTargetShare = 0.8
    /// Cue evidence lead and duration a rival needs to replace the established cue ball.
    static let rivalMargin = 0.25
    static let rivalHoldFrames = 10
    /// Cloth colour samples from the first frames after lock; the reference is their per-channel median.
    private var feltSamples: [(UInt8, UInt8, UInt8)] = []
    /// Rule ids seen before and during the current shot (a pocketed ball's track is gone at settlement).
    private var shotIDs = ShotIdentities()
    /// Last raw (measured) position per track, for the motion-onset signal.
    private var lastRaw: [Int: (p: Vec2, t: Double)] = [:]
    private let feltSampleCount = 10

    /// The shipped detector (the app's call sites pass it; the init default stays classical for logic tests on
    /// rendered scenes): the D32 benchmark winner (`DetectorChoice.benchmarkWinner`). `UserDefaults
    /// "cc.detector.classical" = true` forces classical-only (table-side A/B).
    static func defaultDetector(defaults: UserDefaults = .standard) -> any BallDetector {
        defaults.bool(forKey: "cc.detector.classical") ? HybridBallDetector(model: nil) : DetectorChoice.benchmarkWinner.make()
    }

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
        shotIDs = ShotIdentities()
        lastRaw = [:]
        rivalFrames = nil
        lastPose = nil
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
        var dets = detector.detect(in: f.image, geometry: geo, feltReference: feltReference, timestamp: f.timestamp)
        var depthBalls: [Vec2] = []
        if let d = f.depth {
            depthBalls = depthFinder.find(depth: d, camera: f.camera, table: table)
            dets = DepthFusion.verify(dets, depth: d, camera: f.camera, table: table)
            dets = DepthFusion.merge(dets, depthBalls: depthBalls, image: f.image, geometry: geo, feltReference: feltReference)
        } else if detector.needsShadingCheck {
            // No LiDAR: a white blob must look like a lit sphere (shading), not a flat mark. Fails closed.
            dets = dets.filter { d in
                d.kind != .cue && d.kind != .unknown
                    || ClassicalBallDetector.hasBallShading(f.image, sourcePoint: d.imagePoint, radiusPx: d.radiusPx)
            }
        }
        let ms = Date().timeIntervalSince(t0) * 1000
        if let prev = lastPose, PoseJump.isJump(from: prev.m, to: f.camera.cameraToWorld, dt: f.timestamp - prev.t) {
            tracker.noteFrameShift()
        }
        lastPose = (f.camera.cameraToWorld, f.timestamp)
        let tracks = tracker.update(dets, at: f.timestamp)
        let rest = tracker.isAtRest
        let confirmed = tracks.filter(\.confirmed)
        // At most one cue ball: continuity first, then the whitest steady track (C3).
        // The cue ball is only ever re-chosen with the table at rest and no shot open.
        let cueBall = pickCue(confirmed, at: f.timestamp, allowSwitch: rest && !(segmenter?.inShot ?? false))
        var marks: [Int: TargetMark] = [:]
        for t in confirmed {
            var m = TargetLegality.mark(kind: t.kind, number: t.tentativeNumber, legal: legal)
            // A second "cue" (a reflection, chalk, a glass) is not the cue ball and is never a target.
            if m == .cue && t.id != cueBall?.id { m = .unknown }
            // D29: a warning needs a settled identity; class votes that still disagree are not one.
            if m == .illegal && (t.kindShare < Self.minTargetShare || t.numberShare < Self.minTargetShare) { m = .unknown }
            marks[t.id] = m
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
        // Raw motion onset: a measured ball's position moved this frame (the tracker's at-rest lags onset and its
        // filtered velocity can be zeroed). One threshold: > 4 mm and > 5 cm/s over the frame gap.
        // Raw positions survive short misses: a ball reacquired after a dropout reports its displacement since its
        // last measurement (GPT-5.6 review of 71b0253).
        var onset = false
        var raw: [Int: (p: Vec2, t: Double)] = [:]
        for b in confirmed {
            guard b.measured else { if let prev = lastRaw[b.id] { raw[b.id] = prev }; continue }
            let q = b.measuredPosition
            if let prev = lastRaw[b.id], f.timestamp > prev.t {
                let d = q.distance(to: prev.p)
                if d > max(0.004, 0.05 * (f.timestamp - prev.t)) { onset = true }
            }
            raw[b.id] = (q, f.timestamp)
        }
        // A launching ball reacquired as a NEW track (the old one still coasting) is motion too: a measured track with
        // no raw history appearing within 20 cm of a coasting confirmed track's last raw position, away from it.
        let coasting = confirmed.filter { !$0.measured }.compactMap { lastRaw[$0.id]?.p }
        if !onset, !coasting.isEmpty {
            for b in tracks where b.measured && lastRaw[b.id] == nil {
                let q = b.measuredPosition
                if coasting.contains(where: { let d = $0.distance(to: q); return d > 0.004 && d < 0.2 }) { onset = true; break }
            }
        }
        for b in tracks where b.measured && !b.confirmed { raw[b.id] = (b.measuredPosition, f.timestamp) }
        lastRaw = raw
        let ballIDs = shotIDs.update(known: BallIdentity.known(confirmed, cueID: cueID),
                                     inShot: wasInShot || (segmenter?.inShot ?? false), ended: shot != nil)
        return PerceptionResult(timestamp: f.timestamp, detections: dets, tracks: tracks, marks: marks, atRest: rest,
                                aim: aim, detectMs: ms, ballScale: BallScale.median(dets, geometry: geo),
                                shotStarted: started, shot: shot, liveAim: live, convergence: convergence, liveTargetID: liveTargetID,
                                depthBalls: depthBalls.count, ballIDs: ballIDs,
                                shooterAddressing: addressing,
                                totalMs: Date().timeIntervalSince(t0) * 1000,
                                pocketsInView: Self.pocketsInView(geometry: geo, image: f.image, wrists: f.wristsByPerson.flatMap { $0 }),
                                pocketsOccupied: Self.occupiedPockets(confirmed, spec: table.spec),
                                motionOnset: onset)
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
    func pickCue(_ confirmed: [TrackedBall], at t: Double, allowSwitch: Bool = true) -> TrackedBall? {
        // Missing evidence is neutral (0.5) everywhere: depth-only balls, scripted detections, older detectors.
        func ev(_ b: TrackedBall) -> Double { b.cueScore ?? 0.5 }
        let cands = confirmed.filter { TargetLegality.mark(kind: $0.kind, number: $0.tentativeNumber, legal: legal) == .cue }
        if let id = cueID, let c = cands.first(where: { $0.id == id }) {
            cueLostAt = nil
            // Continuity alone can lock onto a white false positive that was there first. A rival with clearly
            // stronger detector cue evidence (whiteness × sphere shading, or the trained cue-class score) for
            // `rivalHoldFrames` frames takes over.
            let rival = allowSwitch ? cands.filter { $0.id != id && $0.measured && $0.cueScore != nil }.max { ev($0) < ev($1) } : nil
            if let r = rival, ev(r) >= ev(c) + Self.rivalMargin {
                let n = rivalFrames?.id == r.id ? rivalFrames!.n + 1 : 1
                rivalFrames = (r.id, n)
                if n >= Self.rivalHoldFrames { cueID = r.id; rivalFrames = nil; return r }
            } else {
                rivalFrames = nil
            }
            return c
        }
        rivalFrames = nil   // the hold counts consecutive frames with the established cue in view
        if cueID != nil {
            if cueLostAt == nil { cueLostAt = t }
            // While the cue ball is briefly gone (behind the shooter) there is no cue ball rather than a stand-in.
            if let l = cueLostAt, t - l > cueHoldSeconds { cueID = nil; cueLostAt = nil } else { return nil }
        }
        let best = cands.max { a, b in
            let sa = ev(a) * a.kindShare * (a.measured ? 1 : 0.5), sb = ev(b) * b.kindShare * (b.measured ? 1 : 0.5)
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
        // D29: only a settled identity (kind and number votes both ≥ 0.8) has rules consequences.
        for t in tracks where out[t.id] == nil {
            if let n = t.tentativeNumber, n > 0, counts[n] == 1, let id = BallID(n),
               t.kindShare >= PerceptionPipeline.minTargetShare, t.numberShare >= PerceptionPipeline.minTargetShare { out[t.id] = id }
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

/// Track id → rule id over a shot: before a shot it is the live map; during one, ids already known are kept
/// (a pocketed ball's track is dropped before the shot settles) and new tracks only add balls not yet mapped.
struct ShotIdentities: Sendable {
    private var held: [Int: BallID] = [:]

    mutating func update(known: [Int: BallID], inShot: Bool, ended: Bool = false) -> [Int: BallID] {
        guard inShot || ended else { held = known; return known }
        // A new track may take a ball held by a *retired* track (the ball re-acquired after an occlusion): both ids
        // then map to it, so a pocket recorded under either reaches Rules. Two live tracks never share a ball.
        for (k, v) in known where held[k] == nil {
            let liveHolder = held.contains { $0.value == v && $0.key != k && known[$0.key] != nil }
            if !liveHolder { held[k] = v }
        }
        let out = held
        if ended { held = known }
        return out
    }
}

/// ARKit relocalization shows up as a camera-pose jump between consecutive frames that no hand-held motion
/// makes (> 2.5 m/s, or > 8 rad/s, over the frame gap; tiny gaps are judged over at least 1/60 s). A quick
/// hand-held flick reaches ~5 rad/s; a fast walk ~1.5 m/s.
enum PoseJump {
    static func isJump(from a: simd_double4x4, to b: simd_double4x4, dt: Double,
                       maxSpeed: Double = 2.5, maxTurnRate: Double = 8.0) -> Bool {
        let gap = max(1.0 / 60, min(0.5, dt))
        let ta = SIMD3(a.columns.3.x, a.columns.3.y, a.columns.3.z), tb = SIMD3(b.columns.3.x, b.columns.3.y, b.columns.3.z)
        let moved = simd_length(tb - ta)
        let ra = simd_double3x3(SIMD3(a.columns.0.x, a.columns.0.y, a.columns.0.z), SIMD3(a.columns.1.x, a.columns.1.y, a.columns.1.z),
                                SIMD3(a.columns.2.x, a.columns.2.y, a.columns.2.z))
        let rb = simd_double3x3(SIMD3(b.columns.0.x, b.columns.0.y, b.columns.0.z), SIMD3(b.columns.1.x, b.columns.1.y, b.columns.1.z),
                                SIMD3(b.columns.2.x, b.columns.2.y, b.columns.2.z))
        let rel = ra.transpose * rb
        let angle = acos(max(-1, min(1, (rel[0, 0] + rel[1, 1] + rel[2, 2] - 1) / 2)))
        return moved / gap > maxSpeed || angle / gap > maxTurnRate
    }
}

extension PerceptionPipeline {
    /// D30: a pocket can be judged when its centre is inside the frame and no wrist is over it.
    static func pocketsInView(geometry geo: FrameGeometry, image: PixelImage, wrists: [Vec2], margin: Double = 8,
                              handRadius: Double = 0.15) -> Set<Pocket> {
        let w = Double(image.sourceWidth), h = Double(image.sourceHeight)
        let inv = geo.clothInverse
        let hands = wrists.compactMap { inv.apply($0) }
        return Set(geo.spec.pockets.filter { pk in
            let c = geo.spec.pocketCenter(pk)
            guard let p = geo.cloth.apply(c), p.x >= margin, p.y >= margin, p.x <= w - margin, p.y <= h - margin else { return false }
            return !hands.contains { $0.distance(to: c) < handRadius }
        })
    }

    /// D30: pockets with a tracked (measured) ball within `radius` of their centre: hanging in the jaws.
    static func occupiedPockets(_ tracks: [TrackedBall], spec: TableSpec, radius: Double = 0.12) -> Set<Pocket> {
        Set(spec.pockets.filter { pk in
            tracks.contains { $0.confirmed && $0.measured && $0.measuredPosition.distance(to: spec.pocketCenter(pk)) <= radius }
        })
    }
}

import Foundation
import Geometry
import simd
import Synchronization

/// Production table locator (lock plan step 1): `ClassicalAutoTableLocator` (Calibration/Auto) is the only
/// source of a lock. `FeltQuadProposer` survives only as a fast ghost seed while Auto has no pose yet.
/// Plugs into the live screen through `TableLocating`.
final class AutoTableLocating: TableLocating, @unchecked Sendable {
    private let auto: ClassicalAutoTableLocator
    private let state = Mutex(State())
    var profile = AutoTableProfile()
    /// History expires after a timestamp gap this long (the user looked away / the app was paused).
    var expireAfterGap = 1.0
    /// …or after this many consecutive frames with a rejection while not converging.
    var expireAfterFailures = 5

    private struct State {
        var lastT: Double?
        var consecutiveFailures = 0
        var lastFailure: LockFailure?
        /// Pocket evidence seen since the last reset (keypoint mouths, or dark mouths at the fitted pockets).
        var pocketEvidence = 0
        /// Centre of the pose the evidence belongs to: a pose elsewhere (another surface) starts the count over.
        var evidenceAnchor: SIMD3<Double>?
        var lastVisibleFraction: Double?
        var lastAuto: AutoTableEstimate?
    }

    /// Auto's raw estimate for the last ingested frame (dev HUD / tests).
    var lastAutoEstimate: AutoTableEstimate? { state.withLock { $0.lastAuto } }

    /// A lock needs this many frames with pocket evidence (Codex r5: a table-sized green rug must not lock).
    var minPocketEvidenceFrames = 3
    /// m: a candidate pose whose centre is this far from the one the evidence was gathered on is another surface
    /// (Codex autocal-r4: evidence from a real table must not authorise a lock after panning to a rug).
    var evidenceAnchorRadius = 0.3

    private let keypoints: (any TableKeypointProvider)?

    /// - keypoints: nil = the bundled tablekp model (`TableKeypointModel.provider()`); pass `NoKeypoints()` to
    ///   run classical-only.
    /// Counts mouth keypoints per call (pocket evidence must be mouths, not nose corners — Codex r6).
    private let mouthCounter: MouthCountingProvider?

    init(keypoints: (any TableKeypointProvider)? = nil) {
        let kp = keypoints ?? TableKeypointModel.provider()
        self.keypoints = kp is NoKeypoints ? nil : kp
        mouthCounter = self.keypoints.map { MouthCountingProvider(wrapping: $0) }
        auto = ClassicalAutoTableLocator(keypoints: mouthCounter)
    }

    func reset() async {
        auto.reset()
        state.withLock { $0 = State() }
    }

    /// Keypoint model inference time for the dev HUD (nil without the model).
    var keypointInferenceMs: Double? { (keypoints as? CoreMLTableKeypointProvider)?.lastInferenceMs }

    /// Head/foot swap is Auto's (default head = short rail nearer the camera at lock).
    func flipHeadFoot() { auto.flipHeadFoot() }

    func ingest(_ f: LocatorFrame) async -> TableEstimate? {
        // Expire stale history (codex-7): a gap means a different view; start fusion over.
        let gap = state.withLock { s -> Bool in
            defer { s.lastT = f.timestamp }
            guard let t = s.lastT else { return false }
            return f.timestamp - t > expireAfterGap
        }
        if gap { auto.reset(); state.withLock { $0.consecutiveFailures = 0; $0.pocketEvidence = 0; $0.evidenceAnchor = nil } }

        // Plane hint: an ARKit anchor (infinite plane at its height) or nothing — Auto then takes a provisional
        // plane from LiDAR. Either way the floor (> 1.4 m under the camera) is never the table.
        let hint = LocatorMath.plane(for: Vec2(f.camera.intrinsics.cx, f.camera.intrinsics.cy), camera: f.camera,
                                     planes: f.planes)
        if hint == nil, let d = f.depth, LocatorMath.depthLevelIsFloor(d, camera: f.camera) {
            return failing(.noPlane, seed: nil)
        }
        let img = f.image
        let k = f.camera.intrinsics.scaled(toWidth: Double(img.width), height: Double(img.height))
        let frame = AutoTableFrame(
            image: AutoRGBImage(width: img.width, height: img.height, rgb: img.rgb),
            intrinsics: AutoIntrinsics(fx: k.fx, fy: k.fy, cx: k.cx, cy: k.cy, width: k.width, height: k.height),
            cameraToWorld: f.camera.cameraToWorld,
            depth: f.depth.map { AutoDepthMap(width: $0.width, height: $0.height, depth: $0.depth, confidence: $0.confidence) },
            plane: hint.map { AutoPlaneHint(point: $0.point, normal: $0.normal) },
            timestamp: f.timestamp,
            tracking: f.trackingNormal ? .normal : .limited)
        mouthCounter?.beginFrame(timestamp: f.timestamp)   // this frame's count only; ≤ 10 Hz of frame time
        let e = auto.process(frame)
        let matched = e.pose.map { p in
            Self.matchedMouths(mouthCounter?.lastMouthPixels ?? [], pocketPixels: Self.pocketPixels(p, camera: f.camera, image: img),
                               tolerance: max(12, 0.04 * Double(img.width)))
        } ?? 0
        state.withLock { s in
            s.lastAuto = e
            // Evidence belongs to the candidate it was seen on: only mouths at *this* pose's pockets count, the
            // anchor is the pose where the streak began, and a candidate that moves past the radius from it (a jump
            // or a slow pan onto another surface) starts the count over. No candidate, no evidence.
            if let p = e.pose {
                if let a = s.evidenceAnchor, simd_distance(a, p.center) > evidenceAnchorRadius {
                    s.pocketEvidence = 0; s.evidenceAnchor = nil
                }
                if Self.hasPocketEvidence(e.frame, mouthKeypoints: matched) {
                    s.pocketEvidence += 1
                    if s.evidenceAnchor == nil { s.evidenceAnchor = p.center }
                }
            }
            s.lastVisibleFraction = e.frame.visibleLengthFraction
        }
        return map(e, frame: f, plane: hint)
    }

    /// The fused size is trusted unless its D12 estimate, (L + 2W)/2 of the free fits, sits well between the
    /// snapped preset and its neighbour (`SizeAmbiguity`, Codex r6).
    static func sizeIsTrusted(_ p: AutoTablePose) -> Bool {
        let est = (p.measuredLength + 2 * p.measuredWidth) / 2
        return !SizeAmbiguity.isAmbiguous(measuredLength: est, snapped: p.snappedSize)
    }

    /// The candidate's six pocket centres in working-image pixels (where the keypoint model's mouths land).
    static func pocketPixels(_ p: AutoTablePose, camera: CameraModel, image: PixelImage) -> [SIMD2<Double>] {
        let sx = Double(image.width) / camera.intrinsics.width, sy = Double(image.height) / camera.intrinsics.height
        return p.spec.pockets.compactMap { camera.project(p.world(p.spec.pocketCenter($0), height: 0)) }.map { SIMD2($0.x * sx, $0.y * sy) }
    }

    /// Mouth keypoints that sit on one of the candidate's pockets (each pocket counted once).
    static func matchedMouths(_ mouths: [SIMD2<Double>], pocketPixels: [SIMD2<Double>], tolerance: Double) -> Int {
        pocketPixels.filter { pk in mouths.contains { simd_distance($0, pk) <= tolerance } }.count
    }

    /// Pockets are what make a table a table: ≥ 2 keypoint mouths, or ≥ 4 fitted pocket positions that look dark.
    static func hasPocketEvidence(_ d: AutoFrameDiagnostics, mouthKeypoints: Int) -> Bool {
        if mouthKeypoints >= 2 { return true }
        return d.pocketScores.values.filter { $0 >= 0.5 }.count >= 4
    }

    private func map(_ e: AutoTableEstimate, frame f: LocatorFrame, plane: Plane3?) -> TableEstimate? {
        switch e.state {
        case .locked:
            guard let p = e.pose else { return nil }
            // No pocket evidence yet: hold the lock back (show the ghost, keep looking).
            let evidence = state.withLock { $0.pocketEvidence }
            guard evidence >= minPocketEvidenceFrames else {
                return TableEstimate(corners: p.corners, confidence: 0.9, locked: false, size: p.snappedSize,
                                     failure: .badShape, frame: nil, generation: e.generation)
            }
            // Size between two presets (a shadow or occluder edge stood in for a rail): wait for a second look.
            guard Self.sizeIsTrusted(p) else {
                return TableEstimate(corners: p.corners, confidence: 0.9, locked: false, size: nil,
                                     failure: .partialTable, frame: nil, generation: e.generation)
            }
            state.withLock { $0.consecutiveFailures = 0; $0.lastFailure = nil }
            let frame = TableFrame(tableToWorld: p.tableToWorld, spec: p.spec)
            return TableEstimate(corners: p.corners, confidence: 1, locked: true, size: p.snappedSize ?? p.spec.size,
                                 failure: nil, frame: frame, generation: e.generation)
        case .converging(let progress):
            guard let p = e.pose else { return nil }
            state.withLock { $0.consecutiveFailures = 0 }
            // Converging but not tight enough yet: tell the user to hold steady once it drags on.
            let why: LockFailure? = e.cornerSpread > 0.02 ? .unstable : nil
            return TableEstimate(corners: p.corners, confidence: min(0.95, progress), locked: false,
                                 size: p.snappedSize, failure: why, frame: nil, generation: e.generation)
        case .searching:
            let why = LockFailure.from(autoRejection: e.frame.rejection)
            let expire = state.withLock { s -> Bool in
                s.consecutiveFailures += 1
                s.lastFailure = why
                return s.consecutiveFailures >= expireAfterFailures
            }
            if expire { auto.reset(); state.withLock { $0.consecutiveFailures = 0; $0.pocketEvidence = 0; $0.evidenceAnchor = nil } }
            return failing(why, seed: ghost(f, plane: plane))
        }
    }

    private func failing(_ why: LockFailure, seed: [SIMD3<Double>]?) -> TableEstimate {
        TableEstimate(corners: seed ?? [], confidence: seed == nil ? 0 : 0.25, locked: false, size: nil, failure: why)
    }

    /// FeltQuad ghost seed: the felt boundary is the rail-cap edge, so intersect at rail-top height and inset by
    /// the cushion width (Auto's profile), not the cloth plane with a synthetic constant. Never a lock.
    private func ghost(_ f: LocatorFrame, plane: Plane3?) -> [SIMD3<Double>]? {
        guard let plane, let quad = FeltQuadProposer.analyze(f.image).quad else { return nil }
        let railTop = Plane3(point: plane.point + plane.normal * profile.railTopHeight, normal: plane.normal)
        let outer = quad.compactMap { f.camera.intersect(pixel: $0, with: railTop) }
        guard outer.count == 4 else { return nil }
        return TableFitter.insetQuad(outer, by: profile.cushionWidth).map { $0 - plane.normal * profile.railTopHeight }
    }
}

extension LockFailure {
    /// Auto's per-frame rejection strings (they *start with* the reason; a partial fit appends "(partial: …)")
    /// → the user-facing reason (icon only) and the HUD.
    static func from(autoRejection r: String?) -> LockFailure {
        guard let r else { return .unstable }
        // Partial view / too shallow: wait for a second look — hint "step back / pan" (user decision).
        if r.hasPrefix("cloth touches frame") || r.hasPrefix("view too shallow") || r.contains("(partial") { return .partialTable }
        // A rail edge that breaks 2:1 or a size midway between presets: wait for a second look.
        if r.hasPrefix("not 2:1") || r.hasPrefix("size ambiguous") { return .partialTable }
        if r.hasPrefix("cloth too small") || r.hasPrefix("too small") { return .tooFar }
        if r.hasPrefix("no plane") { return .noPlane }
        if r.hasPrefix("no cloth colour") { return .noFelt }
        if r.hasPrefix("tracking") || r.hasPrefix("duplicate frame") || r.hasPrefix("reset") { return .unstable }
        return .badShape   // no quad / edge refine / reprojection / fit / …
    }
}

/// Explicit "no keypoint model" (classical-only locator).
struct NoKeypoints: TableKeypointProvider {
    func keypoints(in image: AutoRGBImage, intrinsics: AutoIntrinsics) -> [AutoTableKeypoint] { [] }
}

/// The table-keypoint Core ML model (tablekp YOLO26n-pose, `TableKeypoints.mlpackage`), shared by every locator.
enum TableKeypointModel {
    static func provider() -> (any TableKeypointProvider)? { CoreMLTableKeypointProvider.shared }
}

/// Wraps the keypoint model: paces it at ≤ 10 Hz of *frame* time (not wall clock, so a replay or the VirtualTable
/// harness running faster than real time sees the same cadence as the phone) and remembers how many *mouth*
/// keypoints (corner/side pocket mouths) it returned on this frame.
final class MouthCountingProvider: TableKeypointProvider, @unchecked Sendable {
    private let inner: any TableKeypointProvider
    private let state = Mutex((mouths: 0, pixels: [SIMD2<Double>](), due: true, lastRun: Double?.none))
    /// Seconds of frame time between model runs (≤ 10 Hz on the ANE).
    var minInterval = 0.1
    init(wrapping inner: any TableKeypointProvider) { self.inner = inner }

    var lastMouths: Int { state.withLock { $0.mouths } }
    /// This frame's confident mouth keypoints (working-image pixels).
    var lastMouthPixels: [SIMD2<Double>] { state.withLock { $0.pixels } }
    /// Call before each locator frame: resets the count (a frame that skips inference reports 0, not the previous
    /// count) and decides whether the model is due on this frame. A timestamp going backwards (new view) runs.
    func beginFrame(timestamp t: Double) {
        state.withLock { s in
            s.mouths = 0; s.pixels = []
            if let l = s.lastRun, t >= l, t - l < minInterval * 0.9 { s.due = false } else { s.due = true; s.lastRun = t }
        }
    }

    func keypoints(in image: AutoRGBImage, intrinsics: AutoIntrinsics) -> [AutoTableKeypoint] {
        // Once per due frame: Auto may ask more than once per frame.
        guard state.withLock({ s -> Bool in defer { s.due = false }; return s.due }) else { return [] }
        let k = inner.keypoints(in: image, intrinsics: intrinsics)
        let px = k.filter { ($0.kind == .cornerMouth || $0.kind == .sideMouth) && $0.confidence >= 0.5 }.map(\.pixel)
        state.withLock { $0.mouths = px.count; $0.pixels = px }
        return k
    }

    static func mouths(in k: [AutoTableKeypoint], minConfidence: Double = 0.5) -> Int {
        k.filter { ($0.kind == .cornerMouth || $0.kind == .sideMouth) && $0.confidence >= minConfidence }.count
    }
}

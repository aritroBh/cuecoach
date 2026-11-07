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
    }

    init(keypoints: (any TableKeypointProvider)? = nil) {
        auto = ClassicalAutoTableLocator(keypoints: keypoints ?? TableKeypointModel.provider())
    }

    func reset() async {
        auto.reset()
        state.withLock { $0 = State() }
    }

    /// Head/foot swap is Auto's (default head = short rail nearer the camera at lock).
    func flipHeadFoot() { auto.flipHeadFoot() }

    func ingest(_ f: LocatorFrame) async -> TableEstimate? {
        // Expire stale history (codex-7): a gap means a different view; start fusion over.
        let gap = state.withLock { s -> Bool in
            defer { s.lastT = f.timestamp }
            guard let t = s.lastT else { return false }
            return f.timestamp - t > expireAfterGap
        }
        if gap { auto.reset(); state.withLock { $0.consecutiveFailures = 0 } }

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
        let e = auto.process(frame)
        return map(e, frame: f, plane: hint)
    }

    private func map(_ e: AutoTableEstimate, frame f: LocatorFrame, plane: Plane3?) -> TableEstimate? {
        switch e.state {
        case .locked:
            guard let p = e.pose else { return nil }
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
            if expire { auto.reset(); state.withLock { $0.consecutiveFailures = 0 } }
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
    /// Auto's per-frame rejection strings → the user-facing reason (icon only) and the HUD.
    static func from(autoRejection r: String?) -> LockFailure {
        switch r {
        case "cloth touches frame": .partialTable
        case "cloth too small", "too small": .tooFar
        case "no plane": .noPlane
        case "no cloth colour": .noFelt
        case nil: .unstable
        default: .badShape   // no rails / parallel rails / reprojection / no quad / edge refine / fit / …
        }
    }
}

/// Seam for the table-keypoint Core ML model (tablekp YOLO-pose). Returns nil until the .mlpackage is bundled;
/// then a provider is created here and every AutoTableLocating gets it.
enum TableKeypointModel {
    static func provider() -> (any TableKeypointProvider)? { nil }
}

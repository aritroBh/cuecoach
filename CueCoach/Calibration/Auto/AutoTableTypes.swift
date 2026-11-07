import Foundation
import Geometry
import simd

// Automatic table locating (SPEC §5.1, D12/D19/D20): the phone finds the table in the live AR video
// with zero taps. Everything here is self-contained (prefixed `Auto…`) so it merges next to the
// capture module's CameraModel / TableFrame without name clashes.
//
// World space = ARKit world: gravity-aligned, metres, +y up. Camera space = ARKit camera: x right,
// y up, looks down −z, in the captured image's native (landscape) orientation.
// Image pixel coordinates: pixel (i, j) has its centre at (i, j) (OpenCV convention), v grows down.

/// Interleaved RGB8 image (3 bytes per pixel). Same layout as the capture module's `PixelImage.rgb`.
struct AutoRGBImage: Sendable {
    var width: Int
    var height: Int
    var rgb: [UInt8]

    init(width: Int, height: Int, rgb: [UInt8]) {
        precondition(rgb.count == width * height * 3, "AutoRGBImage: buffer size mismatch")
        self.width = width; self.height = height; self.rgb = rgb
    }
}

/// Pinhole intrinsics in pixels of the image they are used with.
struct AutoIntrinsics: Hashable, Sendable {
    var fx: Double, fy: Double, cx: Double, cy: Double
    var width: Double, height: Double

    /// Same camera at another resolution (e.g. ARKit 1920×1440 intrinsics → a 960×720 working image).
    /// Pixel centres sit at integers, so a coordinate maps as (x + 0.5)·s − 0.5.
    func scaled(toWidth w: Double, height h: Double) -> AutoIntrinsics {
        let sx = w / width, sy = h / height
        return AutoIntrinsics(fx: fx * sx, fy: fy * sy, cx: (cx + 0.5) * sx - 0.5, cy: (cy + 0.5) * sy - 0.5,
                              width: w, height: h)
    }
}

/// LiDAR scene depth (ARKit `sceneDepth`), pixel-aligned with the colour image (same field of view).
struct AutoDepthMap: Sendable {
    var width: Int
    var height: Int
    /// Metres along the camera's viewing axis.
    var depth: [Float]
    /// ARKit `ARConfidenceLevel` raw values (0 low, 1 medium, 2 high); nil = all trusted.
    var confidence: [UInt8]?
}

/// A detected horizontal plane (ARKit `ARPlaneAnchor` or raycast hit). Usually the cloth.
struct AutoPlaneHint: Sendable {
    var point: SIMD3<Double>
    var normal: SIMD3<Double> = SIMD3(0, 1, 0)
}

/// ARKit `camera.trackingState`, flattened. Only `.normal` frames are used.
enum AutoTrackingState: Sendable, Equatable {
    case normal, limited, notAvailable
}

/// One AR frame handed to the locator.
struct AutoTableFrame: Sendable {
    var image: AutoRGBImage
    /// Intrinsics for `image` (scale ARKit's to the working resolution).
    var intrinsics: AutoIntrinsics
    /// ARKit `camera.transform`.
    var cameraToWorld: simd_double4x4
    var depth: AutoDepthMap?
    var plane: AutoPlaneHint?
    /// ARKit frame timestamp (s). A frame with the same timestamp as the previous one is a duplicate.
    var timestamp: Double
    var tracking: AutoTrackingState = .normal
}

/// Physical cushion/rail model. Defaults are typical commercial tables (est.); the nose-to-nose
/// playing surface still snaps to the WPA presets, and opposite-rail errors cancel in the fixed-size refit.
struct AutoTableProfile: Hashable, Sendable {
    /// Horizontal distance from the cushion nose to the felt/wood boundary on the rail cap (m).
    var cushionWidth: Double = 0.0508
    /// Height of the felt/wood boundary above the bed cloth (m).
    var railTopHeight: Double = 0.045
    /// Cushion nose height above the cloth (WPA 1 7/16" ≈ 36.5 mm).
    var noseHeight: Double = 0.0365
    /// tablekp corner-mouth label offset from the nose corner along each table axis: half its 4.5" mouth (m).
    var cornerMouthInset: Double = 0.05715
}

// MARK: - Keypoint model plug-in (Core ML YOLO-pose, trained in .worktrees/tablekp)

/// What a table keypoint marks — the tablekp YOLO-pose model's three label groups
/// (tools/tablekp/generate_dataset.py `KEYPOINT_NAMES`; see `AutoTableKeypointModel` for the index order).
/// The model labels a planar table texture whose rectangle is the nose lines, so all three kinds are
/// lifted at cushion-nose height. Each group is unordered (no head/foot); the fit matches by geometry.
/// - `noseCorner`: where the two cushion-nose lines meet (Geometry `pocketCenter` of a corner pocket).
/// - `sideMouth`: the long-rail nose line at its midpoint (side-pocket mouth centre).
/// - `cornerMouth`: corner-pocket mouth centre, inset `AutoTableProfile.cornerMouthInset` along both
///   table axes from the nose corner into the bed (generate_dataset.py:170-179).
enum AutoKeypointKind: String, Sendable, CaseIterable {
    case cornerMouth, sideMouth, noseCorner
}

struct AutoTableKeypoint: Sendable {
    var kind: AutoKeypointKind
    /// Pixel in the frame's image (centre-of-pixel = integer convention).
    var pixel: SIMD2<Double>
    /// 0…1 model confidence.
    var confidence: Double
}

/// Plugs a learned detector into the locator. Called synchronously on the locator's thread.
protocol TableKeypointProvider: Sendable {
    func keypoints(in image: AutoRGBImage, intrinsics: AutoIntrinsics) -> [AutoTableKeypoint]
}

// MARK: - Output

/// Locked = the fused corners have been stable (< `lockCornerSpread`) for `lockFrames` frames.
enum AutoLockState: Sendable, Equatable {
    case searching
    case converging(progress: Double)
    case locked
}

/// The table rigidly placed in world space. Table coords (Geometry): head x = 0 → foot x = length,
/// y across ("left" rail y = 0), z up. `tableToWorld` uses the capture module's TableFrame convention
/// (columns: x axis, y = up × x, up, origin at the head-left nose corner, cloth height).
struct AutoTablePose: Sendable {
    var tableToWorld: simd_double4x4
    var spec: TableSpec
    /// Preset the measurement snapped to; nil = measured 2:1 size used directly (D12).
    var snappedSize: TableSize?
    /// Nose-to-nose size from the free fit before snapping (m).
    var measuredLength: Double
    var measuredWidth: Double

    var up: SIMD3<Double> { SIMD3(tableToWorld.columns.2.x, tableToWorld.columns.2.y, tableToWorld.columns.2.z) }
    var xAxis: SIMD3<Double> { SIMD3(tableToWorld.columns.0.x, tableToWorld.columns.0.y, tableToWorld.columns.0.z) }

    func world(_ p: Vec2, height: Double = 0) -> SIMD3<Double> {
        let w = tableToWorld * SIMD4(p.x, p.y, height, 1)
        return SIMD3(w.x, w.y, w.z)
    }

    /// Centre of the playing surface at cloth height.
    var center: SIMD3<Double> { world(Vec2(spec.length / 2, spec.width / 2)) }
    /// Heading of +x (head → foot) about world +y, radians: atan2(−x.z, x.x).
    var yaw: Double { atan2(-xAxis.z, xAxis.x) }

    /// Nose corners at cloth height: headLeft, headRight, footRight, footLeft (TableFrame.corners order).
    var corners: [SIMD3<Double>] {
        [Vec2(0, 0), Vec2(0, spec.width), Vec2(spec.length, spec.width), Vec2(spec.length, 0)].map { world($0) }
    }

    /// The six pocket capture points (Geometry `pocketCenter`) at cloth height.
    var pockets: [Pocket: SIMD3<Double>] {
        var out: [Pocket: SIMD3<Double>] = [:]
        for p in Pocket.allCases { out[p] = world(spec.pocketCenter(p)) }
        return out
    }
}

/// Per-frame detector output, for the debug HUD.
struct AutoFrameDiagnostics: Sendable {
    enum Path: Sendable, Equatable { case full, tracked, keypointsOnly, none }
    var path: Path = .none
    /// Outer felt boundary lines in image pixels (a, b, c with a·u + b·v + c = 0, a² + b² = 1).
    var railLines: [SIMD3<Double>] = []
    /// Intersections of consecutive rail lines (outer felt corners), image pixels.
    var outerCorners: [SIMD2<Double>] = []
    /// This frame's own fit: RMS pixel distance of edge inliers to the re-projected rectangle.
    var reprojectionRMS: Double = .infinity
    /// Accepted sub-pixel edge samples / attempted samples.
    var inlierFraction: Double = 0
    /// 0…1 darkness evidence at each pocket position of this frame's fit.
    var pocketScores: [Pocket: Double] = [:]
    var keypointsUsed: Int = 0
    /// Cloth height refined from LiDAR (world y of the bed), if depth was used.
    var lidarClothHeight: Double?
    /// Rail-cap height above the cloth used for this frame (profile default or the LiDAR median).
    var railTopHeight: Double?
    /// Partial-view fit: fraction of the playing length seen (nil = whole table in view).
    var visibleLengthFraction: Double?
    var processingSeconds: Double = 0
    var rejection: String?
}

struct AutoTableEstimate: Sendable {
    var state: AutoLockState
    /// Fused world pose (nil while searching).
    var pose: AutoTablePose?
    /// 0…1 overall quality for the HUD (fusion stability × reprojection × pocket evidence).
    var confidence: Double
    /// Robust spread of the recent per-frame corners around the fused corners (m).
    var cornerSpread: Double
    /// This frame's edges against the FUSED pose, RMS pixels (validation while running).
    var fusedReprojectionRMS: Double?
    /// Increments every time a new lock is made (first lock = 1). A re-lock after the table or
    /// tracking changed bumps it, and so does a size change > `sizeChangeTolerance` while locked (the size
    /// is otherwise held); integrators rebuild their overlay when it changes.
    var generation: Int
    var frame: AutoFrameDiagnostics
}

/// Integration point for the AR screen: feed every (or every n-th) AR frame; read the estimate.
protocol AutoTableLocator: AnyObject, Sendable {
    /// Process one frame and return the updated fused estimate. Thread-safe; call off the main thread.
    func process(_ frame: AutoTableFrame) -> AutoTableEstimate
    /// Latest estimate without processing.
    var latest: AutoTableEstimate? { get }
    /// Swap head and foot (default head = the short rail nearer the camera at lock time).
    func flipHeadFoot()
    /// Forget everything and search again.
    func reset()
}

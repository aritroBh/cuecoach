import Foundation
import Geometry

/// Coarse ball class from the v0 colour classifier. Tentative: the tracker smooths it, ML replaces it.
enum BallKind: String, Sendable, Codable, CaseIterable {
    case cue, eight, solid, stripe, unknown
}

struct BallDetection: Sendable, Equatable {
    /// Ball centre in source-image pixels.
    var imagePoint: Vec2
    /// Ball centre on the table (ball-centre plane), metres.
    var tablePoint: Vec2
    /// Apparent radius in source pixels.
    var radiusPx: Double
    var confidence: Double
    var kind: BallKind
    /// Best-effort number guess (1–15) from hue + stripe; nil when unsure.
    var tentativeNumber: Int?
    /// 0…1: the detector's evidence that this is the cue ball (whiteness × sphere shading for the classical
    /// detector; the cue-class score for a trained one). nil = no opinion (non-cue classes, depth-only balls).
    var cueScore: Double? = nil
}

/// Swappable detector: `HybridBallDetector` (trained Core ML model + classical fallback) ships; the classical v0
/// detector alone is the fallback and the test default.
protocol BallDetector: Sendable {
    func detect(in image: PixelImage, geometry: FrameGeometry) -> [BallDetection]
    /// Detect with the cloth colour captured at lock, for white balance under changed light.
    func detect(in image: PixelImage, geometry: FrameGeometry, feltReference: (UInt8, UInt8, UInt8)?) -> [BallDetection]
    /// The pipeline's call: also passes the frame time, so a learned detector can pace itself on frame time.
    func detect(in image: PixelImage, geometry: FrameGeometry, feltReference: (UInt8, UInt8, UInt8)?,
                timestamp: Double) -> [BallDetection]
    /// This frame's cloth colour (captured once after lock as the reference); nil when not supported.
    func feltColor(in image: PixelImage, geometry: FrameGeometry) -> (UInt8, UInt8, UInt8)?
    /// Without LiDAR, white/unknown blobs from this detector must show sphere shading to be kept
    /// (true for the classical colour detector; a learned detector or a replay vouches for its own output).
    var needsShadingCheck: Bool { get }
}

extension BallDetector {
    func detect(in image: PixelImage, geometry: FrameGeometry, feltReference: (UInt8, UInt8, UInt8)?) -> [BallDetection] {
        detect(in: image, geometry: geometry)
    }
    func detect(in image: PixelImage, geometry: FrameGeometry, feltReference: (UInt8, UInt8, UInt8)?,
                timestamp: Double) -> [BallDetection] {
        detect(in: image, geometry: geometry, feltReference: feltReference)
    }
    func feltColor(in image: PixelImage, geometry: FrameGeometry) -> (UInt8, UInt8, UInt8)? { nil }
    var needsShadingCheck: Bool { false }
}

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
}

/// Swappable detector (classical v0 now, Core ML later).
protocol BallDetector: Sendable {
    func detect(in image: PixelImage, geometry: FrameGeometry) -> [BallDetection]
    /// Detect with the cloth colour captured at lock, for white balance under changed light.
    func detect(in image: PixelImage, geometry: FrameGeometry, feltReference: (UInt8, UInt8, UInt8)?) -> [BallDetection]
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
    func feltColor(in image: PixelImage, geometry: FrameGeometry) -> (UInt8, UInt8, UInt8)? { nil }
    var needsShadingCheck: Bool { false }
}

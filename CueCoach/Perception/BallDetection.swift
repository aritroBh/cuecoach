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
}

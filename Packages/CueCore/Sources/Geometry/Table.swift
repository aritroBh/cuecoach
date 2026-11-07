/// Table size presets. Playing surface (cushion nose to cushion nose), 2:1 ratio.
/// Sources: WPA Equipment Specifications (9 ft = 100" x 50"); common 8 ft = 88" x 44", 7 ft bar box = 78" x 39".
public enum TableSize: String, CaseIterable, Codable, Sendable {
    case sevenFoot, eightFoot, nineFoot

    /// Playing-surface length in metres.
    public var playingLength: Double {
        switch self {
        case .sevenFoot: 78 * 0.0254
        case .eightFoot: 88 * 0.0254
        case .nineFoot: 100 * 0.0254
        }
    }
}

public enum Pocket: String, CaseIterable, Codable, Sendable {
    case footLeft, footRight, sideLeft, sideRight, headLeft, headRight
    public var isSide: Bool { self == .sideLeft || self == .sideRight }
}

/// Fixed table geometry. Coordinates in metres, origin at the foot-left cushion-nose corner.
/// "Left" = y = 0 rail, "right" = y = width rail.
public struct TableSpec: Hashable, Codable, Sendable {
    /// Standard ball, 2 1/4" (57.15 mm).
    public static let ballRadius: Double = 0.057150 / 2

    public var size: TableSize
    public var length: Double
    public var width: Double
    /// Pocket mouth widths (WPA: corner 4.5"–4.625", side 5"–5.125").
    public var cornerMouth: Double = 4.5 * 0.0254
    public var sideMouth: Double = 5.0 * 0.0254

    public init(size: TableSize) {
        self.size = size
        self.length = size.playingLength
        self.width = size.playingLength / 2
    }

    public var pockets: [Pocket] { Pocket.allCases }

    /// Capture point of each pocket: the point where the cushion-nose lines meet (corners)
    /// or the midpoint of the long rail (sides).
    public func pocketCenter(_ p: Pocket) -> Vec2 {
        switch p {
        case .footLeft: Vec2(0, 0)
        case .footRight: Vec2(0, width)
        case .sideLeft: Vec2(length / 2, 0)
        case .sideRight: Vec2(length / 2, width)
        case .headLeft: Vec2(length, 0)
        case .headRight: Vec2(length, width)
        }
    }

    public var footSpot: Vec2 { Vec2(length * 0.75, width / 2) }
    public var headSpot: Vec2 { Vec2(length * 0.25, width / 2) }
    /// Head string: line through the head spot, parallel to the head rail (kitchen = x > headString... see headStringX).
    public var headStringX: Double { length * 0.25 }
}

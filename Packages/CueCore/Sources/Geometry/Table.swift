/// Table size presets. Playing surface (cushion nose to cushion nose), 2:1 ratio.
/// Sources: WPA Recommended Equipment Specifications §5 (9 ft = 100" x 50", 8 ft = 92" x 46"),
/// https://wpapool.com/wp-content/uploads/2024/01/RECOMMENDED-EQUIPMENT-SPECIFICATIONS.pdf
/// 7 ft is not WPA-defined; Diamond Billiards 7 ft = 80" x 40" (https://diamondbilliards.com/pages/smart).
/// Coin-op "7 ft" bar boxes vary — LiDAR measurement (Calibration) can override the preset.
/// D46: Pro 8 (oversized 8 ft) = 88" x 44"; 86" = 86" x 43". Declared in length order (pickers iterate `allCases`).
/// Raw values are persisted and sent over the mesh; never rename them.
public enum TableSize: String, CaseIterable, Codable, Sendable {
    case sevenFoot, eightySixInch, proEight, eightFoot, nineFoot

    /// Playing-surface length in metres.
    public var playingLength: Double {
        switch self {
        case .sevenFoot: 80 * 0.0254
        case .eightySixInch: 86 * 0.0254
        case .proEight: 88 * 0.0254
        case .eightFoot: 92 * 0.0254
        case .nineFoot: 100 * 0.0254
        }
    }

    /// D50: the presets auto-calibration may snap to. With no size picked only 7/8/9 ft; a picked Pro 8 or 86″
    /// (the lock prior) joins them. Length order.
    public static func autoSnapCandidates(prior: TableSize?) -> [TableSize] {
        let standard: [TableSize] = [.sevenFoot, .eightFoot, .nineFoot]
        guard let prior, !standard.contains(prior) else { return standard }
        return allCases.filter { standard.contains($0) || $0 == prior }
    }
}

public enum Pocket: String, CaseIterable, Codable, Sendable {
    case footLeft, footRight, sideLeft, sideRight, headLeft, headRight
    public var isSide: Bool { self == .sideLeft || self == .sideRight }
}

/// Fixed table geometry. Coordinates in metres, origin at the head-left cushion-nose corner,
/// +x along the long axis toward the foot rail. "Left" = y = 0 rail, "right" = y = width rail.
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
        // Head end (head spot, kitchen) is x = 0; foot end (foot spot, rack) is x = length.
        case .headLeft: Vec2(0, 0)
        case .headRight: Vec2(0, width)
        case .sideLeft: Vec2(length / 2, 0)
        case .sideRight: Vec2(length / 2, width)
        case .footLeft: Vec2(length, 0)
        case .footRight: Vec2(length, width)
        }
    }

    public var footSpot: Vec2 { Vec2(length * 0.75, width / 2) }
    public var headSpot: Vec2 { Vec2(length * 0.25, width / 2) }
    /// Head string: line through the head spot, parallel to the head rail (kitchen = x < headStringX, the head end at x = 0).
    public var headStringX: Double { length * 0.25 }
}

extension TableSpec {
    /// Accepted length:width range. Tables are 2:1 nominal; LiDAR-measured specs may be a little off.
    public static let aspectRange: ClosedRange<Double> = 1.8...2.2

    /// Positive, finite dimensions, roughly 2:1, with pocket mouths a ball fits through and narrower than the table.
    public var isValid: Bool {
        let dims = [length, width, cornerMouth, sideMouth]
        guard dims.allSatisfy({ $0.isFinite && $0 > 0 }) else { return false }
        guard Self.aspectRange.contains(length / width) else { return false }
        let ball = 2 * Self.ballRadius
        return cornerMouth > ball && sideMouth > ball && cornerMouth < width && sideMouth < width
    }

    private enum CodingKeys: String, CodingKey { case size, length, width, cornerMouth, sideMouth }

    /// Decoding validates the spec (peer / persisted payloads are untrusted). All five keys are required.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(size: try c.decode(TableSize.self, forKey: .size))
        length = try c.decode(Double.self, forKey: .length)
        width = try c.decode(Double.self, forKey: .width)
        cornerMouth = try c.decode(Double.self, forKey: .cornerMouth)
        sideMouth = try c.decode(Double.self, forKey: .sideMouth)
        guard isValid else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Invalid TableSpec dimensions: \(self)"))
        }
    }
}

import Geometry

/// Chess.com-style shot classes, best → worst (D18; criteria in docs/RATINGS.md).
/// Raw values are persisted — never rename a case.
public enum DecisionRating: String, CaseIterable, Codable, Sendable {
    case brilliant, great, best, good, okay, book, inaccuracy, miss, mistake, blunder

    /// Highlighted classes that require a successfully executed shot.
    public var isSpecial: Bool { self == .brilliant || self == .great }
    /// Classes that cost the shooter's team.
    public var isNegative: Bool { [.inaccuracy, .miss, .mistake, .blunder].contains(self) }
}

public enum ExecutionResult: String, CaseIterable, Codable, Sendable {
    case made, nearMiss, miss
}

public enum PositionResult: String, Codable, Sendable {
    case inZone, outOfZone, notApplicable
}

public struct ExecutionRating: Hashable, Codable, Sendable {
    public var result: ExecutionResult
    public var position: PositionResult
    public init(result: ExecutionResult, position: PositionResult) {
        self.result = result
        self.position = position
    }
}

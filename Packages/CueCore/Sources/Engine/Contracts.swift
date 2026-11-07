import Geometry

public enum DecisionRating: String, CaseIterable, Codable, Sendable {
    case brilliant, great, best, good, inaccuracy, mistake, blunder
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

public enum LevelPolicyError: Error, Equatable, Sendable {
    case windowTooSmall, thresholdOutOfRange, noHysteresis
}

public enum LevelChange: Equatable, Sendable, Codable {
    case promoted(to: AssistLevel)   // less assist
    case demoted(to: AssistLevel)    // more assist
}

/// Rolling attempt history at the current level of one drill.
public struct LevelProgress: Equatable, Sendable, Codable {
    public private(set) var level: AssistLevel
    /// Most recent attempts at `level`, oldest first. Cleared on every level change.
    public private(set) var recent: [Bool]

    public init(level: AssistLevel = .full) { self.level = level; self.recent = [] }

    public var successRate: Double? {
        recent.isEmpty ? nil : Double(recent.filter { $0 }.count) / Double(recent.count)
    }

    fileprivate mutating func append(_ s: Bool, window: Int) {
        recent.append(s)
        if recent.count > window { recent.removeFirst(recent.count - window) }
    }
    fileprivate mutating func move(to l: AssistLevel) { level = l; recent = [] }
}

/// "Level up on rolling success over N attempts" (SPEC §10).
/// Decisions are made only on a full window. Promote when the success rate is ≥ `promoteAt`,
/// demote when ≤ `demoteAt`; `demoteAt < promoteAt` is the hysteresis band. The window is
/// cleared on every change so a player can't bounce back on the same attempts.
public struct LevelPolicy: Equatable, Sendable, Codable {
    public let window: Int
    public let promoteAt: Double
    public let demoteAt: Double

    public static let standard = try! LevelPolicy(window: 10, promoteAt: 0.8, demoteAt: 0.4)

    public init(window: Int, promoteAt: Double, demoteAt: Double) throws(LevelPolicyError) {
        guard window >= 1 else { throw .windowTooSmall }
        guard (0...1).contains(promoteAt), (0...1).contains(demoteAt) else { throw .thresholdOutOfRange }
        guard demoteAt < promoteAt else { throw .noHysteresis }
        self.window = window; self.promoteAt = promoteAt; self.demoteAt = demoteAt
    }

    private enum CodingKeys: String, CodingKey { case window, promoteAt, demoteAt }

    /// Decoding validates like `init` (stored data can't remove the hysteresis).
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(window: c.decode(Int.self, forKey: .window),
                          promoteAt: c.decode(Double.self, forKey: .promoteAt),
                          demoteAt: c.decode(Double.self, forKey: .demoteAt))
        } catch let e as LevelPolicyError {
            throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath, debugDescription: "\(e)"))
        }
    }

    /// Records one attempt; returns the level change it caused, if any.
    public func record(success: Bool, into p: inout LevelProgress) -> LevelChange? {
        p.append(success, window: window)
        guard p.recent.count == window, let rate = p.successRate else { return nil }
        // Small epsilon so 8/10 counts as exactly 0.8 despite floating point.
        let eps = 1e-9
        if rate + eps >= promoteAt, let up = p.level.harder {
            p.move(to: up); return .promoted(to: up)
        }
        if rate - eps <= demoteAt, let down = p.level.easier {
            p.move(to: down); return .demoted(to: down)
        }
        return nil
    }
}

/// Per-drill levels for one player. Stored only in the Training store (SPEC §4, §10).
public struct TrainingProgress: Equatable, Sendable, Codable {
    public private(set) var drills: [DrillID: LevelProgress] = [:]
    public init() {}

    public func level(for d: DrillID) -> AssistLevel { drills[d]?.level ?? .full }

    public mutating func record(drill d: DrillID, success: Bool, policy: LevelPolicy = .standard) -> LevelChange? {
        var p = drills[d] ?? LevelProgress()
        let c = policy.record(success: success, into: &p)
        drills[d] = p
        return c
    }
}

import Foundation
import Geometry
import Rules

/// One island's view of one shot (mesh-identity.md §2.5 `IslandShot`).
public struct IslandShot: Hashable, Sendable {
    public var id: UUID
    /// Stroke start on the game clock, seconds.
    public var strokeTime: Double
    /// Ball positions before the shot, table metres. Empty = unknown: time alone aligns.
    public var preState: [BallID: Vec2]
    public var outcome: ShotOutcome
    /// Higher wins a disagreement; ties go to the smaller id.
    public var confidence: Double

    public init(id: UUID, strokeTime: Double, preState: [BallID: Vec2], outcome: ShotOutcome, confidence: Double) {
        self.id = id; self.strokeTime = strokeTime; self.preState = preState; self.outcome = outcome
        self.confidence = confidence
    }
}

/// One physical shot after a merge.
public struct MergedShot: Hashable, Sendable {
    /// The kept view.
    public var shot: IslandShot
    /// The views disagreed on the outcome: D47 asks one tap (plan 013b).
    public var needsTap: Bool
    /// Every view folded into it, sorted.
    public var members: [UUID]

    public init(shot: IslandShot, needsTap: Bool, members: [UUID]) {
        self.shot = shot; self.needsTap = needsTap; self.members = members
    }
}

/// Deterministic merge of island shot tails after a heal (§2.5 item 3).
public enum IslandMerge {
    public static let timeTolerance = 0.5

    public static func aligned(_ a: IslandShot, _ b: IslandShot, ballRadius: Double = TableSpec.ballRadius) -> Bool {
        false
    }

    public static func merge(_ islands: [[IslandShot]], ballRadius: Double = TableSpec.ballRadius) -> [MergedShot] {
        []
    }
}

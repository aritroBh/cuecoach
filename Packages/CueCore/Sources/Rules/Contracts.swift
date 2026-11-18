import Geometry

// Shared contracts (docs/INTERFACES.md). Owned by the head orchestrator — workers extend, never rename.

public enum RuleSetID: String, CaseIterable, Codable, Sendable {
    /// 8-ball bar / slop rules (default; docs/RULES.md B1–B25).
    case barEight
    /// 8-ball, WPA Rules of Play eff. 2026-10-21.
    case wpaEight
    /// 9-ball, WPA Rules of Play eff. 2026-10-21 + house break rule D13.
    case wpaNine

    public static let `default` = RuleSetID.barEight
}

public enum GameFormat: String, CaseIterable, Codable, Sendable {
    case oneVsOne, twoVsTwo, threeVsThree, fourVsFour
    public var playersPerTeam: Int {
        switch self { case .oneVsOne: 1; case .twoVsTwo: 2; case .threeVsThree: 3; case .fourVsFour: 4 }
    }
}

public enum Foul: Hashable, Codable, Sendable {
    case scratch
    case cueBallOffTable
    case noContact
    case wrongBallFirst(BallID)
    case noRailAfterContact
    case objectBallOffTable(BallID)
    case illegalBreak
    case badCueBallPlacement
    /// WPA 3.11: cue ball in hand above the head string, first contact also above it without crossing first.
    case badPlayFromAboveHeadString
}

public enum BallInHand: String, Codable, Sendable {
    case none, anywhere, behindHeadString
}

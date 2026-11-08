/// Solo Training drills (SPEC §10). Order is the catalogue order shown in the Training screen.
public enum DrillID: String, Codable, Sendable, CaseIterable, Hashable {
    case straightIn, increasingCuts, long, rail, sidePocket, positionPlay, spinControl, banks

    /// Position play draws a glowing target zone for the cue ball.
    public var hasPositionZone: Bool { self == .positionPlay }

    /// The tendencies the feedback engine watches in this drill. Axes the drill
    /// does not exercise are excluded so they never produce noise-driven advice.
    public var trackedAxes: Set<BiasAxis> {
        switch self {
        case .straightIn:     [.side, .speed]
        case .increasingCuts: [.cut, .side, .speed]
        case .long:           [.cut, .side, .speed]
        case .rail:           [.cut, .side, .speed]
        case .sidePocket:     [.cut, .side, .speed]
        case .positionPlay:   [.cut, .speed, .cueBallDistance]
        case .spinControl:    [.speed, .cueBallDistance, .spin]
        case .banks:          [.side, .speed]
        }
    }
}

/// One element of the live aim overlay (SPEC §5.6).
public enum OverlayElement: String, Codable, Sendable, CaseIterable, Hashable {
    case liveAimLine          // follows the real cue stick
    case cueToGhostLine       // line 1
    case ghostBall            // ghost circle at contact
    case objectToPocketLine   // line 2
    case cueAfterContactLine  // line 3 (dashed)
    case spinDot
    case powerMeter
    case positionZone         // position-play target glow
}

/// Training assist levels (SPEC §10, D1). Higher = less help.
/// 1 all lines + spin + power · 2 object→pocket only · 3 ghost circle only · 4 nothing (reveal after).
public enum AssistLevel: Int, Codable, Sendable, CaseIterable, Comparable, Hashable {
    case full = 1, objectLineOnly = 2, ghostOnly = 3, none = 4

    public static func < (a: AssistLevel, b: AssistLevel) -> Bool { a.rawValue < b.rawValue }

    /// The suggested shot is "always available in Training" at levels 1–3 only (D1).
    public var showsSuggestedShot: Bool { self != .none }

    /// What may be drawn while the player is aiming. Level 4 draws nothing at all (D1),
    /// including the position-play zone.
    public func visibleWhileAiming(in drill: DrillID) -> Set<OverlayElement> {
        var e: Set<OverlayElement>
        switch self {
        case .full: e = [.liveAimLine, .cueToGhostLine, .ghostBall, .objectToPocketLine,
                         .cueAfterContactLine, .spinDot, .powerMeter]
        case .objectLineOnly: e = [.objectToPocketLine]
        case .ghostOnly: e = [.ghostBall]
        case .none: return []
        }
        if drill.hasPositionZone { e.insert(.positionZone) }
        return e
    }

    /// After the balls settle, every level reveals the full overlay so the player can compare.
    public func visibleAfterShot(in drill: DrillID) -> Set<OverlayElement> {
        AssistLevel.full.visibleWhileAiming(in: drill)
    }

    /// One level less assist, or nil at level 4.
    public var harder: AssistLevel? { AssistLevel(rawValue: rawValue + 1) }
    /// One level more assist, or nil at level 1.
    public var easier: AssistLevel? { AssistLevel(rawValue: rawValue - 1) }
}

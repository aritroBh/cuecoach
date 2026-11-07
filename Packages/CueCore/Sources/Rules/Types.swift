import Geometry

/// What happened on one shot, as observed by the tracker or produced from a physics `ShotTrace`.
///
/// Optional fields: `nil` means "not observed". Per WPA Playing Regulation 25 ("If the referee cannot
/// determine whether an athlete fouled, the shot will be considered legal"), a `nil` never creates a foul.
/// The current `GameState.phase` (not `isBreak`) decides whether a shot is a break.
public struct ShotOutcome: Hashable, Codable, Sendable {
    /// Informational; `GameState.phase == .breakShot` is authoritative.
    public var isBreak: Bool
    /// First ball the cue ball touched. Ties are resolved by the tracker in the shooter's favour (WPA 3.2).
    public var firstContact: BallID?
    /// `true` only when the tracker positively saw the cue ball touch no object ball.
    public var noContact: Bool
    /// Balls at rest in a pocket (WPA 2.2). May include `.cue` (scratch).
    public var pocketed: [BallID: Pocket]
    /// Order the balls dropped, if known (used to decide groups, RULES.md B3 / D11). Empty = unknown.
    public var pocketOrder: [BallID]
    /// Balls driven off the table (WPA 2.6). May include `.cue`.
    public var offTable: Set<BallID>
    /// Some ball was driven to a rail after first contact (WPA 2.7, 3.3). `nil` = not observed.
    public var anyRailAfterContact: Bool?
    /// Break only: object balls driven to a rail (WPA 4.3(d), 5.3(b), RULES.md B2).
    public var objectBallsToRailOnBreak: Int?
    /// Break only: object balls pocketed or whose centre crossed the head string (WPA Reg 16(1)).
    public var objectBallsPastHeadStringOrPocketedOnBreak: Int?
    /// Called ball (WPA 4.4/4.6/1.7). `nil` = not called / obvious; the engine then gives the shooter the benefit.
    public var calledBall: BallID?
    /// Called pocket (WPA 1.7; bar RULES.md B1 calls the 8's pocket only). `nil` = not observed.
    public var calledPocket: Pocket?
    /// Shooter called "safety" (WPA 4.6, 1.7; RULES.md B22).
    public var calledSafety: Bool
    /// Ball in hand restricted to above the head string: was the cue ball placed above it? (WPA 3.10)
    public var cueBallStartedAboveHeadString: Bool?
    /// Ball in hand above the head string: did the cue ball cross the head string, or first contact a ball
    /// on/below it? (WPA 3.11)
    public var cueBallCrossedHeadStringFirst: Bool?
    /// Shooter announced a push-out (WPA 5.4).
    public var isPushOut: Bool

    public init(isBreak: Bool = false, firstContact: BallID? = nil, noContact: Bool = false,
                pocketed: [BallID: Pocket] = [:], pocketOrder: [BallID] = [], offTable: Set<BallID> = [],
                anyRailAfterContact: Bool? = nil, objectBallsToRailOnBreak: Int? = nil,
                objectBallsPastHeadStringOrPocketedOnBreak: Int? = nil, calledBall: BallID? = nil,
                calledPocket: Pocket? = nil, calledSafety: Bool = false,
                cueBallStartedAboveHeadString: Bool? = nil, cueBallCrossedHeadStringFirst: Bool? = nil,
                isPushOut: Bool = false) {
        self.isBreak = isBreak
        self.firstContact = firstContact
        self.noContact = noContact
        self.pocketed = pocketed
        self.pocketOrder = pocketOrder
        self.offTable = offTable
        self.anyRailAfterContact = anyRailAfterContact
        self.objectBallsToRailOnBreak = objectBallsToRailOnBreak
        self.objectBallsPastHeadStringOrPocketedOnBreak = objectBallsPastHeadStringOrPocketedOnBreak
        self.calledBall = calledBall
        self.calledPocket = calledPocket
        self.calledSafety = calledSafety
        self.cueBallStartedAboveHeadString = cueBallStartedAboveHeadString
        self.cueBallCrossedHeadStringFirst = cueBallCrossedHeadStringFirst
        self.isPushOut = isPushOut
    }
}

/// A choice offered to a player after certain shots.
public enum PlayerOption: String, Hashable, Codable, Sendable {
    /// Play the table as it lies (WPA 4.3(d)(1), (g)(1), (h)(1); Reg 16(2); after a push-out, 5.4).
    case acceptTable
    /// Make the other side shoot (Reg 16(2)/(4); after a push-out, 5.4).
    case handBack
    /// Take cue ball in hand above the head string (WPA 4.3(g)(2), (h)(2)).
    case ballInHandAboveHeadString
    /// Re-rack; the chooser breaks (WPA 4.3(d)(2), (e)(2), (f)(2)).
    case reBreak
    /// Re-rack; the offending breaker breaks again (WPA 4.3(d)(3)).
    case reBreakByOffender
    /// Spot the 8 and play on; breaker keeps shooting (WPA 4.3(e)(1)).
    case spotEightAndAccept
    /// Spot the 8 and shoot with ball in hand above the head string (WPA 4.3(f)(1)).
    case spotEightBallInHandAboveHeadString
}

/// Why the engine is waiting for a choice.
public enum OptionReason: String, Hashable, Codable, Sendable {
    case illegalBreak          // WPA 4.3(d)
    case eightOnLegalBreak     // WPA 4.3(e)
    case eightOnFoulBreak      // WPA 4.3(f)
    case breakFoul             // WPA 4.3(g)/(h)
    case threeBallRule         // WPA Reg 16
    case pushOut               // WPA 5.4
}

public struct PendingOption: Hashable, Codable, Sendable {
    /// Team that must choose.
    public var chooser: Int
    public var reason: OptionReason
    public var options: [PlayerOption]
    public init(chooser: Int, reason: OptionReason, options: [PlayerOption]) {
        self.chooser = chooser
        self.reason = reason
        self.options = options
    }
}

public enum Phase: Hashable, Codable, Sendable {
    /// Next shot is a break.
    case breakShot
    /// 9-ball: next shot may be a push-out (WPA 5.4).
    case pushOutAvailable
    /// 8-ball: groups not yet decided.
    case open
    /// Normal play.
    case inPlay
    /// A player must pick an option via `RulesEngine.choose`. `GameState.shooter` is the team that just shot.
    case awaitingOption(PendingOption)
    /// Rack over.
    case over(winner: Int)
}

/// How a rack ended.
public enum GameEndReason: String, Hashable, Codable, Sendable {
    case eightOnBreak            // RULES.md B4 (win)
    case eightOnBreakWithFoul    // RULES.md B5 (loss)
    case eightPocketed           // legal win (WPA 4, RULES.md B16)
    case eightEarly              // WPA 4.8(b), RULES.md B13 (loss)
    case eightWithLastGroupBall  // WPA 4.8(b)+4.6, RULES.md B14 (loss)
    case eightWrongPocket        // WPA 4.8(c), RULES.md B12 (loss)
    case eightWithFoul           // WPA 4.8(a), RULES.md B9 (loss)
    case eightOffTable           // WPA 4.8(d), RULES.md B15 (loss)
    case eightNotCalled          // WPA 4.6 + 4.8(c): another ball was called when the 8 dropped (loss)
    case scratchOnEight          // RULES.md B9 (loss, 8 not pocketed)
    case ninePocketed            // WPA 5.5 (win)
    case threeFouls              // WPA 5.8 / 3.13 (loss)
}

/// Rules-relevant state of one rack.
public struct GameState: Hashable, Codable, Sendable {
    public var ruleSet: RuleSetID
    public var teams: Int
    /// Team at the table (index into teams). While awaiting an option, the team that just shot.
    public var shooter: Int
    /// Team that took the opening break of this rack (used for alternation, WPA 1.3, and stalemate, 4.11/5.9).
    public var breaker: Int
    /// Group per team; `nil` = open table.
    public var groups: [Int: BallGroup]?
    public var ballInHand: BallInHand
    /// Fouls without an intervening legal shot, per team (WPA 3.13).
    public var consecutiveFouls: [Int: Int]
    public var phase: Phase
    /// Object balls still in play (cue ball excluded).
    public var onTable: Set<BallID>

    public init(ruleSet: RuleSetID, teams: Int, shooter: Int, breaker: Int, groups: [Int: BallGroup]?,
                ballInHand: BallInHand, consecutiveFouls: [Int: Int], phase: Phase, onTable: Set<BallID>) {
        self.ruleSet = ruleSet
        self.teams = teams
        self.shooter = shooter
        self.breaker = breaker
        self.groups = groups
        self.ballInHand = ballInHand
        self.consecutiveFouls = consecutiveFouls
        self.phase = phase
        self.onTable = onTable
    }

    public var isTableOpen: Bool { groups == nil }

    public var winner: Int? {
        if case .over(let w) = phase { return w }
        return nil
    }

    /// WPA 3.13 / Reg 8: the shooter is on two fouls and must be warned (the on-screen count satisfies Reg 8).
    /// Only 9-ball has the three-foul rule (WPA 5.8; 8-ball excludes it, 3.13).
    public var shooterOnTwoFouls: Bool {
        ruleSet == .wpaNine && consecutiveFouls[shooter, default: 0] == 2
    }
}

/// Result of applying a shot or a choice.
public struct RuleResult: Hashable, Codable, Sendable {
    public var fouls: [Foul]
    public var nextState: GameState
    public var turnPasses: Bool
    public var winner: Int?
    public var endReason: GameEndReason?
    /// Balls to place on the foot spot (WPA 1.5) before the next shot.
    public var spot: [BallID]
    /// Options open to `nextState`'s chooser (also in `nextState.phase`).
    public var options: [PlayerOption]
    /// The rack is re-racked and broken again.
    public var reRack: Bool

    public init(fouls: [Foul] = [], nextState: GameState, turnPasses: Bool = false, winner: Int? = nil,
                endReason: GameEndReason? = nil, spot: [BallID] = [], options: [PlayerOption] = [],
                reRack: Bool = false) {
        self.fouls = fouls
        self.nextState = nextState
        self.turnPasses = turnPasses
        self.winner = winner
        self.endReason = endReason
        self.spot = spot
        self.options = options
        self.reRack = reRack
    }
}

/// Session rule-set poll (SPEC §3): most votes wins; a tie for first or no votes → default (`.barEight`).
public enum Vote {
    public static func winner(_ ballots: [RuleSetID]) -> RuleSetID {
        var counts: [RuleSetID: Int] = [:]
        for b in ballots { counts[b, default: 0] += 1 }
        guard let top = counts.values.max() else { return .default }
        let leaders = RuleSetID.allCases.filter { counts[$0] == top }
        return leaders.count == 1 ? leaders[0] : .default
    }
}

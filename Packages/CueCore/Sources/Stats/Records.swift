import Foundation
import Geometry
import Rules

// Competitive-only inputs to Stats (SPEC §4, §6; docs/SCHEMA.md Competitive store).
// Training data has its own types in the Training module (AttemptFeatures, DrillProgress) and Stats does not
// depend on Training, so a training attempt cannot be passed to any Stats API by construction.

/// Cue-ball position result. Raw values match the app's persisted `CueResult`.
public enum CueResult: String, CaseIterable, Codable, Sendable {
    case inZone, outOfZone, notApplicable
}

/// One competitive shot, as Stats needs it (a projection of the app's `Shot` row).
public struct CompetitiveShot: Hashable, Codable, Sendable, Identifiable {
    public var id: UUID
    public var shooterID: UUID
    /// Team index of the shooter in this game.
    public var team: Int
    public var isBreak: Bool
    public var features: ShotFeatures
    /// Pot attempts: the intended ball dropped. Breaks: any object ball dropped.
    public var made: Bool
    public var onTarget: Bool
    public var cueResult: CueResult
    public var fouls: [Foul]
    /// Object balls pocketed on this shot (break stats).
    public var objectBallsPocketed: Int
    /// Change in the shooter's team win probability caused by this shot.
    public var wpaDelta: Double
    public var isClutch: Bool
    public var timeOnShot: Double

    public init(id: UUID = UUID(), shooterID: UUID, team: Int, isBreak: Bool, features: ShotFeatures,
                made: Bool, onTarget: Bool, cueResult: CueResult, fouls: [Foul], objectBallsPocketed: Int,
                wpaDelta: Double, isClutch: Bool, timeOnShot: Double) {
        self.id = id
        self.shooterID = shooterID
        self.team = team
        self.isBreak = isBreak
        self.features = features
        self.made = made
        self.onTarget = onTarget
        self.cueResult = cueResult
        self.fouls = fouls
        self.objectBallsPocketed = objectBallsPocketed
        self.wpaDelta = wpaDelta
        self.isClutch = isClutch
        self.timeOnShot = timeOnShot
    }

    public var isSafety: Bool { features.kind == .safety }
    public var fouled: Bool { !fouls.isEmpty }
    /// Counts toward pot % (not a break, not a safety).
    public var isPotAttempt: Bool { !isBreak && !isSafety }
}

/// One competitive rack with its shots in order.
public struct CompetitiveGame: Hashable, Codable, Sendable, Identifiable {
    public var id: UUID
    public var ruleSet: RuleSetID
    public var startedAt: Date
    /// Roster: player → team index.
    public var teamOf: [UUID: Int]
    /// `nil` = unfinished / abandoned.
    public var winnerTeam: Int?
    public var shots: [CompetitiveShot]

    public init(id: UUID = UUID(), ruleSet: RuleSetID, startedAt: Date, teamOf: [UUID: Int],
                winnerTeam: Int?, shots: [CompetitiveShot]) {
        self.id = id
        self.ruleSet = ruleSet
        self.startedAt = startedAt
        self.teamOf = teamOf
        self.winnerTeam = winnerTeam
        self.shots = shots
    }

    /// Players on the roster plus anyone who took a shot.
    public var players: Set<UUID> { Set(teamOf.keys).union(shots.map(\.shooterID)) }
}

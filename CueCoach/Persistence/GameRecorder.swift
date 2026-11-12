import Foundation
import SwiftData
import Geometry
import Rules
import Engine

/// Saves a finished rack to the competitive store (INTERFACES "Game saving (plan 011)"; D40, D45).
/// One writer: the solo phone or the mesh host. Upserts by id, so a repeat changes nothing.
@MainActor protocol GameRecorder: AnyObject {
    func record(_ game: FinishedGame) throws
}

struct FinishedGame: Hashable, Sendable {
    var id: UUID
    var ruleSet: RuleSetID
    var tableSize: TableSize
    var format: GameFormat
    var teams: [StoredTeam]
    var winnerTeam: Int
    var winProbSeries: [Double]
    var startedAt: Date
    var endedAt: Date
    var shots: [RecordedShot]
}

struct RecordedShot: Hashable, Sendable {
    var id: UUID
    var index: Int
    var shooterID: UUID
    var team: Int
    var attributionSource: AttributionSource
    var preState: TableState
    var postState: TableState
    var calledPocket: Pocket?
    var firstContact: BallID?
    var railsAfterContact: Int
    var pocketed: [BallID: Pocket]
    var fouls: [Foul]
    var features: StoredShotFeatures
    var made: Bool
    var onTarget: Bool
    var cueResult: CueResult
    var decisionRating: DecisionRating
    var executionRating: ExecutionRating
    var wpaDelta: Double
    var isClutch: Bool
    var timeOnShot: Double
    var clipRef: String?
}

/// Writes `Competitive.store` only.
@MainActor final class StackGameRecorder: GameRecorder {
    private let stack: PersistenceStack
    init(stack: PersistenceStack) { self.stack = stack }

    func record(_ game: FinishedGame) throws {}
}

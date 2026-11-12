import Foundation
import SwiftData
import os
import Geometry
import Rules
import Engine
import Stats

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

extension RecordedShot {
    /// A rated, non-guessed folded shot, per the field table (design §3). nil for a D38 gap or a D31 guess.
    init?(_ s: SessionShot, tableSize: TableSize) {
        guard let rating = s.rating, !s.isGuess else { return nil }
        let spec = TableSpec(size: tableSize)
        let pre = TableState(spec: spec, balls: s.before.mapValues { BallState(position: $0) })
        let post = TableState(spec: spec, balls: s.after.mapValues { BallState(position: $0) })
        // Positions give cut, distance and pocket; without the cue ball the shot is neutral (the stats projection skips it).
        let features = s.before[.cue] != nil
            ? ShotFeatures.extract(pre: pre, post: post, trace: ShotTraceSummary(events: [])) : .neutral
        let made = s.pocketed.keys.contains { $0 != .cue }
        self.init(id: s.id, index: s.index, shooterID: s.shooter.id, team: s.team, attributionSource: s.attribution,
                  preState: pre, postState: post, calledPocket: nil, firstContact: s.firstContact,
                  railsAfterContact: 0, pocketed: s.pocketed, fouls: s.fouls, features: StoredShotFeatures(features),
                  made: made, onTarget: made, cueResult: .notApplicable, decisionRating: rating,
                  executionRating: ExecutionRating(result: made ? .made : .miss, position: .notApplicable),
                  wpaDelta: 0, isClutch: false, timeOnShot: -1, clipRef: nil)
    }
}

extension StoredShotFeatures {
    init(_ f: ShotFeatures) {
        self.init(cutBucket: StoredShotFeatures.CutBucket(rawValue: f.cutBucket.rawValue) ?? .c0to15,
                  distanceBucket: StoredShotFeatures.DistanceBucket(rawValue: f.distanceBucket.rawValue) ?? .short,
                  pocketType: StoredShotFeatures.PocketType(rawValue: f.pocketType.rawValue) ?? .corner,
                  kind: StoredShotFeatures.Kind(rawValue: f.kind.rawValue) ?? .plain)
    }
}

/// Writes `Competitive.store` only: one `Session` + `Game` + its `Shot`s, upserted by id, then one save.
@MainActor final class StackGameRecorder: GameRecorder {
    static let log = Logger(subsystem: "CueCoach", category: "save")
    private let stack: PersistenceStack
    init(stack: PersistenceStack) { self.stack = stack }

    func record(_ g: FinishedGame) throws {
        let ctx = stack.competitiveContext
        let id = g.id
        let session: Session
        if let s = try ctx.fetch(FetchDescriptor<Session>(predicate: #Predicate { $0.id == id })).first {
            session = s
            session.startedAt = g.startedAt
            session.ruleSet = g.ruleSet
            session.format = g.format
            session.tableSize = g.tableSize
        } else {
            session = Session(id: id, startedAt: g.startedAt, ruleSet: g.ruleSet, format: g.format, tableSize: g.tableSize)
            ctx.insert(session)
        }
        session.endedAt = g.endedAt
        let game: Game
        if let existing = try ctx.fetch(FetchDescriptor<Game>(predicate: #Predicate { $0.id == id })).first {
            game = existing
            game.ruleSet = g.ruleSet
            game.teams = g.teams
            game.startedAt = g.startedAt
        } else {
            game = Game(id: id, index: 0, ruleSet: g.ruleSet, teams: g.teams, startedAt: g.startedAt)
            ctx.insert(game)
        }
        game.winnerTeam = g.winnerTeam
        game.winProbSeries = g.winProbSeries
        game.endedAt = g.endedAt
        if game.session?.id != session.id { game.session = session }
        for r in g.shots {
            let sid = r.id
            if let shot = try ctx.fetch(FetchDescriptor<Shot>(predicate: #Predicate { $0.id == sid })).first {
                Self.fill(shot, r)
                if shot.game?.id != game.id { shot.game = game }
            } else {
                let shot = Shot(id: r.id, index: r.index, shooterID: r.shooterID, attributionSource: r.attributionSource,
                                preState: r.preState, postState: r.postState, calledPocket: r.calledPocket,
                                firstContact: r.firstContact, railsAfterContact: r.railsAfterContact,
                                pocketed: r.pocketed, fouls: r.fouls, features: r.features, made: r.made,
                                onTarget: r.onTarget, cueResult: r.cueResult, decisionRating: r.decisionRating,
                                executionRating: r.executionRating, wpaDelta: r.wpaDelta, isClutch: r.isClutch,
                                timeOnShot: r.timeOnShot, clipRef: r.clipRef)
                ctx.insert(shot)
                shot.game = game
            }
        }
        try ctx.save()
    }

    private static func fill(_ shot: Shot, _ r: RecordedShot) {
        shot.index = r.index
        shot.shooterID = r.shooterID
        shot.attributionSource = r.attributionSource
        shot.preState = r.preState
        shot.postState = r.postState
        shot.calledPocket = r.calledPocket
        shot.firstContact = r.firstContact
        shot.railsAfterContact = r.railsAfterContact
        shot.pocketed = r.pocketed
        shot.fouls = r.fouls
        shot.features = r.features
        shot.made = r.made
        shot.onTarget = r.onTarget
        shot.cueResult = r.cueResult
        shot.decisionRating = r.decisionRating
        shot.executionRating = r.executionRating
        shot.wpaDelta = r.wpaDelta
        shot.isClutch = r.isClutch
        shot.timeOnShot = r.timeOnShot
        shot.clipRef = r.clipRef
    }
}

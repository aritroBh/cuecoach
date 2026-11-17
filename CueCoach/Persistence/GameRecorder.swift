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
    func deleteGame(id: UUID) throws
    func confirmGame(id: UUID) throws
}

extension GameRecorder {
    func deleteGame(id: UUID) throws {}
    func confirmGame(id: UUID) throws {}
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
    /// D51 (plan 013b): true when saved by an island without quorum; excluded from stats until confirmed.
    var isUnconfirmed: Bool = false
    /// D55: optional Shot of the Game highlight metadata.
    var shotOfGame: RecordedHighlight? = nil
}

struct RecordedHighlight: Hashable, Sendable {
    var shotID: UUID
    var label: String
    var score: Double
    var clipFile: String = ""
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
    /// D31/D43: `pocketed` is a best guess; stored as `Shot.isGuess` so stats skip it.
    var isGuess: Bool
    var needsTap: Bool = false
    var fullOutcome: ShotOutcome? = nil
    var alternateOutcome: ShotOutcome? = nil
    var alternative: EngineAlternative? = nil
}

extension RecordedShot {
    /// A rated folded shot (a D31 guess too, flagged), per the field table (design §3). nil for a D38 gap.
    init?(_ s: SessionShot, tableSize: TableSize) {
        guard let rating = s.rating else { return nil }
        let spec = TableSpec(size: tableSize)
        let pre = TableState(spec: spec, balls: s.before.mapValues { BallState(position: $0) })
        let post = TableState(spec: spec, balls: s.after.mapValues { BallState(position: $0) })
        // Positions give cut, distance and pocket; without the cue ball the shot is neutral (the stats projection skips it).
        let features = s.before[.cue] != nil
            ? ShotFeatures.extract(pre: pre, post: post, trace: ShotTraceSummary(events: [])) : .neutral
        let made = s.pocketed.keys.contains { $0 != .cue }
        self.init(id: s.id, index: s.index, shooterID: s.shooter.id, team: s.team, attributionSource: s.attribution,
                  preState: pre, postState: post, calledPocket: s.outcome.calledPocket, firstContact: s.firstContact,
                  railsAfterContact: 0, pocketed: s.pocketed, fouls: s.fouls, features: StoredShotFeatures(features),
                  made: made, onTarget: made, cueResult: .notApplicable, decisionRating: rating,
                  executionRating: s.executionRating ?? ExecutionRating(result: made ? .made : .miss, position: .notApplicable),
                  wpaDelta: s.wpaDelta, isClutch: s.isClutch, timeOnShot: -1, clipRef: s.clipRef,
                  isGuess: s.isGuess, needsTap: s.needsTap, fullOutcome: s.outcome,
                  alternateOutcome: s.alternateOutcome, alternative: s.alternative)
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
        game.isUnconfirmed = g.isUnconfirmed
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
                                timeOnShot: r.timeOnShot, clipRef: r.clipRef, isGuess: r.isGuess,
                                needsTap: r.needsTap, fullOutcome: r.fullOutcome,
                                alternateOutcome: r.alternateOutcome, alternative: r.alternative)
                ctx.insert(shot)
                shot.game = game
            }
        }
        let keptIDs = Set(g.shots.map(\.id))
        for stale in game.shots where !keptIDs.contains(stale.id) {
            ctx.delete(stale)
        }
        if let sotg = g.shotOfGame {
            if let h = game.highlights.first(where: { $0.kind == .shotOfGame }) {
                let changedShot = h.shotID != sotg.shotID
                h.shotID = sotg.shotID
                h.label = sotg.label
                h.score = sotg.score
                if !sotg.clipFile.isEmpty || changedShot { h.clipFile = sotg.clipFile }
            } else {
                let h = Highlight(shotID: sotg.shotID, kind: .shotOfGame, clipFile: sotg.clipFile,
                                  label: sotg.label, score: sotg.score)
                ctx.insert(h)
                h.game = game
            }
        } else {
            for h in game.highlights where h.kind == .shotOfGame { ctx.delete(h) }
        }
        try ctx.save()
    }

    func confirmGame(id: UUID) throws {
        let ctx = stack.competitiveContext
        if let game = try ctx.fetch(FetchDescriptor<Game>(predicate: #Predicate { $0.id == id })).first {
            game.isUnconfirmed = false
            game.unconfirmedOriginOwnerID = nil
            try ctx.save()
        }
    }

    func deleteGame(id: UUID) throws {
        let ctx = stack.competitiveContext
        let clipBase = stack.directory ?? ShotClipStore.defaultBaseDirectory
        if let game = try ctx.fetch(FetchDescriptor<Game>(predicate: #Predicate { $0.id == id })).first {
            let clipRefs = game.highlights.map(\.clipFile) + game.shots.compactMap(\.clipRef)
            ShotClipStore.deleteClips(relativePaths: clipRefs, baseDirectory: clipBase)
            let session = game.session
            for shot in game.shots { ctx.delete(shot) }
            for highlight in game.highlights { ctx.delete(highlight) }
            ctx.delete(game)
            if let session, session.games.filter({ $0.id != id }).isEmpty {
                ctx.delete(session)
            }
        } else if let session = try ctx.fetch(FetchDescriptor<Session>(predicate: #Predicate { $0.id == id })).first,
                  session.games.isEmpty {
            ctx.delete(session)
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
        shot.isGuess = r.isGuess
        shot.needsTap = r.needsTap
        shot.fullOutcome = r.fullOutcome
        shot.alternateOutcome = r.alternateOutcome
        shot.alternative = r.alternative
    }
}

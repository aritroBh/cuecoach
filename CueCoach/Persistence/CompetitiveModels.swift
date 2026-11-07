import Foundation
import SwiftData
import Geometry
import Rules
import Engine

// Competitive store (Competitive.store). See docs/SCHEMA.md.
// Every row has a stable `id` and `updatedAt` so JSON backups can merge by UUID, newer wins.
// Callers that mutate a row should call `touch()`.

@Model
final class PlayerProfile {
    @Attribute(.unique) var id: UUID
    var name: String
    var avatarSymbol: String
    var avatarColor: String
    var isLocalOwner: Bool
    /// Peer profile cached only for the current mesh session; removed by `purgeSessionGuests()`.
    var isSessionGuest: Bool
    var createdAt: Date
    var updatedAt: Date
    private var skillModelData: Data
    @Relationship(deleteRule: .cascade, inverse: \RecognitionData.profile)
    var recognition: RecognitionData?

    var skillModel: StoredSkillModel {
        get { Blob.decode(StoredSkillModel.self, skillModelData, fallback: .prior) }
        set { skillModelData = Blob.encode(newValue) }
    }

    init(id: UUID = UUID(), name: String, avatarSymbol: String, avatarColor: String,
         isLocalOwner: Bool = false, isSessionGuest: Bool = false, createdAt: Date = .now,
         updatedAt: Date? = nil, skillModel: StoredSkillModel = .prior) {
        self.id = id
        self.name = name
        self.avatarSymbol = avatarSymbol
        self.avatarColor = avatarColor
        self.isLocalOwner = isLocalOwner
        self.isSessionGuest = isSessionGuest
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.skillModelData = Blob.encode(skillModel)
    }

    func touch(_ now: Date = .now) { updatedAt = now }
}

/// Opt-in face/appearance embeddings. Separate row so "delete my recognition data" is one delete.
@Model
final class RecognitionData {
    @Attribute(.unique) var id: UUID
    @Attribute(.externalStorage) var faceEmbedding: Data?
    @Attribute(.externalStorage) var appearanceEmbedding: Data?
    var optedInAt: Date
    var version: Int
    var updatedAt: Date
    var profile: PlayerProfile?

    init(id: UUID = UUID(), faceEmbedding: Data?, appearanceEmbedding: Data?, optedInAt: Date,
         version: Int, updatedAt: Date? = nil) {
        self.id = id
        self.faceEmbedding = faceEmbedding
        self.appearanceEmbedding = appearanceEmbedding
        self.optedInAt = optedInAt
        self.version = version
        self.updatedAt = updatedAt ?? optedInAt
    }

    func touch(_ now: Date = .now) { updatedAt = now }
}

@Model
final class Session {
    @Attribute(.unique) var id: UUID
    var startedAt: Date
    var endedAt: Date?
    private var ruleSetRaw: String
    private var formatRaw: String
    private var tableSizeRaw: String
    var peerDeviceNames: [String]
    private var voteTallyData: Data
    var updatedAt: Date
    @Relationship(deleteRule: .cascade, inverse: \Game.session)
    var games: [Game] = []

    var ruleSet: RuleSetID {
        get { RuleSetID(rawValue: ruleSetRaw) ?? .default }
        set { ruleSetRaw = newValue.rawValue }
    }
    var format: GameFormat {
        get { GameFormat(rawValue: formatRaw) ?? .oneVsOne }
        set { formatRaw = newValue.rawValue }
    }
    var tableSize: TableSize {
        get { TableSize(rawValue: tableSizeRaw) ?? .sevenFoot }
        set { tableSizeRaw = newValue.rawValue }
    }
    var voteTally: [RuleSetID: Int] {
        get { Blob.decode([RuleSetID: Int].self, voteTallyData, fallback: [:]) }
        set { voteTallyData = Blob.encode(newValue) }
    }

    init(id: UUID = UUID(), startedAt: Date, endedAt: Date? = nil, ruleSet: RuleSetID, format: GameFormat,
         tableSize: TableSize, peerDeviceNames: [String] = [], voteTally: [RuleSetID: Int] = [:],
         updatedAt: Date? = nil) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.ruleSetRaw = ruleSet.rawValue
        self.formatRaw = format.rawValue
        self.tableSizeRaw = tableSize.rawValue
        self.peerDeviceNames = peerDeviceNames
        self.voteTallyData = Blob.encode(voteTally)
        self.updatedAt = updatedAt ?? endedAt ?? startedAt
    }

    func touch(_ now: Date = .now) { updatedAt = now }
}

@Model
final class Game {
    @Attribute(.unique) var id: UUID
    var session: Session?
    var index: Int
    private var ruleSetRaw: String
    private var teamsData: Data
    var winnerTeam: Int?
    var winProbSeries: [Double]
    var startedAt: Date
    var endedAt: Date?
    var updatedAt: Date
    @Relationship(deleteRule: .cascade, inverse: \Shot.game)
    var shots: [Shot] = []
    @Relationship(deleteRule: .cascade, inverse: \Highlight.game)
    var highlights: [Highlight] = []

    var ruleSet: RuleSetID {
        get { RuleSetID(rawValue: ruleSetRaw) ?? .default }
        set { ruleSetRaw = newValue.rawValue }
    }
    var teams: [StoredTeam] {
        get { Blob.decode([StoredTeam].self, teamsData, fallback: []) }
        set { teamsData = Blob.encode(newValue) }
    }

    init(id: UUID = UUID(), index: Int, ruleSet: RuleSetID, teams: [StoredTeam], winnerTeam: Int? = nil,
         winProbSeries: [Double] = [], startedAt: Date, endedAt: Date? = nil, updatedAt: Date? = nil) {
        self.id = id
        self.index = index
        self.ruleSetRaw = ruleSet.rawValue
        self.teamsData = Blob.encode(teams)
        self.winnerTeam = winnerTeam
        self.winProbSeries = winProbSeries
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.updatedAt = updatedAt ?? endedAt ?? startedAt
    }

    func touch(_ now: Date = .now) { updatedAt = now }
}

@Model
final class Shot {
    @Attribute(.unique) var id: UUID
    var game: Game?
    var index: Int
    var shooterID: UUID
    private var attributionSourceRaw: String
    private var preStateData: Data
    private var postStateData: Data
    private var calledPocketRaw: String?
    private var firstContactNumber: Int?
    var railsAfterContact: Int
    private var pocketedData: Data
    private var foulsData: Data
    private var featuresData: Data
    var made: Bool
    var onTarget: Bool
    private var cueResultRaw: String
    private var decisionRatingRaw: String
    private var executionRatingData: Data
    var wpaDelta: Double
    var isClutch: Bool
    var timeOnShot: Double
    var clipRef: String?
    var updatedAt: Date

    var attributionSource: AttributionSource {
        get { AttributionSource(rawValue: attributionSourceRaw) ?? .auto }
        set { attributionSourceRaw = newValue.rawValue }
    }
    var preState: TableState {
        get { Blob.decode(TableState.self, preStateData, fallback: TableState(spec: TableSpec(size: .sevenFoot))) }
        set { preStateData = Blob.encode(newValue) }
    }
    var postState: TableState {
        get { Blob.decode(TableState.self, postStateData, fallback: TableState(spec: TableSpec(size: .sevenFoot))) }
        set { postStateData = Blob.encode(newValue) }
    }
    var calledPocket: Pocket? {
        get { calledPocketRaw.flatMap(Pocket.init(rawValue:)) }
        set { calledPocketRaw = newValue?.rawValue }
    }
    var firstContact: BallID? {
        get { firstContactNumber.flatMap(BallID.init) }
        set { firstContactNumber = newValue?.number }
    }
    var pocketed: [BallID: Pocket] {
        get { Blob.decode([BallID: Pocket].self, pocketedData, fallback: [:]) }
        set { pocketedData = Blob.encode(newValue) }
    }
    var fouls: [Foul] {
        get { Blob.decode([Foul].self, foulsData, fallback: []) }
        set { foulsData = Blob.encode(newValue) }
    }
    var features: StoredShotFeatures {
        get { Blob.decode(StoredShotFeatures.self, featuresData,
                          fallback: StoredShotFeatures(cutBucket: .c0to15, distanceBucket: .short, pocketType: .corner, kind: .plain)) }
        set { featuresData = Blob.encode(newValue) }
    }
    var cueResult: CueResult {
        get { CueResult(rawValue: cueResultRaw) ?? .notApplicable }
        set { cueResultRaw = newValue.rawValue }
    }
    var decisionRating: DecisionRating {
        get { DecisionRating(rawValue: decisionRatingRaw) ?? .good }
        set { decisionRatingRaw = newValue.rawValue }
    }
    var executionRating: ExecutionRating {
        get { Blob.decode(ExecutionRating.self, executionRatingData,
                          fallback: ExecutionRating(result: .miss, position: .notApplicable)) }
        set { executionRatingData = Blob.encode(newValue) }
    }

    init(id: UUID = UUID(), index: Int, shooterID: UUID, attributionSource: AttributionSource,
         preState: TableState, postState: TableState, calledPocket: Pocket?, firstContact: BallID?,
         railsAfterContact: Int, pocketed: [BallID: Pocket], fouls: [Foul], features: StoredShotFeatures,
         made: Bool, onTarget: Bool, cueResult: CueResult, decisionRating: DecisionRating,
         executionRating: ExecutionRating, wpaDelta: Double, isClutch: Bool, timeOnShot: Double,
         clipRef: String?, updatedAt: Date = .now) {
        self.id = id
        self.index = index
        self.shooterID = shooterID
        self.attributionSourceRaw = attributionSource.rawValue
        self.preStateData = Blob.encode(preState)
        self.postStateData = Blob.encode(postState)
        self.calledPocketRaw = calledPocket?.rawValue
        self.firstContactNumber = firstContact?.number
        self.railsAfterContact = railsAfterContact
        self.pocketedData = Blob.encode(pocketed)
        self.foulsData = Blob.encode(fouls)
        self.featuresData = Blob.encode(features)
        self.made = made
        self.onTarget = onTarget
        self.cueResultRaw = cueResult.rawValue
        self.decisionRatingRaw = decisionRating.rawValue
        self.executionRatingData = Blob.encode(executionRating)
        self.wpaDelta = wpaDelta
        self.isClutch = isClutch
        self.timeOnShot = timeOnShot
        self.clipRef = clipRef
        self.updatedAt = updatedAt
    }

    func touch(_ now: Date = .now) { updatedAt = now }
}

/// Append-only archetype history per player (plain `playerID`, no relationship).
@Model
final class ArchetypeSnapshot {
    @Attribute(.unique) var id: UUID
    var playerID: UUID
    var computedAt: Date
    var gamesCount: Int
    var shotsCount: Int
    private var vectorData: Data
    /// Archetype tag identifiers (e.g. "cutArtist"); `ArchetypeTag` lives in Stats once it exists.
    var tags: [String]
    private var proCompData: Data?
    var updatedAt: Date

    var vector: [String: Double] {
        get { Blob.decode([String: Double].self, vectorData, fallback: [:]) }
        set { vectorData = Blob.encode(newValue) }
    }
    var proComp: StoredProComp? {
        get { proCompData.map { Blob.decode(StoredProComp?.self, $0, fallback: nil) } ?? nil }
        set { proCompData = newValue.map(Blob.encode) }
    }

    init(id: UUID = UUID(), playerID: UUID, computedAt: Date, gamesCount: Int, shotsCount: Int,
         vector: [String: Double], tags: [String], proComp: StoredProComp?, updatedAt: Date? = nil) {
        self.id = id
        self.playerID = playerID
        self.computedAt = computedAt
        self.gamesCount = gamesCount
        self.shotsCount = shotsCount
        self.vectorData = Blob.encode(vector)
        self.tags = tags
        self.proCompData = proComp.map(Blob.encode)
        self.updatedAt = updatedAt ?? computedAt
    }
}

@Model
final class Highlight {
    @Attribute(.unique) var id: UUID
    var game: Game?
    var shotID: UUID
    private var kindRaw: String
    /// Relative path inside the app container. Clips are never exported to Photos or backups.
    var clipFile: String
    /// ≤ 2 words.
    var label: String
    var score: Double
    var updatedAt: Date

    var kind: HighlightKind {
        get { HighlightKind(rawValue: kindRaw) ?? .shotOfGame }
        set { kindRaw = newValue.rawValue }
    }

    init(id: UUID = UUID(), shotID: UUID, kind: HighlightKind, clipFile: String, label: String,
         score: Double, updatedAt: Date = .now) {
        self.id = id
        self.shotID = shotID
        self.kindRaw = kind.rawValue
        self.clipFile = clipFile
        self.label = label
        self.score = score
        self.updatedAt = updatedAt
    }
}

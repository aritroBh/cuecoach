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
    private var nameValue: String
    var name: String { get { nameValue } set { nameValue = newValue; updatedAt = .now } }
    private var avatarSymbolValue: String
    var avatarSymbol: String { get { avatarSymbolValue } set { avatarSymbolValue = newValue; updatedAt = .now } }
    private var avatarColorValue: String
    var avatarColor: String { get { avatarColorValue } set { avatarColorValue = newValue; updatedAt = .now } }
    var isLocalOwner: Bool
    /// Peer profile cached only for the current mesh session; removed by `purgeSessionGuests()`.
    var isSessionGuest: Bool
    /// Tombstone set by "Delete recognition data" (schema V2). Exported in backups (the flag, never the data) and
    /// merged newest-wins on import, so a restore can't bring recognition back: any opt-in at or before this
    /// instant is refused by `storeRecognition` and needs a fresh opt-in (audit F4).
    var recognitionRevokedAt: Date? = nil
    private var createdAtValue: Date
    var createdAt: Date { get { createdAtValue } set { createdAtValue = newValue; updatedAt = .now } }
    var updatedAt: Date
    private var skillModelData: Data

    var skillModel: StoredSkillModel {
        get { Blob.decode(StoredSkillModel.self, skillModelData, fallback: .prior) }
        set { skillModelData = Blob.encode(newValue); updatedAt = .now }
    }

    init(id: UUID = UUID(), name: String, avatarSymbol: String, avatarColor: String,
         isLocalOwner: Bool = false, isSessionGuest: Bool = false, createdAt: Date = .now,
         updatedAt: Date? = nil, skillModel: StoredSkillModel = .prior) {
        self.id = id
        self.nameValue = name
        self.avatarSymbolValue = avatarSymbol
        self.avatarColorValue = avatarColor
        self.isLocalOwner = isLocalOwner
        self.isSessionGuest = isSessionGuest
        self.createdAtValue = createdAt
        self.skillModelData = Blob.encode(skillModel)
        self.updatedAt = updatedAt ?? createdAt
    }

    func touch(_ now: Date = .now) { updatedAt = now }
}

// RecognitionData lives in its own backup-excluded store: RecognitionModels.swift.

@Model
final class Session {
    @Attribute(.unique) var id: UUID
    private var startedAtValue: Date
    var startedAt: Date { get { startedAtValue } set { startedAtValue = newValue; updatedAt = .now } }
    private var endedAtValue: Date?
    var endedAt: Date? { get { endedAtValue } set { endedAtValue = newValue; updatedAt = .now } }
    private var ruleSetRaw: String
    private var formatRaw: String
    private var tableSizeRaw: String
    private var peerDeviceNamesValue: [String]
    var peerDeviceNames: [String] { get { peerDeviceNamesValue } set { peerDeviceNamesValue = newValue; updatedAt = .now } }
    private var voteTallyData: Data
    var updatedAt: Date
    @Relationship(deleteRule: .cascade, inverse: \Game.sessionLink)
    fileprivate var gamesLink: [Game] = []
    var games: [Game] { get { gamesLink } set { gamesLink = newValue; updatedAt = .now } }

    var ruleSet: RuleSetID {
        get { RuleSetID(rawValue: ruleSetRaw) ?? .default }
        set { ruleSetRaw = newValue.rawValue; updatedAt = .now }
    }
    var format: GameFormat {
        get { GameFormat(rawValue: formatRaw) ?? .oneVsOne }
        set { formatRaw = newValue.rawValue; updatedAt = .now }
    }
    var tableSize: TableSize {
        get { TableSize(rawValue: tableSizeRaw) ?? .sevenFoot }
        set { tableSizeRaw = newValue.rawValue; updatedAt = .now }
    }
    var voteTally: [RuleSetID: Int] {
        get { Blob.decode([RuleSetID: Int].self, voteTallyData, fallback: [:]) }
        set { voteTallyData = Blob.encode(newValue); updatedAt = .now }
    }

    init(id: UUID = UUID(), startedAt: Date, endedAt: Date? = nil, ruleSet: RuleSetID, format: GameFormat,
         tableSize: TableSize, peerDeviceNames: [String] = [], voteTally: [RuleSetID: Int] = [:],
         updatedAt: Date? = nil) {
        self.id = id
        self.startedAtValue = startedAt
        self.endedAtValue = endedAt
        self.ruleSetRaw = ruleSet.rawValue
        self.formatRaw = format.rawValue
        self.tableSizeRaw = tableSize.rawValue
        self.peerDeviceNamesValue = peerDeviceNames
        self.voteTallyData = Blob.encode(voteTally)
        self.updatedAt = updatedAt ?? endedAt ?? startedAt
    }

    func touch(_ now: Date = .now) { updatedAt = now }
}

@Model
final class Game {
    @Attribute(.unique) var id: UUID
    fileprivate var sessionLink: Session?
    var session: Session? { get { sessionLink } set { sessionLink = newValue; updatedAt = .now } }
    private var indexValue: Int
    var index: Int { get { indexValue } set { indexValue = newValue; updatedAt = .now } }
    private var ruleSetRaw: String
    private var teamsData: Data
    private var winnerTeamValue: Int?
    var winnerTeam: Int? { get { winnerTeamValue } set { winnerTeamValue = newValue; updatedAt = .now } }
    private var winProbSeriesValue: [Double]
    var winProbSeries: [Double] { get { winProbSeriesValue } set { winProbSeriesValue = newValue; updatedAt = .now } }
    private var startedAtValue: Date
    var startedAt: Date { get { startedAtValue } set { startedAtValue = newValue; updatedAt = .now } }
    private var endedAtValue: Date?
    var endedAt: Date? { get { endedAtValue } set { endedAtValue = newValue; updatedAt = .now } }
    var updatedAt: Date
    @Relationship(deleteRule: .cascade, inverse: \Shot.gameLink)
    fileprivate var shotsLink: [Shot] = []
    var shots: [Shot] { get { shotsLink } set { shotsLink = newValue; updatedAt = .now } }
    @Relationship(deleteRule: .cascade, inverse: \Highlight.gameLink)
    fileprivate var highlightsLink: [Highlight] = []
    var highlights: [Highlight] { get { highlightsLink } set { highlightsLink = newValue; updatedAt = .now } }

    var ruleSet: RuleSetID {
        get { RuleSetID(rawValue: ruleSetRaw) ?? .default }
        set { ruleSetRaw = newValue.rawValue; updatedAt = .now }
    }
    var teams: [StoredTeam] {
        get { Blob.decode([StoredTeam].self, teamsData, fallback: []) }
        set { teamsData = Blob.encode(newValue); updatedAt = .now }
    }

    init(id: UUID = UUID(), index: Int, ruleSet: RuleSetID, teams: [StoredTeam], winnerTeam: Int? = nil,
         winProbSeries: [Double] = [], startedAt: Date, endedAt: Date? = nil, updatedAt: Date? = nil) {
        self.id = id
        self.indexValue = index
        self.ruleSetRaw = ruleSet.rawValue
        self.teamsData = Blob.encode(teams)
        self.winnerTeamValue = winnerTeam
        self.winProbSeriesValue = winProbSeries
        self.startedAtValue = startedAt
        self.endedAtValue = endedAt
        self.updatedAt = updatedAt ?? endedAt ?? startedAt
    }

    func touch(_ now: Date = .now) { updatedAt = now }
}

@Model
final class Shot {
    @Attribute(.unique) var id: UUID
    fileprivate var gameLink: Game?
    var game: Game? { get { gameLink } set { gameLink = newValue; updatedAt = .now } }
    private var indexValue: Int
    var index: Int { get { indexValue } set { indexValue = newValue; updatedAt = .now } }
    private var shooterIDValue: UUID
    var shooterID: UUID { get { shooterIDValue } set { shooterIDValue = newValue; updatedAt = .now } }
    private var attributionSourceRaw: String
    private var preStateData: Data
    private var postStateData: Data
    private var calledPocketRaw: String?
    private var firstContactNumber: Int?
    private var railsAfterContactValue: Int
    var railsAfterContact: Int { get { railsAfterContactValue } set { railsAfterContactValue = newValue; updatedAt = .now } }
    private var pocketedData: Data
    private var foulsData: Data
    private var featuresData: Data
    private var madeValue: Bool
    var made: Bool { get { madeValue } set { madeValue = newValue; updatedAt = .now } }
    private var onTargetValue: Bool
    var onTarget: Bool { get { onTargetValue } set { onTargetValue = newValue; updatedAt = .now } }
    private var cueResultRaw: String
    private var decisionRatingRaw: String
    private var executionRatingData: Data
    private var wpaDeltaValue: Double
    var wpaDelta: Double { get { wpaDeltaValue } set { wpaDeltaValue = newValue; updatedAt = .now } }
    private var isClutchValue: Bool
    var isClutch: Bool { get { isClutchValue } set { isClutchValue = newValue; updatedAt = .now } }
    private var timeOnShotValue: Double
    var timeOnShot: Double { get { timeOnShotValue } set { timeOnShotValue = newValue; updatedAt = .now } }
    private var clipRefValue: String?
    var clipRef: String? { get { clipRefValue } set { clipRefValue = newValue; updatedAt = .now } }
    var updatedAt: Date

    var attributionSource: AttributionSource {
        get { AttributionSource(rawValue: attributionSourceRaw) ?? .auto }
        set { attributionSourceRaw = newValue.rawValue; updatedAt = .now }
    }
    var preState: TableState {
        get { Blob.decode(TableState.self, preStateData, fallback: TableState(spec: TableSpec(size: .sevenFoot))) }
        set { preStateData = Blob.encode(newValue); updatedAt = .now }
    }
    var postState: TableState {
        get { Blob.decode(TableState.self, postStateData, fallback: TableState(spec: TableSpec(size: .sevenFoot))) }
        set { postStateData = Blob.encode(newValue); updatedAt = .now }
    }
    var calledPocket: Pocket? {
        get { calledPocketRaw.flatMap(Pocket.init(rawValue:)) }
        set { calledPocketRaw = newValue?.rawValue; updatedAt = .now }
    }
    var firstContact: BallID? {
        get { firstContactNumber.flatMap(BallID.init) }
        set { firstContactNumber = newValue?.number; updatedAt = .now }
    }
    var pocketed: [BallID: Pocket] {
        get { Blob.decode([BallID: Pocket].self, pocketedData, fallback: [:]) }
        set { pocketedData = Blob.encode(newValue); updatedAt = .now }
    }
    var fouls: [Foul] {
        get { Blob.decode([Foul].self, foulsData, fallback: []) }
        set { foulsData = Blob.encode(newValue); updatedAt = .now }
    }
    var features: StoredShotFeatures {
        get { Blob.decode(StoredShotFeatures.self, featuresData,
                          fallback: StoredShotFeatures(cutBucket: .c0to15, distanceBucket: .short, pocketType: .corner, kind: .plain)) }
        set { featuresData = Blob.encode(newValue); updatedAt = .now }
    }
    var cueResult: CueResult {
        get { CueResult(rawValue: cueResultRaw) ?? .notApplicable }
        set { cueResultRaw = newValue.rawValue; updatedAt = .now }
    }
    var decisionRating: DecisionRating {
        get { DecisionRating(rawValue: decisionRatingRaw) ?? .good }
        set { decisionRatingRaw = newValue.rawValue; updatedAt = .now }
    }
    var executionRating: ExecutionRating {
        get { Blob.decode(ExecutionRating.self, executionRatingData,
                          fallback: ExecutionRating(result: .miss, position: .notApplicable)) }
        set { executionRatingData = Blob.encode(newValue); updatedAt = .now }
    }

    init(id: UUID = UUID(), index: Int, shooterID: UUID, attributionSource: AttributionSource,
         preState: TableState, postState: TableState, calledPocket: Pocket?, firstContact: BallID?,
         railsAfterContact: Int, pocketed: [BallID: Pocket], fouls: [Foul], features: StoredShotFeatures,
         made: Bool, onTarget: Bool, cueResult: CueResult, decisionRating: DecisionRating,
         executionRating: ExecutionRating, wpaDelta: Double, isClutch: Bool, timeOnShot: Double,
         clipRef: String?, updatedAt: Date = .now) {
        self.id = id
        self.indexValue = index
        self.shooterIDValue = shooterID
        self.attributionSourceRaw = attributionSource.rawValue
        self.preStateData = Blob.encode(preState)
        self.postStateData = Blob.encode(postState)
        self.calledPocketRaw = calledPocket?.rawValue
        self.firstContactNumber = firstContact?.number
        self.railsAfterContactValue = railsAfterContact
        self.pocketedData = Blob.encode(pocketed)
        self.foulsData = Blob.encode(fouls)
        self.featuresData = Blob.encode(features)
        self.madeValue = made
        self.onTargetValue = onTarget
        self.cueResultRaw = cueResult.rawValue
        self.decisionRatingRaw = decisionRating.rawValue
        self.executionRatingData = Blob.encode(executionRating)
        self.wpaDeltaValue = wpaDelta
        self.isClutchValue = isClutch
        self.timeOnShotValue = timeOnShot
        self.clipRefValue = clipRef
        self.updatedAt = updatedAt
    }

    func touch(_ now: Date = .now) { updatedAt = now }
}

/// Append-only archetype history per player (plain `playerID`, no relationship).
@Model
final class ArchetypeSnapshot {
    @Attribute(.unique) var id: UUID
    private var playerIDValue: UUID
    var playerID: UUID { get { playerIDValue } set { playerIDValue = newValue; updatedAt = .now } }
    private var computedAtValue: Date
    var computedAt: Date { get { computedAtValue } set { computedAtValue = newValue; updatedAt = .now } }
    private var gamesCountValue: Int
    var gamesCount: Int { get { gamesCountValue } set { gamesCountValue = newValue; updatedAt = .now } }
    private var shotsCountValue: Int
    var shotsCount: Int { get { shotsCountValue } set { shotsCountValue = newValue; updatedAt = .now } }
    private var vectorData: Data
    /// Archetype tag identifiers (e.g. "cutArtist"); `ArchetypeTag` lives in Stats once it exists.
    private var tagsValue: [String]
    var tags: [String] { get { tagsValue } set { tagsValue = newValue; updatedAt = .now } }
    private var proCompData: Data?
    var updatedAt: Date

    var vector: [String: Double] {
        get { Blob.decode([String: Double].self, vectorData, fallback: [:]) }
        set { vectorData = Blob.encode(newValue); updatedAt = .now }
    }
    var proComp: StoredProComp? {
        get { proCompData.map { Blob.decode(StoredProComp?.self, $0, fallback: nil) } ?? nil }
        set { proCompData = newValue.map(Blob.encode); updatedAt = .now }
    }

    init(id: UUID = UUID(), playerID: UUID, computedAt: Date, gamesCount: Int, shotsCount: Int,
         vector: [String: Double], tags: [String], proComp: StoredProComp?, updatedAt: Date? = nil) {
        self.id = id
        self.playerIDValue = playerID
        self.computedAtValue = computedAt
        self.gamesCountValue = gamesCount
        self.shotsCountValue = shotsCount
        self.vectorData = Blob.encode(vector)
        self.tagsValue = tags
        self.proCompData = proComp.map(Blob.encode)
        self.updatedAt = updatedAt ?? computedAt
    }
}

@Model
final class Highlight {
    @Attribute(.unique) var id: UUID
    fileprivate var gameLink: Game?
    var game: Game? { get { gameLink } set { gameLink = newValue; updatedAt = .now } }
    private var shotIDValue: UUID
    var shotID: UUID { get { shotIDValue } set { shotIDValue = newValue; updatedAt = .now } }
    private var kindRaw: String
    /// Relative path inside the app container. Clips are never exported to Photos or backups.
    private var clipFileValue: String
    var clipFile: String { get { clipFileValue } set { clipFileValue = newValue; updatedAt = .now } }
    /// ≤ 2 words.
    private var labelValue: String
    var label: String { get { labelValue } set { labelValue = newValue; updatedAt = .now } }
    private var scoreValue: Double
    var score: Double { get { scoreValue } set { scoreValue = newValue; updatedAt = .now } }
    var updatedAt: Date

    var kind: HighlightKind {
        get { HighlightKind(rawValue: kindRaw) ?? .shotOfGame }
        set { kindRaw = newValue.rawValue; updatedAt = .now }
    }

    init(id: UUID = UUID(), shotID: UUID, kind: HighlightKind, clipFile: String, label: String,
         score: Double, updatedAt: Date = .now) {
        self.id = id
        self.shotIDValue = shotID
        self.kindRaw = kind.rawValue
        self.clipFileValue = clipFile
        self.labelValue = label
        self.scoreValue = score
        self.updatedAt = updatedAt
    }
}

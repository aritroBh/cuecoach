import Foundation
import SwiftData
import Geometry

// Training store (Training.store). Never linked to the competitive store: players are referenced
// by plain `playerID` values only. See docs/SCHEMA.md.

@Model
final class TrainingProfile {
    @Attribute(.unique) var id: UUID
    private var playerIDValue: UUID
    var playerID: UUID { get { playerIDValue } set { playerIDValue = newValue; updatedAt = .now } }
    private var createdAtValue: Date
    var createdAt: Date { get { createdAtValue } set { createdAtValue = newValue; updatedAt = .now } }
    var updatedAt: Date

    init(id: UUID = UUID(), playerID: UUID, createdAt: Date = .now, updatedAt: Date? = nil) {
        self.id = id
        self.playerIDValue = playerID
        self.createdAtValue = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }
}

@Model
final class DrillProgress {
    static let levels = 1...4

    @Attribute(.unique) var id: UUID
    private var playerIDValue: UUID
    var playerID: UUID { get { playerIDValue } set { playerIDValue = newValue; updatedAt = .now } }
    /// `DrillID` raw value (Training module, Phase 8).
    private var drillValue: String
    var drill: String { get { drillValue } set { drillValue = newValue; updatedAt = .now } }
    private var levelValue: Int
    var level: Int { get { levelValue } set { levelValue = newValue; updatedAt = .now } }
    /// Rolling window of recent attempt outcomes.
    private var recentResultsValue: [Bool]
    var recentResults: [Bool] { get { recentResultsValue } set { recentResultsValue = newValue; updatedAt = .now } }
    private var levelHistoryData: Data
    var updatedAt: Date
    @Relationship(deleteRule: .cascade, inverse: \TrainingAttempt.progressLink)
    fileprivate var attemptsLink: [TrainingAttempt] = []
    var attempts: [TrainingAttempt] { get { attemptsLink } set { attemptsLink = newValue; updatedAt = .now } }

    var levelHistory: [LevelChange] {
        get { Blob.decode([LevelChange].self, levelHistoryData, fallback: []) }
        set { levelHistoryData = Blob.encode(newValue); updatedAt = .now }
    }

    init(id: UUID = UUID(), playerID: UUID, drill: String, level: Int, recentResults: [Bool] = [],
         levelHistory: [LevelChange] = [], updatedAt: Date = .now) {
        self.id = id
        self.playerIDValue = playerID
        self.drillValue = drill
        self.levelValue = min(max(level, Self.levels.lowerBound), Self.levels.upperBound)
        self.recentResultsValue = recentResults
        self.levelHistoryData = Blob.encode(levelHistory)
        self.updatedAt = updatedAt
    }

    func touch(_ now: Date = .now) { updatedAt = now }
}

@Model
final class TrainingAttempt {
    @Attribute(.unique) var id: UUID
    fileprivate var progressLink: DrillProgress?
    var progress: DrillProgress? { get { progressLink } set { progressLink = newValue; updatedAt = .now } }
    private var atValue: Date
    var at: Date { get { atValue } set { atValue = newValue; updatedAt = .now } }
    private var setupData: Data
    private var resultData: Data
    private var madeValue: Bool
    var made: Bool { get { madeValue } set { madeValue = newValue; updatedAt = .now } }
    private var featuresData: Data
    var updatedAt: Date

    var setup: TableState {
        get { Blob.decode(TableState.self, setupData, fallback: TableState(spec: TableSpec(size: .sevenFoot))) }
        set { setupData = Blob.encode(newValue); updatedAt = .now }
    }
    var result: TableState {
        get { Blob.decode(TableState.self, resultData, fallback: TableState(spec: TableSpec(size: .sevenFoot))) }
        set { resultData = Blob.encode(newValue); updatedAt = .now }
    }
    var features: StoredAttemptFeatures {
        get { Blob.decode(StoredAttemptFeatures.self, featuresData,
                          fallback: StoredAttemptFeatures(signedCutError: 0, signedSpeedError: 0,
                                                          cueLandingError: 0, spinIntended: 0, spinObserved: 0)) }
        set { featuresData = Blob.encode(newValue); updatedAt = .now }
    }

    init(id: UUID = UUID(), at: Date, setup: TableState, result: TableState, made: Bool,
         features: StoredAttemptFeatures, updatedAt: Date? = nil) {
        self.id = id
        self.atValue = at
        self.setupData = Blob.encode(setup)
        self.resultData = Blob.encode(result)
        self.madeValue = made
        self.featuresData = Blob.encode(features)
        self.updatedAt = updatedAt ?? at
    }
}

@Model
final class BiasRecord {
    @Attribute(.unique) var id: UUID
    private var playerIDValue: UUID
    var playerID: UUID { get { playerIDValue } set { playerIDValue = newValue; updatedAt = .now } }
    private var drillValue: String
    var drill: String { get { drillValue } set { drillValue = newValue; updatedAt = .now } }
    private var axisRaw: String
    /// +1 / −1 (e.g. overcut vs undercut).
    private var signValue: Int
    var sign: Int { get { signValue } set { signValue = newValue; updatedAt = .now } }
    private var attemptsWindowValue: Int
    var attemptsWindow: Int { get { attemptsWindowValue } set { attemptsWindowValue = newValue; updatedAt = .now } }
    private var detectedAtValue: Date
    var detectedAt: Date { get { detectedAtValue } set { detectedAtValue = newValue; updatedAt = .now } }
    private var resolvedAtValue: Date?
    var resolvedAt: Date? { get { resolvedAtValue } set { resolvedAtValue = newValue; updatedAt = .now } }
    var updatedAt: Date

    var axis: BiasAxis {
        get { BiasAxis(rawValue: axisRaw) ?? .cut }
        set { axisRaw = newValue.rawValue; updatedAt = .now }
    }

    init(id: UUID = UUID(), playerID: UUID, drill: String, axis: BiasAxis, sign: Int, attemptsWindow: Int,
         detectedAt: Date, resolvedAt: Date? = nil, updatedAt: Date? = nil) {
        self.id = id
        self.playerIDValue = playerID
        self.drillValue = drill
        self.axisRaw = axis.rawValue
        self.signValue = sign
        self.attemptsWindowValue = attemptsWindow
        self.detectedAtValue = detectedAt
        self.resolvedAtValue = resolvedAt
        self.updatedAt = updatedAt ?? resolvedAt ?? detectedAt
    }

    func touch(_ now: Date = .now) { updatedAt = now }
}

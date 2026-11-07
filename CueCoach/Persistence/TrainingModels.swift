import Foundation
import SwiftData
import Geometry

// Training store (Training.store). Never linked to the competitive store: players are referenced
// by plain `playerID` values only. See docs/SCHEMA.md.

@Model
final class TrainingProfile {
    @Attribute(.unique) var id: UUID
    var playerID: UUID
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), playerID: UUID, createdAt: Date = .now, updatedAt: Date? = nil) {
        self.id = id
        self.playerID = playerID
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }
}

@Model
final class DrillProgress {
    static let levels = 1...4

    @Attribute(.unique) var id: UUID
    var playerID: UUID
    /// `DrillID` raw value (Training module, Phase 8).
    var drill: String
    var level: Int
    /// Rolling window of recent attempt outcomes.
    var recentResults: [Bool]
    private var levelHistoryData: Data
    var updatedAt: Date
    @Relationship(deleteRule: .cascade, inverse: \TrainingAttempt.progress)
    var attempts: [TrainingAttempt] = []

    var levelHistory: [LevelChange] {
        get { Blob.decode([LevelChange].self, levelHistoryData, fallback: []) }
        set { levelHistoryData = Blob.encode(newValue) }
    }

    init(id: UUID = UUID(), playerID: UUID, drill: String, level: Int, recentResults: [Bool] = [],
         levelHistory: [LevelChange] = [], updatedAt: Date = .now) {
        self.id = id
        self.playerID = playerID
        self.drill = drill
        self.level = min(max(level, Self.levels.lowerBound), Self.levels.upperBound)
        self.recentResults = recentResults
        self.levelHistoryData = Blob.encode(levelHistory)
        self.updatedAt = updatedAt
    }

    func touch(_ now: Date = .now) { updatedAt = now }
}

@Model
final class TrainingAttempt {
    @Attribute(.unique) var id: UUID
    var progress: DrillProgress?
    var at: Date
    private var setupData: Data
    private var resultData: Data
    var made: Bool
    private var featuresData: Data
    var updatedAt: Date

    var setup: TableState {
        get { Blob.decode(TableState.self, setupData, fallback: TableState(spec: TableSpec(size: .sevenFoot))) }
        set { setupData = Blob.encode(newValue) }
    }
    var result: TableState {
        get { Blob.decode(TableState.self, resultData, fallback: TableState(spec: TableSpec(size: .sevenFoot))) }
        set { resultData = Blob.encode(newValue) }
    }
    var features: StoredAttemptFeatures {
        get { Blob.decode(StoredAttemptFeatures.self, featuresData,
                          fallback: StoredAttemptFeatures(signedCutError: 0, signedSpeedError: 0,
                                                          cueLandingError: 0, spinIntended: 0, spinObserved: 0)) }
        set { featuresData = Blob.encode(newValue) }
    }

    init(id: UUID = UUID(), at: Date, setup: TableState, result: TableState, made: Bool,
         features: StoredAttemptFeatures, updatedAt: Date? = nil) {
        self.id = id
        self.at = at
        self.setupData = Blob.encode(setup)
        self.resultData = Blob.encode(result)
        self.made = made
        self.featuresData = Blob.encode(features)
        self.updatedAt = updatedAt ?? at
    }
}

@Model
final class BiasRecord {
    @Attribute(.unique) var id: UUID
    var playerID: UUID
    var drill: String
    private var axisRaw: String
    /// +1 / −1 (e.g. overcut vs undercut).
    var sign: Int
    var attemptsWindow: Int
    var detectedAt: Date
    var resolvedAt: Date?
    var updatedAt: Date

    var axis: BiasAxis {
        get { BiasAxis(rawValue: axisRaw) ?? .cut }
        set { axisRaw = newValue.rawValue }
    }

    init(id: UUID = UUID(), playerID: UUID, drill: String, axis: BiasAxis, sign: Int, attemptsWindow: Int,
         detectedAt: Date, resolvedAt: Date? = nil, updatedAt: Date? = nil) {
        self.id = id
        self.playerID = playerID
        self.drill = drill
        self.axisRaw = axis.rawValue
        self.sign = sign
        self.attemptsWindow = attemptsWindow
        self.detectedAt = detectedAt
        self.resolvedAt = resolvedAt
        self.updatedAt = updatedAt ?? resolvedAt ?? detectedAt
    }

    func touch(_ now: Date = .now) { updatedAt = now }
}

import Foundation
import Geometry
import Rules
import Engine

/// Manual JSON backup, format version 1 (docs/SCHEMA.md "Backup JSON").
/// Plain Codable DTOs, decoupled from the @Model classes so the file format stays stable.
/// Clips are never included; highlights keep metadata only. Session-guest profiles are never exported.
struct BackupV1: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int = BackupV1.currentVersion
    var exportedAt: Date
    var competitive: Competitive
    var training: Training

    struct Competitive: Codable, Equatable, Sendable {
        var profiles: [Profile] = []
        var sessions: [SessionDTO] = []
        var games: [GameDTO] = []
        var shots: [ShotDTO] = []
        var archetypes: [Archetype] = []
        var highlights: [HighlightDTO] = []
    }

    struct Training: Codable, Equatable, Sendable {
        var profiles: [TrainingProfileDTO] = []
        var drillProgress: [DrillProgressDTO] = []
        var attempts: [Attempt] = []
        var biases: [Bias] = []
    }

    struct Profile: Codable, Equatable, Sendable {
        var id: UUID
        var name: String
        var avatarSymbol: String
        var avatarColor: String
        var isLocalOwner: Bool
        var createdAt: Date
        var updatedAt: Date
        var skillModel: StoredSkillModel
        /// "Delete recognition data" tombstone: the flag travels so revocation survives a restore.
        /// Embeddings themselves are never exported (D26, SPEC §2); a legacy file's `recognition` key is ignored.
        var recognitionRevokedAt: Date? = nil
    }

    struct SessionDTO: Codable, Equatable, Sendable {
        var id: UUID
        var startedAt: Date
        var endedAt: Date?
        var ruleSet: RuleSetID
        var format: GameFormat
        var tableSize: TableSize
        var peerDeviceNames: [String]
        /// Keyed by `RuleSetID.rawValue` so the JSON is a plain object.
        var voteTally: [String: Int]
        var updatedAt: Date
    }

    struct GameDTO: Codable, Equatable, Sendable {
        var id: UUID
        var sessionID: UUID?
        var index: Int
        var ruleSet: RuleSetID
        var teams: [StoredTeam]
        var winnerTeam: Int?
        var winProbSeries: [Double]
        var startedAt: Date
        var endedAt: Date?
        var updatedAt: Date
    }

    struct ShotDTO: Codable, Equatable, Sendable {
        var id: UUID
        var gameID: UUID?
        var index: Int
        var shooterID: UUID
        var attributionSource: AttributionSource
        var preState: TableState
        var postState: TableState
        var calledPocket: Pocket?
        var firstContact: BallID?
        var railsAfterContact: Int
        /// Keyed by ball number ("8") so the JSON is a plain object.
        var pocketed: [String: Pocket]
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
        var updatedAt: Date
    }

    struct Archetype: Codable, Equatable, Sendable {
        var id: UUID
        var playerID: UUID
        var computedAt: Date
        var gamesCount: Int
        var shotsCount: Int
        var vector: [String: Double]
        var tags: [String]
        var proComp: StoredProComp?
        var updatedAt: Date
    }

    struct HighlightDTO: Codable, Equatable, Sendable {
        var id: UUID
        var gameID: UUID?
        var shotID: UUID
        var kind: HighlightKind
        var clipFile: String
        var label: String
        var score: Double
        var updatedAt: Date
    }

    struct TrainingProfileDTO: Codable, Equatable, Sendable {
        var id: UUID
        var playerID: UUID
        var createdAt: Date
        var updatedAt: Date
    }

    struct DrillProgressDTO: Codable, Equatable, Sendable {
        var id: UUID
        var playerID: UUID
        var drill: String
        var level: Int
        var recentResults: [Bool]
        var levelHistory: [LevelChange]
        var updatedAt: Date
    }

    struct Attempt: Codable, Equatable, Sendable {
        var id: UUID
        var progressID: UUID?
        var at: Date
        var setup: TableState
        var result: TableState
        var made: Bool
        var features: StoredAttemptFeatures
        var updatedAt: Date
    }

    struct Bias: Codable, Equatable, Sendable {
        var id: UUID
        var playerID: UUID
        var drill: String
        var axis: BiasAxis
        var sign: Int
        var attemptsWindow: Int
        var detectedAt: Date
        var resolvedAt: Date?
        var updatedAt: Date
    }
}

enum BackupError: Error, Equatable {
    case unsupportedVersion(Int)
    /// A row references a parent that is neither in the backup nor on this device.
    case missingParent(child: String, childID: UUID, parentID: UUID)
    /// Import refused: a store has unsaved edits that a failed import would otherwise roll back.
    case pendingChanges
}

// MARK: - JSON coding (ISO-8601 with milliseconds, sorted keys)

extension BackupV1 {
    private struct Header: Decodable { var version: Int }

    private static let isoFractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let isoWhole = Date.ISO8601FormatStyle()

    /// Whole milliseconds since 1970. Backups carry millisecond precision; merge compares at this grain.
    static func millis(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }

    /// "yyyy-MM-ddTHH:mm:ss.SSSZ". Formatted by hand because ISO8601FormatStyle truncates
    /// (not rounds) fractional seconds, which drifts 1 ms on every export/import cycle.
    static func isoString(_ date: Date) -> String {
        let ms = millis(date)
        let secs = ms >= 0 ? ms / 1000 : (ms - 999) / 1000
        let frac = ms - secs * 1000
        let whole = Date(timeIntervalSince1970: TimeInterval(secs)).formatted(isoWhole)   // ends in "Z"
        return whole.dropLast() + "." + String(format: "%03lld", frac) + "Z"
    }

    /// Non-finite Doubles (a stat that overflowed, a NaN feature) are written as these strings instead of
    /// failing the whole export, and read back unchanged (audit F6/F10).
    static let nonFinite = (positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")

    /// Parses `s`, rejecting impossible calendar values that the parser would roll over
    /// ("2023-02-30" → Mar 2): the parsed instant must format back to the same date and time fields.
    static func parseDate(_ s: String) -> Date? {
        guard let date = (try? isoFractional.parse(s)) ?? (try? isoWhole.parse(s)) else { return nil }
        let wholeSeconds = Date(timeIntervalSince1970: (date.timeIntervalSince1970).rounded(.down))
        let fields = wholeSeconds.formatted(isoWhole).prefix(19)          // "yyyy-MM-ddTHH:mm:ss"
        return s.hasPrefix(fields) ? date : nil
    }

    static func decode(_ data: Data) throws -> BackupV1 {
        let d = JSONDecoder()
        d.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: nonFinite.positiveInfinity, negativeInfinity: nonFinite.negativeInfinity,
            nan: nonFinite.nan)
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            if let date = parseDate(s) { return date }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Not a valid ISO-8601 date: \(s)")
        }
        let version = try d.decode(Header.self, from: data).version
        guard version == currentVersion else { throw BackupError.unsupportedVersion(version) }
        return try d.decode(BackupV1.self, from: data)
    }

    func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: Self.nonFinite.positiveInfinity, negativeInfinity: Self.nonFinite.negativeInfinity,
            nan: Self.nonFinite.nan)
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(Self.isoString(date))
        }
        return try e.encode(self)
    }
}

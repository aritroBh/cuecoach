import Foundation

// Codable value types persisted inside @Model rows and mirrored verbatim in BackupV1.
// The `Stored*` types stand in for CueCore types that don't exist yet (SkillModel → Engine,
// ShotFeatures/ProComp → Stats, AttemptFeatures → Training). When those land, map them here;
// the on-disk/backup format stays these shapes.

/// Per-player execution noise used by the shot engine (docs/SCHEMA.md `skillModel`).
struct StoredSkillModel: Hashable, Codable, Sendable {
    var aimSigma: Double
    var speedSigma: Double
    var spinSigma: Double
    var samples: Int
    static let prior = StoredSkillModel(aimSigma: 0.02, speedSigma: 0.1, spinSigma: 0.2, samples: 0)
}

/// One team in a game. Mid-game shooting-order edits are appended to `orderChanges`.
struct StoredTeam: Hashable, Codable, Sendable {
    struct OrderChange: Hashable, Codable, Sendable {
        var afterShotIndex: Int
        var shootingOrder: [UUID]
    }
    var memberIDs: [UUID]
    var shootingOrder: [UUID]
    var orderChanges: [OrderChange] = []
}

enum AttributionSource: String, Codable, Sendable, CaseIterable { case auto, turnOrder, tap }
enum CueResult: String, Codable, Sendable, CaseIterable { case inZone, outOfZone, notApplicable }
enum HighlightKind: String, Codable, Sendable, CaseIterable { case shotOfGame, mvp }
enum BiasAxis: String, Codable, Sendable, CaseIterable { case cut, side, speed, cueDistance, spin }

/// Shot classification buckets (docs/SPEC.md §6).
struct StoredShotFeatures: Hashable, Codable, Sendable {
    enum CutBucket: String, Codable, Sendable, CaseIterable { case c0to15, c15to30, c30to45, c45to60, c60plus }
    enum DistanceBucket: String, Codable, Sendable, CaseIterable { case short, mid, long }
    enum PocketType: String, Codable, Sendable, CaseIterable { case corner, side }
    enum Kind: String, Codable, Sendable, CaseIterable { case plain, bank, combo, kick, rail, jump, safety }
    var cutBucket: CutBucket
    var distanceBucket: DistanceBucket
    var pocketType: PocketType
    var kind: Kind
}

/// Closest pro for an archetype snapshot.
struct StoredProComp: Hashable, Codable, Sendable {
    var proID: String
    var similarity: Double
    var sharedTraits: [String]
}

struct LevelChange: Hashable, Codable, Sendable {
    var at: Date
    var from: Int
    var to: Int
}

/// Signed errors of one training attempt (docs/SCHEMA.md `AttemptFeatures`).
struct StoredAttemptFeatures: Hashable, Codable, Sendable {
    var signedCutError: Double
    var signedSpeedError: Double
    var cueLandingError: Double
    var spinIntended: Double
    var spinObserved: Double
}

/// JSON blob helper for composite values stored as `Data` columns.
/// Composite values are stored as JSON blobs rather than SwiftData composite attributes because
/// `TableState` and `[BallID: Pocket]` use non-String dictionary keys, which SwiftData can't map.
enum Blob {
    static func encode<T: Encodable>(_ value: T) -> Data {
        let e = JSONEncoder()
        e.outputFormatting = .sortedKeys
        e.dateEncodingStrategy = .millisecondsSince1970
        do { return try e.encode(value) } catch { preconditionFailure("Blob encode \(T.self): \(error)") }
    }

    static func decode<T: Decodable>(_ type: T.Type, _ data: Data, fallback: @autoclosure () -> T) -> T {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .millisecondsSince1970
        return (try? d.decode(T.self, from: data)) ?? fallback()
    }
}

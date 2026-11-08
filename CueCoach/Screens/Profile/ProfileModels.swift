import Foundation
import Rules

// Local contracts for the Player profile screen. The Stats agent implements `ProfileStatsSource`
// from Shot rows; Training implements `TrainingProfileSource` from the Training store only.

typealias CutBucket = StoredShotFeatures.CutBucket
typealias DistanceBucket = StoredShotFeatures.DistanceBucket

struct ProfileSummary: Equatable, Sendable {
    var id: UUID
    var name: String
    var avatarSymbol: String
    /// Hex "#RRGGBB" (SCHEMA `avatarColor`).
    var avatarColor: String
    var isTeamA: Bool = false
    var games: Int
    var wins: Int
    var shots: Int
    var makes: Int
}

struct ArchetypeView: Equatable, Sendable {
    var vector: [String: Double]
    /// Tag ids, strongest first (e.g. "cutArtist").
    var tags: [String]
    /// Previous snapshot's vector, for the long-press evolution overlay.
    var previous: [String: Double]?
}

struct HeatCell: Equatable, Sendable {
    var cut: CutBucket
    var distance: DistanceBucket
    var attempts: Int
    var makes: Int
}

struct EarnedBadge: Equatable, Sendable, Identifiable {
    var id: String
    var name: String
    var symbol: String
    var earnedAt: Date
}

/// One shelf disc per badge kind (name + glyph), however many times it was awarded.
struct BadgeGroup: Equatable, Sendable, Identifiable {
    var name: String
    var symbol: String
    /// Award dates, newest first.
    var dates: [Date]
    var id: String { name + "|" + symbol }
    var count: Int { dates.count }
    var latest: Date { dates[0] }
    /// Quiet count line for repeat awards (badges are per game), nil for a single award.
    var countCaption: String? { count > 1 ? "\(count) games" : nil }
}

struct ProCompView: Equatable, Sendable {
    var proName: String
    var similarity: Double
    /// Archetype vector keys shared with the pro, strongest first.
    var sharedTraits: [String]
    /// The pro's shape on the same axes as the archetype vector (`ProProfiles.json`, SPEC §8). Keys the
    /// pro has no sourced value for are absent, never filled in.
    var proVector: [String: Double] = [:]
}

struct GameSummary: Equatable, Sendable, Identifiable {
    var id: UUID
    var index: Int
    /// nil = unfinished.
    var won: Bool?
}

struct SessionSummary: Equatable, Sendable, Identifiable {
    var id: UUID
    var startedAt: Date
    var ruleSet: RuleSetID
    var format: GameFormat
    var games: [GameSummary]

    /// More games won than lost = won, fewer = lost, equal = tied; nil when no game finished.
    var result: SessionResult? {
        let w = games.filter { $0.won == true }.count
        let l = games.filter { $0.won == false }.count
        if w + l == 0 { return nil }
        return w > l ? .won : w < l ? .lost : .tied
    }
}

enum SessionResult: Equatable, Sendable {
    case won, lost, tied
    init?(game won: Bool?) {
        guard let won else { return nil }
        self = won ? .won : .lost
    }
    var spoken: String {
        switch self { case .won: "Won"; case .lost: "Lost"; case .tied: "Tied" }
    }
}

protocol ProfileStatsSource: Sendable {
    func profile(_ id: UUID) async throws -> ProfileSummary
    func archetype(_ id: UUID) async throws -> ArchetypeView?
    func makeGrid(_ id: UUID) async throws -> [HeatCell]
    func badges(_ id: UUID) async throws -> [EarnedBadge]
    func proComp(_ id: UUID) async throws -> ProCompView?
    func history(_ id: UUID) async throws -> [SessionSummary]
    /// Writes the owner's name and avatar glyph to the competitive `PlayerProfile` row.
    func updateProfile(_ id: UUID, name: String, avatarSymbol: String) async throws
}

// MARK: Training (separate store, never joined with the competitive types above)

struct DrillLevel: Equatable, Sendable, Identifiable {
    var drill: String
    var name: String
    var level: Int
    var id: String { drill }
    var clampedLevel: Int { min(4, max(1, level)) }
}

struct BiasHint: Equatable, Sendable {
    var axis: BiasAxis
    var sign: Int

    /// ≤2 words, never numeric.
    var word: String {
        let plus = sign >= 0
        switch axis {
        case .cut: return plus ? "Overcut" : "Undercut"
        case .side: return plus ? "Drifts right" : "Drifts left"
        case .speed: return plus ? "Too hard" : "Too soft"
        case .cueDistance: return plus ? "Rolls long" : "Stops short"
        case .spin: return plus ? "Overspin" : "Underspin"
        }
    }
    var symbol: String {
        switch axis {
        case .cut, .side: "arrow.uturn.left"
        case .speed: sign >= 0 ? "gauge.with.dots.needle.67percent" : "gauge.with.dots.needle.33percent"
        case .cueDistance: "arrow.left.and.right"
        case .spin: "arrow.trianglehead.2.clockwise.rotate.90"
        }
    }
}

protocol TrainingProfileSource: Sendable {
    func drills(_ playerID: UUID) async throws -> [DrillLevel]
    func activeBias(_ playerID: UUID) async throws -> BiasHint?
}

// MARK: Archetype tags (SPEC §7)

struct ArchetypeTagInfo: Equatable, Sendable {
    let id: String
    let name: String
    let symbol: String

    init?(_ id: String) {
        let table: [String: (String, String)] = [
            "cutArtist": ("Cut Artist", "scope"),
            "longGun": ("Long Gun", "arrow.up.right"),
            "sidePocketSniper": ("Side-Pocket Sniper", "circle.dotted"),
            "iceVeins": ("Ice Veins", "snowflake"),
            "safetyChess": ("Safety Chess", "shield.lefthalf.filled"),
            "cannonBreak": ("Cannon Break", "burst.fill"),
            "runOutMachine": ("Run-out Machine", "repeat"),
            "bankWizard": ("Bank Wizard", "arrow.turn.up.right"),
        ]
        guard let (name, symbol) = table[id] else { return nil }
        self.id = id
        self.name = name
        self.symbol = symbol
    }
}

/// Short axis names + trait glyphs for archetype vector keys.
enum ArchetypeAxis {
    static let names: [String: String] = [
        "cut": "Cut", "long": "Long", "bank": "Banks", "side": "Side", "clutch": "Clutch",
        "safety": "Safety", "break": "Break", "runout": "Run-outs",
    ]
    static let symbols: [String: String] = [
        "cut": "scope", "long": "arrow.up.right", "bank": "arrow.turn.up.right", "side": "circle.dotted",
        "clutch": "snowflake", "safety": "shield.lefthalf.filled", "break": "burst.fill", "runout": "repeat",
    ]
    static func name(_ key: String) -> String { names[key] ?? key.prefix(1).uppercased() + key.dropFirst() }
}

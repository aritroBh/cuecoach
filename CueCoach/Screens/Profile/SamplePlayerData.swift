import Foundation
import Rules
import Synchronization

/// In-memory fixtures for previews, tests and the debug router: `.newPlayer`, `.preUnlock`, `.veteran`, `.error`,
/// `.errorOnce` (fails the first load, then recovers). Each access builds a fresh fixture, so edits made through
/// one (rename) never leak into another.
struct SamplePlayerData: Sendable {
    let playerID: UUID
    let stats: SampleStatsSource
    let training: SampleTrainingSource

    static var newPlayer: SamplePlayerData {
        let id = UUID()
        return .init(playerID: id,
                     stats: .init(summary: .init(id: id, name: "Riley", avatarSymbol: "person.fill",
                                                 avatarColor: "#A78BFA", games: 0, wins: 0, shots: 0, makes: 0)),
                     training: .init(drills: [], bias: nil))
    }

    static var preUnlock: SamplePlayerData {
        let id = UUID()
        return .init(playerID: id,
                     stats: .init(summary: .init(id: id, name: "Jo", avatarSymbol: "star.fill",
                                                 avatarColor: "#F59E0B", games: 2, wins: 1, shots: 38, makes: 19),
                                  archetype: .init(vector: vector(0.5), tags: ["longGun"]),
                                  grid: grid(scale: 0.4, attempts: 4),
                                  badges: [],
                                  pro: .init(proName: "Earl Strickland", similarity: 0.6, sharedTraits: ["break"]),
                                  history: Array(sessions.prefix(1))),
                     training: .init(drills: [.init(drill: "straightIn", name: "Straight-ins", level: 2)], bias: nil))
    }

    static var veteran: SamplePlayerData {
        let id = UUID()
        return .init(playerID: id,
                     stats: .init(summary: .init(id: id, name: "Sam", avatarSymbol: "person.fill",
                                                 avatarColor: "#60A5FA", isTeamA: true,
                                                 games: 42, wins: 25, shots: 812, makes: 503),
                                  archetype: .init(vector: ["cut": 0.86, "long": 0.55, "bank": 0.72, "side": 0.4,
                                                            "clutch": 0.63, "safety": 0.35, "break": 0.5,
                                                            "runout": 0.58],
                                                   tags: ["cutArtist", "bankWizard"],
                                                   previous: ["cut": 0.7, "long": 0.5, "bank": 0.5, "side": 0.45,
                                                              "clutch": 0.5, "safety": 0.3, "break": 0.45,
                                                              "runout": 0.4]),
                                  grid: grid(scale: 1, attempts: 40),
                                  badges: badges,
                                  pro: .init(proName: "Efren Reyes", similarity: 0.78, sharedTraits: ["cut", "bank"],
                                             proVector: ["cut": 0.95, "long": 0.6, "bank": 0.97, "side": 0.7,
                                                         "clutch": 0.9, "safety": 0.85, "break": 0.55,
                                                         "runout": 0.8]),
                                  history: sessions),
                     training: .init(drills: [.init(drill: "straightIn", name: "Straight-ins", level: 3),
                                              .init(drill: "cuts", name: "Cuts", level: 2),
                                              .init(drill: "banks", name: "Banks", level: 1)],
                                     bias: .init(axis: .cut, sign: 1)))
    }

    static var error: SamplePlayerData {
        let id = UUID()
        return .init(playerID: id,
                     stats: .init(summary: .init(id: id, name: "?", avatarSymbol: "person", avatarColor: "#888888",
                                                 games: 0, wins: 0, shots: 0, makes: 0), failures: .max),
                     // Training is a separate store: it still loads when competitive stats fail.
                     training: .init(drills: [.init(drill: "straightIn", name: "Straight-ins", level: 2)], bias: nil))
    }

    /// The veteran, behind a store that is unreadable for the first load only (exercises Retry).
    static var errorOnce: SamplePlayerData {
        let v = veteran
        return .init(playerID: v.playerID, stats: v.stats.failing(firstLoads: 1), training: v.training)
    }

    static func named(_ name: String) -> SamplePlayerData? {
        switch name {
        case "newPlayer": .newPlayer
        case "preUnlock": .preUnlock
        case "veteran": .veteran
        case "error": .error
        case "errorOnce": .errorOnce
        default: nil
        }
    }

    // MARK: builders

    private static func vector(_ v: Double) -> [String: Double] {
        ["cut": v, "long": v + 0.1, "bank": v - 0.2, "side": v, "clutch": v - 0.1, "safety": v + 0.05]
    }

    private static func grid(scale: Double, attempts: Int) -> [HeatCell] {
        var cells: [HeatCell] = []
        for (di, d) in DistanceBucket.allCases.enumerated() {
            for (ci, c) in CutBucket.allCases.enumerated() {
                let base = max(0.05, 0.92 - 0.17 * Double(ci) - 0.14 * Double(di)) * scale
                let n = max(0, attempts - ci * 7 - di * 6)
                cells.append(.init(cut: c, distance: d, attempts: n, makes: Int(Double(n) * base)))
            }
        }
        return cells
    }

    private static func date(_ m: Int, _ d: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: m, day: d, hour: 20))!
    }

    private static let badges: [EarnedBadge] = [
        .init(id: "cutArtist", name: "Cut Artist", symbol: "scope", earnedAt: date(11, 6)),
        .init(id: "bankWizard", name: "Bank Wizard", symbol: "arrow.turn.up.right", earnedAt: date(11, 2)),
        .init(id: "mvp-1", name: "MVP", symbol: "crown.fill", earnedAt: date(10, 30)),
        .init(id: "sotg-1", name: "Shot of Game", symbol: "sparkles", earnedAt: date(10, 28)),
        .init(id: "iceVeins", name: "Ice Veins", symbol: "snowflake", earnedAt: date(10, 25)),
        .init(id: "runOutMachine", name: "Run-out Machine", symbol: "repeat", earnedAt: date(10, 20)),
        .init(id: "mvp-2", name: "MVP", symbol: "crown.fill", earnedAt: date(10, 18)),
        .init(id: "longGun", name: "Long Gun", symbol: "arrow.up.right", earnedAt: date(10, 12)),
        .init(id: "sotg-2", name: "Shot of Game", symbol: "sparkles", earnedAt: date(10, 8)),
        .init(id: "cannonBreak", name: "Cannon Break", symbol: "burst.fill", earnedAt: date(10, 3)),
        .init(id: "sidePocketSniper", name: "Side-Pocket Sniper", symbol: "circle.dotted", earnedAt: date(9, 27)),
        .init(id: "safetyChess", name: "Safety Chess", symbol: "shield.lefthalf.filled", earnedAt: date(9, 20)),
    ]

    private static let sessions: [SessionSummary] = [
        .init(id: UUID(), startedAt: date(11, 6), ruleSet: .barEight, format: .twoVsTwo,
              games: [.init(id: UUID(), index: 0, won: true), .init(id: UUID(), index: 1, won: false),
                      .init(id: UUID(), index: 2, won: true)]),
        .init(id: UUID(), startedAt: date(11, 2), ruleSet: .wpaNine, format: .oneVsOne,
              games: [.init(id: UUID(), index: 0, won: false), .init(id: UUID(), index: 1, won: false)]),
        .init(id: UUID(), startedAt: date(10, 28), ruleSet: .wpaEight, format: .oneVsOne,
              games: [.init(id: UUID(), index: 0, won: true)]),
        .init(id: UUID(), startedAt: date(10, 12), ruleSet: .barEight, format: .threeVsThree,
              games: [.init(id: UUID(), index: 0, won: true), .init(id: UUID(), index: 1, won: true)]),
    ]
}

/// In-memory stats source. The summary lives in a shared box so `updateProfile` is visible to later loads,
/// like the real `PlayerProfile` row.
struct SampleStatsSource: ProfileStatsSource {
    struct Unreadable: Error {}
    final class State: Sendable {
        let summary: Mutex<ProfileSummary>
        /// Loads still to fail. Only `profile(_:)` consumes it: one throw fails the whole load.
        let failuresLeft: Mutex<Int>
        init(_ summary: ProfileSummary, failures: Int) {
            self.summary = Mutex(summary)
            failuresLeft = Mutex(failures)
        }
    }

    let state: State
    var archetype: ArchetypeView?
    var grid: [HeatCell] = []
    var badges: [EarnedBadge] = []
    var pro: ProCompView?
    var history: [SessionSummary] = []
    var failsWrites = false

    init(summary: ProfileSummary, archetype: ArchetypeView? = nil, grid: [HeatCell] = [], badges: [EarnedBadge] = [],
         pro: ProCompView? = nil, history: [SessionSummary] = [], failures: Int = 0) {
        state = State(summary, failures: failures)
        self.archetype = archetype
        self.grid = grid
        self.badges = badges
        self.pro = pro
        self.history = history
    }

    /// Same data in its own store, unreadable for the first `firstLoads` loads.
    func failing(firstLoads: Int) -> SampleStatsSource {
        SampleStatsSource(summary: state.summary.withLock { $0 }, archetype: archetype, grid: grid, badges: badges,
                          pro: pro, history: history, failures: firstLoads)
    }

    /// Same data, but every profile write throws.
    func failingWrites() -> SampleStatsSource {
        var copy = self
        copy.failsWrites = true
        return copy
    }

    func profile(_ id: UUID) async throws -> ProfileSummary {
        let fail = state.failuresLeft.withLock { n in
            guard n > 0 else { return false }
            if n != .max { n -= 1 }
            return true
        }
        if fail { throw Unreadable() }
        return state.summary.withLock { $0 }
    }
    func archetype(_ id: UUID) async throws -> ArchetypeView? { archetype }
    func makeGrid(_ id: UUID) async throws -> [HeatCell] { grid }
    func badges(_ id: UUID) async throws -> [EarnedBadge] { badges }
    func proComp(_ id: UUID) async throws -> ProCompView? { pro }
    func history(_ id: UUID) async throws -> [SessionSummary] { history }
    func updateProfile(_ id: UUID, name: String, avatarSymbol: String) async throws {
        if failsWrites { throw Unreadable() }
        state.summary.withLock { s in
            s.name = name
            s.avatarSymbol = avatarSymbol
        }
    }
}

struct SampleTrainingSource: TrainingProfileSource {
    var drills: [DrillLevel]
    var bias: BiasHint?
    func drills(_ playerID: UUID) async throws -> [DrillLevel] { drills }
    func activeBias(_ playerID: UUID) async throws -> BiasHint? { bias }
}

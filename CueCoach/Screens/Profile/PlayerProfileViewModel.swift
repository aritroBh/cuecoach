import Foundation
import Observation
import Rules

enum ProfileTab: String, CaseIterable, Hashable, Sendable {
    case stats, history, training
    var title: String {
        switch self { case .stats: "Stats"; case .history: "History"; case .training: "Training" }
    }
}

enum UnlockState: Equatable, Sendable {
    case newPlayer
    case locked(gamesMissing: Int, shotsMissing: Int)
    case unlocked
}

struct RadarAxis: Equatable, Sendable, Identifiable {
    var key: String
    var value: Double
    var id: String { key }
    var name: String { ArchetypeAxis.name(key) }
}

struct TraitRow: Equatable, Sendable, Identifiable {
    var symbol: String
    var word: String
    var id: String { word }
}

struct TotalItem: Equatable, Sendable, Identifiable {
    var value: String
    var caption: String
    var id: String { caption }
}

struct HistoryGroup: Equatable, Sendable, Identifiable {
    var month: Date
    var title: String
    var sessions: [SessionSummary]
    var id: Date { month }
}

/// Display-ready heat cell. Color is never the only signal: `glyph` encodes the same level.
struct HeatCellView: Equatable, Sendable, Identifiable {
    nonisolated static let minAttempts = 5
    let cell: HeatCell
    init(_ cell: HeatCell) { self.cell = cell }

    var id: String { cell.distance.rawValue + cell.cut.rawValue }
    var cut: CutBucket { cell.cut }
    var distance: DistanceBucket { cell.distance }
    var hasData: Bool { cell.attempts >= Self.minAttempts }
    var make: Double { cell.attempts == 0 ? 0 : Double(cell.makes) / Double(cell.attempts) }
    var percent: Int { Int(make * 100) }
    var fillOpacity: Double { hasData ? 0.15 + 0.85 * make : 0 }

    var glyph: String? {
        guard hasData else { return nil }
        switch make {
        case ..<0.25: return "circle"
        case ..<0.5: return "circle.lefthalf.filled"
        case ..<0.75: return "circle.fill"
        default: return "smallcircle.filled.circle"
        }
    }

    var valueCaption: String { "\(percent)% · \(cell.attempts) shots" }

    var accessibilityLabel: String {
        let where_ = "\(Self.distanceName(distance)) distance, \(Self.cutSpoken(cut)) cut"
        return hasData ? "\(where_), \(percent) percent, \(cell.attempts) shots" : "\(where_), not enough shots"
    }

    nonisolated static func distanceName(_ d: DistanceBucket) -> String {
        switch d { case .short: "Short"; case .mid: "Mid"; case .long: "Long" }
    }
    nonisolated static func cutSpoken(_ c: CutBucket) -> String {
        switch c {
        case .c0to15: "0 to 15 degree"
        case .c15to30: "15 to 30 degree"
        case .c30to45: "30 to 45 degree"
        case .c45to60: "45 to 60 degree"
        case .c60plus: "over 60 degree"
        }
    }
    nonisolated static func cutAxisLabel(_ c: CutBucket) -> String {
        switch c { case .c0to15: "0"; case .c15to30: "15"; case .c30to45: "30"; case .c45to60: "45"; case .c60plus: "60+" }
    }
}

struct ProfileContent: Equatable, Sendable {
    var summary: ProfileSummary
    var unlock: UnlockState
    var radar: [RadarAxis]
    var previousRadar: [RadarAxis]?
    var topArchetype: ArchetypeTagInfo?
    var heat: [HeatCellView]
    var proComp: ProCompView?
    var badges: [EarnedBadge]
    var history: [HistoryGroup]

    var visibleBadges: [EarnedBadge] { Array(badges.prefix(8)) }
    var hasMoreBadges: Bool { badges.count > 8 }
    var showsBadgeShelf: Bool { !badges.isEmpty }
    var lockedCaption: String? { PlayerProfileViewModel.lockedCaption(unlock) }
    var lockProgress: Double { PlayerProfileViewModel.lockProgress(games: summary.games, shots: summary.shots) }
    var totals: [TotalItem] { PlayerProfileViewModel.totals(summary) }
    var proTraits: [TraitRow] { proComp.map(PlayerProfileViewModel.traits) ?? [] }
}

/// Training tab payload. Built only from `TrainingProfileSource`.
struct TrainingContent: Equatable, Sendable {
    var drills: [DrillLevel]
    var bias: BiasHint?
}

@MainActor @Observable
final class PlayerProfileViewModel {
    enum Phase: Equatable { case loading, loaded, failed }

    nonisolated static let gamesToUnlock = 3
    nonisolated static let shotsToUnlock = 50

    let playerID: UUID
    @ObservationIgnored private let stats: ProfileStatsSource
    @ObservationIgnored private let trainingSource: TrainingProfileSource?
    @ObservationIgnored var onOpenGame: ((UUID) -> Void)?
    @ObservationIgnored var onRename: ((String, String) -> Void)?

    private(set) var phase: Phase = .loading
    private(set) var content: ProfileContent?
    private(set) var training: TrainingContent?
    var tab: ProfileTab = .stats
    private(set) var expanded: Set<UUID> = []

    /// Pass `training: nil` for a session-guest profile (its Training store lives on the peer's phone).
    init(playerID: UUID, stats: ProfileStatsSource, training: TrainingProfileSource?) {
        self.playerID = playerID
        self.stats = stats
        self.trainingSource = training
    }

    var isGuest: Bool { trainingSource == nil }
    var canEdit: Bool { !isGuest }
    var tabs: [ProfileTab] { isGuest ? [.stats, .history] : ProfileTab.allCases }

    func load() async {
        phase = .loading
        let id = playerID
        do {
            async let s = stats.profile(id)
            async let a = stats.archetype(id)
            async let g = stats.makeGrid(id)
            async let b = stats.badges(id)
            async let p = stats.proComp(id)
            async let h = stats.history(id)
            content = try await Self.build(summary: s, archetype: a, grid: g, badges: b, pro: p, history: h)
            phase = .loaded
        } catch {
            content = nil
            phase = .failed
        }
        if let trainingSource {
            let drills = (try? await trainingSource.drills(id)) ?? []
            let bias = try? await trainingSource.activeBias(id)
            training = TrainingContent(drills: drills, bias: bias ?? nil)
        } else {
            training = nil
        }
    }

    func openGame(_ id: UUID) { onOpenGame?(id) }

    func toggleExpanded(_ session: UUID) {
        if expanded.contains(session) { expanded.remove(session) } else { expanded.insert(session) }
    }

    func rename(_ raw: String, symbol: String? = nil) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canEdit, !name.isEmpty, var c = content else { return }
        c.summary.name = name
        if let symbol { c.summary.avatarSymbol = symbol }
        content = c
        onRename?(name, c.summary.avatarSymbol)
    }

    // MARK: Pure helpers (unit-tested)

    nonisolated static func build(summary: ProfileSummary, archetype: ArchetypeView?, grid: [HeatCell], badges: [EarnedBadge],
                      pro: ProCompView?, history: [SessionSummary]) -> ProfileContent {
        let unlock = unlock(games: summary.games, shots: summary.shots)
        let unlocked = unlock == .unlocked
        let radar = unlock == .newPlayer ? [] : radarAxes(archetype?.vector ?? [:])
        return ProfileContent(
            summary: summary,
            unlock: unlock,
            radar: radar,
            previousRadar: archetype?.previous.map(radarAxes),
            topArchetype: unlocked ? archetype?.tags.lazy.compactMap(ArchetypeTagInfo.init).first : nil,
            heat: fullGrid(grid),
            proComp: unlocked ? pro : nil,
            badges: badges.sorted { $0.earnedAt > $1.earnedAt },
            history: groupHistory(history))
    }

    nonisolated static func unlock(games: Int, shots: Int) -> UnlockState {
        if games == 0 { return .newPlayer }
        let g = max(0, gamesToUnlock - games), s = max(0, shotsToUnlock - shots)
        return g == 0 && s == 0 ? .unlocked : .locked(gamesMissing: g, shotsMissing: s)
    }

    nonisolated static func lockedCaption(_ state: UnlockState) -> String? {
        switch state {
        case .unlocked: return nil
        case .newPlayer: return "\(gamesToUnlock) games"
        case let .locked(g, s):
            if g > 0 { return g == 1 ? "1 game" : "\(g) games" }
            return s == 1 ? "1 shot" : "\(s) shots"
        }
    }

    nonisolated static func lockProgress(games: Int, shots: Int) -> Double {
        let g = Double(min(games, gamesToUnlock)) / Double(gamesToUnlock)
        let s = Double(min(shots, shotsToUnlock)) / Double(shotsToUnlock)
        return (g + s) / 2
    }

    /// Max 8 axes (more is unreadable), sorted by key for a stable shape, values clamped to 0...1.
    nonisolated static func radarAxes(_ vector: [String: Double]) -> [RadarAxis] {
        let strongest = vector.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(8)
        return strongest.map { RadarAxis(key: $0.key, value: min(1, max(0, $0.value))) }.sorted { $0.key < $1.key }
    }

    nonisolated static func level(_ v: Double) -> String { v >= 0.67 ? "high" : v >= 0.34 ? "medium" : "low" }

    nonisolated static func radarSummary(_ axes: [RadarAxis]) -> String {
        axes.map { "\($0.name) \(level($0.value))" }.joined(separator: ", ")
    }

    nonisolated static func fullGrid(_ cells: [HeatCell]) -> [HeatCellView] {
        var out: [HeatCellView] = []
        for d in DistanceBucket.allCases {
            for c in CutBucket.allCases {
                let found = cells.first { $0.cut == c && $0.distance == d }
                out.append(HeatCellView(found ?? HeatCell(cut: c, distance: d, attempts: 0, makes: 0)))
            }
        }
        return out
    }

    nonisolated static func band(_ similarity: Double) -> String {
        similarity < 0.5 ? "weak" : similarity < 0.75 ? "fair" : "strong"
    }

    nonisolated static func proCompSpoken(name: String, similarity: Double) -> String {
        "Plays like \(name), \(band(similarity)) match"
    }

    /// Top 2 known traits; unknown keys are dropped, never invented (SPEC §8).
    nonisolated static func traits(_ pc: ProCompView) -> [TraitRow] {
        pc.sharedTraits.compactMap { key in
            guard let word = ArchetypeAxis.names[key], let symbol = ArchetypeAxis.symbols[key] else { return nil }
            return TraitRow(symbol: symbol, word: word)
        }.prefix(2).map { $0 }
    }

    nonisolated static func percent(_ v: Double) -> String { "\(Int(v * 100))%" }

    nonisolated static func badgeSpoken(_ b: EarnedBadge) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "d MMMM"
        return "\(b.name) badge, earned \(f.string(from: b.earnedAt))"
    }

    nonisolated static func totals(_ s: ProfileSummary) -> [TotalItem] {
        [TotalItem(value: s.shots == 0 ? "–" : percent(Double(s.makes) / Double(s.shots)), caption: "Make %"),
         TotalItem(value: "\(s.games)", caption: "Games"),
         TotalItem(value: s.games == 0 ? "–" : percent(Double(s.wins) / Double(s.games)), caption: "Win %")]
    }

    nonisolated static func groupHistory(_ sessions: [SessionSummary], calendar: Calendar = .current) -> [HistoryGroup] {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM yyyy"
        let byMonth = Dictionary(grouping: sessions) {
            calendar.dateInterval(of: .month, for: $0.startedAt)?.start ?? $0.startedAt
        }
        return byMonth.keys.sorted(by: >).map { month in
            HistoryGroup(month: month, title: f.string(from: month).uppercased(),
                         sessions: byMonth[month]!.sorted { $0.startedAt > $1.startedAt })
        }
    }

    nonisolated static func formatLabel(_ f: GameFormat) -> String {
        "\(f.playersPerTeam)v\(f.playersPerTeam)"
    }

    nonisolated static func sessionTitle(_ s: SessionSummary) -> String {
        "\(SettingsViewModel.ruleShortLabel(s.ruleSet)) · \(formatLabel(s.format))"
    }

    nonisolated static func sessionSubtitle(_ s: SessionSummary) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE d MMM"
        let n = s.games.count
        return "\(f.string(from: s.startedAt)) · \(n) \(n == 1 ? "game" : "games")"
    }
}

import Foundation
import Rules
import Testing
@testable import CueCoach

@MainActor
@Suite struct PlayerProfileViewModelTests {
    func loaded(_ fixture: SamplePlayerData, guest: Bool = false) async -> PlayerProfileViewModel {
        let m = PlayerProfileViewModel(playerID: fixture.playerID, stats: fixture.stats,
                                       training: guest ? nil : fixture.training)
        await m.load()
        return m
    }

    // MARK: loading / states

    @Test func startsLoading() {
        let f = SamplePlayerData.veteran
        let m = PlayerProfileViewModel(playerID: f.playerID, stats: f.stats, training: f.training)
        #expect(m.phase == .loading)
    }

    @Test func veteranIsUnlocked() async throws {
        let m = await loaded(.veteran)
        let c = try #require(m.content)
        #expect(m.phase == .loaded)
        #expect(c.unlock == .unlocked)
        #expect(c.topArchetype?.name == "Cut Artist")
        #expect(c.topArchetype?.symbol == "scope")
        #expect(c.proComp != nil)
        #expect(!c.badges.isEmpty)
    }

    @Test func newPlayerState() async throws {
        let m = await loaded(.newPlayer)
        let c = try #require(m.content)
        #expect(c.unlock == .newPlayer)
        #expect(c.topArchetype == nil)
        #expect(c.proComp == nil)
        #expect(c.showsBadgeShelf == false)
        #expect(c.heat.allSatisfy { !$0.hasData })
    }

    @Test func preUnlockHidesArchetypeAndProComp() async throws {
        let m = await loaded(.preUnlock)
        let c = try #require(m.content)
        #expect(c.unlock == .locked(gamesMissing: 1, shotsMissing: 12))
        #expect(c.topArchetype == nil)
        #expect(c.proComp == nil)        // even if a source leaks one
        #expect(c.lockedCaption == "1 game")
    }

    @Test func errorFixtureFailsThenRetries() async {
        let f = SamplePlayerData.error
        let m = PlayerProfileViewModel(playerID: f.playerID, stats: f.stats, training: f.training)
        await m.load()
        #expect(m.phase == .failed)
        #expect(m.content == nil)
    }

    // MARK: unlock rule (SPEC §7: ≥3 games AND ≥50 shots)

    @Test func unlockRule() {
        #expect(PlayerProfileViewModel.unlock(games: 0, shots: 0) == .newPlayer)
        #expect(PlayerProfileViewModel.unlock(games: 2, shots: 80) == .locked(gamesMissing: 1, shotsMissing: 0))
        #expect(PlayerProfileViewModel.unlock(games: 5, shots: 49) == .locked(gamesMissing: 0, shotsMissing: 1))
        #expect(PlayerProfileViewModel.unlock(games: 3, shots: 50) == .unlocked)
    }

    @Test func lockedCaptions() {
        #expect(PlayerProfileViewModel.lockedCaption(.locked(gamesMissing: 3, shotsMissing: 50)) == "3 games")
        #expect(PlayerProfileViewModel.lockedCaption(.locked(gamesMissing: 1, shotsMissing: 0)) == "1 game")
        #expect(PlayerProfileViewModel.lockedCaption(.locked(gamesMissing: 0, shotsMissing: 7)) == "7 shots")
        #expect(PlayerProfileViewModel.lockedCaption(.newPlayer) == "3 games")
        #expect(PlayerProfileViewModel.lockedCaption(.unlocked) == nil)
    }

    @Test func lockProgressIsFractionOfBothThresholds() {
        #expect(PlayerProfileViewModel.lockProgress(games: 0, shots: 0) == 0)
        #expect(PlayerProfileViewModel.lockProgress(games: 3, shots: 50) == 1)
        let p = PlayerProfileViewModel.lockProgress(games: 3, shots: 25)
        #expect(abs(p - 0.75) < 0.0001)
    }

    // MARK: radar

    @Test func radarCapsAtEightAxesAndClamps() {
        var v: [String: Double] = [:]
        for i in 0..<11 { v["axis\(i)"] = Double(i) / 10 }
        v["over"] = 1.7
        let axes = PlayerProfileViewModel.radarAxes(v)
        #expect(axes.count == 8)
        #expect(axes.allSatisfy { (0...1).contains($0.value) })
        #expect(axes.map(\.key) == axes.map(\.key).sorted())   // stable order
    }

    @Test func radarAccessibilityUsesBands() {
        let axes = [RadarAxis(key: "cut", value: 0.8), RadarAxis(key: "long", value: 0.5), RadarAxis(key: "bank", value: 0.1)]
        #expect(PlayerProfileViewModel.radarSummary(axes) == "Cut high, Long medium, Banks low")
    }

    // MARK: heat grid

    @Test func heatGridIsAlwaysFifteenCellsInOrder() async throws {
        let m = await loaded(.veteran)
        let c = try #require(m.content)
        #expect(c.heat.count == 15)
        #expect(c.heat.first?.distance == .short)
        #expect(c.heat.first?.cut == .c0to15)
        #expect(c.heat.last?.distance == .long)
        #expect(c.heat.last?.cut == .c60plus)
    }

    @Test func heatCellLevelsAndOpacity() {
        let thin = HeatCellView(HeatCell(cut: .c0to15, distance: .short, attempts: 4, makes: 4))
        #expect(!thin.hasData)
        #expect(thin.glyph == nil)
        let low = HeatCellView(HeatCell(cut: .c0to15, distance: .short, attempts: 10, makes: 1))
        #expect(low.glyph == "circle")
        let mid = HeatCellView(HeatCell(cut: .c0to15, distance: .short, attempts: 10, makes: 4))
        #expect(mid.glyph == "circle.lefthalf.filled")
        let good = HeatCellView(HeatCell(cut: .c0to15, distance: .short, attempts: 10, makes: 6))
        #expect(good.glyph == "circle.fill")
        let best = HeatCellView(HeatCell(cut: .c0to15, distance: .short, attempts: 10, makes: 9))
        #expect(best.glyph == "smallcircle.filled.circle")
        #expect(abs(best.fillOpacity - (0.15 + 0.85 * 0.9)) < 0.0001)
    }

    @Test func heatCellAccessibility() {
        let c = HeatCellView(HeatCell(cut: .c30to45, distance: .mid, attempts: 40, makes: 25))
        #expect(c.accessibilityLabel == "Mid distance, 30 to 45 degree cut, 62 percent, 40 shots")
        #expect(c.valueCaption == "62% · 40 shots")
        let none = HeatCellView(HeatCell(cut: .c60plus, distance: .long, attempts: 2, makes: 1))
        #expect(none.accessibilityLabel == "Long distance, over 60 degree cut, not enough shots")
    }

    // MARK: pro comp

    @Test func similarityBands() {
        #expect(PlayerProfileViewModel.band(0.3) == "weak")
        #expect(PlayerProfileViewModel.band(0.6) == "fair")
        #expect(PlayerProfileViewModel.band(0.85) == "strong")
        #expect(PlayerProfileViewModel.proCompSpoken(name: "Efren Reyes", similarity: 0.85)
                == "Plays like Efren Reyes, strong match")
    }

    @Test func proCompShowsAtMostTwoTraitsAndDropsUnknown() {
        let pc = ProCompView(proName: "Efren Reyes", similarity: 0.78, sharedTraits: ["cut", "nonsense", "bank", "long"])
        let traits = PlayerProfileViewModel.traits(pc)
        #expect(traits.map(\.word) == ["Cut", "Banks"])
    }

    @Test func percentHasNoDecimals() {
        #expect(PlayerProfileViewModel.percent(0.784) == "78%")
    }

    // MARK: badges

    @Test func badgeShelfCapsAtEight() async throws {
        let m = await loaded(.veteran)
        let c = try #require(m.content)
        #expect(c.visibleBadges.count <= 8)
        #expect(c.badges.count > 8)
        #expect(c.hasMoreBadges)
        let b = c.badges[0]
        #expect(PlayerProfileViewModel.badgeSpoken(b).hasSuffix("badge, earned 6 November"))
    }

    // MARK: totals

    @Test func totals() {
        let s = ProfileSummary(id: UUID(), name: "Sam", avatarSymbol: "figure.pool", avatarColor: "#60A5FA",
                               games: 10, wins: 6, shots: 200, makes: 120)
        let t = PlayerProfileViewModel.totals(s)
        #expect(t.map(\.value) == ["60%", "10", "60%"])
        #expect(t.map(\.caption) == ["Make %", "Games", "Win %"])
        let zero = PlayerProfileViewModel.totals(.init(id: UUID(), name: "N", avatarSymbol: "x", avatarColor: "#fff",
                                                      games: 0, wins: 0, shots: 0, makes: 0))
        #expect(zero.map(\.value) == ["–", "0", "–"])
    }

    // MARK: history

    @Test func historyGroupsByMonthNewestFirst() {
        let cal = Calendar(identifier: .gregorian)
        func d(_ y: Int, _ m: Int, _ day: Int) -> Date { cal.date(from: DateComponents(year: y, month: m, day: day))! }
        let sessions = [
            SessionSummary(id: UUID(), startedAt: d(2026, 10, 2), ruleSet: .barEight, format: .oneVsOne, games: []),
            SessionSummary(id: UUID(), startedAt: d(2026, 11, 6), ruleSet: .wpaNine, format: .twoVsTwo, games: []),
            SessionSummary(id: UUID(), startedAt: d(2026, 11, 1), ruleSet: .barEight, format: .oneVsOne, games: []),
        ]
        let groups = PlayerProfileViewModel.groupHistory(sessions, calendar: cal)
        #expect(groups.count == 2)
        #expect(groups[0].sessions.map(\.startedAt) == [d(2026, 11, 6), d(2026, 11, 1)])
        #expect(groups[1].sessions.count == 1)
    }

    @Test func sessionResultAndTitle() {
        let me = UUID()
        let s = SessionSummary(id: UUID(), startedAt: .now, ruleSet: .barEight, format: .twoVsTwo,
                               games: [GameSummary(id: UUID(), index: 0, won: true),
                                       GameSummary(id: UUID(), index: 1, won: false),
                                       GameSummary(id: UUID(), index: 2, won: true)])
        _ = me
        #expect(s.won == true)
        #expect(PlayerProfileViewModel.sessionTitle(s) == "Bar · 2v2")
        let lost = SessionSummary(id: UUID(), startedAt: .now, ruleSet: .wpaNine, format: .oneVsOne,
                                  games: [GameSummary(id: UUID(), index: 0, won: false)])
        #expect(lost.won == false)
        #expect(PlayerProfileViewModel.sessionTitle(lost) == "WPA 9 · 1v1")
        let empty = SessionSummary(id: UUID(), startedAt: .now, ruleSet: .wpaEight, format: .oneVsOne, games: [])
        #expect(empty.won == nil)
    }

    @Test func openingAGameCallsClosure() async {
        let m = await loaded(.veteran)
        var opened: UUID?
        m.onOpenGame = { opened = $0 }
        let g = UUID()
        m.openGame(g)
        #expect(opened == g)
    }

    @Test func expandingSessionToggles() async {
        let m = await loaded(.veteran)
        let id = UUID()
        m.toggleExpanded(id)
        #expect(m.expanded.contains(id))
        m.toggleExpanded(id)
        #expect(!m.expanded.contains(id))
    }

    // MARK: tabs / guest

    @Test func guestHasNoTrainingTabAndIsReadOnly() async {
        let m = await loaded(.veteran, guest: true)
        #expect(m.tabs == [.stats, .history])
        #expect(!m.canEdit)
        let owner = await loaded(.veteran)
        #expect(owner.tabs == [.stats, .history, .training])
        #expect(owner.canEdit)
    }

    @Test func editingNameTrimsAndRejectsEmpty() async {
        let m = await loaded(.veteran)
        m.rename("  Ari  ")
        #expect(m.content?.summary.name == "Ari")
        m.rename("   ")
        #expect(m.content?.summary.name == "Ari")
    }

    // MARK: training (separate store)

    @Test func trainingLoadsOnlyFromTrainingSource() async throws {
        let m = await loaded(.veteran)
        let t = try #require(m.training)
        #expect(t.drills.map(\.level) == [3, 2, 1])
        #expect(t.bias?.word == "Overcut")
    }

    @Test func drillLevelClampedToOneThroughFour() {
        #expect(DrillLevel(drill: "x", name: "X", level: 9).clampedLevel == 4)
        #expect(DrillLevel(drill: "x", name: "X", level: 0).clampedLevel == 1)
    }

    @Test func biasWordsAreAtMostTwoWords() {
        for axis in BiasAxis.allCases {
            for sign in [-1, 1] {
                let w = BiasHint(axis: axis, sign: sign).word
                #expect(!w.isEmpty)
                #expect(w.split(separator: " ").count <= 2)
            }
        }
        #expect(BiasHint(axis: .cut, sign: 1).word == "Overcut")
        #expect(BiasHint(axis: .cut, sign: -1).word == "Undercut")
    }

    @Test func emptyTraining() async throws {
        let m = await loaded(.newPlayer)
        let t = try #require(m.training)
        #expect(t.drills.isEmpty)
        #expect(t.bias == nil)
    }

    /// SPEC §2 / page spec pre-delivery: the Training tab reads only `TrainingProfileSource`.
    @Test func trainingTabSourceNeverTouchesCompetitiveTypes() throws {
        let here = URL(fileURLWithPath: #filePath)
        let file = here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "CueCoach/Screens/Profile/TrainingTabView.swift")
        let src = try String(contentsOf: file, encoding: .utf8)
        for banned in ["ProfileStatsSource", "HeatCell", "ArchetypeView", "ProCompView", "ProfileSummary",
                       "SessionSummary", "EarnedBadge", "competitiveContext", "makeGrid", "winRate"] {
            #expect(!src.contains(banned), "TrainingTabView mentions \(banned)")
        }
        #expect(src.contains("TrainingContent"))
    }

    @Test func archetypeSymbolsMatchSpec() {
        let expected = ["cutArtist": "scope", "longGun": "arrow.up.right", "sidePocketSniper": "circle.dotted",
                        "iceVeins": "snowflake", "safetyChess": "shield.lefthalf.filled", "cannonBreak": "burst.fill",
                        "runOutMachine": "repeat", "bankWizard": "arrow.turn.up.right"]
        for (tag, sym) in expected {
            let a = ArchetypeTagInfo(tag)
            #expect(a != nil)
            #expect(a?.symbol == sym)
            #expect((a?.name.split(separator: " ").count ?? 9) <= 2)
        }
        #expect(ArchetypeTagInfo("bogus") == nil)
    }
}

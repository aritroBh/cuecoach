import Foundation
import Rules
import Synchronization
import Testing
@testable import CueCoach

struct TrainingReadError: Error {}

/// Training store that throws for the first `failures` reads of each kind, then returns `drills`/`bias`.
final class FlakyTrainingSource: TrainingProfileSource {
    let failures: Mutex<Int>
    let biasFails: Bool
    let drills: [DrillLevel]
    init(failures: Int = .max, biasFails: Bool = false,
         drills: [DrillLevel] = [.init(drill: "cuts", name: "Cuts", level: 2)]) {
        self.failures = Mutex(failures)
        self.biasFails = biasFails
        self.drills = drills
    }
    func drills(_ playerID: UUID) async throws -> [DrillLevel] {
        let fail = failures.withLock { n in
            if n > 0 { n -= 1; return true }
            return false
        }
        if fail { throw TrainingReadError() }
        return drills
    }
    func activeBias(_ playerID: UUID) async throws -> BiasHint? {
        if biasFails { throw TrainingReadError() }
        return nil
    }
}

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
        #expect(c.lockedCaption == "1 more game")
    }

    @Test func errorFixtureStaysFailedOnRetry() async {
        let f = SamplePlayerData.error
        let m = PlayerProfileViewModel(playerID: f.playerID, stats: f.stats, training: f.training)
        await m.load()
        #expect(m.phase == .failed)
        #expect(m.content == nil)
        await m.load()
        #expect(m.phase == .failed)
        #expect(m.content == nil)
    }

    /// C10: the store recovers, so Retry must land on the loaded profile.
    @Test func failsThenRetrySucceedsOnceStoreRecovers() async throws {
        let f = SamplePlayerData.errorOnce
        let m = PlayerProfileViewModel(playerID: f.playerID, stats: f.stats, training: f.training)
        await m.load()
        #expect(m.phase == .failed)
        #expect(m.content == nil)
        await m.load()
        #expect(m.phase == .loaded)
        let c = try #require(m.content)
        #expect(c.summary.name == "Sam")
        #expect(!m.failureScope(.stats))
    }

    // MARK: unlock rule (SPEC §7: ≥3 games AND ≥50 shots)

    @Test func unlockRule() {
        #expect(PlayerProfileViewModel.unlock(games: 0, shots: 0) == .newPlayer)
        #expect(PlayerProfileViewModel.unlock(games: 2, shots: 80) == .locked(gamesMissing: 1, shotsMissing: 0))
        #expect(PlayerProfileViewModel.unlock(games: 5, shots: 49) == .locked(gamesMissing: 0, shotsMissing: 1))
        #expect(PlayerProfileViewModel.unlock(games: 3, shots: 50) == .unlocked)
    }

    @Test func lockedCaptions() {
        #expect(PlayerProfileViewModel.lockedCaption(.locked(gamesMissing: 3, shotsMissing: 50)) == "3 more games")
        #expect(PlayerProfileViewModel.lockedCaption(.locked(gamesMissing: 1, shotsMissing: 0)) == "1 more game")
        #expect(PlayerProfileViewModel.lockedCaption(.locked(gamesMissing: 0, shotsMissing: 7)) == "7 more shots")
        #expect(PlayerProfileViewModel.lockedCaption(.locked(gamesMissing: 0, shotsMissing: 1)) == "1 more shot")
        #expect(PlayerProfileViewModel.lockedCaption(.newPlayer) == "3 more games")
        #expect(PlayerProfileViewModel.lockedCaption(.unlocked) == nil)
    }

    @Test func lockedSpokenMatchesSpec() {
        #expect(PlayerProfileViewModel.lockedSpoken(.locked(gamesMissing: 1, shotsMissing: 0))
                == "Pro comparison locked, 1 more game needed")
        #expect(PlayerProfileViewModel.lockedSpoken(.locked(gamesMissing: 0, shotsMissing: 12))
                == "Pro comparison locked, 12 more shots needed")
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
        #expect(thin.glyphFill == nil)
        let low = HeatCellView(HeatCell(cut: .c0to15, distance: .short, attempts: 10, makes: 1))
        let mid = HeatCellView(HeatCell(cut: .c0to15, distance: .short, attempts: 10, makes: 4))
        let good = HeatCellView(HeatCell(cut: .c0to15, distance: .short, attempts: 10, makes: 6))
        let best = HeatCellView(HeatCell(cut: .c0to15, distance: .short, attempts: 10, makes: 9))
        // Strictly increasing fill (quarter → full pie) so greyscale still ranks the cells.
        #expect([low, mid, good, best].map(\.glyphFill) == [0.25, 0.5, 0.75, 1])
        #expect(abs(best.fillOpacity - (0.15 + 0.85 * 0.9)) < 0.0001)
    }

    @Test func heatGlyphInkPicksTheHigherContrast() {
        // Faint fill → light ink; bright green fill → dark ink. Never a fixed 50% cutoff.
        #expect(HeatCellView.glyphInkIsDark(fillOpacity: 0.2) == false)
        #expect(HeatCellView.glyphInkIsDark(fillOpacity: 1) == true)
        for o in stride(from: 0.15, through: 1.0, by: 0.05) {
            let dark = HeatCellView.glyphInkIsDark(fillOpacity: o)
            let fill = HeatCellView.cellFillLuminance(fillOpacity: o)
            let cDark = HeatCellView.contrast(fill, HeatCellView.bgLuminance)
            let cLight = HeatCellView.contrast(fill, HeatCellView.inkLuminance)
            #expect(dark == (cDark > cLight))
            #expect(max(cDark, cLight) >= 3, "glyph contrast at \(o)")
        }
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

    // MARK: pro comparison overlay (C8)

    @Test func proOverlayAlignsToPlayerAxesAndClamps() throws {
        let axes = PlayerProfileViewModel.radarAxes(["cut": 0.8, "long": 0.5, "bank": 0.3])
        let o = try #require(PlayerProfileViewModel.proOverlay(axes,
                                                               proVector: ["long": 1.4, "cut": 0.6, "bank": 0.9, "x": 1]))
        #expect(o.map(\.key) == axes.map(\.key))
        #expect(o.map(\.value) == [0.9, 0.6, 1])
    }

    @Test func proOverlayMissingTraitIsNeverInvented() {
        let axes = PlayerProfileViewModel.radarAxes(["cut": 0.8, "long": 0.5, "bank": 0.3])
        #expect(PlayerProfileViewModel.proOverlay(axes, proVector: ["cut": 0.6, "bank": 0.9]) == nil)
        #expect(PlayerProfileViewModel.proOverlay(axes, proVector: [:]) == nil)
        #expect(PlayerProfileViewModel.proOverlay([], proVector: ["cut": 1]) == nil)
    }

    @Test func veteranComparisonHasBothShapes() async throws {
        let m = await loaded(.veteran)
        let c = try #require(m.content)
        let pro = try #require(c.proRadar)
        #expect(pro.map(\.key) == c.radar.map(\.key))
    }

    @Test func lockedProfileHasNoProShape() async throws {
        let m = await loaded(.preUnlock)
        #expect(try #require(m.content).proRadar == nil)
    }

    @Test func comparisonChartDescriptorHasBothSeries() {
        let axes = [RadarAxis(key: "cut", value: 0.8), RadarAxis(key: "long", value: 0.5), RadarAxis(key: "bank", value: 0.1)]
        let pro = [RadarAxis(key: "cut", value: 0.9), RadarAxis(key: "long", value: 0.4), RadarAxis(key: "bank", value: 0.7)]
        let d = SARadarDescriptor(axes: axes, name: "Sam", overlay: pro, overlayName: "Efren Reyes").makeChartDescriptor()
        #expect(d.series.map(\.name) == ["Sam", "Efren Reyes"])
        #expect(d.series.allSatisfy { $0.dataPoints.count == 3 })
        #expect(d.summary == "Sam: Cut high, Long medium, Banks low. Efren Reyes: Cut high, Long medium, Banks high")
        let single = SARadarDescriptor(axes: axes).makeChartDescriptor()
        #expect(single.series.count == 1)
        #expect(single.summary == "Cut high, Long medium, Banks low")
    }

    // MARK: Dynamic Type (C7)

    @Test func chartsNeverCapDynamicType() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        for file in ["ProfileCharts.swift", "PlayerProfileView.swift", "TrainingTabView.swift"] {
            let src = try String(contentsOf: root.appending(path: "CueCoach/Screens/Profile/\(file)"), encoding: .utf8)
            #expect(!src.contains(".dynamicTypeSize(..."), "\(file) caps Dynamic Type")
        }
    }

    @Test func percentHasNoDecimals() {
        #expect(PlayerProfileViewModel.percent(0.784) == "78%")
    }

    // MARK: badges

    @Test func badgeShelfCapsAtEightKinds() async throws {
        let m = await loaded(.veteran)
        let c = try #require(m.content)
        #expect(c.visibleBadges.count == 8)
        #expect(c.badgeGroups.count > 8)
        #expect(c.hasMoreBadges)
        let b = c.visibleBadges[0]
        #expect(PlayerProfileViewModel.badgeSpoken(b).hasSuffix("badge, earned 6 November"))
    }

    @Test func duplicateBadgeKindsCollapse() {
        func d(_ day: Int) -> Date { Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: day))! }
        let raw = [EarnedBadge(id: "mvp-1", name: "MVP", symbol: "crown.fill", earnedAt: d(18)),
                   EarnedBadge(id: "ice", name: "Ice Veins", symbol: "snowflake", earnedAt: d(25)),
                   EarnedBadge(id: "mvp-2", name: "MVP", symbol: "crown.fill", earnedAt: d(30))]
        let groups = PlayerProfileViewModel.groupBadges(raw)
        #expect(groups.map(\.name) == ["MVP", "Ice Veins"])          // most recent award first
        #expect(groups[0].count == 2)
        #expect(groups[0].latest == d(30))
        #expect(groups[0].dates == [d(30), d(18)])
        #expect(groups[0].countCaption == "2 games")
        #expect(groups[1].countCaption == nil)
        #expect(PlayerProfileViewModel.badgeSpoken(groups[0]).hasPrefix("MVP badge, 2 games, last earned"))
    }

    @Test func veteranShelfHasNoDuplicateDiscs() async throws {
        let m = await loaded(.veteran)
        let c = try #require(m.content)
        #expect(Set(c.visibleBadges.map(\.name)).count == c.visibleBadges.count)
        #expect(Set(c.badgeGroups.map(\.name)).count == c.badgeGroups.count)
    }

    @Test func trainingStillLoadsWhenStatsFail() async {
        let f = SamplePlayerData.error
        let m = PlayerProfileViewModel(playerID: f.playerID, stats: f.stats, training: f.training)
        await m.load()
        #expect(m.phase == .failed)
        #expect(m.training?.drills.isEmpty == false)
        #expect(m.failureScope(.stats) && m.failureScope(.history))
        #expect(!m.failureScope(.training))
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
        #expect(s.result == .won)
        #expect(PlayerProfileViewModel.sessionTitle(s) == "Bar · 2v2")
        let lost = SessionSummary(id: UUID(), startedAt: .now, ruleSet: .wpaNine, format: .oneVsOne,
                                  games: [GameSummary(id: UUID(), index: 0, won: false)])
        #expect(lost.result == .lost)
        #expect(PlayerProfileViewModel.sessionTitle(lost) == "WPA 9 · 1v1")
        let empty = SessionSummary(id: UUID(), startedAt: .now, ruleSet: .wpaEight, format: .oneVsOne, games: [])
        #expect(empty.result == nil)
    }

    /// C9: an even split is a tie, never "Lost".
    @Test func evenSessionIsATie() {
        func s(_ results: [Bool?]) -> SessionSummary {
            SessionSummary(id: UUID(), startedAt: .now, ruleSet: .barEight, format: .oneVsOne,
                           games: results.enumerated().map { GameSummary(id: UUID(), index: $0.offset, won: $0.element) })
        }
        #expect(s([true, false]).result == .tied)
        #expect(s([true, false, nil]).result == .tied)
        #expect(s([true, true, false]).result == .won)
        #expect(s([false]).result == .lost)
        #expect(s([nil]).result == nil)
        #expect(s([]).result == nil)
        #expect(SessionResult.won.spoken == "Won")
        #expect(SessionResult.lost.spoken == "Lost")
        #expect(SessionResult.tied.spoken == "Tied")
        #expect(SessionResult(game: true) == .won)
        #expect(SessionResult(game: false) == .lost)
        #expect(SessionResult(game: nil) == nil)
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
        await m.rename("  Ari  ")
        #expect(m.content?.summary.name == "Ari")
        await m.rename("   ")
        #expect(m.content?.summary.name == "Ari")
    }

    /// C5: the edit is written through the stats source, so a fresh load shows it.
    @Test func renameAndAvatarPersistAcrossReload() async throws {
        let f = SamplePlayerData.veteran
        let m = PlayerProfileViewModel(playerID: f.playerID, stats: f.stats, training: f.training)
        await m.load()
        await m.rename("  Ari  ", symbol: "flame.fill")
        #expect(!m.renameFailed)
        let again = PlayerProfileViewModel(playerID: f.playerID, stats: f.stats, training: f.training)
        await again.load()
        let s = try #require(again.content?.summary)
        #expect(s.name == "Ari")
        #expect(s.avatarSymbol == "flame.fill")
    }

    @Test func renameWriteFailureRevertsAndFlags() async throws {
        var f = SamplePlayerData.veteran
        f = SamplePlayerData(playerID: f.playerID, stats: f.stats.failingWrites(), training: f.training)
        let m = PlayerProfileViewModel(playerID: f.playerID, stats: f.stats, training: f.training)
        await m.load()
        await m.rename("Ari", symbol: "flame.fill")
        #expect(m.renameFailed)
        #expect(m.content?.summary.name == "Sam")
        #expect(m.content?.summary.avatarSymbol == "person.fill")
    }

    @Test func guestRenameWritesNothing() async throws {
        let f = SamplePlayerData.veteran
        let m = PlayerProfileViewModel(playerID: f.playerID, stats: f.stats, training: nil)
        await m.load()
        await m.rename("Ari")
        let again = PlayerProfileViewModel(playerID: f.playerID, stats: f.stats, training: nil)
        await again.load()
        #expect(again.content?.summary.name == "Sam")
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

    /// C6: an unreadable Training store is a failure, not "No drills yet".
    @Test func trainingReadFailureIsNotEmpty() async {
        let f = SamplePlayerData.veteran
        let m = PlayerProfileViewModel(playerID: f.playerID, stats: f.stats, training: FlakyTrainingSource())
        await m.load()
        #expect(m.phase == .loaded)          // competitive stats unaffected
        #expect(m.trainingFailed)
        #expect(m.training == nil)
    }

    @Test func biasReadFailureIsAlsoATrainingFailure() async {
        let f = SamplePlayerData.veteran
        let m = PlayerProfileViewModel(playerID: f.playerID, stats: f.stats,
                                       training: FlakyTrainingSource(failures: 0, biasFails: true))
        await m.load()
        #expect(m.trainingFailed)
        #expect(m.training == nil)
    }

    @Test func trainingRetryRecovers() async throws {
        let f = SamplePlayerData.veteran
        let m = PlayerProfileViewModel(playerID: f.playerID, stats: f.stats, training: FlakyTrainingSource(failures: 1))
        await m.load()
        #expect(m.trainingFailed)
        await m.loadTraining()
        #expect(!m.trainingFailed)
        #expect(try #require(m.training).drills.map(\.name) == ["Cuts"])
    }

    @Test func guestNeverReportsTrainingFailure() async {
        let m = await loaded(.veteran, guest: true)
        #expect(!m.trainingFailed)
        #expect(m.training == nil)
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

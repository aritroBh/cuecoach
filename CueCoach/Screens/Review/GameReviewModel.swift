import Foundation
import Observation
import Geometry
import Engine

struct ReviewMVP: Hashable {
    var player: ReviewPlayer
    var team: Int
    var bestShot: ReviewShot
}

/// Game review state (pages/screens-b.md §3).
@MainActor @Observable
public final class GameReviewModel {
    enum Phase: Equatable { case loading, loaded, failed }
    enum ReplayMoment: Hashable { case before, after }

    private(set) var phase: Phase
    private(set) var data: GameReviewData?
    private(set) var selectedShotID: UUID?
    var replayMoment: ReplayMoment = .after

    @ObservationIgnored private let source: (any GameReviewSource)?
    @ObservationIgnored var onDone: (() -> Void)?
    /// Full-screen clip player hook (Highlights module wires it; no-op until then).
    @ObservationIgnored var onPlayClip: ((UUID) -> Void)?

    init(source: any GameReviewSource) {
        self.source = source
        self.phase = .loading
    }

    init(data: GameReviewData) {
        self.source = nil
        self.phase = .loaded
        apply(data)
    }

    func load() async {
        guard let source else { return }
        do { apply(try await source.load()) } catch { phase = .failed }
    }

    /// The failed state's retry button (ui-QA-2): only when there is a source to reload from.
    var canRetry: Bool { source != nil }

    func retry() async {
        guard source != nil else { return }
        phase = .loading
        await load()
    }

    private func apply(_ d: GameReviewData) {
        data = d
        phase = .loaded
        selectedShotID = shotOfGame?.id ?? d.shots.first?.id
    }

    // MARK: Derived

    var shots: [ReviewShot] { data?.shots ?? [] }
    var isLocked: Bool { !(data?.isFinished ?? true) }
    var isEmpty: Bool { phase == .loaded && !shots.contains { $0.rating != nil } }
    var selectedShot: ReviewShot? { shots.first { $0.id == selectedShotID } }

    var showsChart: Bool { (data?.winProb.count ?? 0) >= 4 }

    /// Offset between series and shots: 1 when the series has an opening point.
    private var seriesOffset: Int {
        guard let d = data else { return 0 }
        return d.winProb.count > d.shots.count ? 1 : 0
    }

    private func position(_ s: ReviewShot) -> Int? { shots.firstIndex { $0.id == s.id } }

    private func series(_ j: Int) -> Double? {
        guard let w = data?.winProb else { return nil }
        if j < 0 { return 0.5 }
        return w.indices.contains(j) ? w[j] : nil
    }

    func winProbBefore(_ s: ReviewShot) -> Double {
        guard let i = position(s) else { return 0.5 }
        return series(i + seriesOffset - 1) ?? 0.5
    }

    func winProbAfter(_ s: ReviewShot) -> Double {
        guard let i = position(s) else { return 0.5 }
        return series(i + seriesOffset) ?? winProbBefore(s)
    }

    /// Chart points: x = shot position (opening point at -1), y = P(Team A wins).
    var chartPoints: [(x: Int, y: Double)] {
        (data?.winProb ?? []).enumerated().map { (x: $0.offset - seriesOffset, y: $0.element) }
    }

    func chartX(_ s: ReviewShot) -> Int { position(s) ?? 0 }

    var chartMarkers: [ReviewShot] { shots.filter { $0.rating != nil && RatingBadgeStyle.of($0.rating).marksChart } }

    func timelineStyle(_ s: ReviewShot) -> RatingBadgeStyle {
        isReplayAvailable(s) ? .of(s.rating) : .of(nil)
    }

    func isReplayAvailable(_ s: ReviewShot) -> Bool { s.pre != nil && s.post != nil }

    func showsAlternative(_ s: ReviewShot) -> Bool {
        guard s.alternative != nil, let r = s.rating,
              let ri = DecisionRating.allCases.firstIndex(of: r),
              let bi = DecisionRating.allCases.firstIndex(of: .best) else { return false }
        return ri > bi
    }

    var shotOfGame: ReviewShot? {
        guard !isLocked, let id = data?.shotOfGame?.shotID else { return nil }
        return shots.first { $0.id == id }
    }

    /// The SotG play control exists only when there is a clip to play.
    var canPlayShotOfGameClip: Bool { shotOfGame != nil && data?.shotOfGame?.hasClip == true }

    func playShotOfGameClip() {
        guard canPlayShotOfGameClip, let id = shotOfGame?.id else { return }
        onPlayClip?(id)
    }

    /// "Actual" is only claimed for traced paths; inferred ones are drawn as faint displacement arrows.
    func showsActualLegend(_ s: ReviewShot) -> Bool { s.pathsAreTraced }

    var mvp: ReviewMVP? {
        guard !isLocked, let d = data else { return nil }
        let rated = d.shots.filter { $0.shooter != nil }
        let isTeamGame = d.teams.contains { $0.count > 1 }
        let player: ReviewPlayer?
        if isTeamGame {
            let totals = Dictionary(grouping: rated, by: { $0.shooter!.id }).mapValues { $0.reduce(0) { $0 + $1.wpaDelta } }
            player = totals.max { $0.value < $1.value }.flatMap { best in rated.first { $0.shooter?.id == best.key }?.shooter }
        } else {
            guard let w = d.winnerTeam, d.teams.indices.contains(w) else { return nil }
            player = d.teams[w].first
        }
        guard let player,
              let best = rated.filter({ $0.shooter?.id == player.id }).max(by: { $0.wpaDelta < $1.wpaDelta }) else { return nil }
        return ReviewMVP(player: player, team: best.team, bestShot: best)
    }

    // MARK: Selection

    func select(_ id: UUID) {
        guard shots.contains(where: { $0.id == id }) else { return }
        selectedShotID = id
    }

    func selectNext() { step(1) }
    func selectPrevious() { step(-1) }

    private func step(_ d: Int) {
        guard let s = selectedShot, let i = position(s) else { return }
        let j = min(max(0, i + d), shots.count - 1)
        selectedShotID = shots[j].id
    }

    func selectNearest(chartX x: Double) {
        guard !shots.isEmpty else { return }
        let i = min(max(0, Int(x.rounded())), shots.count - 1)
        selectedShotID = shots[i].id
    }

    // MARK: Accessibility (direction words only, never numbers)

    /// "up" / "down" / "steady" for a change in Team A's win chance.
    nonisolated static func directionWord(_ delta: Double) -> String {
        abs(delta) < 0.02 ? "steady" : (delta > 0 ? "up" : "down")
    }

    /// Who leads at a win chance (the chart's spoken y values use the same words).
    nonisolated static func standingWords(_ p: Double) -> String {
        p > 0.55 ? "Team A ahead" : (p < 0.45 ? "Team B ahead" : "Even")
    }

    /// The eval-bar fallback (chart hidden): direction + standing, never a number.
    var evalBarsAccessibilityLabel: String? {
        guard let first = shots.first, let last = shots.last else { return nil }
        let before = winProbBefore(first), after = winProbAfter(last)
        return "Team A win chance \(Self.directionWord(after - before)), \(Self.standingWords(after))"
    }

    func accessibilityLabel(_ s: ReviewShot) -> String {
        let dir = Self.directionWord(winProbAfter(s) - winProbBefore(s))
        return ["Shot \(s.index + 1)", s.shooter?.name, timelineStyle(s).words, "Team A win chance \(dir)"]
            .compactMap { $0 }.joined(separator: ", ")
    }

    // MARK: Shot result (pocketed balls, fouls, D31 guess)

    /// The card shows a result row when something dropped, a foul was called, or the shot is a guess.
    nonisolated static func showsResult(_ s: ReviewShot) -> Bool { !s.pocketed.isEmpty || !s.fouls.isEmpty || s.isGuess }

    /// Pocketed balls for the glyph row: object balls by number, the cue ball (a scratch) last.
    nonisolated static func resultBalls(_ s: ReviewShot) -> [BallID] {
        s.pocketed.keys.filter { !$0.isCue }.sorted() + (s.pocketed[.cue] != nil ? [.cue] : [])
    }

    /// Spoken result: ball numbers only, "Foul" without detail, and "Best guess" for a D31 shot.
    nonisolated static func resultAccessibilityLabel(_ s: ReviewShot) -> String {
        let balls = resultBalls(s).map { $0.isCue ? "cue ball" : "\($0.number)" }
        var parts = [balls.isEmpty ? "Nothing pocketed" : "Pocketed " + balls.joined(separator: ", ")]
        if !s.fouls.isEmpty { parts.append("Foul") }
        if s.isGuess { parts.append("Best guess") }
        return parts.joined(separator: ". ")
    }

    func replayDescription(_ s: ReviewShot) -> String {
        guard isReplayAvailable(s) else { return "Replay unavailable." }
        let who = s.shooter?.name ?? "The shooter"
        let made = s.pocketed.keys.filter { !$0.isCue }.sorted()
        var text: String
        if let b = made.first, let p = s.pocketed[b] {
            text = "\(who) pocketed the \(b.number) in the \(p.isSide ? "side" : "corner")."
        } else {
            text = "\(who) did not pocket a ball."
        }
        if !s.fouls.isEmpty { text += " Foul." }
        if showsAlternative(s), let alt = s.alternative {
            text += " Engine preferred the \(alt.objectBall.number) in the \(alt.pocket.isSide ? "side" : "corner")."
        }
        return text
    }
}

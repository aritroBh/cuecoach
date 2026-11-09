import SwiftUI
import Charts
import Geometry
import Engine

/// Game review (pages/screens-b.md §3).
public struct GameReviewView: View {
    @Bindable var model: GameReviewModel
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.sbForceReduceMotion) private var forcedReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || forcedReduceMotion }
    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(\.verticalSizeClass) private var vSize
    @Environment(\.dynamicTypeSize) private var typeSize

    public init(model: GameReviewModel) { self.model = model }

    public var body: some View {
        ZStack {
            AX.page.ignoresSafeArea()
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 32) {
                        header
                        content
                    }
                    .padding(.horizontal, wide ? 24 : 16)
                    .padding(.bottom, 24)
                }
                doneBar.padding(.horizontal, wide ? 24 : 16).padding(.bottom, 8)
                    // Content fades out above the bar instead of being chopped at its edge.
                    .background(alignment: .top) {
                        LinearGradient(colors: [AX.page.opacity(0), AX.page], startPoint: .top, endPoint: .bottom)
                            .frame(height: 24)
                            .offset(y: -24)
                            .allowsHitTesting(false)
                    }
                    .background(AX.page)
            }
        }
        .task { await model.load() }
        .sensoryFeedback(.selection, trigger: model.selectedShotID)
    }

    private var wide: Bool { (vSize == .compact || hSize == .regular) && !typeSize.isAccessibilitySize }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .failed:
            VStack(spacing: 24) {
                centered("exclamationmark.triangle", "Unavailable", tint: AX.caution, id: "review.failed")
                if model.canRetry {
                    Button { Task { await model.retry() } } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(AXGlyph.font(28, .semibold))
                            .foregroundStyle(AX.ink)
                            .frame(width: 72, height: 72)
                            .background(Circle().fill(AX.surface))
                            .overlay(Circle().strokeBorder(AX.ink.opacity(0.2), lineWidth: 1))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Try again")
                    .accessibilityIdentifier("review.retry")
                }
            }
            .frame(maxWidth: .infinity)
        case .loading:
            VStack(spacing: 24) {
                Skeleton(height: 200, reduceMotion: reduceMotion)
                Skeleton(height: 56, reduceMotion: reduceMotion)
                Skeleton(height: 200, reduceMotion: reduceMotion)
                Skeleton(height: 260, reduceMotion: reduceMotion)
            }
            .accessibilityLabel("Loading review")
            .accessibilityIdentifier("review.loading")
        case .loaded:
            if model.isEmpty {
                centered("circle.slash", "No shots", tint: AX.inkMuted, id: "review.empty")
            } else if wide {
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 32) { winChance; timeline; replayCard }
                    VStack(alignment: .leading, spacing: 32) { sotgCard; mvpCard }
                }
            } else if typeSize.isAccessibilitySize {
                // AX sizes: the replay (the hero) comes first so it isn't pushed under the Done bar.
                VStack(alignment: .leading, spacing: 32) { replayCard; timeline; winChance; sotgCard; mvpCard }
            } else {
                VStack(alignment: .leading, spacing: 32) { winChance; timeline; replayCard; sotgCard; mvpCard }
            }
        }
    }

    private func centered(_ symbol: String, _ word: String, tint: Color, id: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: symbol).font(AXGlyph.font(64, .regular)).foregroundStyle(tint)
            Text(word).axFont(.headline).foregroundStyle(AX.inkMuted)
        }
        .frame(maxWidth: .infinity, minHeight: 320)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(id)
    }

    // MARK: Header

    @ViewBuilder private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let d = model.data {
                Text("Game \(d.gameIndex + 1)")
                    .axFont(.display).foregroundStyle(AX.ink)
                    .accessibilityAddTraits(.isHeader)
            } else if model.phase == .loading {
                // Title-sized placeholder: no made-up game number while loading.
                Text("Game 0").axFont(.display).hidden()
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: AX.radius.element).fill(AX.surface).opacity(0.8)
                    }
                    .accessibilityHidden(true)
            }
            if model.data == nil && model.phase == .loading {
                headerSkeleton
            } else if let d = model.data {
                HStack(spacing: 16) {
                    teamCluster(d.teams.first ?? [], team: 0, winner: d.winnerTeam == 0)
                    Spacer(minLength: 0)
                    Text("\(d.score.first ?? 0) – \(d.score.last ?? 0)")
                        .axFont(.display, weight: .bold, monospacedDigits: true)
                        .foregroundStyle(AX.ink)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Spacer(minLength: 0)
                    teamCluster(d.teams.last ?? [], team: 1, winner: d.winnerTeam == 1)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Team A \(d.score.first ?? 0), Team B \(d.score.last ?? 0)"
                                    + (d.winnerTeam.map { ", team \($0 == 0 ? "A" : "B") won" } ?? ""))
                .accessibilityIdentifier("review.header")
            }
        }
        .padding(.top, 8)
    }

    /// Same footprint as the loaded header row (two 40-pt avatars per side + score), so nothing jumps.
    private var headerSkeleton: some View {
        HStack(spacing: 16) {
            HStack(spacing: -12) { ForEach(0..<2, id: \.self) { _ in Circle().fill(AX.surface).frame(width: 40, height: 40) } }
                .padding(4)
            Spacer(minLength: 0)
            RoundedRectangle(cornerRadius: AX.radius.element).fill(AX.surface).frame(width: 96, height: 40)
            Spacer(minLength: 0)
            HStack(spacing: -12) { ForEach(0..<2, id: \.self) { _ in Circle().fill(AX.surface).frame(width: 40, height: 40) } }
                .padding(4)
        }
        .opacity(0.8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading score")
        .accessibilityIdentifier("review.header.skeleton")
    }

    private func teamCluster(_ players: [ReviewPlayer], team: Int, winner: Bool) -> some View {
        HStack(spacing: -12) {
            ForEach(players) { p in
                SBAvatar(symbol: p.symbol, colorName: p.colorName, size: 40)
                    .overlay(Circle().strokeBorder(AX.page, lineWidth: 2))
                    .overlay {
                        Circle().strokeBorder(winner ? AX.legal : AX.team(team),
                                              style: StrokeStyle(lineWidth: 3, dash: team == 0 ? [] : [4, 3]))
                            .padding(-4)
                    }
            }
        }
        .padding(4)
        .overlay(alignment: .top) {
            if winner {
                Image(systemName: "crown.fill").font(AXGlyph.font(16, .semibold))
                    .foregroundStyle(AX.legal).offset(y: -18)
            }
        }
        .opacity(winner || model.data?.winnerTeam == nil ? 1 : 0.6)
    }

    // MARK: Win chance

    @ViewBuilder private var winChance: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("Win chance")
            if model.showsChart {
                HStack(spacing: 8) {
                    VStack { TeamRing(team: 0); Spacer(); TeamRing(team: 1) }
                        .padding(.vertical, 4)
                    WinChanceChart(model: model)
                }
                .frame(height: 180)
            } else if let first = model.shots.first, let last = model.shots.last {
                let before = model.winProbBefore(first), after = model.winProbAfter(last)
                HStack(spacing: 12) {
                    TeamRing(team: 0)
                    VStack(spacing: 8) {
                        EvalBar(p: before).opacity(0.5)
                        EvalBar(p: after, delta: before)
                    }
                    TeamRing(team: 1)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(model.evalBarsAccessibilityLabel ?? "")   // direction words only, never numbers
                .accessibilityIdentifier("review.evalbars")
            }
        }
    }

    // MARK: Timeline

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("Shots")
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(model.shots) { s in
                            let selected = s.id == model.selectedShotID
                            let style = model.timelineStyle(s)
                            Button { model.select(s.id) } label: {
                                VStack(spacing: 2) {
                                    RatingBadgeCircle(style: style, diameter: selected ? 56 : 44, symbolSize: 20,
                                                      selected: selected, showGlow: false)
                                    TeamArc().stroke(AX.team(s.team), style: AX.teamStroke(s.team))
                                        .frame(width: 30, height: 12)
                                        .offset(y: -14)
                                }
                                .opacity(style.recedes && !selected ? 0.6 : 1)
                                .frame(width: 60, height: 76)
                            }
                            .buttonStyle(.plain)
                            .id(s.id)
                            .accessibilityLabel(model.accessibilityLabel(s))
                            .accessibilityAddTraits(selected ? .isSelected : [])
                            .accessibilityIdentifier("review.shot.\(s.index)")
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 4)
                }
                .scrollClipDisabled()
                .onAppear { if let id = model.shotOfGame?.id { proxy.scrollTo(id, anchor: .center) } }
                .onChange(of: model.selectedShotID) { _, id in
                    if let id { withAnimation(.snappy) { proxy.scrollTo(id, anchor: .center) } }
                }
            }
        }
    }

    // MARK: Replay

    @ViewBuilder private var replayCard: some View {
        if let s = model.selectedShot {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    sectionTitle("Replay")
                    Spacer()
                    Text("Shot \(s.index + 1)").axFont(.body).foregroundStyle(AX.inkMuted)
                }
                Group {
                    if model.isReplayAvailable(s) {
                        ReplayDiagram(shot: s, moment: model.replayMoment, showAlternative: model.showsAlternative(s),
                                      tableSize: model.data?.tableSize ?? .sevenFoot)
                            .id("\(s.id)-\(model.replayMoment)")
                            .transition(.opacity)
                            .accessibilityElement()
                            .accessibilityLabel(model.replayDescription(s))
                            .accessibilityIdentifier("review.replay")
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle").font(AXGlyph.font(32, .regular)).foregroundStyle(AX.caution)
                            Text("Unavailable").axFont(.headline).foregroundStyle(AX.inkMuted)
                        }
                        .frame(maxWidth: .infinity)
                        .aspectRatio(ReplayLayout.aspect(TableSpec(size: model.data?.tableSize ?? .sevenFoot)), contentMode: .fit)
                        .background(RoundedRectangle(cornerRadius: AX.radius.container).fill(AX.feltEdge.opacity(0.4)))
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("review.replay.unavailable")
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: model.selectedShotID)
                .animation(.easeInOut(duration: 0.2), value: model.replayMoment)
                .gesture(DragGesture(minimumDistance: 30).onEnded { v in
                    guard abs(v.translation.width) > abs(v.translation.height) else { return }
                    v.translation.width < 0 ? model.selectNext() : model.selectPrevious()
                })
                .accessibilityAction(named: "Next shot") { model.selectNext() }
                .accessibilityAction(named: "Previous shot") { model.selectPrevious() }

                Picker("Moment", selection: $model.replayMoment) {
                    Text("Before").tag(GameReviewModel.ReplayMoment.before)
                    Text("After").tag(GameReviewModel.ReplayMoment.after)
                }
                .pickerStyle(.segmented)
                .controlSize(.large)
                .frame(minHeight: 44)
                .accessibilityIdentifier("review.moment")

                if model.showsActualLegend(s) || model.showsAlternative(s) {
                    HStack(spacing: 24) {
                        if model.showsActualLegend(s) { legend(dashed: false, "Actual") }
                        if model.showsAlternative(s) { legend(dashed: true, "Engine") }
                    }
                }
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: AX.radius.container).fill(AX.surface))
        }
    }

    private func legend(dashed: Bool, _ word: String) -> some View {
        HStack(spacing: 8) {
            Path { p in p.move(to: CGPoint(x: 0, y: 6)); p.addLine(to: CGPoint(x: 24, y: 6)) }
                .stroke(dashed ? AX.onDark.opacity(0.5) : AX.ink, style: StrokeStyle(lineWidth: 2, dash: dashed ? [6, 6] : []))
                .frame(width: 24, height: 12)
            Text(word).axFont(.label, weight: .semibold).foregroundStyle(AX.inkMuted)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Shot of the Game

    @ViewBuilder private var sotgCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("Shot of the Game")
            if model.isLocked {
                lockedBody
            } else if let s = model.shotOfGame, let h = model.data?.shotOfGame {
                if model.canPlayShotOfGameClip {
                    Button { model.playShotOfGameClip() } label: {
                        ZStack {
                            RoundedRectangle(cornerRadius: AX.radius.container).fill(AX.feltEdge)
                            Image(systemName: "play.circle.fill").font(AXGlyph.font(64)).foregroundStyle(AX.ink)
                        }
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .contentShape(RoundedRectangle(cornerRadius: AX.radius.container))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Play clip")
                    .accessibilityIdentifier("review.sotg.play")
                } else {
                    // No clip yet: nothing that looks tappable.
                    ZStack {
                        RoundedRectangle(cornerRadius: AX.radius.container).fill(AX.feltEdge.opacity(0.6))
                        Image(systemName: "film").font(AXGlyph.font(40)).foregroundStyle(AX.inkMuted)
                    }
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(h.hasClip ? "Clip" : "Clip not ready")
                }
                HStack(spacing: 12) {
                    RatingBadgeCircle(style: .of(s.rating), diameter: 44, symbolSize: 20)
                    Text(h.label).axFont(.headline).foregroundStyle(AX.ink).lineLimit(2)
                    Spacer()
                }
                HStack(spacing: 12) {
                    EvalBar(p: model.winProbBefore(s))
                    Image(systemName: "arrow.right").axFont(.headline).foregroundStyle(AX.inkMuted)
                    EvalBar(p: model.winProbAfter(s))
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(model.accessibilityLabel(s))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: AX.radius.container).fill(AX.surface))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("review.sotg")
    }

    // MARK: MVP

    @ViewBuilder private var mvpCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("MVP")
            if model.isLocked {
                lockedBody
            } else if let mvp = model.mvp {
                HStack(spacing: 16) {
                    SBAvatar(symbol: mvp.player.symbol, colorName: mvp.player.colorName, size: 80, team: mvp.team)
                        .padding(5)
                    Text(mvp.player.name).axFont(.title).foregroundStyle(AX.ink).lineLimit(2)
                    Image(systemName: "crown.fill").axFont(.title).foregroundStyle(AX.ink)
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
                HStack(alignment: .center, spacing: 16) {
                    RatingBadgeCircle(style: .of(mvp.bestShot.rating), diameter: 44, symbolSize: 20, showGlow: false)
                    if model.isReplayAvailable(mvp.bestShot) {
                        ReplayDiagram(shot: mvp.bestShot, moment: .after, showAlternative: false,
                                      tableSize: model.data?.tableSize ?? .sevenFoot)
                            .frame(height: 120)
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { model.select(mvp.bestShot.id) }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: AX.radius.container).fill(AX.surface))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("review.mvp")
    }

    private var lockedBody: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.fill").font(AXGlyph.font(24, .semibold)).foregroundStyle(AX.inkMuted)
            Text("After game").axFont(.headline).foregroundStyle(AX.inkMuted)
        }
        .frame(maxWidth: .infinity, minHeight: 88)
        .accessibilityElement(children: .combine)
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s).axFont(.title).foregroundStyle(AX.ink)
            .dynamicTypeSize(...DynamicTypeSize.accessibility2)   // ui-QA-3: headings don't crowd out the hero
            .accessibilityAddTraits(.isHeader)
    }

    private var doneBar: some View {
        // Astryx Button (secondary, full width); its tap area is at least 44 pt.
        AXButton(title: "Done", variant: .secondary, fill: true, id: "review.done") { model.onDone?() }
    }
}

// MARK: - Pieces

/// Horizontal eval bar: Team A share on the left (solid), Team B on the right (hatched by opacity).
/// With `delta`, the change since that value is outlined so the swing reads without colour.
struct EvalBar: View {
    var p: Double
    var delta: Double? = nil
    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let x = w * min(max(p, 0), 1)
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    Rectangle().fill(AX.teamA).frame(width: x)
                    Rectangle().fill(AX.teamB.opacity(0.85))
                }
                .clipShape(RoundedRectangle(cornerRadius: AX.radius.inner))
                if let d = delta {
                    let x0 = w * min(max(d, 0), 1)
                    RoundedRectangle(cornerRadius: AX.radius.inner)
                        .strokeBorder(AX.ink, lineWidth: 2)
                        .frame(width: max(abs(x - x0), 4), height: 20)
                        .offset(x: min(x, x0))
                }
                Rectangle().fill(AX.ink).frame(width: 2, height: 20).offset(x: x - 1)
            }
            .frame(height: 20)
        }
        .frame(height: 20)
        .accessibilityHidden(true)
    }
}

/// Team marker that doesn't rely on colour: solid ring = Team A, dashed ring = Team B.
struct TeamRing: View {
    var team: Int
    var size: CGFloat = 20
    var body: some View {
        Circle().stroke(AX.team(team), style: AX.teamStroke(team, width: 3))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

private struct Skeleton: View {
    var height: CGFloat
    var reduceMotion: Bool
    @State private var dim = false
    var body: some View {
        RoundedRectangle(cornerRadius: AX.radius.container).fill(AX.surface)
            .frame(height: height)
            .opacity(reduceMotion ? 0.5 : (dim ? 0.5 : 1))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1).repeatForever()) { dim = true }
            }
    }
}

private struct WinChanceChart: View {
    let model: GameReviewModel

    var body: some View {
        let pts = model.chartPoints
        Chart {
            ForEach(pts, id: \.x) { p in
                AreaMark(x: .value("Shot", p.x), yStart: .value("Even", 0.5), yEnd: .value("A", max(p.y, 0.5)),
                         series: .value("Side", "A"))
                    .foregroundStyle(AX.teamA.opacity(0.18))
                AreaMark(x: .value("Shot", p.x), yStart: .value("B", min(p.y, 0.5)), yEnd: .value("Even", 0.5),
                         series: .value("Side", "B"))
                    .foregroundStyle(AX.teamB.opacity(0.18))
                LineMark(x: .value("Shot", p.x), y: .value("Team A", p.y))
                    .foregroundStyle(AX.ink)
                    .lineStyle(StrokeStyle(lineWidth: 2))
            }
            RuleMark(y: .value("Even", 0.5))
                .foregroundStyle(AX.inkMuted)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            ForEach(model.chartMarkers) { s in
                PointMark(x: .value("Shot", model.chartX(s)), y: .value("Team A", model.winProbAfter(s)))
                    .foregroundStyle(AX.ink)
                    .symbolSize(28)
            }
            if let sel = model.selectedShot {
                RuleMark(x: .value("Shot", model.chartX(sel)), yStart: .value("Low", 0), yEnd: .value("High", 1))
                    .foregroundStyle(AX.ink.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
        }
        .chartYScale(domain: 0...1)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(values: [0.5]) { _ in
                AxisValueLabel("50%").font(.footnote.weight(.semibold))   // Charts takes a Font, not a view modifier.foregroundStyle(AX.inkMuted)
            }
        }
        .chartLegend(.hidden)
        .chartPlotStyle { $0.clipped() }
        .clipped()
        // System selection gesture: coexists with the page's vertical scroll (a raw drag would swallow it).
        .chartXSelection(value: Binding<Int?>(
            get: { model.selectedShot.map(model.chartX) },
            set: { if let x = $0 { model.selectNearest(chartX: Double(x)) } }))
        .accessibilityChartDescriptor(WinChanceDescriptor(xs: pts.map(\.x), ys: pts.map(\.y)))
        .accessibilityIdentifier("review.chart")
    }
}

private struct WinChanceDescriptor: AXChartDescriptorRepresentable {
    let xs: [Int]
    let ys: [Double]
    func makeChartDescriptor() -> AXChartDescriptor {
        let pts = zip(xs, ys).map { (x: $0, y: $1) }
        let x = AXNumericDataAxisDescriptor(title: "Shot", range: Double(pts.first?.x ?? 0)...Double(max(pts.last?.x ?? 1, 1)),
                                            gridlinePositions: []) { "Shot \(Int($0) + 1)" }
        let y = AXNumericDataAxisDescriptor(title: "Team A win chance", range: 0...1, gridlinePositions: [0.5]) { v in
            GameReviewModel.standingWords(v)
        }
        let series = AXDataSeriesDescriptor(name: "Win chance", isContinuous: true,
                                            dataPoints: pts.map { AXDataPoint(x: Double($0.x), y: $0.y) })
        return AXChartDescriptor(title: "Win chance", summary: nil, xAxis: x, yAxis: y, additionalAxes: [], series: [series])
    }
}

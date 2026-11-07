import SwiftUI
import Charts
import Engine

/// Game review (pages/screens-b.md §3).
public struct GameReviewView: View {
    @State private var model: GameReviewModel
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.sbForceReduceMotion) private var forcedReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || forcedReduceMotion }
    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(\.verticalSizeClass) private var vSize
    @Environment(\.dynamicTypeSize) private var typeSize

    public init(model: GameReviewModel) { _model = State(initialValue: model) }

    public var body: some View {
        ZStack {
            SBColor.bg.ignoresSafeArea()
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
            }
        }
        .preferredColorScheme(.dark)
        .task { await model.load() }
        .sensoryFeedback(.selection, trigger: model.selectedShotID)
        .accessibilityIdentifier("screen.review")
    }

    private var wide: Bool { (vSize == .compact || hSize == .regular) && !typeSize.isAccessibilitySize }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .failed:
            centered("exclamationmark.triangle", "Unavailable", tint: SBColor.caution, id: "review.failed")
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
                centered("circle.dashed", "No shots", tint: SBColor.inkMuted, id: "review.empty")
            } else if wide {
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 32) { winChance; timeline; replayCard }
                    VStack(alignment: .leading, spacing: 32) { sotgCard; mvpCard }
                }
            } else {
                VStack(alignment: .leading, spacing: 32) { winChance; timeline; replayCard; sotgCard; mvpCard }
            }
        }
    }

    private func centered(_ symbol: String, _ word: String, tint: Color, id: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: symbol).font(.system(size: 64, weight: .regular)).foregroundStyle(tint)
            Text(word).font(.system(size: 17, weight: .semibold)).foregroundStyle(SBColor.inkMuted)
        }
        .frame(maxWidth: .infinity, minHeight: 320)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(id)
    }

    // MARK: Header

    @ViewBuilder private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Game \((model.data?.gameIndex ?? 0) + 1)")
                .font(.system(size: 34, weight: .bold)).foregroundStyle(SBColor.ink)
                .accessibilityAddTraits(.isHeader)
            if let d = model.data {
                HStack(spacing: 16) {
                    teamCluster(d.teams.first ?? [], team: 0, winner: d.winnerTeam == 0)
                    Spacer(minLength: 0)
                    Text("\(d.score.first ?? 0) – \(d.score.last ?? 0)")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(SBColor.ink)
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

    private func teamCluster(_ players: [ReviewPlayer], team: Int, winner: Bool) -> some View {
        HStack(spacing: -12) {
            ForEach(players) { p in
                SBAvatar(symbol: p.symbol, colorName: p.colorName, size: 40)
                    .overlay(Circle().strokeBorder(SBColor.bg, lineWidth: 2))
                    .overlay {
                        Circle().strokeBorder(winner ? SBColor.legal : SBColor.team(team),
                                              style: StrokeStyle(lineWidth: 3, dash: team == 0 ? [] : [4, 3]))
                            .padding(-4)
                    }
            }
        }
        .padding(4)
        .overlay(alignment: .top) {
            if winner {
                Image(systemName: "crown.fill").font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(SBColor.legal).offset(y: -18)
            }
        }
        .opacity(winner || model.data?.winnerTeam == nil ? 1 : 0.6)
    }

    // MARK: Win chance

    @ViewBuilder private var winChance: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("Win chance")
            if model.showsChart {
                WinChanceChart(model: model)
                    .frame(height: 180)
            } else if let first = model.shots.first, let last = model.shots.last {
                HStack(spacing: 16) {
                    EvalBar(p: model.winProbBefore(first))
                    Image(systemName: "arrow.right").font(.system(size: 17, weight: .semibold)).foregroundStyle(SBColor.inkMuted)
                    EvalBar(p: model.winProbAfter(last))
                }
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
                                    TeamArc().stroke(SBColor.team(s.team), style: StrokeStyle(lineWidth: 2, lineCap: .round))
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
                    Text("Shot \(s.index + 1)").font(.system(size: 17)).foregroundStyle(SBColor.inkMuted)
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
                            Image(systemName: "exclamationmark.triangle").font(.system(size: 32)).foregroundStyle(SBColor.caution)
                            Text("Unavailable").font(.system(size: 17, weight: .semibold)).foregroundStyle(SBColor.inkMuted)
                        }
                        .frame(maxWidth: .infinity)
                        .aspectRatio(2.18, contentMode: .fit)
                        .background(RoundedRectangle(cornerRadius: 14).fill(SBColor.feltEdge.opacity(0.4)))
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

                HStack(spacing: 24) {
                    legend(dashed: false, "Actual")
                    if model.showsAlternative(s) { legend(dashed: true, "Engine") }
                }
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 20).fill(SBColor.surface))
        }
    }

    private func legend(dashed: Bool, _ word: String) -> some View {
        HStack(spacing: 8) {
            Path { p in p.move(to: CGPoint(x: 0, y: 6)); p.addLine(to: CGPoint(x: 24, y: 6)) }
                .stroke(dashed ? SBColor.predict : SBColor.ink, style: StrokeStyle(lineWidth: 2, dash: dashed ? [6, 6] : []))
                .frame(width: 24, height: 12)
            Text(word).font(.system(size: 13, weight: .semibold)).foregroundStyle(SBColor.inkMuted)
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
                ZStack {
                    RoundedRectangle(cornerRadius: 14).fill(SBColor.feltEdge)
                    Image(systemName: h.hasClip ? "play.circle.fill" : "film")
                        .font(.system(size: h.hasClip ? 64 : 40, weight: .regular))
                        .foregroundStyle(h.hasClip ? SBColor.ink : SBColor.inkMuted)
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .accessibilityLabel(h.hasClip ? "Play clip" : "Clip not ready")
                HStack(spacing: 12) {
                    RatingBadgeCircle(style: .of(s.rating), diameter: 44, symbolSize: 20)
                    Text(h.label).font(.system(size: 17, weight: .semibold)).foregroundStyle(SBColor.ink).lineLimit(2)
                    Spacer()
                }
                HStack(spacing: 12) {
                    EvalBar(p: model.winProbBefore(s))
                    Image(systemName: "arrow.right").font(.system(size: 17, weight: .semibold)).foregroundStyle(SBColor.inkMuted)
                    EvalBar(p: model.winProbAfter(s))
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(model.accessibilityLabel(s))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20).fill(SBColor.surface))
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
                    Text(mvp.player.name).font(.system(size: 22, weight: .semibold)).foregroundStyle(SBColor.ink).lineLimit(2)
                    Image(systemName: "crown.fill").font(.system(size: 22, weight: .semibold)).foregroundStyle(SBColor.ink)
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
        .background(RoundedRectangle(cornerRadius: 20).fill(SBColor.surface))
        .accessibilityIdentifier("review.mvp")
    }

    private var lockedBody: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.fill").font(.system(size: 24, weight: .semibold)).foregroundStyle(SBColor.inkMuted)
            Text("After game").font(.system(size: 17, weight: .semibold)).foregroundStyle(SBColor.inkMuted)
        }
        .frame(maxWidth: .infinity, minHeight: 88)
        .accessibilityElement(children: .combine)
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s).font(.system(size: 22, weight: .semibold)).foregroundStyle(SBColor.ink)
            .accessibilityAddTraits(.isHeader)
    }

    private var doneBar: some View {
        Button { model.onDone?() } label: {
            Text("Done").font(.system(size: 17, weight: .semibold)).foregroundStyle(SBColor.bg)
                .frame(maxWidth: .infinity, minHeight: 56)
                .background(RoundedRectangle(cornerRadius: 14).fill(SBColor.ink))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("review.done")
    }
}

// MARK: - Pieces

/// Horizontal eval bar: Team A share on the left (solid), Team B on the right (hatched by opacity).
struct EvalBar: View {
    var p: Double
    var body: some View {
        GeometryReader { g in
            HStack(spacing: 0) {
                Rectangle().fill(SBColor.teamA).frame(width: g.size.width * min(max(p, 0), 1))
                Rectangle().fill(SBColor.teamB.opacity(0.85))
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .frame(height: 12)
        .accessibilityHidden(true)
    }
}

private struct Skeleton: View {
    var height: CGFloat
    var reduceMotion: Bool
    @State private var dim = false
    var body: some View {
        RoundedRectangle(cornerRadius: 20).fill(SBColor.surface)
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
                    .foregroundStyle(SBColor.teamA.opacity(0.18))
                AreaMark(x: .value("Shot", p.x), yStart: .value("B", min(p.y, 0.5)), yEnd: .value("Even", 0.5),
                         series: .value("Side", "B"))
                    .foregroundStyle(SBColor.teamB.opacity(0.18))
                LineMark(x: .value("Shot", p.x), y: .value("Team A", p.y))
                    .foregroundStyle(SBColor.ink)
                    .lineStyle(StrokeStyle(lineWidth: 2))
            }
            RuleMark(y: .value("Even", 0.5))
                .foregroundStyle(SBColor.inkMuted)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            ForEach(model.chartMarkers) { s in
                PointMark(x: .value("Shot", model.chartX(s)), y: .value("Team A", model.winProbAfter(s)))
                    .foregroundStyle(RatingBadgeStyle.of(s.rating).tone.color)
                    .symbolSize(36)
            }
            if let sel = model.selectedShot {
                RuleMark(x: .value("Shot", model.chartX(sel)))
                    .foregroundStyle(SBColor.ink.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
        }
        .chartYScale(domain: 0...1)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(values: [0.5]) { _ in
                AxisValueLabel("50%").font(.system(size: 13, weight: .semibold)).foregroundStyle(SBColor.inkMuted)
            }
        }
        .chartLegend(.hidden)
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                        guard let plot = proxy.plotFrame else { return }
                        let x = v.location.x - geo[plot].origin.x
                        if let shot: Double = proxy.value(atX: x) { model.selectNearest(chartX: shot) }
                    })
            }
        }
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
            v > 0.55 ? "Team A ahead" : (v < 0.45 ? "Team B ahead" : "Even")
        }
        let series = AXDataSeriesDescriptor(name: "Win chance", isContinuous: true,
                                            dataPoints: pts.map { AXDataPoint(x: Double($0.x), y: $0.y) })
        return AXChartDescriptor(title: "Win chance", summary: nil, xAxis: x, yAxis: y, additionalAxes: [], series: [series])
    }
}

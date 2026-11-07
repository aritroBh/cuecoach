import Rules
import SwiftUI

/// Player profile (SPEC §6–§8, §10, §11; design-system/cuecoach/pages/screens-a.md §2).
struct PlayerProfileView: View {
    @State private var model: PlayerProfileViewModel
    @State private var badge: EarnedBadge?
    @State private var showingPro = false
    @State private var editing = false
    @State private var showEvolution = false
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.saForceReduceMotion) private var forceReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || forceReduceMotion }
    @Environment(\.dynamicTypeSize) private var typeSize

    init(model: PlayerProfileViewModel) { _model = State(initialValue: model) }

    private var accent: Color {
        guard let s = model.content?.summary else { return SA.teamA }
        return s.isTeamA ? SA.teamA : Color(saHex: s.avatarColor)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: SA.section) {
                header
                Picker("Section", selection: Binding(get: { model.tab },
                                                     set: { t in withAnimation(SAMotion(reduce: reduceMotion).smooth) { model.tab = t }; SA.selection() })) {
                    ForEach(model.tabs, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .controlSize(.large)
                .frame(minHeight: 44)
                .accessibilityIdentifier("profile.tabs")
                tabContent
            }
            .padding(.horizontal, SA.gutter)
            .padding(.bottom, 32)
        }
        .background(SA.bg.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if model.canEdit && model.phase == .loaded {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { editing = true } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                        .accessibilityLabel("Edit profile")
                        .accessibilityIdentifier("profile.edit")
                }
            }
        }
        .toolbarBackground(SA.bg, for: .navigationBar)
        .preferredColorScheme(.dark)
        .task { if model.content == nil { await model.load() } }
        .sheet(item: $badge) { BadgeDetail(badge: $0).presentationDetents([.medium]) }
        .sheet(isPresented: $showingPro) {
            if let c = model.content, let pro = c.proComp {
                ProCompDetail(pro: pro, axes: c.radar, accent: accent).presentationDetents([.large])
            }
        }
        .sheet(isPresented: $editing) {
            if let s = model.content?.summary {
                EditProfileSheet(name: s.name, symbol: s.avatarSymbol) { name, symbol in
                    model.rename(name, symbol: symbol)
                }
                .presentationDetents([.medium])
            }
        }
        .accessibilityIdentifier("screen.profile")
    }

    // MARK: Header

    @ViewBuilder private var header: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().fill(model.content.map { Color(saHex: $0.summary.avatarColor) } ?? SA.surface)
                Image(systemName: model.content?.summary.avatarSymbol ?? "person.fill")
                    .font(.system(size: 44, weight: .semibold)).foregroundStyle(SA.ink)
            }
            .frame(width: 96, height: 96)
            .accessibilityHidden(true)
            Text(model.content?.summary.name ?? "Player")
                .font(.largeTitle.bold()).foregroundStyle(SA.ink)
                .redacted(reason: model.phase == .loading ? .placeholder : [])
                .accessibilityIdentifier("profile.name")
            if let top = model.content?.topArchetype {
                Label(top.name, systemImage: top.symbol)
                    .font(.body.weight(.semibold)).foregroundStyle(SA.inkMuted)
                    .accessibilityLabel("Archetype \(top.name)")
                    .accessibilityIdentifier("profile.archetype")
            }
        }
        .padding(.top, 8)
    }

    // MARK: Tabs

    @ViewBuilder private var tabContent: some View {
        switch model.phase {
        case .failed:
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 44)).foregroundStyle(SA.caution)
                Text("Couldn't load stats.").font(.body).foregroundStyle(SA.ink)
                Button("Retry") { Task { await model.load() } }
                    .buttonStyle(.borderedProminent).tint(SA.surface).controlSize(.large)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("profile.retry")
            }
            .frame(maxWidth: .infinity, minHeight: 320)
            .accessibilityIdentifier("profile.error")
        case .loading:
            statsTab(placeholderContent).redacted(reason: .placeholder).allowsHitTesting(false)
        case .loaded:
            if let c = model.content {
                switch model.tab {
                case .stats: statsTab(c)
                case .history: HistoryTab(groups: c.history, expanded: model.expanded,
                                          toggle: { model.toggleExpanded($0) }, open: { model.openGame($0) })
                case .training: TrainingTabView(content: model.training)
                }
            }
        }
    }

    private var placeholderContent: ProfileContent {
        PlayerProfileViewModel.build(
            summary: .init(id: model.playerID, name: "Player", avatarSymbol: "person", avatarColor: "#151B19",
                           games: 0, wins: 0, shots: 0, makes: 0),
            archetype: nil, grid: [], badges: [], pro: nil, history: [])
    }

    // MARK: Stats tab

    private func statsTab(_ c: ProfileContent) -> some View {
        VStack(spacing: SA.section) {
            radarCard(c)
            SACard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Make %").font(.title2.weight(.semibold)).foregroundStyle(SA.ink)
                        .accessibilityAddTraits(.isHeader)
                    MakeHeatGrid(cells: c.heat).frame(maxWidth: .infinity)
                }
            }
            proCard(c)
            if c.showsBadgeShelf { badgeShelf(c) }
            totals(c)
        }
        .accessibilityIdentifier("profile.stats")
    }

    private func radarCard(_ c: ProfileContent) -> some View {
        SACard {
            ZStack(alignment: .topTrailing) {
                if c.unlock == .newPlayer {
                    VStack(spacing: 16) {
                        ZStack {
                            ArchetypeRadar(axes: [], accent: accent, showsLabels: false)
                            Image(systemName: "figure.pool.swim").font(.system(size: 44)).foregroundStyle(SA.inkMuted)
                        }
                        .frame(height: 200)
                        Text("Play a game to start.").font(.body).foregroundStyle(SA.inkMuted)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("profile.radar.empty")
                } else {
                    ArchetypeRadar(axes: c.radar, overlay: showEvolution ? c.previousRadar : nil,
                                   accent: accent, draft: c.unlock != .unlocked)
                        .frame(height: typeSize.isAccessibilitySize ? 360 : 300)
                        .contentShape(Rectangle())
                        .onLongPressGesture(minimumDuration: 0.3) {} onPressingChanged: { showEvolution = $0 }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Archetype shape")
                        .accessibilityValue(PlayerProfileViewModel.radarSummary(c.radar))
                        .accessibilityChartDescriptor(SARadarDescriptor(axes: c.radar))
                        .accessibilityIdentifier("profile.radar")
                    if c.unlock != .unlocked {
                        Image(systemName: "lock.fill").font(.body.weight(.semibold)).foregroundStyle(SA.inkMuted)
                            .accessibilityLabel("Draft shape, locked")
                    }
                }
            }
        }
    }

    @ViewBuilder private func proCard(_ c: ProfileContent) -> some View {
        if let pro = c.proComp {
            Button { showingPro = true } label: {
                SACard {
                    HStack(spacing: 16) {
                        ZStack {
                            SARing(progress: pro.similarity, color: accent)
                            Text(PlayerProfileViewModel.percent(pro.similarity))
                                .font(.system(.body, design: .rounded).weight(.bold)).monospacedDigit()
                                .foregroundStyle(SA.ink)
                        }
                        .frame(width: 72, height: 72)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(pro.proName).font(.title2.weight(.semibold)).foregroundStyle(SA.ink)
                            HStack(spacing: 16) {
                                ForEach(c.proTraits) { t in
                                    Label(t.word, systemImage: t.symbol)
                                        .font(.body).foregroundStyle(SA.inkMuted)
                                }
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: 88)
                }
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(PlayerProfileViewModel.proCompSpoken(name: pro.proName, similarity: pro.similarity))
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("profile.procomp")
        } else if c.unlock != .unlocked {
            SACard {
                HStack(spacing: 16) {
                    ZStack {
                        SARing(progress: c.lockProgress, color: SA.inkMuted)
                        Image(systemName: "lock.fill").font(.title3).foregroundStyle(SA.inkMuted)
                    }
                    .frame(width: 72, height: 72)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Plays like").font(.title2.weight(.semibold)).foregroundStyle(SA.inkMuted)
                        if let cap = c.lockedCaption {
                            Text(cap).font(.body.weight(.semibold)).monospacedDigit().foregroundStyle(SA.ink)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 88)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Pro comparison locked, \(c.lockedCaption ?? "") more needed")
            .accessibilityIdentifier("profile.procomp.locked")
        }
    }

    private func badgeShelf(_ c: ProfileContent) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SA.sectionHeader("Badges")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 56, maximum: 72), spacing: 12)], spacing: 12) {
                ForEach(c.visibleBadges) { b in
                    Button { badge = b } label: {
                        ZStack {
                            Circle().fill(SA.surface)
                            Circle().stroke(accent.opacity(0.5), lineWidth: 1.5)
                            Image(systemName: b.symbol).font(.system(size: 26, weight: .semibold))
                                .foregroundStyle(SA.ink)
                        }
                        .frame(width: 56, height: 56)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(PlayerProfileViewModel.badgeSpoken(b))
                }
            }
            .accessibilityIdentifier("profile.badges")
        }
    }

    private func totals(_ c: ProfileContent) -> some View {
        SAAdaptiveStack(spacing: 8) {
            ForEach(c.totals) { t in
                VStack(spacing: 4) {
                    Text(t.value).font(.system(size: 28, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(SA.ink)
                    Text(t.caption).font(.footnote.weight(.semibold)).foregroundStyle(SA.inkMuted)
                }
                .frame(maxWidth: .infinity, minHeight: 72)
                .accessibilityElement(children: .combine)
            }
        }
        .accessibilityIdentifier("profile.totals")
    }
}

// MARK: - History

private struct HistoryTab: View {
    let groups: [HistoryGroup]
    let expanded: Set<UUID>
    let toggle: (UUID) -> Void
    let open: (UUID) -> Void

    var body: some View {
        if groups.isEmpty {
            ContentUnavailableView("No games yet", systemImage: "clock")
                .foregroundStyle(SA.inkMuted)
                .frame(minHeight: 280)
                .accessibilityIdentifier("profile.history.empty")
        } else {
            VStack(spacing: SA.section) {
                ForEach(groups) { g in
                    VStack(spacing: 8) {
                        SA.sectionHeader(g.title)
                        SACard(padding: 0) {
                            VStack(spacing: 0) {
                                ForEach(Array(g.sessions.enumerated()), id: \.element.id) { i, s in
                                    if i > 0 { Divider().overlay(SA.inkMuted.opacity(0.3)).padding(.leading, 68) }
                                    sessionRow(s)
                                    if expanded.contains(s.id) {
                                        ForEach(s.games) { game in gameRow(game) }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .accessibilityIdentifier("profile.history")
        }
    }

    private func sessionRow(_ s: SessionSummary) -> some View {
        Button { toggle(s.id) } label: {
            HStack(spacing: 16) {
                SARuleBall(number: SettingsViewModel.ruleBall(s.ruleSet), size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(PlayerProfileViewModel.sessionTitle(s)).font(.body).foregroundStyle(SA.ink)
                    Text(PlayerProfileViewModel.sessionSubtitle(s))
                        .font(.footnote.weight(.semibold)).foregroundStyle(SA.inkMuted)
                }
                Spacer(minLength: 8)
                ResultMark(won: s.won)
                Image(systemName: expanded.contains(s.id) ? "chevron.down" : "chevron.right")
                    .font(.footnote.weight(.semibold)).foregroundStyle(SA.inkMuted)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 64)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint(expanded.contains(s.id) ? "Hides games" : "Shows games")
    }

    private func gameRow(_ g: GameSummary) -> some View {
        Button { open(g.id) } label: {
            HStack(spacing: 16) {
                Text("Game \(g.index + 1)").font(.body).monospacedDigit().foregroundStyle(SA.ink)
                Spacer()
                ResultMark(won: g.won)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(SA.inkMuted)
            }
            .padding(.leading, 68).padding(.trailing, 16)
            .frame(minHeight: 52)
            .background(SA.bg.opacity(0.3))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }
}

/// Win = filled green check, loss = outlined red ×. Shape + color, never color alone.
private struct ResultMark: View {
    let won: Bool?
    var body: some View {
        switch won {
        case true?:
            Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(SA.legal)
                .accessibilityLabel("Won")
        case false?:
            Image(systemName: "xmark.circle").font(.title2).foregroundStyle(SA.danger)
                .accessibilityLabel("Lost")
        case nil:
            Image(systemName: "circle.dotted").font(.title2).foregroundStyle(SA.inkMuted)
                .accessibilityLabel("Unfinished")
        }
    }
}

// MARK: - Sheets

private struct BadgeDetail: View {
    let badge: EarnedBadge
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: badge.symbol).font(.system(size: 72, weight: .semibold)).foregroundStyle(SA.ink)
            Text(badge.name).font(.title2.weight(.semibold)).foregroundStyle(SA.ink)
            Text(badge.earnedAt, format: .dateTime.day().month(.wide).year())
                .font(.body).foregroundStyle(SA.inkMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SA.bg)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("profile.badge.detail")
    }
}

private struct ProCompDetail: View {
    let pro: ProCompView
    let axes: [RadarAxis]
    let accent: Color
    var body: some View {
        VStack(spacing: 24) {
            Text(pro.proName).font(.title2.weight(.semibold)).foregroundStyle(SA.ink).padding(.top, 24)
            // The pro's per-axis shape isn't in the local contract yet, so the sheet shows the player's shape only.
            ArchetypeRadar(axes: axes, accent: accent).frame(height: 320)
            Text(PlayerProfileViewModel.band(pro.similarity).capitalized + " match")
                .font(.body.weight(.semibold)).foregroundStyle(SA.inkMuted)
            Spacer()
        }
        .padding(.horizontal, SA.gutter)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SA.bg)
        .accessibilityIdentifier("profile.procomp.detail")
    }
}

private struct EditProfileSheet: View {
    @State var name: String
    @State var symbol: String
    let save: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    private let symbols = ["figure.pool.swim", "star.fill", "flame.fill", "bolt.fill", "moon.fill", "leaf.fill"]

    var body: some View {
        NavigationStack {
            VStack(spacing: SA.section) {
                TextField("Name", text: $name)
                    .font(.title2).padding(16).frame(minHeight: 56)
                    .background(SA.surface, in: RoundedRectangle(cornerRadius: SA.buttonRadius))
                    .accessibilityIdentifier("profile.edit.name")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6)) {
                    ForEach(symbols, id: \.self) { s in
                        Button { symbol = s } label: {
                            Image(systemName: s).font(.title2).frame(width: 52, height: 52)
                                .background(Circle().fill(symbol == s ? SA.surface : .clear))
                                .overlay(Circle().stroke(symbol == s ? SA.ink : .clear, lineWidth: 2))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(symbol == s ? .isSelected : [])
                    }
                }
                Spacer()
            }
            .padding(SA.gutter)
            .background(SA.bg)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save(name, symbol); dismiss() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Accessibility chart

struct SARadarDescriptor: AXChartDescriptorRepresentable {
    let axes: [RadarAxis]
    func makeChartDescriptor() -> AXChartDescriptor {
        let x = AXCategoricalDataAxisDescriptor(title: "Trait", categoryOrder: axes.map(\.name))
        let y = AXNumericDataAxisDescriptor(title: "Strength", range: 0...1, gridlinePositions: [1 / 3, 2 / 3, 1]) {
            PlayerProfileViewModel.level($0)
        }
        let series = AXDataSeriesDescriptor(name: "Archetype", isContinuous: false,
                                            dataPoints: axes.map { .init(x: $0.name, y: $0.value) })
        return AXChartDescriptor(title: "Archetype shape", summary: PlayerProfileViewModel.radarSummary(axes),
                                 xAxis: x, yAxis: y, additionalAxes: [], series: [series])
    }
}

#Preview("Veteran") {
    let f = SamplePlayerData.veteran
    return NavigationStack {
        PlayerProfileView(model: PlayerProfileViewModel(playerID: f.playerID, stats: f.stats, training: f.training))
    }
}

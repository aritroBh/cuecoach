import Rules
import SwiftUI

/// Player profile (SPEC §6–§8, §10, §11; design-system/cuecoach/pages/screens-a.md §2).
public struct PlayerProfileView: View {
    @State private var model: PlayerProfileViewModel
    @State private var badge: BadgeGroup?
    @State private var showingAllBadges = false
    @State private var showingPro = false
    @State private var editing = false
    @State private var showEvolution = false
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.saForceReduceMotion) private var forceReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || forceReduceMotion }
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var ringSide: CGFloat = 72

    public init(model: PlayerProfileViewModel) { _model = State(initialValue: model) }

    private var accent: Color {
        guard let s = model.content?.summary else { return AX.teamA }
        return s.isTeamA ? AX.teamA : AX.avatar(s.avatarColor)
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: AX.space.s6) {
                header
                Picker("Section", selection: Binding(get: { model.tab },
                                                     set: { t in withAnimation(SAMotion(reduce: reduceMotion).smooth) { model.tab = t }; Haptics.selection() })) {
                    ForEach(model.tabs, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .controlSize(.large)
                .frame(minHeight: 44)
                .accessibilityIdentifier("profile.tabs")
                tabContent
            }
            .padding(.horizontal, AX.space.s4)
            .padding(.bottom, 32)
        }
        .background(AX.page.ignoresSafeArea())
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
        .toolbarBackground(AX.page, for: .navigationBar)
        .task { if model.content == nil { await model.load() } }
        .sheet(item: $badge) { BadgeDetail(badge: $0).presentationDetents([.medium]) }
        .sheet(isPresented: $showingAllBadges) {
            if let c = model.content { AllBadges(groups: c.badgeGroups).presentationDetents([.large]) }
        }
        .sheet(isPresented: $showingPro) {
            if let c = model.content, let pro = c.proComp {
                ProCompDetail(pro: pro, playerName: c.summary.name, axes: c.radar, proAxes: c.proRadar,
                              accent: accent)
                    .presentationDetents([.large])
            }
        }
        .sheet(isPresented: $editing) {
            if let s = model.content?.summary {
                EditProfileSheet(name: s.name, symbol: s.avatarSymbol) { name, symbol in
                    Task {
                        await model.rename(name, symbol: symbol)
                        Haptics.notify(model.renameFailed ? .error : .success)
                    }
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
                Circle().fill(model.content.map { AX.avatar($0.summary.avatarColor) } ?? AX.surface)
                if let symbol = model.content?.summary.avatarSymbol {
                    Image(systemName: symbol).font(AXGlyph.font(44, .semibold)).foregroundStyle(AX.onDark)
                }
            }
            .frame(width: 96, height: 96)
            .accessibilityHidden(true)
            Text(model.content?.summary.name ?? "Player")
                .axFont(.display, weight: .bold).foregroundStyle(AX.ink)
                .redacted(reason: model.phase == .loaded ? [] : .placeholder)
                .accessibilityIdentifier("profile.name")
            if let top = model.content?.topArchetype {
                Label(top.name, systemImage: top.symbol)
                    .axFont(.headline).foregroundStyle(AX.inkMuted)
                    .accessibilityLabel("Archetype \(top.name)")
                    .accessibilityIdentifier("profile.archetype")
            }
        }
        .padding(.top, 8)
    }

    // MARK: Tabs

    @ViewBuilder private var tabContent: some View {
        switch model.phase {
        case .failed where !model.failureScope(model.tab):
            TrainingTabView(content: model.training, failed: model.trainingFailed) {
                Task { await model.loadTraining() }
            }
        case .failed:
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 44)).foregroundStyle(AX.caution)
                Text("Couldn't load stats.").axFont(.body).foregroundStyle(AX.ink)
                Button("Retry") { Task { await model.load() } }
                    .buttonStyle(.borderedProminent).tint(AX.surface).controlSize(.large)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("profile.retry")
            }
            .frame(maxWidth: .infinity, minHeight: 320)
        case .loading:
            statsTab(placeholderContent).redacted(reason: .placeholder).allowsHitTesting(false)
        case .loaded:
            if let c = model.content {
                switch model.tab {
                case .stats: statsTab(c)
                case .history: HistoryTab(groups: c.history, expanded: model.expanded,
                                          toggle: { model.toggleExpanded($0) }, open: { model.openGame($0) })
                case .training: TrainingTabView(content: model.training, failed: model.trainingFailed) {
                Task { await model.loadTraining() }
            }
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
        VStack(spacing: AX.space.s6) {
            radarCard(c)
            SACard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Make %").axFont(.title).foregroundStyle(AX.ink)
                        .accessibilityAddTraits(.isHeader)
                    MakeHeatGrid(cells: c.heat).frame(maxWidth: .infinity)
                }
            }
            proCard(c)
            if c.showsBadgeShelf { badgeShelf(c) }
            totals(c)
        }
    }

    private func radarCard(_ c: ProfileContent) -> some View {
        SACard {
            ZStack(alignment: .topTrailing) {
                if c.unlock == .newPlayer {
                    VStack(spacing: 16) {
                        ZStack {
                            ArchetypeRadar(axes: [], accent: accent, showsLabels: false)
                            Image(systemName: "8.circle").font(.system(size: 44)).foregroundStyle(AX.inkMuted)
                        }
                        .frame(height: 200)
                        Text("Play a game to start.").axFont(.body).foregroundStyle(AX.inkMuted)
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
                        Image(systemName: "lock.fill").axFont(.headline).foregroundStyle(AX.inkMuted)
                            .accessibilityLabel("Draft shape, locked")
                    }
                }
            }
        }
    }

    /// Ring + "Plays like" + name/caption. Unlocked and locked share one layout; it stacks at AX sizes.
    private func proLayout<Ring: View, Detail: View>(@ViewBuilder ring: () -> Ring,
                                                     @ViewBuilder detail: () -> Detail) -> some View {
        let side = min(ringSide, 132)
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                                                  : AnyLayout(HStackLayout(spacing: 16))
        return layout {
            ring().frame(width: side, height: side)
            VStack(alignment: .leading, spacing: 4) {
                Text("Plays like").axFont(.headline).foregroundStyle(AX.inkMuted)
                detail()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 88)
    }

    @ViewBuilder private func proCard(_ c: ProfileContent) -> some View {
        if let pro = c.proComp {
            Button { showingPro = true } label: {
                SACard {
                    proLayout {
                        ZStack {
                            SARing(progress: pro.similarity, color: accent)
                            Text(PlayerProfileViewModel.percent(pro.similarity))
                                .font(.system(.body, design: .rounded).weight(.bold)).monospacedDigit()
                                .lineLimit(1).minimumScaleFactor(0.5)
                                .padding(10)
                                .foregroundStyle(AX.ink)
                        }
                    } detail: {
                        Text(pro.proName).axFont(.title).foregroundStyle(AX.ink)
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 16) { traitLabels(c) }
                            VStack(alignment: .leading, spacing: 4) { traitLabels(c) }
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(PlayerProfileViewModel.proCompSpoken(name: pro.proName, similarity: pro.similarity))
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("profile.procomp")
        } else if c.unlock != .unlocked {
            SACard {
                proLayout {
                    ZStack {
                        SARing(progress: c.lockProgress, color: AX.inkMuted)
                        Image(systemName: "lock.fill").axFont(.subtitle, weight: .regular).foregroundStyle(AX.inkMuted)
                    }
                } detail: {
                    if let cap = c.lockedCaption {
                        Text(cap).axFont(.title).monospacedDigit().foregroundStyle(AX.ink)
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(c.lockedSpoken)
            .accessibilityIdentifier("profile.procomp.locked")
        }
    }

    @ViewBuilder private func traitLabels(_ c: ProfileContent) -> some View {
        ForEach(c.proTraits) { t in
            Label(t.word, systemImage: t.symbol).axFont(.body).foregroundStyle(AX.inkMuted).fixedSize()
        }
    }

    private func badgeShelf(_ c: ProfileContent) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                AXSectionHeader("Badges")
                if c.hasMoreBadges {
                    Button { showingAllBadges = true } label: {
                        Text("All").axFont(.headline).foregroundStyle(AX.ink)
                            .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                    }
                        .accessibilityLabel("All badges")
                        .accessibilityIdentifier("profile.badges.all")
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 56, maximum: 72), spacing: 12)], spacing: 12) {
                ForEach(c.visibleBadges) { b in
                    Button { badge = b } label: {
                        ZStack {
                            Circle().fill(AX.surface)
                            Circle().stroke(accent.opacity(0.5), lineWidth: 1.5)
                            Image(systemName: b.symbol).font(.system(size: 26, weight: .semibold))
                                .foregroundStyle(AX.ink)
                        }
                        .frame(width: 56, height: 56)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(PlayerProfileViewModel.badgeSpoken(b))
                }
            }
        }
    }

    private func totals(_ c: ProfileContent) -> some View {
        SAAdaptiveStack(spacing: 8) {
            ForEach(c.totals) { t in
                VStack(spacing: 4) {
                    Text(t.value).font(.system(.title, design: .rounded, weight: .bold)).monospacedDigit()
                        .foregroundStyle(AX.ink)
                    Text(t.caption).axFont(.label, weight: .semibold).foregroundStyle(AX.inkMuted)
                }
                .frame(maxWidth: .infinity, minHeight: 72)
                .accessibilityElement(children: .combine)
            }
        }
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
                .foregroundStyle(AX.inkMuted)
                .frame(minHeight: 280)
                .accessibilityIdentifier("profile.history.empty")
        } else {
            VStack(spacing: AX.space.s6) {
                ForEach(groups) { g in
                    VStack(spacing: 8) {
                        AXSectionHeader(g.title)
                        SACard(padding: 0) {
                            VStack(spacing: 0) {
                                ForEach(Array(g.sessions.enumerated()), id: \.element.id) { i, s in
                                    if i > 0 { Divider().overlay(AX.border).padding(.leading, 68) }
                                    sessionRow(s)
                                    if expanded.contains(s.id) {
                                        ForEach(s.games) { game in
                                            Divider().overlay(AX.border).padding(.leading, 68)
                                            gameRow(game)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func sessionRow(_ s: SessionSummary) -> some View {
        Button { toggle(s.id) } label: {
            HStack(spacing: 16) {
                SARuleBall(number: SettingsViewModel.ruleBall(s.ruleSet), size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(PlayerProfileViewModel.sessionTitle(s)).axFont(.body).foregroundStyle(AX.ink)
                    Text(PlayerProfileViewModel.sessionSubtitle(s))
                        .axFont(.label, weight: .semibold).foregroundStyle(AX.inkMuted)
                }
                Spacer(minLength: 8)
                ResultMark(result: s.result)
                Image(systemName: expanded.contains(s.id) ? "chevron.up" : "chevron.down")
                    .axFont(.label, weight: .semibold).foregroundStyle(AX.inkMuted)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 64)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityRemoveTraits(.isSelected)
        .accessibilityValue(expanded.contains(s.id) ? "Expanded" : "Collapsed")
        .accessibilityHint(expanded.contains(s.id) ? "Hides games" : "Shows games")
    }

    private func gameRow(_ g: GameSummary) -> some View {
        Button { open(g.id) } label: {
            HStack(spacing: 16) {
                Text("Game \(g.index + 1)").axFont(.body).monospacedDigit().foregroundStyle(AX.ink)
                Spacer()
                ResultMark(result: SessionResult(game: g.won))
                Image(systemName: "chevron.right").axFont(.label, weight: .semibold).foregroundStyle(AX.inkMuted)
            }
            .padding(.leading, 68).padding(.trailing, 16)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityRemoveTraits(.isSelected)
    }
}

/// Win = filled green check, loss = outlined red ×, tie = outlined grey =. Shape + color, never color alone.
private struct ResultMark: View {
    let result: SessionResult?
    var body: some View {
        switch result {
        case .won?:
            Image(systemName: "checkmark.circle.fill").axFont(.title, weight: .regular).foregroundStyle(AX.legal)
                .accessibilityLabel(SessionResult.won.spoken)
        case .lost?:
            Image(systemName: "xmark.circle").axFont(.title, weight: .regular).foregroundStyle(AX.danger)
                .accessibilityLabel(SessionResult.lost.spoken)
        case .tied?:
            Image(systemName: "equal.circle").axFont(.title, weight: .regular).foregroundStyle(AX.inkMuted)
                .accessibilityLabel(SessionResult.tied.spoken)
        case nil:
            Image(systemName: "circle.dotted").axFont(.title, weight: .regular).foregroundStyle(AX.inkMuted)
                .accessibilityLabel("Unfinished")
        }
    }
}

// MARK: - Sheets

private struct BadgeDetail: View {
    let badge: BadgeGroup
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: badge.symbol).font(.system(size: 72, weight: .semibold)).foregroundStyle(AX.ink)
            Text(badge.name).axFont(.title).foregroundStyle(AX.ink)
            if let count = badge.countCaption {
                Text(count).axFont(.headline).foregroundStyle(AX.ink)
            }
            Text(badge.latest, format: .dateTime.day().month(.wide).year())
                .axFont(.body).foregroundStyle(AX.inkMuted)
        }
        .padding(AX.space.s4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AX.page)
        .presentationDragIndicator(.visible)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("profile.badge.detail")
    }
}

private struct AllBadges: View {
    let groups: [BadgeGroup]
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 16)], spacing: 24) {
                    ForEach(groups) { g in
                        VStack(spacing: 8) {
                            Image(systemName: g.symbol).font(.system(size: 26, weight: .semibold))
                                .foregroundStyle(AX.ink)
                                .frame(width: 56, height: 56).background(Circle().fill(AX.surface))
                            Text(g.name).axFont(.headline).foregroundStyle(AX.ink)
                                .multilineTextAlignment(.center)
                            Text(g.countCaption ?? PlayerProfileViewModel.dayMonth(g.latest))
                                .axFont(.label, weight: .semibold).foregroundStyle(AX.inkMuted)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(PlayerProfileViewModel.badgeSpoken(g))
                    }
                }
                .padding(AX.space.s4)
            }
            .background(AX.page)
            .navigationTitle("Badges")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AX.page, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("profile.badges.done")
                }
            }
        }
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("profile.badges.sheet")
    }
}

/// Player's shape (accent, filled) over the pro's shape (dashed outline): max 2 datasets.
private struct ProCompDetail: View {
    let pro: ProCompView
    let playerName: String
    let axes: [RadarAxis]
    let proAxes: [RadarAxis]?
    let accent: Color
    var body: some View {
        VStack(spacing: 24) {
            Text(pro.proName).axFont(.title).foregroundStyle(AX.ink).padding(.top, 24)
            ArchetypeRadar(axes: axes, overlay: proAxes, accent: accent)
                .frame(height: 320)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Archetype shape compared with \(pro.proName)")
                .accessibilityValue(descriptor.summary)
                .accessibilityChartDescriptor(descriptor)
                .accessibilityIdentifier("profile.procomp.radar")
            Text(PlayerProfileViewModel.band(pro.similarity).capitalized + " match")
                .axFont(.headline).foregroundStyle(AX.inkMuted)
            Spacer()
        }
        .padding(.horizontal, AX.space.s4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AX.page)
        // `.contain` keeps the radar's own identifier: without it the container's id overwrites every child's.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("profile.procomp.detail")
    }

    private var descriptor: SARadarDescriptor {
        SARadarDescriptor(axes: axes, name: playerName, overlay: proAxes, overlayName: pro.proName)
    }
}

private struct EditProfileSheet: View {
    @State var name: String
    @State var symbol: String
    let save: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    private let symbols = ["person.fill", "star.fill", "flame.fill", "bolt.fill", "moon.fill", "leaf.fill"]

    var body: some View {
        NavigationStack {
            VStack(spacing: AX.space.s6) {
                TextField("Name", text: $name)
                    .axFont(.title, weight: .regular).padding(16).frame(minHeight: 56)
                    .background(AX.surface, in: RoundedRectangle(cornerRadius: AX.radius.element))
                    .accessibilityIdentifier("profile.edit.name")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6)) {
                    ForEach(symbols, id: \.self) { s in
                        Button { symbol = s } label: {
                            Image(systemName: s).axFont(.title, weight: .regular).frame(width: 52, height: 52)
                                .background(Circle().fill(symbol == s ? AX.surface : .clear))
                                .overlay(Circle().stroke(symbol == s ? AX.ink : .clear, lineWidth: 2))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(symbol == s ? .isSelected : [])
                    }
                }
                Spacer()
            }
            .padding(AX.space.s4)
            .background(AX.page)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save(name, symbol); dismiss() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

// MARK: - Accessibility chart

/// One series (the player), or two when a comparison overlay is given (player + pro). Values speak as bands.
struct SARadarDescriptor: AXChartDescriptorRepresentable {
    let axes: [RadarAxis]
    var name = "Archetype"
    var overlay: [RadarAxis]?
    var overlayName = ""

    var summary: String {
        guard let overlay else { return PlayerProfileViewModel.radarSummary(axes) }
        return "\(name): \(PlayerProfileViewModel.radarSummary(axes)). "
            + "\(overlayName): \(PlayerProfileViewModel.radarSummary(overlay))"
    }

    func makeChartDescriptor() -> AXChartDescriptor {
        let x = AXCategoricalDataAxisDescriptor(title: "Trait", categoryOrder: axes.map(\.name))
        let y = AXNumericDataAxisDescriptor(title: "Strength", range: 0...1, gridlinePositions: [1 / 3, 2 / 3, 1]) {
            PlayerProfileViewModel.level($0)
        }
        func series(_ name: String, _ a: [RadarAxis]) -> AXDataSeriesDescriptor {
            AXDataSeriesDescriptor(name: name, isContinuous: false, dataPoints: a.map { .init(x: $0.name, y: $0.value) })
        }
        var all = [series(name, axes)]
        if let overlay { all.append(series(overlayName, overlay)) }
        return AXChartDescriptor(title: "Archetype shape", summary: summary,
                                 xAxis: x, yAxis: y, additionalAxes: [], series: all)
    }
}

#Preview("Veteran") {
    let f = SamplePlayerData.veteran
    return NavigationStack {
        PlayerProfileView(model: PlayerProfileViewModel(playerID: f.playerID, stats: f.stats, training: f.training))
    }
}

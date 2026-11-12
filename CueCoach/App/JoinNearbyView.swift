import SwiftUI
import Rules

/// Join nearby: games hosted on nearby phones (MultipeerConnectivity), live. This phone becomes a camera angle.
struct JoinNearbyView: View {
    @State var model: JoinNearbyModel
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Environment(\.shellForceReduceMotion) private var forced
    @Environment(\.shellNoLoops) private var noLoops
    private var reduceMotion: Bool { reduce || forced }
    private var loops: Bool { !reduceMotion && !noLoops }
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        ZStack {
            ShellBackground()
            ScrollView {
                VStack(spacing: 16) { content }
                    .padding(16)
                    // No crossfade between states: a terminal state (full, host left) replaces the old one outright.
                    .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: model.games)
            }
        }
        .navigationTitle("Join nearby")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { model.appear() }
        .onDisappear { model.disappear() }
        .overlay(alignment: .bottomTrailing) {
            Color.clear.frame(width: 1, height: 1)
                .accessibilityElement()
                .accessibilityIdentifier("join.state")
                .accessibilityValue(stateName)
        }
    }

    private var stateName: String {
        switch model.state {
        case .searching: model.games.isEmpty ? "searching" : "list"
        case .joining: "joining"
        case .joined: "joined"
        case .full: "full"
        case .hostLeft: "hostLeft"
        case .unavailable: "unavailable"
        }
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .searching:
            if model.games.isEmpty {
                StatusGlyph(symbol: "dot.radiowaves.left.and.right", tint: AX.teamA, title: "Looking",
                            animate: loops, id: "join.searching")
            } else {
                ForEach(model.games) { g in
                    GameRow(game: g) { model.join(g) }
                }
            }
        case .joining(let g):
            GameRow(game: g, trailing: AnyView(ProgressView().tint(AX.ink))) {}
                .disabled(true)
            cancelButton
        case .joined(let g):
            // AX sizes: compact "Waiting" + Leave first so both sit in the first viewport; the lineup (which
            // carries the host's rules and table) follows. The big game row is skipped there.
            if typeSize.isAccessibilitySize {
                StatusGlyph(symbol: "video.fill", tint: AX.legal, title: "Waiting", animate: loops, id: "join.waiting",
                            compact: true)
                cancelButton
                if let l = model.lineup { LineupStrip(lineup: l) }
            } else {
                GameRow(game: g, trailing: AnyView(Image(systemName: "checkmark.circle.fill").foregroundStyle(AX.legal))) {}
                    .disabled(true)
                if let l = model.lineup { LineupStrip(lineup: l) }
                StatusGlyph(symbol: "video.fill", tint: AX.legal, title: "Waiting", animate: loops, id: "join.waiting")
                cancelButton
            }
        case .full:
            StatusGlyph(symbol: "lock.fill", tint: AX.caution, title: "Game full", animate: false, id: "join.full")
            backButton
        case .hostLeft:
            StatusGlyph(symbol: "wifi.slash", tint: AX.danger, title: "Host left", animate: false, id: "join.hostLeft")
            backButton
        case .unavailable:
            StatusGlyph(symbol: "lock.shield", tint: AX.caution, title: "No access", animate: false, id: "join.unavailable")
            // Astryx Button: the tappable (and accessibility) area is at least 44 × 44 pt.
            AXButton(title: "Settings", variant: .primary, id: "join.openSettings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
        }
    }

    private var cancelButton: some View {
        AXButton(title: "Leave", variant: .ghost, id: "join.leave") { model.backToList() }
    }

    private var backButton: some View {
        AXButton(title: "Back", variant: .secondary, id: "join.back") { model.backToList() }
    }
}

/// Big glyph + ≤2 words for each lobby state.
private struct StatusGlyph: View {
    let symbol: String
    let tint: Color
    let title: String
    let animate: Bool
    let id: String
    var compact = false
    var body: some View {
        VStack(spacing: compact ? 8 : 16) {
            Image(systemName: symbol)
                .font(.system(size: compact ? 32 : 56, weight: .semibold))
                .foregroundStyle(tint)
                .symbolEffect(.variableColor.iterative, isActive: animate)
                .frame(width: compact ? 72 : 120, height: compact ? 72 : 120)
                .background(Circle().fill(AX.surface))
            Text(title).axFont(.title).foregroundStyle(AX.ink)
                .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, compact ? 8 : 32)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(id)
    }
}

/// One hosted game: host avatar, rule ball, seat dots.
private struct GameRow: View {
    let game: NearbyGame
    var trailing: AnyView = AnyView(Image(systemName: "chevron.right").foregroundStyle(AX.inkMuted))
    let action: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Button(action: action) {
            let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                                                       : AnyLayout(HStackLayout(spacing: 16))
            layout {
                SBAvatar(symbol: game.host?.symbol ?? "person.fill", colorName: game.host?.colorName ?? "blue", size: 52, team: 0)
                VStack(alignment: .leading, spacing: 6) {
                    Text(game.host?.name ?? "Nearby").axFont(.subtitle).foregroundStyle(AX.ink)
                    HStack(spacing: 4) {
                        ForEach(0..<max(game.seatsTotal, 0), id: \.self) { i in
                            Circle().fill(i < game.seatsFilled ? AX.ink : AX.ink.opacity(0.2)).frame(width: 8, height: 8)
                        }
                    }
                    .accessibilityHidden(true)
                }
                Spacer(minLength: 0)
                // Ball + short rule name: Bar 8 and WPA 8 must not look identical.
                VStack(spacing: 4) {
                    SARuleBall(number: SettingsViewModel.ruleBall(game.ruleSet), size: 36)
                    Text(SettingsViewModel.ruleShortLabel(game.ruleSet))
                        .axFont(.label, weight: .semibold).foregroundStyle(AX.inkMuted)
                        .lineLimit(1)
                }
                trailing.axFont(.subtitle)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 88)
            .background(RoundedRectangle(cornerRadius: AX.radius.container).fill(AX.surface))
            .contentShape(RoundedRectangle(cornerRadius: AX.radius.container))
        }
        .buttonStyle(ShellPressStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(game.host?.name ?? "Nearby") game, \(SettingsViewModel.ruleLabel(game.ruleSet)), \(game.seatsFilled) of \(game.seatsTotal) players")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("join.game.\(game.id)")
    }
}

/// The host's lineup in D17 order, mirrored live while this phone waits.
private struct LineupStrip: View {
    let lineup: LobbyLineup
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        let n = lineup.seats.map(\.count).max() ?? 0
        let order = (0..<n).flatMap { slot in (0..<lineup.seats.count).map { SeatRef(team: $0, slot: slot) } }
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                SARuleBall(number: SettingsViewModel.ruleBall(lineup.ruleSet), size: 32)
                SATableSilhouette(size: lineup.tableSize).frame(width: 56, height: 28)
                Text(SettingsViewModel.tableShortLabel(lineup.tableSize)).axFont(.headline).foregroundStyle(AX.inkMuted)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(SettingsViewModel.ruleLabel(lineup.ruleSet)), \(SettingsViewModel.tableSpokenLabel(lineup.tableSize)) table")
            .accessibilityIdentifier("join.lineup.rules.\(lineup.ruleSet.rawValue)")
            FlowRow(spacing: 8) {
                ForEach(order, id: \.self) { seat in
                    let p = lineup.seats[seat.team].indices.contains(seat.slot) ? lineup.seats[seat.team][seat.slot] : nil
                    VStack(spacing: 6) {
                        if let p {
                            SBAvatar(symbol: p.symbol, colorName: p.colorName, size: 48, team: seat.team)
                        } else {
                            Circle().strokeBorder(AX.team(seat.team), style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
                                .frame(width: 48, height: 48)
                        }
                        Text(p?.name ?? "\(GameSetupModel.teamLetter(seat.team))\(seat.slot + 1)")
                            .axFont(.label, weight: .semibold).foregroundStyle(p == nil ? AX.inkMuted : AX.ink)
                            .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: typeSize.isAccessibilitySize ? 220 : 80)
                    }
                    .frame(minWidth: 56)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel((p?.name ?? "Empty seat") + ", team \(GameSetupModel.teamLetter(seat.team))")
                    .accessibilityIdentifier("join.lineup.\(p?.name ?? "empty")")
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: AX.radius.container).fill(AX.surface))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("join.lineup")
    }
}

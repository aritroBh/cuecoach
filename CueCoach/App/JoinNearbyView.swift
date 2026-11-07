import SwiftUI
import Rules

/// Join nearby: games hosted on nearby phones (MultipeerConnectivity), live. This phone becomes a camera angle.
struct JoinNearbyView: View {
    @State var model: JoinNearbyModel
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Environment(\.shellForceReduceMotion) private var forced
    private var reduceMotion: Bool { reduce || forced }

    var body: some View {
        ZStack {
            ShellBackground()
            ScrollView {
                VStack(spacing: 16) { content }
                    .padding(16)
                    .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: model.state)
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
                StatusGlyph(symbol: "dot.radiowaves.left.and.right", tint: SBColor.teamA, title: "Looking",
                            animate: !reduceMotion, id: "join.searching")
            } else {
                ForEach(model.games) { g in
                    GameRow(game: g) { model.join(g) }
                }
            }
        case .joining(let g):
            GameRow(game: g, trailing: AnyView(ProgressView().tint(SBColor.ink))) {}
                .disabled(true)
            cancelButton
        case .joined(let g):
            GameRow(game: g, trailing: AnyView(Image(systemName: "checkmark.circle.fill").foregroundStyle(SBColor.legal))) {}
                .disabled(true)
            StatusGlyph(symbol: "video.fill", tint: SBColor.legal, title: "Waiting", animate: !reduceMotion, id: "join.waiting")
            cancelButton
        case .full:
            StatusGlyph(symbol: "lock.fill", tint: SBColor.caution, title: "Game full", animate: false, id: "join.full")
            backButton
        case .hostLeft:
            StatusGlyph(symbol: "wifi.slash", tint: SBColor.danger, title: "Host left", animate: false, id: "join.hostLeft")
            backButton
        case .unavailable:
            StatusGlyph(symbol: "lock.shield", tint: SBColor.caution, title: "No access", animate: false, id: "join.unavailable")
            Button("Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            .font(.body.weight(.semibold)).frame(minHeight: 44)
            .accessibilityIdentifier("join.openSettings")
        }
    }

    private var cancelButton: some View {
        Button("Leave") { model.backToList() }
            .font(.body.weight(.semibold)).foregroundStyle(SBColor.inkMuted).frame(minWidth: 88, minHeight: 44)
            .accessibilityIdentifier("join.leave")
    }

    private var backButton: some View {
        Button { model.backToList() } label: {
            Label("Back", systemImage: "arrow.uturn.backward").font(.body.weight(.semibold)).frame(minWidth: 88, minHeight: 44)
        }
        .accessibilityIdentifier("join.back")
    }
}

/// Big glyph + ≤2 words for each lobby state.
private struct StatusGlyph: View {
    let symbol: String
    let tint: Color
    let title: String
    let animate: Bool
    let id: String
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 56, weight: .semibold))
                .foregroundStyle(tint)
                .symbolEffect(.variableColor.iterative, isActive: animate)
                .frame(width: 120, height: 120)
                .background(Circle().fill(SBColor.surface))
            Text(title).font(.title2.weight(.semibold)).foregroundStyle(SBColor.ink)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(id)
    }
}

/// One hosted game: host avatar, rule ball, seat dots.
private struct GameRow: View {
    let game: NearbyGame
    var trailing: AnyView = AnyView(Image(systemName: "chevron.right").foregroundStyle(SBColor.inkMuted))
    let action: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Button(action: action) {
            let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                                                       : AnyLayout(HStackLayout(spacing: 16))
            layout {
                SBAvatar(symbol: game.host?.symbol ?? "person.fill", colorName: game.host?.colorName ?? "blue", size: 52, team: 0)
                VStack(alignment: .leading, spacing: 6) {
                    Text(game.host?.name ?? "Nearby").font(.title3.weight(.semibold)).foregroundStyle(SBColor.ink)
                    HStack(spacing: 4) {
                        ForEach(0..<max(game.seatsTotal, 0), id: \.self) { i in
                            Circle().fill(i < game.seatsFilled ? SBColor.ink : SBColor.ink.opacity(0.2)).frame(width: 8, height: 8)
                        }
                    }
                    .accessibilityHidden(true)
                }
                Spacer(minLength: 0)
                SARuleBall(number: SettingsViewModel.ruleBall(game.ruleSet), size: 36)
                trailing.font(.title3.weight(.semibold))
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 88)
            .background(RoundedRectangle(cornerRadius: 20).fill(SBColor.surface))
            .contentShape(RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(ShellPressStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(game.host?.name ?? "Nearby") game, \(SettingsViewModel.ruleLabel(game.ruleSet)), \(game.seatsFilled) of \(game.seatsTotal) players")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("join.game.\(game.id)")
    }
}

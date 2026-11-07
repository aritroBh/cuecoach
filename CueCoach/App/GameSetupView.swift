import SwiftUI
import Geometry
import Rules

/// New game (host): rules, singles/teams in D17 order, table size, joined phones, Start.
struct GameSetupView: View {
    @State var model: GameSetupModel
    @State private var seatSheet: SeatRef?
    @State private var shake = 0
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Environment(\.shellForceReduceMotion) private var forced
    @Environment(\.dynamicTypeSize) private var typeSize

    private var columns: [GridItem] {
        typeSize.isAccessibilitySize ? [GridItem(.flexible())] : Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)
    }

    var body: some View {
        ZStack {
            ShellBackground()
            ScrollView {
                VStack(spacing: 28) {
                    rules
                    players
                    table
                    phones
                }
                .padding(16)
            }
        }
        .safeAreaInset(edge: .bottom) {
            ShellStartButton(enabled: model.isValid, id: "setup.start") {
                if model.start() == nil { shake += 1 }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .background(SBColor.bg.opacity(0.9))
        }
        .sensoryFeedback(.error, trigger: model.blockedStartCount)
        .navigationTitle("New game")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { model.beginHosting() }
        .onDisappear { model.endHosting() }
        .sheet(item: $seatSheet) { seat in
            SeatPickerSheet(model: model, seat: seat).presentationDetents([.medium, .large])
        }
    }

    // MARK: Rules

    private var rules: some View {
        ShellSection(title: "Rules") {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(RuleSetID.allCases, id: \.self) { r in
                    ChoiceTile(selected: model.ruleSet == r, id: "setup.rule.\(r.rawValue)",
                               label: SettingsViewModel.ruleLabel(r)) {
                        model.ruleSet = r
                    } content: {
                        SARuleBall(number: SettingsViewModel.ruleBall(r))
                        Text(SettingsViewModel.ruleShortLabel(r)).font(.body.weight(.semibold))
                    }
                }
            }
        }
    }

    // MARK: Players

    private var players: some View {
        ShellSection(title: "Players") {
            HStack(spacing: 12) {
                ChoiceTile(selected: !model.isTeams, id: "setup.format.singles", label: "Singles") {
                    model.setPlayersPerTeam(1)
                } content: {
                    formatGlyph(1)
                    Text("Singles").font(.body.weight(.semibold))
                }
                ChoiceTile(selected: model.isTeams, id: "setup.format.teams", label: "Teams") {
                    if !model.isTeams { model.setPlayersPerTeam(2) }
                } content: {
                    formatGlyph(2)
                    Text("Teams").font(.body.weight(.semibold))
                }
            }
            if model.isTeams {
                HStack(spacing: 12) {
                    ForEach(2...GameSetupModel.maxPerTeam, id: \.self) { n in
                        Button { model.setPlayersPerTeam(n) } label: {
                            Text("\(n)v\(n)")
                                .font(.body.weight(.semibold)).monospacedDigit()
                                .foregroundStyle(model.playersPerTeam == n ? Color.black : SBColor.ink)
                                .frame(minWidth: 64, minHeight: 48)
                                .background(Capsule().fill(model.playersPerTeam == n ? SBColor.ink : SBColor.surface))
                        }
                        .buttonStyle(ShellPressStyle())
                        .accessibilityAddTraits(model.playersPerTeam == n ? .isSelected : [])
                        .accessibilityIdentifier("setup.size.\(n)")
                    }
                }
            }
            SeatOrderRow(model: model, shake: shake, reduceMotion: reduce || forced) { seatSheet = $0 }
        }
    }

    private func formatGlyph(_ n: Int) -> some View {
        HStack(spacing: 6) {
            HStack(spacing: -6) { ForEach(0..<n, id: \.self) { _ in Circle().fill(SBColor.teamA).frame(width: 18, height: 18) } }
            Text("vs").font(.caption.weight(.semibold)).foregroundStyle(SBColor.inkMuted)
            HStack(spacing: -6) { ForEach(0..<n, id: \.self) { _ in Circle().fill(SBColor.teamB).frame(width: 18, height: 18) } }
        }
        .frame(height: 40)
        .accessibilityHidden(true)
    }

    // MARK: Table

    private var table: some View {
        ShellSection(title: "Table") {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(TableSize.allCases, id: \.self) { s in
                    let measured = model.measuredTable == s
                    ChoiceTile(selected: model.tableSize == s, id: "setup.table.\(s.rawValue)",
                               label: "\(SettingsViewModel.feet(s)) foot" + (measured ? ", measured" : "")) {
                        model.tableSize = s
                    } content: {
                        SATableSilhouette(size: s).frame(height: 40)
                        HStack(spacing: 4) {
                            if measured { Image(systemName: "ruler.fill").font(.caption.weight(.semibold)).foregroundStyle(SBColor.legal) }
                            Text("\(SettingsViewModel.feet(s)) ft").font(.body.weight(.semibold)).monospacedDigit()
                        }
                    }
                }
            }
        }
    }

    // MARK: Phones

    private var phones: some View {
        ShellSection(title: "Cameras") {
            HStack(spacing: 12) {
                PhoneDisc(active: true).accessibilityLabel("This phone")
                ForEach(model.joinedPhones) { p in
                    PhoneDisc(active: true)
                        .transition(.scale.combined(with: .opacity))
                        .accessibilityLabel(p.name ?? "Nearby phone")
                        .accessibilityIdentifier("setup.phone.\(p.id)")
                }
                Spacer()
            }
            .animation(reduce || forced ? nil : .smooth(duration: 0.35), value: model.joinedPhones)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("setup.phones")
            .accessibilityValue("\(model.joinedPhones.count + 1)")
        }
    }
}

private struct PhoneDisc: View {
    var active: Bool
    var body: some View {
        Image(systemName: "iphone.gen3")
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(SBColor.ink)
            .frame(width: 52, height: 52)
            .background(Circle().fill(SBColor.surface))
            .overlay(Circle().stroke(active ? SBColor.legal : .clear, lineWidth: 2))
    }
}

/// Selectable tile with an outline + check when selected (shape, not only colour).
struct ChoiceTile<Content: View>: View {
    let selected: Bool
    let id: String
    let label: String
    let action: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) { content() }
                .foregroundStyle(selected ? SBColor.ink : SBColor.inkMuted)
                .padding(8)
                .frame(maxWidth: .infinity, minHeight: 96)
                .background(RoundedRectangle(cornerRadius: 14).fill(SBColor.surface.opacity(selected ? 1 : 0.5)))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(selected ? SBColor.ink : .clear, lineWidth: 2))
                .overlay(alignment: .topTrailing) {
                    if selected {
                        Image(systemName: "checkmark.circle.fill").font(.body).foregroundStyle(SBColor.ink).padding(6)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(ShellPressStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier(id)
    }
}

/// Seats in D17 shooting order (A1 → B1 → A2 → B2 …). Empty seats are dashed circles with +.
struct SeatOrderRow: View {
    let model: GameSetupModel
    let shake: Int
    let reduceMotion: Bool
    let pick: (SeatRef) -> Void
    @State private var pulse = false

    var body: some View {
        let order = model.seatOrder
        FlowRow(spacing: 8) {
            ForEach(Array(order.enumerated()), id: \.offset) { i, seat in
                HStack(spacing: 8) {
                    if i > 0 {
                        Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(SBColor.inkMuted)
                            .accessibilityHidden(true)
                    }
                    seatButton(seat, number: i + 1)
                }
            }
        }
        .onChange(of: shake) {
            guard !reduceMotion else { return }
            withAnimation(.spring(response: 0.15, dampingFraction: 0.3)) { pulse = true }
            withAnimation(.spring(response: 0.3).delay(0.2)) { pulse = false }
        }
    }

    private func seatButton(_ seat: SeatRef, number: Int) -> some View {
        let p = model[seat]
        let blocking = model.firstEmptySeat == seat
        return Button { pick(seat) } label: {
            VStack(spacing: 6) {
                ZStack {
                    if let p {
                        SBAvatar(symbol: p.symbol, colorName: p.colorName, size: 52, team: seat.team)
                    } else {
                        Circle()
                            .strokeBorder(SBColor.team(seat.team), style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
                            .frame(width: 52, height: 52)
                        Image(systemName: "plus").font(.title3.weight(.semibold)).foregroundStyle(SBColor.team(seat.team))
                    }
                }
                .frame(width: 64, height: 64)
                .scaleEffect(blocking && pulse ? 1.18 : 1)
                Text(p?.name ?? "\(GameSetupModel.teamLetter(seat.team))\(seat.slot + 1)")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(p == nil ? SBColor.inkMuted : SBColor.ink)
                    .lineLimit(1)
                    .frame(maxWidth: 88)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(ShellPressStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel((p.map { "\($0.name)" } ?? "Empty seat") +
                            ", team \(GameSetupModel.teamLetter(seat.team)), shoots \(ordinal(number))")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("setup.seat.\(seat.team).\(seat.slot)")
    }

    private func ordinal(_ n: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .ordinal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}

extension GameSetupModel {
    nonisolated static func teamLetter(_ t: Int) -> String { t == 0 ? "A" : "B" }
}

/// Simple wrapping row (seats wrap at large text sizes and in 4v4).
struct FlowRow: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, w: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0 && x + sz.width > maxW { y += rowH + spacing; x = 0; rowH = 0 }
            x += sz.width + spacing; rowH = max(rowH, sz.height); w = max(w, x - spacing)
        }
        return CGSize(width: proposal.width ?? w, height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + sz.width > bounds.maxX { y += rowH + spacing; x = bounds.minX; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing; rowH = max(rowH, sz.height)
        }
    }
}

extension SeatRef: Identifiable { var id: String { "\(team).\(slot)" } }

/// Who sits here: roster players, a session guest (never saved), or a new roster player.
struct SeatPickerSheet: View {
    let model: GameSetupModel
    let seat: SeatRef
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(model.pickablePlayers(for: seat)) { p in
                        row(symbol: p.symbol, color: p.colorName, title: p.name, id: "seat.player.\(p.name)") {
                            model.assign(p, to: seat); dismiss()
                        }
                    }
                    row(symbol: "person.fill", color: "#334155", title: "Guest", id: "seat.guest") {
                        model.addGuest(to: seat); dismiss()
                    }
                }
                Section {
                    HStack(spacing: 12) {
                        TextField("Name", text: $newName)
                            .textInputAutocapitalization(.words)
                            .submitLabel(.done)
                            .focused($nameFocused)
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("seat.newName")
                            .onSubmit(addNew)
                        Button("Add", action: addNew)
                            .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                            .frame(minWidth: 44, minHeight: 44)
                            .accessibilityIdentifier("seat.add")
                    }
                } header: { Text("New player") }
                if model[seat] != nil {
                    Section {
                        Button(role: .destructive) { model.clear(seat); dismiss() } label: {
                            Label("Empty seat", systemImage: "xmark.circle").frame(minHeight: 44)
                        }
                        .accessibilityIdentifier("seat.clear")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(SBColor.bg)
            .navigationTitle("\(GameSetupModel.teamLetter(seat.team))\(seat.slot + 1)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
    }

    private func addNew() {
        guard (try? model.registerNew(name: newName, to: seat)) != nil else { return }
        dismiss()
    }

    private func row(symbol: String, color: String, title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                SBAvatar(symbol: symbol, colorName: color, size: 40)
                Text(title).font(.body.weight(.semibold)).foregroundStyle(SBColor.ink)
                Spacer()
            }
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier(id)
    }
}

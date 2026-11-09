import SwiftUI
import Geometry
import Rules

/// Session lobby (pages/screens-b.md §1).
public struct LobbyView: View {
    let model: LobbyModel
    @State private var sheet: LobbySheet?
    @State private var pulseSeat: SeatRef?
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.sbForceReduceMotion) private var forcedReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || forcedReduceMotion }
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.verticalSizeClass) private var vSize

    public init(model: LobbyModel) { self.model = model }

    /// Debug/preview: open with a sheet already presented.
    init(model: LobbyModel, initialSheet: LobbySheet?) {
        self.model = model
        _sheet = State(initialValue: initialSheet)
    }

    public var body: some View {
        ZStack {
            AX.page.ignoresSafeArea()
            if vSize == .compact {
                HStack(alignment: .top, spacing: 24) {
                    ScrollView { VStack(alignment: .leading, spacing: 24) { header; peersRow; teamsBlock } }
                    VStack(alignment: .leading, spacing: 24) {
                        ScrollView { VStack(alignment: .leading, spacing: 24) { rulesBlock; tableBlock } }
                        startBar
                    }
                }
                .padding(.horizontal, 24)
            } else {
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 32) {
                            header; peersRow; teamsBlock; rulesBlock; tableBlock
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 40)
                    }
                    // ui-QA-5: content fades into the bar instead of being sliced at its edge.
                    .overlay(alignment: .bottom) {
                        LinearGradient(colors: [AX.page.opacity(0), AX.page], startPoint: .top, endPoint: .bottom)
                            .frame(height: 32).allowsHitTesting(false)
                    }
                    startBar.padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 8)
                }
            }
        }
        .sheet(item: $sheet) { s in
            Group {
                switch s {
                case .join: JoinHostSheet(model: model) { sheet = nil }.presentationDetents([.height(sheetHeight(model.nearbyHosts.isEmpty && model.meshAvailability != .discovering ? 190 : 290))])
                case .identity(let seat):
                    IdentitySheet(model: model, seat: seat) { sheet = nil }
                        .presentationDetents([.height(sheetHeight(model.canCreatePlayers ? 320 : 200)), .large])
                case .meshDenied: MeshDeniedSheet { sheet = nil }.presentationDetents([.height(sheetHeight(280))])
                }
            }
            .presentationCornerRadius(AX.radius.page)
            .presentationBackground(AX.raised)
        }
        .sensoryFeedback(.error, trigger: model.blockedStartCount)
        .sensoryFeedback(.success, trigger: model.startCount)
    }

    /// Content-sized sheet heights, grown for large Dynamic Type so nothing clips.
    private func sheetHeight(_ base: CGFloat) -> CGFloat {
        typeSize.isAccessibilitySize ? base * 1.7 : (typeSize >= .xxLarge ? base * 1.2 : base)
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Text("Lobby").axFont(.display).foregroundStyle(AX.ink)
                .accessibilityAddTraits(.isHeader)
            Spacer()
        }
        .padding(.top, 8)
    }

    // MARK: Peers

    private var peersRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 16) {
                ForEach(model.peers) { peer in
                    PeerAvatar(peer: peer, reduceMotion: reduceMotion) {
                        if peer.isLocal, let seat = model.seatOrder.first(where: { model[$0]?.id == model.localPlayer.id }) {
                            sheet = .identity(seat)
                        }
                    }
                }
                joinButton
            }
            .padding(.vertical, 8)
        }
        .scrollClipDisabled()
    }

    private var joinButton: some View {
        Button {
            sheet = model.meshAvailability == .unavailable ? .meshDenied : .join
        } label: {
            VStack(spacing: 8) {
                ZStack {
                    Circle().strokeBorder(AX.inkMuted, lineWidth: 2)
                    Image(systemName: model.meshAvailability == .unavailable ? "exclamationmark.triangle" : "plus")
                        .font(AXGlyph.font(22, .semibold))
                        .foregroundStyle(model.meshAvailability == .unavailable ? AX.caution : AX.ink)
                }
                .frame(width: 56, height: 56)
                .modifier(PulseEvery2s(active: model.meshAvailability == .discovering && !reduceMotion))
                Text("Join").axFont(.label, weight: .semibold).foregroundStyle(AX.inkMuted)
                    .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(model.meshAvailability == .unavailable ? "Nearby phones unavailable" : "Join or host")
        .accessibilityIdentifier("lobby.join")
    }

    // MARK: Teams

    private var teamsBlock: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Teams").axFont(.title).foregroundStyle(AX.ink)
                Spacer()
            }
            Picker("Format", selection: Binding(get: { model.format }, set: { model.setFormat($0) })) {
                ForEach(GameFormat.allCases, id: \.self) { f in
                    Text("\(f.playersPerTeam)v\(f.playersPerTeam)").tag(f)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.large)
            .frame(minHeight: 44)
            .disabled(model.isFormatLocked)
            .accessibilityIdentifier("lobby.format")

            let columns = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
                : AnyLayout(HStackLayout(alignment: .top, spacing: 16))
            columns {
                ForEach(0..<2, id: \.self) { team in teamColumn(team) }
            }

            if !model.bench.isEmpty { benchRow }
            orderStrip
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: AX.radius.container).fill(AX.surface))
    }

    private func teamColumn(_ team: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().strokeBorder(AX.team(team), style: StrokeStyle(lineWidth: 3, dash: team == 0 ? [] : [4, 3]))
                    .frame(width: 20, height: 20)
                Text(LobbyModel.teamName(team)).axFont(.headline)
                    .foregroundStyle(AX.team(team))
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Team \(LobbyModel.teamName(team))")
            ForEach(0..<model.teams[team].count, id: \.self) { slot in
                SeatRow(model: model, seat: SeatRef(team: team, slot: slot),
                        pulse: (pulseSeat ?? (model.isHost && !model.canStart ? model.blockingSeat : nil)) == SeatRef(team: team, slot: slot),
                        reduceMotion: reduceMotion) {
                    sheet = .identity(SeatRef(team: team, slot: slot))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var benchRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "chair.lounge").axFont(.headline).foregroundStyle(AX.inkMuted)
                .accessibilityLabel("Bench")
            ForEach(model.bench) { p in
                SBAvatar(symbol: p.symbol, colorName: p.colorName, size: 36, dimmed: true)
                    .accessibilityLabel("\(p.name), on bench")
            }
        }
        .frame(minHeight: 44)
    }

    private var orderStrip: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.triangle.turn.up.right.circle").font(AXGlyph.font(17, .semibold))
                .foregroundStyle(AX.inkMuted)
                .padding(.trailing, 4)
            ForEach(Array(model.seatOrder.enumerated()), id: \.offset) { i, seat in
                if i > 0 {
                    Image(systemName: "chevron.right").font(AXGlyph.font(13, .semibold)).foregroundStyle(AX.inkMuted)
                }
                if let p = model[seat] {
                    SBAvatar(symbol: p.symbol, colorName: p.colorName, size: 28)
                        .overlay(Circle().strokeBorder(AX.team(seat.team), style: StrokeStyle(lineWidth: 2, dash: seat.team == 0 ? [] : [3, 2])).padding(-3))
                } else {
                    Circle().strokeBorder(AX.inkMuted, style: StrokeStyle(lineWidth: 1.5, dash: [3, 3])).frame(width: 28, height: 28)
                }
            }
        }
        .padding(.top, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Shooting order: " + model.shootingOrder.map { $0?.name ?? "empty" }.joined(separator: ", "))
        .accessibilityIdentifier("lobby.order")
    }

    // MARK: Rules

    private var rulesBlock: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rules").axFont(.title).foregroundStyle(AX.ink)
            HStack(alignment: .top, spacing: 0) {
                ForEach(RuleSetID.allCases, id: \.self) { r in
                    VoteDisc(rule: r, mine: model.myVote == r, leading: model.voteWinner == r,
                             tally: model.tally(r)) { model.toggleVote(r) }
                        .frame(maxWidth: .infinity)
                }
            }
            .sensoryFeedback(.impact(flexibility: .soft), trigger: model.myVote)
        }
    }

    // MARK: Table

    private var tableBlock: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Table").axFont(.title).foregroundStyle(AX.ink)
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(TableSize.allCases, id: \.self) { s in
                    TableTile(size: s, selected: model.tableSize == s, measured: model.measuredTableSize == s) {
                        model.selectTable(s)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    // MARK: Start

    @ViewBuilder private var startBar: some View {
        if model.isHost { hostStartBar } else { waitingBar }
    }

    /// Peers: status, not a disabled action, so it is drawn at full contrast on `surface`.
    private var waitingBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "hourglass").axFont(.headline)
            Text("Waiting").axFont(.headline)
        }
        .foregroundStyle(AX.inkMuted)
        .frame(maxWidth: .infinity, minHeight: 56)
        .background(RoundedRectangle(cornerRadius: AX.radius.container).fill(AX.surface))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Waiting for host")
        .accessibilityIdentifier("lobby.start")
    }

    private var hostStartBar: some View {
        Button {
            if model.start() == nil, let seat = model.blockingSeat {
                pulseSeat = seat
                Task { try? await Task.sleep(for: .seconds(0.8)); pulseSeat = nil }
            }
        } label: {
            // ui-QA-4: locked = surface + lock glyph at full contrast (≥4.5:1); the blocking seat pulses above.
            HStack(spacing: 8) {
                Image(systemName: model.canStart ? "play.fill" : "lock.fill").axFont(.headline)
                Text("Start").axFont(.headline)
            }
            .foregroundStyle(model.canStart ? AX.onAccent : AX.ink)
            .frame(maxWidth: .infinity, minHeight: 56)
            // Astryx primary when ready; Astryx neutral (a secondary button's fill) while locked.
            .background(RoundedRectangle(cornerRadius: AX.radius.container, style: .continuous)
                .fill(model.canStart ? AX.accent : AX.neutral))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Start")
        .accessibilityValue(model.canStart ? "" : "Locked")
        .accessibilityIdentifier("lobby.start")
    }
}

enum LobbySheet: Identifiable, Hashable {
    case join, identity(SeatRef), meshDenied
    var id: String {
        switch self {
        case .join: "join"
        case .meshDenied: "mesh"
        case .identity(let s): "id-\(s.team)-\(s.slot)"
        }
    }
}

// MARK: - Pieces

private struct PulseEvery2s: ViewModifier {
    var active: Bool
    func body(content: Content) -> some View {
        if active {
            content.phaseAnimator([false, true]) { v, up in
                v.scaleEffect(up ? 1.08 : 1)
            } animation: { up in up ? .easeOut(duration: 0.3) : .easeIn(duration: 0.3).delay(1.4) }
        } else {
            content
        }
    }
}

private struct PeerAvatar: View {
    var peer: LobbyPeer
    var reduceMotion: Bool
    var tap: () -> Void

    var body: some View {
        Button(action: tap) {
            VStack(spacing: 8) {
                ZStack(alignment: .topLeading) {
                    SBAvatar(symbol: peer.player?.symbol ?? "iphone", colorName: peer.player?.colorName ?? "", size: 56,
                             dimmed: peer.status == .lost)
                        .overlay {
                            if peer.status == .connecting {
                                ConnectingRing(reduceMotion: reduceMotion)
                            }
                        }
                    if peer.isHost {
                        Image(systemName: "crown.fill").font(AXGlyph.font(16, .semibold))
                            .foregroundStyle(AX.ink).offset(x: -4, y: -6)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if peer.status == .lost {
                        Image(systemName: "wifi.slash").font(AXGlyph.font(16, .semibold))
                            .foregroundStyle(AX.caution).offset(x: 4, y: 4)
                    }
                }
                Text(peer.isLocal ? "You" : (peer.player?.name ?? peer.deviceName))
                    .axFont(.label, weight: .semibold).foregroundStyle(AX.inkMuted).lineLimit(2)
                    .multilineTextAlignment(.center)
                    .dynamicTypeSize(...DynamicTypeSize.accessibility1)   // caption under a fixed 56-pt avatar
                    .frame(maxWidth: 72)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel([peer.isLocal ? "You" : (peer.player?.name ?? peer.deviceName),
                             peer.isHost ? "host" : nil,
                             peer.status == .lost ? "disconnected" : (peer.status == .connecting ? "connecting" : nil)]
                                .compactMap { $0 }.joined(separator: ", "))
        .accessibilityIdentifier("lobby.peer.\(peer.id)")
    }
}

private struct ConnectingRing: View {
    var reduceMotion: Bool
    @State private var spin = false
    var body: some View {
        Circle().trim(from: 0, to: 0.7)
            .stroke(AX.inkMuted, style: StrokeStyle(lineWidth: 3, lineCap: .round))
            .padding(-5)
            .opacity(reduceMotion ? 0.5 : 1)
            .rotationEffect(.degrees(spin ? 360 : 0))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { spin = true }
            }
    }
}

private struct SeatRow: View {
    let model: LobbyModel
    let seat: SeatRef
    var pulse: Bool
    var reduceMotion: Bool
    var editIdentity: () -> Void
    @State private var targeted = false

    var body: some View {
        HStack(spacing: 8) {
            // Read-only seats are plain views: a disabled Button would dim them like a lost peer.
            if model.canOpenIdentity(seat) {
                Button(action: editIdentity) { seatContent }.buttonStyle(.plain)
            } else {
                seatContent
            }
            Spacer(minLength: 0)
            if model.canEditLineup && model[seat] != nil {
                Image(systemName: "line.3.horizontal")
                    .font(AXGlyph.font(17, .semibold))
                    .foregroundStyle(AX.inkMuted)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .draggable("\(seat.team):\(seat.slot)")
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: 66)
        .background(RoundedRectangle(cornerRadius: AX.radius.container).fill(targeted ? AX.ink.opacity(0.08) : .clear))
        .dropDestination(for: String.self) { items, _ in
            guard let from = items.first.flatMap(Self.parse) else { return false }
            return model.move(from: from, to: seat)
        } isTargeted: { targeted = $0 }
        .gesture(DragGesture(minimumDistance: 24).onEnded { v in
            if v.translation.width < -80, abs(v.translation.height) < 40 { model.removeToBench(seat) }
        }, including: model.canEditLineup ? .all : .subviews)
        .sensoryFeedback(.selection, trigger: targeted) { _, now in now }
        .sensoryFeedback(.impact(flexibility: .soft), trigger: model.shootingOrder.map { $0?.id })
        .accessibilityElement(children: .combine)
        .accessibilityLabel(model.accessibilityLabel(seat))
        .accessibilityIdentifier("lobby.seat.\(seat.team).\(seat.slot)")
        .accessibilityActions {
            if model.canEditLineup && model[seat] != nil {
                Button("Move up") { model.moveUp(seat) }
                Button("Move down") { model.moveDown(seat) }
                Button("Move to team \(LobbyModel.teamName(1 - seat.team))") { model.moveToOtherTeam(seat) }
                Button("Bench") { model.removeToBench(seat) }
            }
        }
    }

    private var seatContent: some View {
        HStack(spacing: 8) {
            if let p = model[seat] {
                SBAvatar(symbol: p.symbol, colorName: p.colorName, size: 56, team: seat.team,
                         dimmed: model.peer(for: p)?.status == .lost)
                    .padding(5)
            } else {
                ZStack {
                    Circle().strokeBorder(pulse ? AX.caution : AX.inkMuted,
                                          style: StrokeStyle(lineWidth: pulse ? 3 : 2, dash: [5, 4]))
                    if model.canOpenIdentity(seat) {
                        Image(systemName: "plus").font(AXGlyph.font(20, .semibold)).foregroundStyle(AX.inkMuted)
                    }
                }
                .frame(width: 56, height: 56)
                .padding(5)
                .scaleEffect(pulse && !reduceMotion ? 1.08 : 1)
                .animation(.snappy, value: pulse)
            }
            Text("\(seat.slot + 1)").axFont(.headline)
                .foregroundStyle(AX.ink)
        }
        .contentShape(Rectangle())
    }

    static func parse(_ s: String) -> SeatRef? {
        let parts = s.split(separator: ":").compactMap { Int($0) }
        return parts.count == 2 ? SeatRef(team: parts[0], slot: parts[1]) : nil
    }
}

private struct VoteDisc: View {
    var rule: RuleSetID
    var mine: Bool
    var leading: Bool
    var tally: Int
    var tap: () -> Void

    var symbol: String {
        switch rule { case .barEight: "8.circle.fill"; case .wpaEight: "8.circle"; case .wpaNine: "9.circle.fill" }
    }
    var label: String {
        switch rule { case .barEight: "Bar 8"; case .wpaEight: "WPA 8"; case .wpaNine: "WPA 9" }
    }
    var spoken: String {
        switch rule { case .barEight: "Bar 8-ball"; case .wpaEight: "WPA 8-ball"; case .wpaNine: "WPA 9-ball" }
    }

    var body: some View {
        Button(action: tap) {
            VStack(spacing: 8) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: symbol).font(AXGlyph.font(52, .regular))
                        .foregroundStyle(AX.ink)
                        .frame(width: 72, height: 72)
                        // ui-QA-6: one selected treatment (the ring); votes are the dots below.
                        .overlay { if mine { Circle().strokeBorder(AX.legal, lineWidth: 3) } }
                }
                Text(label).axFont(.label, weight: .semibold).foregroundStyle(AX.ink).lineLimit(1)
                HStack(spacing: 4) {
                    ForEach(0..<min(tally, 8), id: \.self) { _ in Circle().fill(AX.ink).frame(width: 8, height: 8) }
                }
                .frame(height: 8)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(spoken), \(tally) \(tally == 1 ? "vote" : "votes")\(leading ? ", leading" : "")")
        .accessibilityAddTraits(mine ? .isSelected : [])
        .accessibilityIdentifier("lobby.vote.\(rule.rawValue)")
    }
}

private struct TableTile: View {
    var size: TableSize
    var selected: Bool
    var measured: Bool
    var tap: () -> Void

    var feet: Int { switch size { case .sevenFoot: 7; case .eightFoot: 8; case .nineFoot: 9 } }

    var body: some View {
        Button(action: tap) {
            VStack(spacing: 8) {
                let w = 96 * LobbyModel.relativeLength(size)
                ZStack(alignment: .topTrailing) {
                    RoundedRectangle(cornerRadius: AX.radius.inner)
                        .fill(selected ? AnyShapeStyle(AX.felt) : AnyShapeStyle(Color.clear))
                        .overlay(RoundedRectangle(cornerRadius: AX.radius.inner).strokeBorder(AX.railHighlight, lineWidth: 4))
                        .frame(width: w, height: w / 2)
                        .overlay { if selected { RoundedRectangle(cornerRadius: AX.radius.inner).strokeBorder(AX.accent, lineWidth: 2).padding(-5) } }
                    if measured {
                        Image(systemName: "ruler").font(AXGlyph.font(16, .semibold))
                            .foregroundStyle(AX.ink).offset(x: 8, y: -12)
                    }
                }
                .frame(minHeight: 56)
                Text("\(feet) ft").axFont(.label, weight: .semibold)
                    .foregroundStyle(selected ? AX.ink : AX.inkMuted)
            }
            .frame(minWidth: 96, minHeight: 88)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(feet) foot table\(selected ? ", selected" : "")\(measured ? ", measured" : "")")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("lobby.table.\(size.rawValue)")
    }
}

#Preview("Lobby") {
    LobbyView(model: LobbySamples.hostFull())
}

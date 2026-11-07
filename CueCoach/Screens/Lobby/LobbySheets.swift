import SwiftUI
import UIKit
import Geometry

/// Host / Join sheet: two 64-pt buttons, nearby hosts as avatars.
struct JoinHostSheet: View {
    let model: LobbyModel
    var done: () -> Void

    var body: some View {
        VStack(spacing: 32) {
            HStack(spacing: 32) {
                bigButton("antenna.radiowaves.left.and.right", "Host", id: "lobby.sheet.host") { model.host(); done() }
                bigButton("person.2.wave.2", "Join", id: "lobby.sheet.joinMode") {}
            }
            if model.nearbyHosts.isEmpty {
                HStack(spacing: 16) {
                    ForEach(0..<3, id: \.self) { _ in Circle().fill(SBColor.ink.opacity(0.08)).frame(width: 64, height: 64) }
                }
                .accessibilityLabel("Looking for nearby phones")
            } else {
                HStack(spacing: 24) {
                    ForEach(model.nearbyHosts) { h in
                        Button { model.join(h.id); done() } label: {
                            VStack(spacing: 8) {
                                SBAvatar(symbol: h.player?.symbol ?? "iphone", colorName: h.player?.colorName ?? "", size: 64)
                                Text(h.player?.name ?? h.deviceName).font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(SBColor.inkMuted).lineLimit(1).frame(maxWidth: 80)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Join \(h.player?.name ?? h.deviceName)")
                    }
                }
            }
            Spacer()
        }
        .padding(.top, 40)
        .padding(.horizontal, 16)
        .accessibilityIdentifier("lobby.sheet.join")
    }

    private func bigButton(_ symbol: String, _ word: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(SBColor.ink)
                    .frame(width: 64, height: 64)
                    .background(Circle().fill(SBColor.ink.opacity(0.1)))
                Text(word).font(.system(size: 17, weight: .semibold)).foregroundStyle(SBColor.ink)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }
}

/// Identity: pick a local profile, register a new one, or play as guest.
struct IdentitySheet: View {
    let model: LobbyModel
    let seat: SeatRef
    var done: () -> Void

    @State private var registering = false
    @State private var name = ""
    @State private var symbol = "figure.pool.swim"
    @State private var colorName = ""

    static let symbols = ["figure.pool.swim", "hare.fill", "tortoise.fill", "bolt.fill", "flame.fill", "star.fill",
                          "leaf.fill", "moon.fill"]

    var body: some View {
        ScrollView {
            if registering { registerForm } else { picker }
        }
        .padding(.top, 24)
        .accessibilityIdentifier("lobby.sheet.identity")
        .onAppear { colorName = model.nextFreeColorName }
    }

    private var picker: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 3), spacing: 24) {
            if model.isLoadingProfiles {
                ForEach(0..<3, id: \.self) { _ in Circle().fill(SBColor.ink.opacity(0.08)).frame(width: 64, height: 64) }
            } else {
                ForEach(model.pickableProfiles) { p in
                    cell(name: p.name) {
                        SBAvatar(symbol: p.symbol, colorName: p.colorName, size: 64)
                    } action: { model.assign(p, to: seat); done() }
                }
            }
            cell(name: "New") { glyph("person.badge.plus") } action: { registering = true }
                .accessibilityIdentifier("lobby.identity.new")
            cell(name: "Guest") { glyph("person.fill.questionmark") } action: { try? model.assignGuest(to: seat); done() }
                .accessibilityIdentifier("lobby.identity.guest")
        }
        .padding(.horizontal, 16)
    }

    private var registerForm: some View {
        VStack(spacing: 24) {
            SBAvatar(symbol: symbol, colorName: colorName, size: 80)
            TextField("Name", text: $name)
                .font(.system(size: 17))
                .textInputAutocapitalization(.words)
                .padding(.horizontal, 16)
                .frame(minHeight: 52)
                .background(RoundedRectangle(cornerRadius: 14).fill(SBColor.ink.opacity(0.08)))
                .accessibilityIdentifier("lobby.identity.name")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 12) {
                ForEach(Self.symbols, id: \.self) { s in
                    Button { symbol = s } label: {
                        Image(systemName: s).font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(SBColor.ink)
                            .frame(width: 52, height: 52)
                            .background(Circle().fill(SBColor.ink.opacity(symbol == s ? 0.2 : 0.06)))
                    }
                    .buttonStyle(.plain)
                }
                ForEach(SBColor.avatarNames, id: \.self) { c in
                    Button { colorName = c } label: {
                        Circle().fill(SBColor.avatar(c)).frame(width: 44, height: 44)
                            .overlay { if colorName == c { Circle().strokeBorder(SBColor.ink, lineWidth: 3).padding(-4) } }
                            .frame(width: 52, height: 52)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(c)
                    .accessibilityAddTraits(colorName == c ? .isSelected : [])
                }
            }
            Button {
                if (try? model.registerAndAssign(name: name, symbol: symbol, colorName: colorName, to: seat)) != nil { done() }
            } label: {
                Label("Save", systemImage: "checkmark")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(SBColor.bg)
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .background(RoundedRectangle(cornerRadius: 14).fill(SBColor.legal))
                    .opacity(name.trimmingCharacters(in: .whitespaces).isEmpty ? 0.4 : 1)
            }
            .buttonStyle(.plain)
            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 16)
    }

    private func glyph(_ s: String) -> some View {
        Image(systemName: s).font(.system(size: 26, weight: .semibold)).foregroundStyle(SBColor.ink)
            .frame(width: 64, height: 64)
            .background(Circle().strokeBorder(SBColor.inkMuted, style: StrokeStyle(lineWidth: 2, dash: [5, 4])))
    }

    private func cell<V: View>(name: String, @ViewBuilder _ icon: () -> V, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                icon()
                Text(name).font(.system(size: 13, weight: .semibold)).foregroundStyle(SBColor.inkMuted)
                    .lineLimit(1).truncationMode(.tail)
            }
            .frame(minWidth: 64, minHeight: 88)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
    }
}

/// Local Network denied: one sentence + Settings.
struct MeshDeniedSheet: View {
    var done: () -> Void
    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 40, weight: .regular))
                .foregroundStyle(SBColor.caution)
            Text("Allow Local Network to link phones.")
                .font(.system(size: 17)).foregroundStyle(SBColor.ink).multilineTextAlignment(.center)
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                done()
            } label: {
                Label("Settings", systemImage: "gear")
                    .font(.system(size: 17, weight: .semibold)).foregroundStyle(SBColor.bg)
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .background(RoundedRectangle(cornerRadius: 14).fill(SBColor.ink))
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .padding(.top, 40)
        .padding(.horizontal, 16)
        .accessibilityIdentifier("lobby.sheet.meshDenied")
    }
}

/// In-memory sample lobbies for previews, tests and the debug router.
@MainActor enum LobbySamples {
    static let ari = LobbyPlayer(id: UUID(), name: "Ari", symbol: "figure.pool.swim", colorName: "teal")
    static let sam = LobbyPlayer(id: UUID(), name: "Sam", symbol: "hare.fill", colorName: "orange")
    static let ana = LobbyPlayer(id: UUID(), name: "Ana", symbol: "tortoise.fill", colorName: "pink")
    static let bo = LobbyPlayer(id: UUID(), name: "Bo", symbol: "bolt.fill", colorName: "purple")

    static func peers(host: Int = 0, local: Int = 0, lost: Int? = nil, connecting: Int? = nil) -> [LobbyPeer] {
        [ari, sam, ana, bo].enumerated().map { i, p in
            LobbyPeer(id: "p\(i)", deviceName: "Phone \(i)", player: p, isHost: i == host, isLocal: i == local,
                      status: i == lost ? .lost : (i == connecting ? .connecting : .connected))
        }
    }

    static func make(local: LobbyPlayer = ari, localPeer: String = "p0", isHost: Bool = true,
                     peers: [LobbyPeer], measured: TableSize? = .eightFoot) -> LobbyModel {
        LobbyModel(localPeerID: localPeer, localPlayer: local, isHost: isHost,
                   profiles: InMemoryLobbyProfiles(profiles: [ari, LobbyPlayer(id: UUID(), name: "Kim", symbol: "flame.fill", colorName: "red"), bo]),
                   mesh: RecordingLobbyMesh(), peers: peers, measuredTableSize: measured)
    }

    /// 2v2, every seat filled, votes cast: Start ready.
    static func hostFull() -> LobbyModel {
        let m = make(peers: peers())
        m.setFormat(.twoVsTwo)
        m.assign(ana, to: SeatRef(team: 0, slot: 1))
        m.assign(bo, to: SeatRef(team: 1, slot: 1))
        m.toggleVote(.wpaNine)
        m.receiveBallot(peerID: "p1", vote: .wpaNine)
        m.receiveBallot(peerID: "p2", vote: .barEight)
        return m
    }

    /// 2v2 with an empty seat and a dropped peer: Start locked.
    static func hostLocked() -> LobbyModel {
        let m = make(peers: peers(lost: 1, connecting: 3))
        m.setFormat(.twoVsTwo)
        m.receiveBallot(peerID: "p1", vote: .wpaEight)
        return m
    }

    static func solo() -> LobbyModel {
        make(peers: [LobbyPeer(id: "p0", deviceName: "This phone", player: ari, isHost: true, isLocal: true, status: .connected)],
             measured: nil)
    }

    /// Non-host phone: no handles, "Waiting".
    static func peerView() -> LobbyModel {
        let m = make(local: sam, localPeer: "p1", isHost: false, peers: peers(host: 0, local: 1))
        m.receiveBallot(peerID: "p0", vote: .barEight)
        m.toggleVote(.wpaEight)
        return m
    }

    static func meshDenied() -> LobbyModel {
        let m = solo()
        m.setMeshAvailability(.unavailable)
        return m
    }

    static func joinable() -> LobbyModel {
        let m = solo()
        m.setMeshAvailability(.discovering)
        m.setNearbyHosts([NearbyHost(id: "h1", player: sam, deviceName: "Sam's iPhone"),
                          NearbyHost(id: "h2", player: ana, deviceName: "Ana's iPhone")])
        return m
    }
}

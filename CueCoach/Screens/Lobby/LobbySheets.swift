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
                // Join = look for nearby hosts; they appear below as avatars, tap one to join.
                bigButton("person.2.wave.2", "Join", id: "lobby.sheet.joinMode", active: model.meshAvailability == .discovering) {
                    model.browse()
                }
            }
            if model.nearbyHosts.isEmpty && model.meshAvailability == .discovering {
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
                                Text(h.player?.name ?? h.deviceName).font(SBFont.caption)
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
    }

    private func bigButton(_ symbol: String, _ word: String, id: String, active: Bool = false,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: symbol).font(SBFont.glyph(28, .semibold))
                    .foregroundStyle(SBColor.ink)
                    .frame(width: 64, height: 64)
                    .background(Circle().fill(SBColor.ink.opacity(active ? 0.2 : 0.1)))
                    .overlay { if active { Circle().strokeBorder(SBColor.legal, lineWidth: 3) } }
                Text(word).font(SBFont.headline).foregroundStyle(SBColor.ink)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? .isSelected : [])
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
    @State private var refusals = 0

    static let symbols = ["figure.pool.swim", "hare.fill", "tortoise.fill", "bolt.fill", "flame.fill", "star.fill",
                          "leaf.fill", "moon.fill"]

    var body: some View {
        ScrollView {
            if registering { registerForm } else { picker }
        }
        .padding(.top, 24)
        .accessibilityIdentifier("lobby.sheet.identity")
        .onAppear { colorName = model.nextFreeColorName }
        .sensoryFeedback(.error, trigger: refusals)
    }

    private var picker: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 3), spacing: 24) {
            if model.isLoadingProfiles {
                ForEach(0..<3, id: \.self) { _ in Circle().fill(SBColor.ink.opacity(0.08)).frame(width: 64, height: 64) }
            } else {
                ForEach(model.identityChoices(for: seat)) { p in
                    cell(name: p.id == model.localPlayer.id && !model.canCreatePlayers ? "You" : p.name) {
                        SBAvatar(symbol: p.symbol, colorName: p.colorName, size: 64)
                    } action: { finish(model.assign(p, to: seat)) }
                }
            }
            // Only the host can add players; the check happens before anything is created.
            if model.canCreatePlayers {
                cell(name: "New") { glyph("person.badge.plus") } action: { registering = true }
                    .accessibilityIdentifier("lobby.identity.new")
                cell(name: "Guest") { glyph("person.fill.questionmark") } action: {
                    finish((try? model.assignGuest(to: seat)) != nil)
                }
                .accessibilityIdentifier("lobby.identity.guest")
            }
        }
        .padding(.horizontal, 16)
    }

    private var registerForm: some View {
        VStack(spacing: 24) {
            SBAvatar(symbol: symbol, colorName: colorName, size: 80)
            TextField("Name", text: $name)
                .font(SBFont.body)
                .textInputAutocapitalization(.words)
                .padding(.horizontal, 16)
                .frame(minHeight: 52)
                .background(RoundedRectangle(cornerRadius: 14).fill(SBColor.ink.opacity(0.08)))
                .accessibilityIdentifier("lobby.identity.name")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 12) {
                ForEach(Self.symbols, id: \.self) { s in
                    Button { symbol = s } label: {
                        Image(systemName: s).font(SBFont.glyph(22, .semibold))
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
                finish((try? model.registerAndAssign(name: name, symbol: symbol, colorName: colorName, to: seat)) != nil)
            } label: {
                Label("Save", systemImage: "checkmark")
                    .font(SBFont.headline)
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

    /// Close only when the change was accepted; otherwise stay open with an error haptic.
    private func finish(_ ok: Bool) {
        if ok { done() } else { refusals += 1 }
    }

    private func glyph(_ s: String) -> some View {
        Image(systemName: s).font(SBFont.glyph(26, .semibold)).foregroundStyle(SBColor.ink)
            .frame(width: 64, height: 64)
            .background(Circle().strokeBorder(SBColor.inkMuted, style: StrokeStyle(lineWidth: 2, dash: [5, 4])))
    }

    private func cell<V: View>(name: String, @ViewBuilder _ icon: () -> V, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                icon()
                Text(name).font(SBFont.caption).foregroundStyle(SBColor.inkMuted)
                    .lineLimit(1).truncationMode(.tail)
                    .dynamicTypeSize(...DynamicTypeSize.accessibility2)
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
            Image(systemName: "exclamationmark.triangle").font(SBFont.glyph(40, .regular))
                .foregroundStyle(SBColor.caution)
            Text("Allow Local Network to link phones.")
                .font(SBFont.body).foregroundStyle(SBColor.ink).multilineTextAlignment(.center)
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                done()
            } label: {
                Label("Settings", systemImage: "gear")
                    .font(SBFont.headline).foregroundStyle(SBColor.bg)
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .background(RoundedRectangle(cornerRadius: 14).fill(SBColor.ink))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("lobby.meshDenied.settings")
            Spacer()
        }
        .padding(.top, 40)
        .padding(.horizontal, 16)
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
        // The host's lineup as it arrives over the mesh: Ari A1, Sam B1, Ana A2, B2 open.
        m.applyLineup([[ari.id, ana.id], [sam.id, nil]], roster: [ari, sam, ana], format: .twoVsTwo, tableSize: .eightFoot)
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

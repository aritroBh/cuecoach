import Foundation
import MultipeerConnectivity
import Geometry
import Rules

/// Lobby wire format: Bonjour discovery info for adverts + small JSON messages on a reliable MPC session.
enum LobbyWire {
    static let serviceType = "cuecoach-lb"   // listed in NSBonjourServices (project.yml)
    static let version = "1"
    static let inviteContext = Data("cuecoach-lobby-v1".utf8)
    /// This phone + up to 7 more (MPC session limit 8).
    static let maxJoiners = 7

    enum Message: Hashable, Codable, Sendable {
        case hello(name: String)
        case welcome
        case full
        case lineup(LobbyLineup)
        case start(GameConfig, sessionTag: UInt16)
        case phones([NearbyPhone])
    }

    /// Lobby messages are tiny; anything bigger is dropped unread.
    static let maxMessageBytes = 16_384
    static let maxNameLength = 64
    struct TooBig: Error {}

    static func encode(_ m: Message) throws -> Data { try JSONEncoder().encode(m) }
    static func decode(_ d: Data) throws -> Message {
        guard d.count <= maxMessageBytes else { throw TooBig() }
        return try JSONDecoder().decode(Message.self, from: d)
    }

    /// Peer-supplied content stays inside the app's limits: two teams, 1–4 players each, short names (SPEC §4).
    static func isAcceptable(_ m: Message) -> Bool {
        func ok(_ p: ShellPlayer?) -> Bool { p.map { $0.name.count <= maxNameLength && $0.symbol.count <= 64 && $0.colorName.count <= 32 } ?? true }
        switch m {
        case .hello(let name): return name.count <= maxNameLength
        case .welcome, .full: return true
        case .lineup(let l):
            return l.seats.count == 2 && l.seats.allSatisfy { (1...4).contains($0.count) && $0.allSatisfy(ok) }
        case .start(let c, let tag):
            return tag != 0 && c.teams.count == 2 && c.teams.allSatisfy { (1...4).contains($0.count) && $0.allSatisfy(ok) }
        case .phones(let p):
            return p.count <= maxJoiners && p.allSatisfy { ($0.name?.count ?? 0) <= maxNameLength }
        }
    }

    static func discoveryInfo(_ g: NearbyGame) -> [String: String] {
        var info = ["v": version, "g": g.id, "r": g.ruleSet.rawValue, "f": "\(g.seatsFilled)", "t": "\(g.seatsTotal)"]
        if let h = g.host {
            info["i"] = h.id.uuidString
            info["n"] = String(h.name.prefix(24))
            info["y"] = h.symbol
            info["c"] = h.colorName
        }
        return info
    }

    static func game(from info: [String: String]?, peerKey: String) -> NearbyGame? {
        guard let info, info["v"] == version, let id = info["g"],
              let rule = info["r"].flatMap(RuleSetID.init(rawValue:)) else { return nil }
        var host: ShellPlayer?
        if let i = info["i"].flatMap(UUID.init(uuidString:)), let n = info["n"] {
            host = ShellPlayer(id: i, name: n, symbol: info["y"] ?? "person.fill", colorName: info["c"] ?? "blue")
        }
        let total = min(8, max(2, Int(info["t"] ?? "") ?? 2))
        let filled = min(total, max(0, Int(info["f"] ?? "") ?? 0))
        if let h = host, h.name.count > maxNameLength { host?.name = String(h.name.prefix(maxNameLength)) }
        return NearbyGame(id: String(id.prefix(16)), host: host, ruleSet: rule, seatsFilled: filled, seatsTotal: total)
    }

    static func randomSessionTag() -> UInt16 { UInt16.random(in: 1...UInt16.max) }
}


/// Real lobby over MultipeerConnectivity (local link only, encryption required, zero network).
/// Host: advertises `cuecoach-lb` with a small advert, accepts joiners, pushes the lineup and the start.
/// Joiner: browses adverts, invites the chosen host, mirrors its lineup, starts when the host does.
/// The game itself then runs on `MultipeerMeshSession` with the `sessionTag` from the start message.
@MainActor final class MPCGameLobby: NSObject, GameLobbyMesh {
    var onEvent: ((LobbyEvent) -> Void)?
    private let localName: () -> String

    private enum Mode { case idle, hosting, browsing }
    private var mode: Mode = .idle
    private var session: MCSession?
    private var peer: MCPeerID?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?

    // Host state
    private var advert: NearbyGame?
    private var lineup: LobbyLineup?
    private var phoneNames: [String: String] = [:]   // displayName → name
    private var admitted: [String] = []

    // Joiner state
    private var found: [String: (MCPeerID, NearbyGame)] = [:]   // displayName → advert
    private var joinedHost: (peer: String, gameID: String)?
    private var welcomed = false
    private var started = false

    init(localName: @escaping () -> String) { self.localName = localName }

    // MARK: Host

    func host(_ advert: NearbyGame) {
        let changed = self.advert != advert
        self.advert = advert
        if mode != .hosting {
            teardown()
            mode = .hosting
            makeSession()
        } else if !changed { return }
        advertiser?.stopAdvertisingPeer()
        let a = MCNearbyServiceAdvertiser(peer: peer!, discoveryInfo: LobbyWire.discoveryInfo(advert),
                                          serviceType: LobbyWire.serviceType)
        a.delegate = self
        a.startAdvertisingPeer()
        advertiser = a
    }

    func publish(lineup: LobbyLineup) {
        self.lineup = lineup
        send(.lineup(lineup), to: admitted)
    }

    func announceStart(_ config: GameConfig) {
        send(.start(config, sessionTag: config.sessionTag ?? LobbyWire.randomSessionTag()), to: admitted)
        started = true
    }

    func stopHosting() {
        guard mode == .hosting else { return }
        // Let a just-sent start message flush before the session goes away.
        let s = session
        let delay: Double = started ? 2 : 0   // captured before `started` resets below
        advertiser?.stopAdvertisingPeer()
        advertiser = nil
        session = nil
        mode = .idle
        phoneNames = [:]; admitted = []
        started = false
        Task { try? await Task.sleep(for: .seconds(delay)); s?.disconnect() }
    }

    // MARK: Joiner

    func browse() {
        guard mode != .browsing else { return }
        teardown()
        mode = .browsing
        makeSession()
        let b = MCNearbyServiceBrowser(peer: peer!, serviceType: LobbyWire.serviceType)
        b.delegate = self
        b.startBrowsingForPeers()
        browser = b
    }

    func stopBrowsing() {
        guard mode == .browsing else { return }
        teardown()
    }

    func join(gameID: String) {
        guard let (key, entry) = found.first(where: { $0.value.1.id == gameID }), let session else { return }
        joinedHost = (key, gameID)
        welcomed = false
        started = false
        browser?.invitePeer(entry.0, to: session, withContext: LobbyWire.inviteContext, timeout: 15)
    }

    func leave() {
        joinedHost = nil
        welcomed = false
        session?.disconnect()
    }

    // MARK: Plumbing

    private func makeSession() {
        let p = MCPeerID(displayName: UUID().uuidString)   // random per session; never the device name (TN3213)
        peer = p
        let s = MCSession(peer: p, securityIdentity: nil, encryptionPreference: .required)
        s.delegate = self
        session = s
    }

    private func teardown() {
        advertiser?.stopAdvertisingPeer(); advertiser = nil
        browser?.stopBrowsingForPeers(); browser = nil
        session?.disconnect(); session = nil
        mode = .idle
        found = [:]; joinedHost = nil; welcomed = false
        phoneNames = [:]; admitted = []
    }

    private func send(_ m: LobbyWire.Message, to keys: [String]) {
        guard let session, let data = try? LobbyWire.encode(m) else { return }
        let targets = session.connectedPeers.filter { keys.contains($0.displayName) }
        guard !targets.isEmpty else { return }
        try? session.send(data, toPeers: targets, with: .reliable)
    }

    private func emitGames() {
        onEvent?(.gamesChanged(found.values.map(\.1).sorted { ($0.host?.name ?? "") < ($1.host?.name ?? "") }))
    }

    private func emitPhones() {
        onEvent?(.phonesChanged(admitted.map { NearbyPhone(id: $0, name: phoneNames[$0]) }))
    }

    /// Delegate callbacks carry the identity of the object that fired; anything from a retired session,
    /// browser or advertiser is ignored.
    fileprivate func isCurrent(session id: ObjectIdentifier) -> Bool { session.map(ObjectIdentifier.init) == id }
    fileprivate func isCurrent(browser id: ObjectIdentifier) -> Bool { browser.map(ObjectIdentifier.init) == id }
    fileprivate func isCurrent(advertiser id: ObjectIdentifier) -> Bool { advertiser.map(ObjectIdentifier.init) == id }

    fileprivate func invitation(from advertiserID: ObjectIdentifier, context: Data?, reply: (Bool, MCSession?) -> Void) {
        guard mode == .hosting, isCurrent(advertiser: advertiserID), context == LobbyWire.inviteContext, let session else {
            reply(false, nil); return
        }
        reply(true, session)
    }

    fileprivate func peerChanged(_ key: String, connected: Bool) {
        switch mode {
        case .hosting:
            if connected {
                guard !admitted.contains(key) else { return }
                if admitted.count >= LobbyWire.maxJoiners {
                    if let s = session, let p = s.connectedPeers.first(where: { $0.displayName == key }),
                       let d = try? LobbyWire.encode(.full) { try? s.send(d, toPeers: [p], with: .reliable) }
                    return
                }
                admitted.append(key)
                send(.welcome, to: [key])
                if let lineup { send(.lineup(lineup), to: [key]) }
            } else {
                admitted.removeAll { $0 == key }
                phoneNames[key] = nil
            }
            emitPhones()
        case .browsing:
            guard let j = joinedHost, j.peer == key else { return }
            if connected {
                send(.hello(name: localName()), to: [key])
            } else if !started {
                // Only an explicit `.full` means full; any other drop (host gone, invite failed) is host-left.
                onEvent?(.hostLeft(gameID: j.gameID))
                joinedHost = nil
            }
        case .idle: break
        }
    }

    fileprivate func received(_ data: Data, from key: String) {
        guard let m = try? LobbyWire.decode(data), LobbyWire.isAcceptable(m) else { return }
        switch (mode, m) {
        case (.hosting, .hello(let name)):
            phoneNames[key] = String(name.prefix(24))
            emitPhones()
        case (.browsing, .welcome):
            guard let j = joinedHost, j.peer == key else { return }
            welcomed = true
            onEvent?(.joined(gameID: j.gameID))
        case (.browsing, .full):
            guard let j = joinedHost, j.peer == key else { return }
            onEvent?(.rejectedFull(gameID: j.gameID))
            welcomed = true   // suppress the disconnect's second event
            started = true
            session?.disconnect()
        case (.browsing, .lineup(let l)):
            guard let j = joinedHost, j.peer == key else { return }
            onEvent?(.lineupChanged(gameID: j.gameID, l))
        case (.browsing, .start(var cfg, let tag)):
            guard let j = joinedHost, j.peer == key else { return }
            started = true
            cfg.sessionTag = tag
            onEvent?(.started(gameID: j.gameID, cfg))
        default: break
        }
    }

    fileprivate func foundAdvert(_ p: MCPeerID, info: [String: String]?) {
        guard mode == .browsing, let g = LobbyWire.game(from: info, peerKey: p.displayName) else { return }
        found[p.displayName] = (p, g)
        emitGames()
    }

    fileprivate func lostAdvert(_ key: String) {
        guard found.removeValue(forKey: key) != nil else { return }
        emitGames()
    }

    fileprivate func failed() { onEvent?(.unavailable) }
}

extension MPCGameLobby: MCSessionDelegate, MCNearbyServiceAdvertiserDelegate, MCNearbyServiceBrowserDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        let key = peerID.displayName
        let connected = state == .connected
        let id = ObjectIdentifier(session)
        guard state != .connecting else { return }
        Task { @MainActor in if self.isCurrent(session: id) { self.peerChanged(key, connected: connected) } }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        let key = peerID.displayName
        let id = ObjectIdentifier(session)
        guard data.count <= LobbyWire.maxMessageBytes else { return }
        Task { @MainActor in if self.isCurrent(session: id) { self.received(data, from: key) } }
    }

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String,
                             fromPeer peerID: MCPeerID) {}
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String,
                             fromPeer peerID: MCPeerID, with progress: Progress) {}
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String,
                             fromPeer peerID: MCPeerID, at localURL: URL?, withError error: (any Error)?) {}

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                                withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        // Decide on the main actor against current state; MPC accepts an asynchronous reply.
        let id = ObjectIdentifier(advertiser)
        nonisolated(unsafe) let reply = invitationHandler
        Task { @MainActor in self.invitation(from: id, context: context, reply: reply) }
    }

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: any Error) {
        Task { @MainActor in self.failed() }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID,
                             withDiscoveryInfo info: [String: String]?) {
        nonisolated(unsafe) let p = peerID
        let id = ObjectIdentifier(browser)
        Task { @MainActor in if self.isCurrent(browser: id) { self.foundAdvert(p, info: info) } }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        let key = peerID.displayName
        let id = ObjectIdentifier(browser)
        Task { @MainActor in if self.isCurrent(browser: id) { self.lostAdvert(key) } }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: any Error) {
        Task { @MainActor in self.failed() }
    }
}

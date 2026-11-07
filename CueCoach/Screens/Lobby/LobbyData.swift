import Foundation
import SwiftData
import Rules
import Geometry

/// A player who can sit in a seat (local profile, peer's profile, or session guest).
struct LobbyPlayer: Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    var symbol: String
    var colorName: String
    var isGuest = false
}

/// A phone in the mesh.
struct LobbyPeer: Identifiable, Hashable, Sendable {
    enum Status: Hashable, Sendable { case connecting, connected, lost }
    var id: String
    var deviceName: String
    var player: LobbyPlayer?
    var isHost: Bool
    var isLocal: Bool
    var status: Status
}

/// A nearby host shown in the Join sheet.
struct NearbyHost: Identifiable, Hashable, Sendable {
    var id: String
    var player: LobbyPlayer?
    var deviceName: String
}

enum MeshAvailability: Hashable, Sendable { case idle, discovering, unavailable }

struct SeatRef: Hashable, Sendable {
    var team: Int
    var slot: Int
}

/// What Start hands to the live game.
struct LobbyStartConfig: Equatable, Sendable {
    var format: GameFormat
    var ruleSet: RuleSetID
    var tableSize: TableSize
    var teams: [StoredTeam]
}

enum LobbyError: Error, Equatable { case blankName, notAllowed }

// MARK: - Dependencies (local protocols; Mesh/Identity agents implement them later)

/// Outbound mesh actions. The host is the single source of truth for the lineup.
///
/// Inbound counterparts (the Mesh agent calls these on the receiving phone's `LobbyModel`):
/// - `send(lineup:roster:format:tableSize:)` (host) → `LobbyModel.applyLineup(_:roster:format:tableSize:)` (peers)
/// - `send(seatRequest:)` (peer) → `LobbyModel.receiveSeatRequest(peerID:seat:)` (host)
/// - `send(vote:)` (anyone) → `LobbyModel.receiveBallot(peerID:vote:)` (everyone)
/// - discovery → `setNearbyHosts(_:)`, `setMeshAvailability(_:)`; membership → `updatePeers(_:)`, `updatePeerStatus(_:_:)`
@MainActor protocol LobbyMeshLink: AnyObject {
    func startHosting()
    func startBrowsing()
    func join(hostID: String)
    func send(vote: RuleSetID?)
    /// `roster` carries every seated or benched player so peers can draw players they have never met (host-side guests).
    func send(lineup: [[UUID?]], roster: [LobbyPlayer], format: GameFormat, tableSize: TableSize)
    /// A peer asking the host to seat its local player.
    func send(seatRequest: SeatRef)
}

/// Local profiles for the identity sheet.
@MainActor protocol LobbyProfileStore: AnyObject {
    func localProfiles() -> [LobbyPlayer]
    func register(name: String, symbol: String, colorName: String) throws -> LobbyPlayer
    func makeGuest(colorName: String) throws -> LobbyPlayer
}

// MARK: - In-memory implementations (previews, tests, debug router)

@MainActor final class InMemoryLobbyProfiles: LobbyProfileStore {
    private(set) var profiles: [LobbyPlayer]
    private var guestCount = 0
    init(profiles: [LobbyPlayer]) { self.profiles = profiles }
    func localProfiles() -> [LobbyPlayer] { profiles.filter { !$0.isGuest } }
    func register(name: String, symbol: String, colorName: String) throws -> LobbyPlayer {
        let p = LobbyPlayer(id: UUID(), name: name, symbol: symbol, colorName: colorName)
        profiles.append(p)
        return p
    }
    func makeGuest(colorName: String) throws -> LobbyPlayer {
        guestCount += 1
        let p = LobbyPlayer(id: UUID(), name: guestCount == 1 ? "Guest" : "Guest \(guestCount)",
                            symbol: "person.fill", colorName: colorName, isGuest: true)
        profiles.append(p)
        return p
    }
}

@MainActor final class RecordingLobbyMesh: LobbyMeshLink {
    struct Lineup { var ids: [[UUID?]]; var roster: [LobbyPlayer]; var format: GameFormat; var tableSize: TableSize }
    private(set) var sentVotes: [RuleSetID?] = []
    private(set) var hosted = false
    private(set) var browsing = false
    private(set) var joined: [String] = []
    private(set) var lineupsSent = 0
    private(set) var lastLineup: Lineup?
    private(set) var seatRequests: [(seat: SeatRef, at: Date)] = []
    func startHosting() { hosted = true }
    func startBrowsing() { browsing = true }
    func join(hostID: String) { joined.append(hostID) }
    func send(vote: RuleSetID?) { sentVotes.append(vote) }
    func send(lineup: [[UUID?]], roster: [LobbyPlayer], format: GameFormat, tableSize: TableSize) {
        lineupsSent += 1
        lastLineup = Lineup(ids: lineup, roster: roster, format: format, tableSize: tableSize)
    }
    func send(seatRequest: SeatRef) { seatRequests.append((seatRequest, .now)) }
}

// MARK: - Persistence-backed profile store (reads/inserts PlayerProfile; never edits other rows)

@MainActor final class PersistenceLobbyProfiles: LobbyProfileStore {
    private let stack: PersistenceStack
    init(stack: PersistenceStack) { self.stack = stack }

    func localProfiles() -> [LobbyPlayer] {
        let d = FetchDescriptor<PlayerProfile>(predicate: #Predicate { !$0.isSessionGuest })
        let rows = (try? stack.competitiveContext.fetch(d)) ?? []
        return rows.sorted { $0.createdAt < $1.createdAt }.map(Self.player)
    }

    func register(name: String, symbol: String, colorName: String) throws -> LobbyPlayer {
        let p = PlayerProfile(name: name, avatarSymbol: symbol, avatarColor: colorName)
        stack.competitiveContext.insert(p)
        try stack.competitiveContext.save()
        return Self.player(p)
    }

    /// Guests are cached as `isSessionGuest` and purged on session end (`purgeSessionGuests`).
    func makeGuest(colorName: String) throws -> LobbyPlayer {
        let p = PlayerProfile(name: "Guest", avatarSymbol: "person.fill", avatarColor: colorName, isSessionGuest: true)
        stack.competitiveContext.insert(p)
        try stack.competitiveContext.save()
        return Self.player(p)
    }

    static func player(_ p: PlayerProfile) -> LobbyPlayer {
        LobbyPlayer(id: p.id, name: p.name, symbol: p.avatarSymbol, colorName: p.avatarColor, isGuest: p.isSessionGuest)
    }
}

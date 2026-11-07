import Foundation
import Observation
import SwiftData
import Geometry
import Rules

enum SetupIssue: Hashable, Sendable {
    case emptySeat(SeatRef)
    case duplicate(UUID)
    case unevenTeams
}

/// On-device roster (persisted `PlayerProfile` rows). Guests never pass through here.
@MainActor protocol RosterStore: AnyObject {
    func allPlayers() -> [ShellPlayer]
    func register(name: String, symbol: String, colorName: String) throws -> ShellPlayer
}

@MainActor final class InMemoryRoster: RosterStore {
    private(set) var players: [ShellPlayer]
    private(set) var registerCount = 0
    init(_ players: [ShellPlayer]) { self.players = players }
    func allPlayers() -> [ShellPlayer] { players }
    func register(name: String, symbol: String, colorName: String) throws -> ShellPlayer {
        registerCount += 1
        let p = ShellPlayer(id: UUID(), name: name, symbol: symbol, colorName: colorName)
        players.append(p)
        return p
    }
}

/// Reads and inserts `PlayerProfile` rows in the competitive store. Never edits or deletes rows.
@MainActor final class PersistenceRoster: RosterStore {
    private let stack: PersistenceStack
    init(stack: PersistenceStack) { self.stack = stack }

    func allPlayers() -> [ShellPlayer] {
        let d = FetchDescriptor<PlayerProfile>(predicate: #Predicate { !$0.isSessionGuest })
        let rows = (try? stack.competitiveContext.fetch(d)) ?? []
        return rows.sorted { $0.createdAt < $1.createdAt }.map(Self.player)
    }

    func register(name: String, symbol: String, colorName: String) throws -> ShellPlayer {
        let p = PlayerProfile(name: name, avatarSymbol: symbol, avatarColor: colorName)
        stack.competitiveContext.insert(p)
        try stack.competitiveContext.save()
        return Self.player(p)
    }

    static func player(_ p: PlayerProfile) -> ShellPlayer {
        ShellPlayer(id: p.id, name: p.name, symbol: p.avatarSymbol, colorName: p.avatarColor)
    }
}

/// New game (host): rules, singles/teams, seats in D17 order, table size, joiners.
@MainActor @Observable
final class GameSetupModel {
    var ruleSet: RuleSetID { didSet { readvertise() } }
    var tableSize: TableSize { didSet { readvertise() } }
    let measuredTable: TableSize?
    private(set) var seats: [[ShellPlayer?]] = [[nil], [nil]] { didSet { readvertise() } }
    private(set) var rosterPlayers: [ShellPlayer]
    private(set) var joinedPhones: [NearbyPhone] = []
    private(set) var blockedStartCount = 0
    private(set) var isHosting = false
    /// Local network permission denied / MPC failed: the host can still play on this phone alone.
    private(set) var meshUnavailable = false
    /// The last lineup/start message didn't reach the joiners.
    private(set) var syncFailed = false
    /// Start is one-shot: a second tap can't mint another session tag or a second Live.
    private(set) var hasStarted = false

    @ObservationIgnored private let roster: any RosterStore
    @ObservationIgnored private let mesh: (any GameLobbyMesh)?
    @ObservationIgnored private var guestCount = 0
    @ObservationIgnored var onStart: ((GameConfig) -> Void)?
    /// Advertised id of this phone's game.
    @ObservationIgnored let gameID = String(UUID().uuidString.prefix(8))

    static let maxPerTeam = 4

    init(roster: any RosterStore, defaults: SetupDefaults, measuredTable: TableSize?, mesh: (any GameLobbyMesh)?) {
        self.roster = roster
        self.mesh = mesh
        self.measuredTable = measuredTable
        ruleSet = defaults.ruleSet
        tableSize = measuredTable ?? defaults.manualTable ?? .sevenFoot
        rosterPlayers = roster.allPlayers().filter { !$0.isGuest }
    }

    // MARK: Derived

    var playersPerTeam: Int { seats[0].count }
    var isTeams: Bool { playersPerTeam > 1 }

    var seatOrder: [SeatRef] {
        (0..<playersPerTeam).flatMap { s in [SeatRef(team: 0, slot: s), SeatRef(team: 1, slot: s)] }
    }
    var rotationPreview: [ShellPlayer?] { seatOrder.map { self[$0] } }

    var issues: [SetupIssue] {
        var out: [SetupIssue] = seatOrder.filter { self[$0] == nil }.map { .emptySeat($0) }
        let ids = seats.flatMap { $0 }.compactMap { $0?.id }
        for id in Set(ids) where ids.filter({ $0 == id }).count > 1 { out.append(.duplicate(id)) }
        if seats[0].count != seats[1].count { out.append(.unevenTeams) }
        return out
    }
    var isValid: Bool { issues.isEmpty }
    var firstEmptySeat: SeatRef? { seatOrder.first { self[$0] == nil } }

    subscript(seat: SeatRef) -> ShellPlayer? {
        guard seats.indices.contains(seat.team), seats[seat.team].indices.contains(seat.slot) else { return nil }
        return seats[seat.team][seat.slot]
    }

    /// Roster players not seated somewhere else (the seat's own occupant stays pickable).
    func pickablePlayers(for seat: SeatRef) -> [ShellPlayer] {
        rosterPlayers.filter { p in location(of: p).map { $0 == seat } ?? true }
    }

    var usedColors: Set<String> { Set(seats.flatMap { $0 }.compactMap { $0?.colorName }) }
    private var nextColor: String { ShellPalette.names.first { !usedColors.contains($0) } ?? ShellPalette.names[0] }

    // MARK: Editing

    func setPlayersPerTeam(_ n: Int) {
        let n = min(Self.maxPerTeam, max(1, n))
        guard n != playersPerTeam else { return }
        seats = seats.map { team in
            team.count > n ? Array(team.prefix(n)) : team + Array(repeating: nil, count: n - team.count)
        }
    }

    func assign(_ p: ShellPlayer, to seat: SeatRef) {
        guard isValid(seat) else { return }
        var s = seats
        if let from = location(of: p) { s[from.team][from.slot] = nil }
        s[seat.team][seat.slot] = p
        seats = s
    }

    func clear(_ seat: SeatRef) {
        guard isValid(seat) else { return }
        seats[seat.team][seat.slot] = nil
    }

    /// Session guest: memory only, never persisted, gone with the game.
    func addGuest(to seat: SeatRef) {
        guestCount += 1
        let g = ShellPlayer(id: UUID(), name: guestCount == 1 ? "Guest" : "Guest \(guestCount)",
                            symbol: "person.fill", colorName: nextColor, isGuest: true)
        assign(g, to: seat)
    }

    /// New roster player (persisted), seated immediately.
    func registerNew(name: String, to seat: SeatRef) throws {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(LobbyWire.maxNameLength))
        guard !trimmed.isEmpty else { throw SetupError.blankName }
        let symbol = ShellPalette.symbols[rosterPlayers.count % ShellPalette.symbols.count]
        let p = try roster.register(name: trimmed, symbol: symbol, colorName: nextColor)
        rosterPlayers = roster.allPlayers().filter { !$0.isGuest }
        assign(p, to: seat)
    }

    // MARK: Start

    @discardableResult
    func start() -> GameConfig? {
        guard !hasStarted else { return nil }
        guard isValid else { blockedStartCount += 1; return nil }
        hasStarted = true
        let cfg = GameConfig(ruleSet: ruleSet, tableSize: tableSize, teams: seats.map { $0.compactMap { $0 } },
                             sessionTag: isHosting ? LobbyWire.randomSessionTag() : nil)
        if isHosting { mesh?.announceStart(cfg) }
        onStart?(cfg)
        return cfg
    }

    // MARK: Hosting

    func beginHosting() {
        guard let mesh, !isHosting else { return }
        isHosting = true
        mesh.onEvent = { [weak self] e in
            switch e {
            case .phonesChanged(let phones): self?.joinedPhones = phones
            case .unavailable: self?.meshUnavailable = true
            case .sendFailed: self?.syncFailed = true
            default: break
            }
        }
        readvertise()
    }

    func endHosting() {
        guard isHosting else { return }
        isHosting = false
        mesh?.stopHosting()
        mesh?.onEvent = nil
        joinedPhones = []
        meshUnavailable = false
    }

    var advert: NearbyGame {
        NearbyGame(id: gameID, host: seats[0][0], ruleSet: ruleSet,
                   seatsFilled: seats.flatMap { $0 }.compactMap { $0 }.count, seatsTotal: playersPerTeam * 2)
    }

    // MARK: Private

    var lineup: LobbyLineup { LobbyLineup(ruleSet: ruleSet, tableSize: tableSize, seats: seats) }

    private func readvertise() {
        guard isHosting, let mesh else { return }
        syncFailed = false
        mesh.host(advert)
        mesh.publish(lineup: lineup)
    }

    private func isValid(_ s: SeatRef) -> Bool {
        seats.indices.contains(s.team) && seats[s.team].indices.contains(s.slot)
    }

    private func location(of p: ShellPlayer) -> SeatRef? {
        for t in 0..<seats.count {
            if let s = seats[t].firstIndex(where: { $0?.id == p.id }) { return SeatRef(team: t, slot: s) }
        }
        return nil
    }
}

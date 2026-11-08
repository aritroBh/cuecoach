import Foundation
import Observation
import Geometry
import Rules

/// Session lobby state (pages/screens-b.md §1): peers, identity, format, D17 lineups, rule vote, table size.
@MainActor @Observable
public final class LobbyModel {
    let localPeerID: String
    let localPlayer: LobbyPlayer
    let isHost: Bool

    private(set) var peers: [LobbyPeer]
    private(set) var nearbyHosts: [NearbyHost] = []
    private(set) var meshAvailability: MeshAvailability = .idle
    private(set) var isLoadingProfiles = false

    private(set) var format: GameFormat = .oneVsOne
    /// `teams[team][slot]`; nil = empty seat.
    private(set) var teams: [[LobbyPlayer?]] = [[nil], [nil]]
    /// Players pushed out by a smaller format. Never deleted.
    private(set) var bench: [LobbyPlayer] = []
    /// Peers mirror the host's lineup; until the first one arrives every seat is shown empty.
    private(set) var hasHostLineup: Bool

    private(set) var ballots: [String: RuleSetID] = [:]
    private(set) var tableSize: TableSize
    let measuredTableSize: TableSize?

    /// Increments on every blocked Start tap (drives the caution pulse + `.error` haptic).
    private(set) var blockedStartCount = 0
    /// Increments on every successful Start (`.success` haptic).
    private(set) var startCount = 0

    @ObservationIgnored private let profiles: any LobbyProfileStore
    @ObservationIgnored private let mesh: any LobbyMeshLink
    @ObservationIgnored var onStart: ((LobbyStartConfig) -> Void)?
    /// Session guests live in memory until Start, so rebuilding the model or abandoning the lobby writes nothing.
    @ObservationIgnored private var unsavedGuestIDs: Set<UUID> = []
    @ObservationIgnored private var guestCount = 0

    init(localPeerID: String, localPlayer: LobbyPlayer, isHost: Bool, profiles: any LobbyProfileStore,
         mesh: any LobbyMeshLink, peers: [LobbyPeer], measuredTableSize: TableSize? = nil) {
        self.localPeerID = localPeerID
        self.localPlayer = localPlayer
        self.isHost = isHost
        self.profiles = profiles
        self.mesh = mesh
        self.peers = peers.isEmpty
            ? [LobbyPeer(id: localPeerID, deviceName: "This phone", player: localPlayer, isHost: true, isLocal: true, status: .connected)]
            : peers
        self.measuredTableSize = measuredTableSize
        self.tableSize = measuredTableSize ?? .sevenFoot
        self.hasHostLineup = isHost
        guard isHost else { return }   // peers wait for `applyLineup`
        teams[0][0] = localPlayer
        if isSolo {
            teams[1][0] = makeLocalGuest()
        } else {
            let others = self.peers.filter { !$0.isLocal }.compactMap(\.player)
            for (seat, p) in zip(seatOrder.dropFirst(), others) { teams[seat.team][seat.slot] = p }
        }
    }

    // MARK: Derived

    var isSolo: Bool { peers.count <= 1 }
    var isFormatLocked: Bool { isSolo || !isHost }
    var canEditLineup: Bool { isHost }
    var localPeer: LobbyPeer? { peers.first { $0.isLocal } }

    /// Seats in D17 shooting order: A1, B1, A2, B2, …
    var seatOrder: [SeatRef] {
        (0..<format.playersPerTeam).flatMap { s in [SeatRef(team: 0, slot: s), SeatRef(team: 1, slot: s)] }
    }

    var shootingOrder: [LobbyPlayer?] { seatOrder.map { self[$0] } }
    var blockingSeat: SeatRef? { seatOrder.first { self[$0] == nil } }
    var canStart: Bool { isHost && blockingSeat == nil && teams[0].count == teams[1].count }

    var seatedPlayers: [LobbyPlayer] { teams.flatMap { $0 }.compactMap { $0 } }

    var usedColorNames: Set<String> {
        Set((seatedPlayers + bench + peers.compactMap(\.player)).map(\.colorName))
    }

    var nextFreeColorName: String {
        SBColor.avatarNames.first { !usedColorNames.contains($0) } ?? SBColor.avatarNames[0]
    }

    subscript(seat: SeatRef) -> LobbyPlayer? {
        guard teams.indices.contains(seat.team), teams[seat.team].indices.contains(seat.slot) else { return nil }
        return teams[seat.team][seat.slot]
    }

    func isHostPlayer(_ p: LobbyPlayer) -> Bool { peers.contains { $0.isHost && $0.player?.id == p.id } }
    func peer(for p: LobbyPlayer) -> LobbyPeer? { peers.first { $0.player?.id == p.id } }

    static func teamName(_ t: Int) -> String { t == 0 ? "A" : "B" }

    func accessibilityLabel(_ seat: SeatRef) -> String {
        let where_ = "team \(Self.teamName(seat.team)), seat \(seat.slot + 1)"
        guard let p = self[seat] else { return "Empty seat, \(where_)" }
        return "\(p.name), \(where_)" + (isHostPlayer(p) ? ", host" : "")
    }

    // MARK: Format

    func setFormat(_ f: GameFormat) {
        guard !isFormatLocked, f != format else { return }
        let n = f.playersPerTeam
        for t in 0..<2 {
            if teams[t].count > n {
                bench.append(contentsOf: teams[t][n...].compactMap { $0 })
                teams[t].removeSubrange(n...)
            } else {
                teams[t].append(contentsOf: Array(repeating: nil, count: n - teams[t].count))
            }
        }
        let raised = f.playersPerTeam > format.playersPerTeam
        format = f
        for seat in seatOrder where raised && self[seat] == nil && !bench.isEmpty {
            teams[seat.team][seat.slot] = bench.removeFirst()
        }
        broadcastLineup()
    }

    // MARK: Seat permissions

    /// Host: any seat. Peer: their own seat, or any empty seat while they are unseated.
    func canOpenIdentity(_ seat: SeatRef) -> Bool {
        guard isValid(seat) else { return false }
        if canEditLineup { return true }
        if self[seat]?.id == localPlayer.id { return true }
        return self[seat] == nil && location(of: localPlayer) == nil
    }

    /// Only the host registers players or adds guests (peers have no write path to the host's roster).
    var canCreatePlayers: Bool { canEditLineup }

    /// Who the identity sheet offers for a seat.
    func identityChoices(for seat: SeatRef) -> [LobbyPlayer] {
        guard canOpenIdentity(seat) else { return [] }
        return canEditLineup ? pickableProfiles : [localPlayer]
    }

    // MARK: Lineup editing (host; peers may only seat themselves)

    /// Assign a player to a seat. Moves them if already seated (swapping with the occupant); pulls them off the bench.
    /// Returns false (and changes nothing) when this phone may not make that change.
    @discardableResult
    func assign(_ player: LobbyPlayer, to seat: SeatRef) -> Bool {
        guard isValid(seat) else { return false }
        if !canEditLineup {
            guard player.id == localPlayer.id, canOpenIdentity(seat) else { return false }
            if self[seat]?.id == player.id { return true }
            teams[seat.team][seat.slot] = player   // optimistic; the host's next lineup is authoritative
            mesh.send(seatRequest: seat)
            return true
        }
        if let from = location(of: player) {
            if from == seat { return true }
            teams[from.team][from.slot] = self[seat]
        } else if let occupant = self[seat] {
            bench.append(occupant)
        }
        bench.removeAll { $0.id == player.id }
        teams[seat.team][seat.slot] = player
        broadcastLineup()
        return true
    }

    /// Drag-drop. Within a team: reorder; across teams: swap. Returns whether anything changed.
    @discardableResult
    func move(from: SeatRef, to: SeatRef) -> Bool {
        guard canEditLineup, isValid(from), isValid(to), from != to else { return false }
        if from.team == to.team {
            let p = teams[from.team].remove(at: from.slot)
            teams[to.team].insert(p, at: to.slot)
        } else {
            let a = self[from]
            teams[from.team][from.slot] = self[to]
            teams[to.team][to.slot] = a
        }
        broadcastLineup()
        return true
    }

    func moveUp(_ seat: SeatRef) { move(from: seat, to: SeatRef(team: seat.team, slot: max(0, seat.slot - 1))) }
    func moveDown(_ seat: SeatRef) {
        move(from: seat, to: SeatRef(team: seat.team, slot: min(format.playersPerTeam - 1, seat.slot + 1)))
    }
    func moveToOtherTeam(_ seat: SeatRef) {
        let other = 1 - seat.team
        let target = teams[other].firstIndex { $0 == nil } ?? seat.slot
        move(from: seat, to: SeatRef(team: other, slot: target))
    }

    func removeToBench(_ seat: SeatRef) {
        guard canEditLineup, let p = self[seat] else { return }
        teams[seat.team][seat.slot] = nil
        bench.append(p)
        broadcastLineup()
    }

    // MARK: Identity

    var pickableProfiles: [LobbyPlayer] { profiles.localProfiles() }

    func registerAndAssign(name: String, symbol: String, colorName: String, to seat: SeatRef) throws {
        guard canCreatePlayers, canOpenIdentity(seat) else { throw LobbyError.notAllowed }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LobbyError.blankName }
        let p = try profiles.register(name: trimmed, symbol: symbol, colorName: colorName)
        assign(p, to: seat)
    }

    /// Seats a session guest. Kept in memory; persisted as `isSessionGuest` only on Start.
    func assignGuest(to seat: SeatRef) throws {
        guard canCreatePlayers, canOpenIdentity(seat) else { throw LobbyError.notAllowed }
        assign(makeLocalGuest(), to: seat)
    }

    private func makeLocalGuest() -> LobbyPlayer {
        guestCount += 1
        let g = LobbyPlayer(id: UUID(), name: guestCount == 1 ? "Guest" : "Guest \(guestCount)", symbol: "person.fill",
                            colorName: nextFreeColorName, isGuest: true)
        unsavedGuestIDs.insert(g.id)
        return g
    }

    // MARK: Inbound lineup

    /// Peer side of `LobbyMeshLink.send(lineup:roster:format:tableSize:)`: mirror the host exactly.
    func applyLineup(_ ids: [[UUID?]], roster: [LobbyPlayer], format f: GameFormat, tableSize t: TableSize) {
        guard !isHost else { return }
        var known: [UUID: LobbyPlayer] = [:]
        for p in seatedPlayers + bench + peers.compactMap(\.player) + roster + [localPlayer] { known[p.id] = p }
        func player(_ id: UUID) -> LobbyPlayer {
            known[id] ?? LobbyPlayer(id: id, name: "Player", symbol: "person.fill", colorName: "")
        }
        let n = f.playersPerTeam
        teams = (0..<2).map { t in
            let row = ids.indices.contains(t) ? ids[t] : []
            return (0..<n).map { s in row.indices.contains(s) ? row[s].map(player) : nil }
        }
        let seated = Set(seatedPlayers.map(\.id))
        bench = roster.filter { !seated.contains($0.id) }
        format = f
        tableSize = t
        hasHostLineup = true
    }

    /// Host side of `LobbyMeshLink.send(seatRequest:)`: seat that peer's player if the seat is empty.
    @discardableResult
    func receiveSeatRequest(peerID: String, seat: SeatRef) -> Bool {
        guard isHost, isValid(seat), self[seat] == nil,
              let p = peers.first(where: { $0.id == peerID })?.player else { return false }
        return assign(p, to: seat)
    }

    // MARK: Votes

    var myVote: RuleSetID? { ballots[localPeerID] }
    var voteWinner: RuleSetID { Vote.winner(Array(ballots.values)) }
    func tally(_ r: RuleSetID) -> Int { ballots.values.filter { $0 == r }.count }

    func toggleVote(_ r: RuleSetID) {
        let new: RuleSetID? = myVote == r ? nil : r
        ballots[localPeerID] = new
        mesh.send(vote: new)
    }

    func receiveBallot(peerID: String, vote: RuleSetID?) { ballots[peerID] = vote }

    // MARK: Table

    func selectTable(_ s: TableSize) {
        guard isHost else { return }
        tableSize = s
        broadcastLineup()
    }

    /// Length relative to a 9-ft table (tiles are drawn to scale, 2:1).
    static func relativeLength(_ s: TableSize) -> Double { s.playingLength / TableSize.nineFoot.playingLength }

    // MARK: Mesh

    func host() { mesh.startHosting() }
    func browse() {
        mesh.startBrowsing()
        if meshAvailability != .unavailable { meshAvailability = .discovering }
    }
    func join(_ hostID: String) { mesh.join(hostID: hostID) }
    func setMeshAvailability(_ a: MeshAvailability) { meshAvailability = a }
    func setNearbyHosts(_ h: [NearbyHost]) { nearbyHosts = h }
    func setProfilesLoading(_ v: Bool) { isLoadingProfiles = v }
    func updatePeers(_ p: [LobbyPeer]) { peers = p }
    func updatePeerStatus(_ id: String, _ s: LobbyPeer.Status) {
        if let i = peers.firstIndex(where: { $0.id == id }) { peers[i].status = s }
    }

    // MARK: Start

    /// Returns the configuration if Start is allowed; otherwise records a blocked attempt.
    @discardableResult
    func start() -> LobbyStartConfig? {
        guard canStart else { blockedStartCount += 1; return nil }
        guard persistGuests() else { blockedStartCount += 1; return nil }
        let stored = teams.map { t -> StoredTeam in
            let ids = t.compactMap { $0?.id }
            return StoredTeam(memberIDs: ids, shootingOrder: ids)
        }
        let cfg = LobbyStartConfig(format: format, ruleSet: voteWinner, tableSize: tableSize, teams: stored)
        startCount += 1
        onStart?(cfg)
        return cfg
    }

    // MARK: Private

    /// Writes seated in-memory guests through the profile store and swaps in the stored identities.
    private func persistGuests() -> Bool {
        for t in 0..<2 {
            for s in teams[t].indices {
                guard let g = teams[t][s], unsavedGuestIDs.contains(g.id) else { continue }
                guard let stored = try? profiles.makeGuest(colorName: g.colorName) else { return false }
                unsavedGuestIDs.remove(g.id)
                teams[t][s] = stored
            }
        }
        return true
    }

    private func isValid(_ s: SeatRef) -> Bool {
        teams.indices.contains(s.team) && teams[s.team].indices.contains(s.slot)
    }

    private func location(of p: LobbyPlayer) -> SeatRef? {
        for t in 0..<2 { if let s = teams[t].firstIndex(where: { $0?.id == p.id }) { return SeatRef(team: t, slot: s) } }
        return nil
    }

    private func broadcastLineup() {
        guard isHost else { return }
        mesh.send(lineup: teams.map { $0.map { $0?.id } }, roster: seatedPlayers + bench, format: format, tableSize: tableSize)
    }
}

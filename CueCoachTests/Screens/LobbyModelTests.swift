import Foundation
import Testing
import Geometry
import Rules
@testable import CueCoach

@MainActor
@Suite struct LobbyModelTests {
    let me = LobbyPlayer(id: UUID(), name: "Ari", symbol: "figure.pool.swim", colorName: "teal")
    let sam = LobbyPlayer(id: UUID(), name: "Sam", symbol: "hare.fill", colorName: "orange")
    let ana = LobbyPlayer(id: UUID(), name: "Ana", symbol: "tortoise.fill", colorName: "pink")
    let bo = LobbyPlayer(id: UUID(), name: "Bo", symbol: "bolt.fill", colorName: "purple")

    func peers(_ n: Int) -> [LobbyPeer] {
        let players = [me, sam, ana, bo]
        return (0..<n).map { i in
            LobbyPeer(id: "p\(i)", deviceName: "Phone \(i)", player: players[i], isHost: i == 0,
                      isLocal: i == 0, status: .connected)
        }
    }

    func makeModel(peers n: Int = 4, isHost: Bool = true, measured: TableSize? = nil) -> (LobbyModel, InMemoryLobbyProfiles, RecordingLobbyMesh) {
        let store = InMemoryLobbyProfiles(profiles: [me])
        let mesh = RecordingLobbyMesh()
        let m = LobbyModel(localPeerID: "p0", localPlayer: me, isHost: isHost, profiles: store, mesh: mesh,
                           peers: peers(n), measuredTableSize: measured)
        return (m, store, mesh)
    }

    // MARK: Solo

    @Test func soloLocksFormatToOneVsOneWithGuestOpponent() {
        let (m, _, _) = makeModel(peers: 1)
        #expect(m.isFormatLocked)
        #expect(m.format == .oneVsOne)
        #expect(m.teams[0][0]?.id == me.id)
        #expect(m.teams[1][0]?.isGuest == true)
        #expect(m.canStart)
        m.setFormat(.twoVsTwo)
        #expect(m.format == .oneVsOne)
    }

    // MARK: Format + bench

    @Test func raisingFormatAddsEmptySeatsAndLowersPushesToBench() {
        let (m, _, _) = makeModel()
        m.setFormat(.twoVsTwo)
        #expect(m.teams.map(\.count) == [2, 2])
        m.assign(sam, to: SeatRef(team: 0, slot: 1))
        m.assign(ana, to: SeatRef(team: 1, slot: 1))
        m.setFormat(.oneVsOne)
        #expect(m.teams.map(\.count) == [1, 1])
        #expect(Set(m.bench.map(\.id)) == [sam.id, ana.id])
        m.setFormat(.twoVsTwo)
        #expect(m.bench.isEmpty)
        #expect(Set(m.teams.flatMap { $0 }.compactMap { $0?.id }) == [me.id, sam.id, ana.id])
    }

    @Test func neverMoreThanEightSeats() {
        let (m, _, _) = makeModel()
        m.setFormat(.fourVsFour)
        #expect(m.teams.flatMap { $0 }.count == 8)
    }

    // MARK: D17 order

    @Test func peersAreSeatedInOrderOnOpen() {
        let (m, _, _) = makeModel()
        #expect(m.teams[0][0]?.id == me.id)
        #expect(m.teams[1][0]?.id == sam.id)
        #expect(!m.isFormatLocked)
    }

    @Test func shootingOrderInterleavesTeams() {
        let (m, _, _) = makeModel()
        m.setFormat(.twoVsTwo)
        m.assign(sam, to: SeatRef(team: 1, slot: 0))
        m.assign(ana, to: SeatRef(team: 0, slot: 1))
        m.assign(bo, to: SeatRef(team: 1, slot: 1))
        #expect(m.shootingOrder.map { $0?.id } == [me.id, sam.id, ana.id, bo.id])
    }

    @Test func moveWithinTeamReorders() {
        let (m, _, _) = makeModel()
        m.setFormat(.twoVsTwo)
        m.assign(ana, to: SeatRef(team: 0, slot: 1))
        #expect(m.move(from: SeatRef(team: 0, slot: 1), to: SeatRef(team: 0, slot: 0)))
        #expect(m.teams[0].map { $0?.id } == [ana.id, me.id])
    }

    @Test func moveAcrossTeamsSwaps() {
        let (m, _, _) = makeModel()
        m.setFormat(.twoVsTwo)
        m.assign(sam, to: SeatRef(team: 1, slot: 0))
        m.move(from: SeatRef(team: 0, slot: 0), to: SeatRef(team: 1, slot: 0))
        #expect(m.teams[0][0]?.id == sam.id)
        #expect(m.teams[1][0]?.id == me.id)
    }

    @Test func accessibilityMoves() {
        let (m, _, _) = makeModel()
        m.setFormat(.twoVsTwo)
        m.assign(ana, to: SeatRef(team: 0, slot: 1))
        m.moveUp(SeatRef(team: 0, slot: 1))
        #expect(m.teams[0][0]?.id == ana.id)
        m.moveDown(SeatRef(team: 0, slot: 0))
        #expect(m.teams[0][1]?.id == ana.id)
        m.moveToOtherTeam(SeatRef(team: 0, slot: 1))
        #expect(m.teams[1].contains { $0?.id == ana.id })
        #expect(m.teams[0][1] == nil)
    }

    @Test func assigningSeatedPlayerMovesThemNotDuplicates() {
        let (m, _, _) = makeModel()
        m.setFormat(.twoVsTwo)
        m.assign(me, to: SeatRef(team: 1, slot: 1))
        let ids = m.teams.flatMap { $0 }.compactMap { $0?.id }
        #expect(ids.filter { $0 == me.id }.count == 1)
        #expect(m.teams[0][0] == nil)
        #expect(m.teams[1][1]?.id == me.id)
    }

    @Test func removeToBenchKeepsPlayer() {
        let (m, _, _) = makeModel()
        m.removeToBench(SeatRef(team: 0, slot: 0))
        #expect(m.teams[0][0] == nil)
        #expect(m.bench.map(\.id) == [me.id])
    }

    @Test func nonHostCannotEditLineup() {
        let (m, _, _) = makeModel(isHost: false)
        m.applyLineup([[me.id], [sam.id]], roster: [], format: .oneVsOne, tableSize: .sevenFoot)
        m.setFormat(.twoVsTwo)
        #expect(!m.canEditLineup)
        #expect(m.format == .oneVsOne)
        #expect(!m.move(from: SeatRef(team: 0, slot: 0), to: SeatRef(team: 1, slot: 0)))
        #expect(m.teams[0][0]?.id == me.id)
    }

    // MARK: Start

    @Test func startLockedUntilEverySeatFilledAndPointsAtBlocker() {
        let (m, _, _) = makeModel()
        m.setFormat(.twoVsTwo)
        m.assign(sam, to: SeatRef(team: 1, slot: 0))
        #expect(!m.canStart)
        #expect(m.blockingSeat == SeatRef(team: 0, slot: 1))
        #expect(m.start() == nil)
        #expect(m.blockedStartCount == 1)
        m.assign(ana, to: SeatRef(team: 0, slot: 1))
        m.assign(bo, to: SeatRef(team: 1, slot: 1))
        #expect(m.canStart)
        let cfg = m.start()
        #expect(cfg?.format == .twoVsTwo)
        #expect(cfg?.teams[0].shootingOrder == [me.id, ana.id])
        #expect(cfg?.teams[1].memberIDs == [sam.id, bo.id])
    }

    @Test func peersCannotStart() {
        let (m, _, _) = makeModel(peers: 2, isHost: false)
        #expect(!m.canStart)
    }

    // MARK: Votes

    @Test func voteToggleAndTallyUseVoteWinner() {
        let (m, _, mesh) = makeModel()
        #expect(m.voteWinner == .barEight)
        m.toggleVote(.wpaNine)
        #expect(m.myVote == .wpaNine)
        #expect(mesh.sentVotes.last == .some(.wpaNine))
        m.receiveBallot(peerID: "p1", vote: .wpaNine)
        m.receiveBallot(peerID: "p2", vote: .wpaEight)
        #expect(m.tally(.wpaNine) == 2)
        #expect(m.voteWinner == .wpaNine)
        m.toggleVote(.wpaNine)
        #expect(m.myVote == nil)
        #expect(mesh.sentVotes.last == .some(nil))
        // 1–1 tie → default Bar 8, matching Vote.winner
        #expect(m.voteWinner == Vote.winner([.wpaNine, .wpaEight]))
        #expect(m.voteWinner == .barEight)
    }

    // MARK: Table size

    @Test func measuredTablePreselected() {
        let (m, _, _) = makeModel(measured: .eightFoot)
        #expect(m.tableSize == .eightFoot)
        m.selectTable(.nineFoot)
        #expect(m.tableSize == .nineFoot)
        let (d, _, _) = makeModel()
        #expect(d.tableSize == .sevenFoot)
    }

    @Test func tableAspectAndRelativeLength() {
        #expect(LobbyModel.relativeLength(.nineFoot) == 1)
        #expect(LobbyModel.relativeLength(.sevenFoot) < LobbyModel.relativeLength(.eightFoot))
    }

    // MARK: Identity

    @Test func registerAndGuestGoThroughStore() throws {
        let (m, store, _) = makeModel()
        m.setFormat(.twoVsTwo)
        try m.registerAndAssign(name: "Kim", symbol: "flame.fill", colorName: "red", to: SeatRef(team: 1, slot: 1))
        #expect(store.profiles.contains { $0.name == "Kim" })
        #expect(m.teams[1][1]?.name == "Kim")
        try m.assignGuest(to: SeatRef(team: 1, slot: 0))
        let guest = try #require(m.teams[1][0])
        #expect(guest.isGuest)
        #expect(!m.usedColorNames.subtracting([guest.colorName]).contains(guest.colorName))
    }

    @Test func nextFreeColorSkipsUsed() {
        let (m, _, _) = makeModel()
        #expect(m.nextFreeColorName != me.colorName)
        #expect(m.nextFreeColorName != sam.colorName || !m.usedColorNames.contains(sam.colorName))
    }

    @Test func blankNameRejected() {
        let (m, _, _) = makeModel()
        #expect(throws: LobbyError.self) {
            try m.registerAndAssign(name: "  ", symbol: "flame.fill", colorName: "red", to: SeatRef(team: 1, slot: 0))
        }
    }

    // MARK: Peers

    @Test func lostPeerKeepsSeat() {
        let (m, _, _) = makeModel(peers: 2)
        m.assign(sam, to: SeatRef(team: 1, slot: 0))
        m.updatePeerStatus("p1", .lost)
        #expect(m.peers.first { $0.id == "p1" }?.status == .lost)
        #expect(m.teams[1][0]?.id == sam.id)
    }

    @Test func accessibilityLabelsForSeat() {
        let (m, _, _) = makeModel()
        m.setFormat(.twoVsTwo)
        m.assign(sam, to: SeatRef(team: 0, slot: 1))
        #expect(m.accessibilityLabel(SeatRef(team: 0, slot: 0)) == "Ari, team A, seat 1, host")
        #expect(m.accessibilityLabel(SeatRef(team: 0, slot: 1)) == "Sam, team A, seat 2")
        #expect(m.accessibilityLabel(SeatRef(team: 1, slot: 1)) == "Empty seat, team B, seat 2")
    }

    @Test func persistenceProfileStoreRegistersGuestAsSessionGuest() throws {
        let stack = try PersistenceStack(inMemory: true)
        stack.competitiveContext.insert(PlayerProfile(name: "Ari", avatarSymbol: "person.fill", avatarColor: "teal",
                                                      isLocalOwner: true))
        try stack.competitiveContext.save()
        let store = PersistenceLobbyProfiles(stack: stack)
        #expect(store.localProfiles().map(\.name) == ["Ari"])
        let g = try store.makeGuest(colorName: "red")
        #expect(g.isGuest)
        let k = try store.register(name: "Kim", symbol: "flame.fill", colorName: "blue")
        #expect(!k.isGuest)
        // guests are not listed as pickable local profiles
        #expect(store.localProfiles().map(\.name).sorted() == ["Ari", "Kim"])
    }

    // MARK: Inbound lineup (peer phones mirror the host)

    func peerModel(local: LobbyPlayer, localPeer: String, players: [LobbyPlayer]) -> (LobbyModel, InMemoryLobbyProfiles, RecordingLobbyMesh) {
        let store = InMemoryLobbyProfiles(profiles: [local])
        let mesh = RecordingLobbyMesh()
        let ps = players.enumerated().map { i, p in
            LobbyPeer(id: "p\(i)", deviceName: "Phone \(i)", player: p, isHost: i == 0, isLocal: "p\(i)" == localPeer,
                      status: .connected)
        }
        return (LobbyModel(localPeerID: localPeer, localPlayer: local, isHost: false, profiles: store, mesh: mesh, peers: ps),
                store, mesh)
    }

    @Test func peerStartsEmptyUntilHostLineupArrives() {
        let (p, _, _) = peerModel(local: sam, localPeer: "p1", players: [me, sam])
        #expect(!p.hasHostLineup)
        #expect(p.seatedPlayers.isEmpty)
        #expect(!p.canStart)
    }

    @Test func peerAppliesHostLineupAndMatchesHostOrder() throws {
        let (host, _, hostMesh) = makeModel()
        host.setFormat(.twoVsTwo)
        host.assign(ana, to: SeatRef(team: 0, slot: 1))
        host.assign(bo, to: SeatRef(team: 1, slot: 1))
        try host.assignGuest(to: SeatRef(team: 1, slot: 1))   // a host-side guest the peer has never seen
        host.selectTable(.nineFoot)
        let sent = try #require(hostMesh.lastLineup)

        let (peer, _, _) = peerModel(local: sam, localPeer: "p1", players: [me, sam, ana, bo])
        peer.applyLineup(sent.ids, roster: sent.roster, format: sent.format, tableSize: sent.tableSize)
        #expect(peer.hasHostLineup)
        #expect(peer.format == .twoVsTwo)
        #expect(peer.tableSize == .nineFoot)
        #expect(peer.shootingOrder.map { $0?.id } == host.shootingOrder.map { $0?.id })
        #expect(peer.shootingOrder.map { $0?.name } == host.shootingOrder.map { $0?.name })
        #expect(peer.teams[0][0]?.id == me.id)   // host's A1, not the local player
    }

    @Test func applyLineupIgnoredOnHost() {
        let (host, _, _) = makeModel()
        host.applyLineup([[sam.id], [me.id]], roster: [], format: .oneVsOne, tableSize: .nineFoot)
        #expect(host.teams[0][0]?.id == me.id)
    }

    // MARK: Seat permissions

    @Test func peerCanOnlySeatThemselvesInAnEmptySeat() {
        let (p, store, mesh) = peerModel(local: sam, localPeer: "p1", players: [me, sam])
        p.applyLineup([[me.id, nil], [nil, nil]], roster: [], format: .twoVsTwo, tableSize: .sevenFoot)
        let empty = SeatRef(team: 1, slot: 0)
        #expect(p.canOpenIdentity(empty))
        #expect(!p.canCreatePlayers)
        #expect(p.identityChoices(for: empty).map(\.id) == [sam.id])
        #expect(!p.assign(ana, to: empty))
        #expect(p.assign(sam, to: empty))
        #expect(mesh.seatRequests.last?.seat == empty)
        #expect(!p.canOpenIdentity(SeatRef(team: 1, slot: 1)))   // now seated: other empty seats are read-only
        #expect(!p.canOpenIdentity(SeatRef(team: 0, slot: 0)))   // someone else's seat
        #expect(p.canOpenIdentity(empty))                        // own seat
        #expect(throws: LobbyError.self) { try p.assignGuest(to: SeatRef(team: 1, slot: 1)) }
        #expect(store.profiles.count == 1)                       // no orphan guest row
    }

    @Test func hostSeatsAPeerOnRequestOnlyIntoAnEmptySeat() {
        let (m, _, _) = makeModel()
        m.setFormat(.twoVsTwo)
        m.removeToBench(SeatRef(team: 1, slot: 0))   // sam off
        #expect(m.receiveSeatRequest(peerID: "p1", seat: SeatRef(team: 1, slot: 1)))
        #expect(m.teams[1][1]?.id == sam.id)
        #expect(!m.receiveSeatRequest(peerID: "p1", seat: SeatRef(team: 0, slot: 0)))   // occupied
        #expect(m.teams[0][0]?.id == me.id)
    }

    // MARK: Guests are persisted only on Start

    @Test func soloGuestIsNotPersistedUntilStart() throws {
        let (m, store, _) = makeModel(peers: 1)
        #expect(store.profiles.filter(\.isGuest).isEmpty)
        let cfg = try #require(m.start())
        let guests = store.profiles.filter(\.isGuest)
        #expect(guests.count == 1)
        #expect(cfg.teams[1].memberIDs == [guests[0].id])
    }

    @Test func assignedGuestIsPersistedOnStartNotOnTap() throws {
        let (m, store, _) = makeModel(peers: 2)
        try m.assignGuest(to: SeatRef(team: 1, slot: 0))
        #expect(store.profiles.filter(\.isGuest).isEmpty)
        let cfg = try #require(m.start())
        #expect(store.profiles.filter(\.isGuest).count == 1)
        #expect(cfg.teams[1].memberIDs == store.profiles.filter(\.isGuest).map(\.id))
    }
}

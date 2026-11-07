import Foundation
import Testing
import Geometry
import Rules
@testable import CueCoach

@MainActor
@Suite struct GameSetupModelTests {
    let ari = ShellPlayer(id: UUID(), name: "Ari", symbol: "hare.fill", colorName: "teal")
    let sam = ShellPlayer(id: UUID(), name: "Sam", symbol: "bolt.fill", colorName: "orange")
    let ana = ShellPlayer(id: UUID(), name: "Ana", symbol: "leaf.fill", colorName: "pink")
    let bo = ShellPlayer(id: UUID(), name: "Bo", symbol: "flame.fill", colorName: "purple")

    func make(roster: [ShellPlayer]? = nil, measured: TableSize? = nil, manual: TableSize? = nil,
              rules: RuleSetID = .barEight, mesh: FakeGameLobbyMesh? = nil) -> (GameSetupModel, InMemoryRoster) {
        let store = InMemoryRoster(roster ?? [ari, sam, ana, bo])
        let m = GameSetupModel(roster: store, defaults: .init(ruleSet: rules, manualTable: manual),
                               measuredTable: measured, mesh: mesh)
        return (m, store)
    }

    // MARK: defaults

    @Test func defaultsToSinglesBarRulesAndSevenFoot() {
        let (m, _) = make()
        #expect(m.ruleSet == .barEight)
        #expect(m.playersPerTeam == 1)
        #expect(m.tableSize == .sevenFoot)
        #expect(m.seats == [[nil], [nil]])
    }

    @Test func rulesDefaultComesFromSettings() {
        let (m, _) = make(rules: .wpaNine)
        #expect(m.ruleSet == .wpaNine)
    }

    @Test func lidarMeasurementPreselectsTableOverManualDefault() {
        #expect(make(measured: .nineFoot, manual: .eightFoot).0.tableSize == .nineFoot)
        #expect(make(manual: .eightFoot).0.tableSize == .eightFoot)
        #expect(make(measured: .nineFoot).0.measuredTable == .nineFoot)
    }

    @Test func userCanOverrideTheTableAndRules() {
        let (m, _) = make(measured: .nineFoot)
        m.tableSize = .sevenFoot
        m.ruleSet = .wpaEight
        #expect(m.tableSize == .sevenFoot)
        #expect(m.ruleSet == .wpaEight)
    }

    // MARK: format + validation

    @Test func emptySeatsBlockStart() {
        let (m, _) = make()
        #expect(!m.isValid)
        #expect(m.issues.contains(.emptySeat(SeatRef(team: 0, slot: 0))))
        #expect(m.start() == nil)
        #expect(m.blockedStartCount == 1)
        #expect(m.firstEmptySeat == SeatRef(team: 0, slot: 0))
    }

    @Test func singlesWithTwoPlayersIsValid() {
        let (m, _) = make()
        m.assign(ari, to: SeatRef(team: 0, slot: 0))
        m.assign(sam, to: SeatRef(team: 1, slot: 0))
        #expect(m.isValid)
        let cfg = m.start()
        #expect(cfg?.teams == [[ari], [sam]])
        #expect(cfg?.ruleSet == .barEight)
        #expect(cfg?.tableSize == .sevenFoot)
    }

    @Test func assigningAPlayerAlreadySeatedMovesThemInsteadOfDuplicating() {
        let (m, _) = make()
        m.assign(ari, to: SeatRef(team: 0, slot: 0))
        m.assign(ari, to: SeatRef(team: 1, slot: 0))
        #expect(m.seats == [[nil], [ari]])
    }

    @Test func teamsGrowAndShrinkKeepingSeatedPlayers() {
        let (m, _) = make()
        m.assign(ari, to: SeatRef(team: 0, slot: 0))
        m.assign(sam, to: SeatRef(team: 1, slot: 0))
        m.setPlayersPerTeam(2)
        #expect(m.seats == [[ari, nil], [sam, nil]])
        #expect(!m.isValid)
        m.setPlayersPerTeam(1)
        #expect(m.seats == [[ari], [sam]])
    }

    @Test func teamSizeIsClampedToOneThroughFour() {
        let (m, _) = make()
        m.setPlayersPerTeam(9)
        #expect(m.playersPerTeam == 4)
        m.setPlayersPerTeam(0)
        #expect(m.playersPerTeam == 1)
    }

    @Test func clearSeatEmptiesIt() {
        let (m, _) = make()
        m.assign(ari, to: SeatRef(team: 0, slot: 0))
        m.clear(SeatRef(team: 0, slot: 0))
        #expect(m.seats[0][0] == nil)
    }

    // MARK: D17 rotation preview

    @Test func rotationPreviewFollowsD17Order() {
        let (m, _) = make()
        m.setPlayersPerTeam(2)
        m.assign(ari, to: SeatRef(team: 0, slot: 0))
        m.assign(ana, to: SeatRef(team: 0, slot: 1))
        m.assign(sam, to: SeatRef(team: 1, slot: 0))
        m.assign(bo, to: SeatRef(team: 1, slot: 1))
        #expect(m.seatOrder == [SeatRef(team: 0, slot: 0), SeatRef(team: 1, slot: 0),
                                SeatRef(team: 0, slot: 1), SeatRef(team: 1, slot: 1)])
        #expect(m.rotationPreview.map { $0?.name } == ["Ari", "Sam", "Ana", "Bo"])
        #expect(m.start()?.rotation.map(\.name) == ["Ari", "Sam", "Ana", "Bo"])
    }

    // MARK: guests

    @Test func guestsAreNeverWrittenToTheRoster() {
        let (m, store) = make(roster: [ari])
        m.addGuest(to: SeatRef(team: 1, slot: 0))
        #expect(m.seats[1][0]?.isGuest == true)
        #expect(store.players.count == 1)
        #expect(store.registerCount == 0)
        #expect(!m.rosterPlayers.contains { $0.isGuest })
    }

    @Test func guestsGetDistinctNamesAndColours() {
        let (m, _) = make()
        m.setPlayersPerTeam(2)
        m.addGuest(to: SeatRef(team: 0, slot: 0))
        m.addGuest(to: SeatRef(team: 1, slot: 0))
        let g1 = m.seats[0][0]!, g2 = m.seats[1][0]!
        #expect(g1.name == "Guest")
        #expect(g2.name == "Guest 2")
        #expect(g1.colorName != g2.colorName)
        #expect(g1.id != g2.id)
    }

    @Test func clearingAGuestDropsThemEntirely() {
        let (m, _) = make()
        m.addGuest(to: SeatRef(team: 0, slot: 0))
        m.clear(SeatRef(team: 0, slot: 0))
        #expect(m.seats[0][0] == nil)
        #expect(!m.pickablePlayers(for: SeatRef(team: 0, slot: 0)).contains { $0.isGuest })
    }

    @Test func newPlayerIsPersistedAndSeated() throws {
        let (m, store) = make(roster: [])
        try m.registerNew(name: "  Kim ", to: SeatRef(team: 0, slot: 0))
        #expect(store.players.map(\.name) == ["Kim"])
        #expect(m.seats[0][0]?.name == "Kim")
        #expect(m.seats[0][0]?.isGuest == false)
    }

    @Test func newPlayerNamesAreCapped() throws {
        let (m, store) = make(roster: [])
        try m.registerNew(name: String(repeating: "k", count: 120), to: SeatRef(team: 0, slot: 0))
        #expect(store.players.first?.name.count == 64)
    }

    @Test func blankNewPlayerNameIsRejected() {
        let (m, store) = make(roster: [])
        #expect(throws: SetupError.blankName) { try m.registerNew(name: "  ", to: SeatRef(team: 0, slot: 0)) }
        #expect(store.players.isEmpty)
    }

    @Test func pickableHidesPlayersSeatedElsewhere() {
        let (m, _) = make()
        m.assign(ari, to: SeatRef(team: 0, slot: 0))
        #expect(!m.pickablePlayers(for: SeatRef(team: 1, slot: 0)).contains(ari))
        #expect(m.pickablePlayers(for: SeatRef(team: 0, slot: 0)).contains(ari))
    }

    // MARK: hosting (joiners appear live)

    @Test func hostingAdvertisesAndJoinersAppearLive() {
        let mesh = FakeGameLobbyMesh()
        let (m, _) = make(mesh: mesh)
        m.beginHosting()
        #expect(mesh.hosting)
        mesh.emit(.phonesChanged([NearbyPhone(id: "p1", name: "Sam's phone")]))
        #expect(m.joinedPhones.map(\.id) == ["p1"])
        mesh.emit(.phonesChanged([]))
        #expect(m.joinedPhones.isEmpty)
    }

    @Test func startAnnouncesConfigToJoiners() {
        let mesh = FakeGameLobbyMesh()
        let (m, _) = make(mesh: mesh)
        m.beginHosting()
        m.assign(ari, to: SeatRef(team: 0, slot: 0))
        m.assign(sam, to: SeatRef(team: 1, slot: 0))
        let cfg = m.start()
        #expect(mesh.announced == cfg)
    }

    @Test func hostPublishesLineupOnEveryChange() {
        let mesh = FakeGameLobbyMesh()
        let (m, _) = make(mesh: mesh)
        m.beginHosting()
        #expect(mesh.lineup?.seats == [[nil], [nil]])
        m.assign(ari, to: SeatRef(team: 0, slot: 0))
        #expect(mesh.lineup?.seats == [[ari], [nil]])
        m.ruleSet = .wpaNine
        #expect(mesh.lineup?.ruleSet == .wpaNine)
        m.tableSize = .nineFoot
        #expect(mesh.lineup?.tableSize == .nineFoot)
        #expect(mesh.advert?.seatsFilled == 1)
    }

    @Test func notHostingPublishesNothing() {
        let mesh = FakeGameLobbyMesh()
        let (m, _) = make(mesh: mesh)
        m.assign(ari, to: SeatRef(team: 0, slot: 0))
        #expect(mesh.lineup == nil)
    }

    @Test func startIsOneShot() {
        let mesh = FakeGameLobbyMesh()
        let (m, _) = make(mesh: mesh)
        var starts = 0
        m.onStart = { _ in starts += 1 }
        m.beginHosting()
        m.assign(ari, to: SeatRef(team: 0, slot: 0))
        m.assign(sam, to: SeatRef(team: 1, slot: 0))
        let first = m.start()
        #expect(first != nil)
        #expect(m.start() == nil)
        #expect(starts == 1)
        #expect(mesh.announced == first)
    }

    @Test func hostSeesWhenLocalNetworkIsUnavailable() {
        let mesh = FakeGameLobbyMesh()
        let (m, _) = make(mesh: mesh)
        m.beginHosting()
        #expect(!m.meshUnavailable)
        mesh.emit(.unavailable)
        #expect(m.meshUnavailable)
        m.endHosting()
        #expect(!m.meshUnavailable)
    }

    @Test func endHostingStopsAdvertising() {
        let mesh = FakeGameLobbyMesh()
        let (m, _) = make(mesh: mesh)
        m.beginHosting()
        m.endHosting()
        #expect(!mesh.hosting)
    }
}

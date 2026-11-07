import Foundation
import Testing
import Geometry
import Rules
@testable import CueCoach

@MainActor
@Suite struct JoinNearbyModelTests {
    let host = ShellPlayer(id: UUID(), name: "Sam", symbol: "bolt.fill", colorName: "orange")
    var game: NearbyGame { NearbyGame(id: "g1", host: host, ruleSet: .wpaNine, seatsFilled: 1, seatsTotal: 2) }
    let kim = ShellPlayer(id: UUID(), name: "Kim", symbol: "leaf.fill", colorName: "teal")
    var config: GameConfig { GameConfig(ruleSet: .wpaNine, tableSize: .nineFoot, teams: [[host], [kim]]) }

    func make() -> (JoinNearbyModel, FakeGameLobbyMesh) {
        let mesh = FakeGameLobbyMesh()
        return (JoinNearbyModel(mesh: mesh), mesh)
    }

    @Test func appearingStartsBrowsingAndSearches() {
        let (m, mesh) = make()
        m.appear()
        #expect(mesh.browsing)
        #expect(m.state == .searching)
    }

    @Test func gamesListUpdatesLive() {
        let (m, mesh) = make()
        m.appear()
        mesh.emit(.gamesChanged([game]))
        #expect(m.games == [game])
        mesh.emit(.gamesChanged([]))
        #expect(m.games.isEmpty)
        #expect(m.state == .searching)
    }

    @Test func joinGoesJoiningThenJoined() {
        let (m, mesh) = make()
        m.appear()
        mesh.emit(.gamesChanged([game]))
        m.join(game)
        #expect(m.state == .joining(game))
        #expect(mesh.joined == ["g1"])
        mesh.emit(.joined(gameID: "g1"))
        #expect(m.state == .joined(game))
    }

    @Test func fullLobbyIsShownAndCanGoBackToList() {
        let (m, mesh) = make()
        m.appear()
        mesh.emit(.gamesChanged([game]))
        m.join(game)
        mesh.emit(.rejectedFull(gameID: "g1"))
        #expect(m.state == .full(game))
        m.backToList()
        #expect(m.state == .searching)
        #expect(m.games == [game])
    }

    @Test func hostLeftWhileWaitingIsShown() {
        let (m, mesh) = make()
        m.appear()
        mesh.emit(.gamesChanged([game]))
        m.join(game)
        mesh.emit(.joined(gameID: "g1"))
        mesh.emit(.hostLeft(gameID: "g1"))
        #expect(m.state == .hostLeft(game))
    }

    @Test func hostLeftForAnotherGameIsIgnored() {
        let (m, mesh) = make()
        m.appear()
        mesh.emit(.gamesChanged([game]))
        m.join(game)
        mesh.emit(.joined(gameID: "g1"))
        mesh.emit(.hostLeft(gameID: "other"))
        #expect(m.state == .joined(game))
    }

    @Test func hostStartingTheGameStartsLiveOnThisPhone() {
        let (m, mesh) = make()
        var started: GameConfig?
        m.onStart = { started = $0 }
        m.appear()
        mesh.emit(.gamesChanged([game]))
        m.join(game)
        mesh.emit(.joined(gameID: "g1"))
        mesh.emit(.started(gameID: "g1", config))
        #expect(started == config)
    }

    @Test func startOfAGameWeDidNotJoinIsIgnored() {
        let (m, mesh) = make()
        var started: GameConfig?
        m.onStart = { started = $0 }
        m.appear()
        mesh.emit(.started(gameID: "g1", config))
        #expect(started == nil)
    }

    @Test func hostLineupSyncsWhileWaiting() {
        let (m, mesh) = make()
        m.appear()
        mesh.emit(.gamesChanged([game]))
        m.join(game)
        mesh.emit(.joined(gameID: "g1"))
        mesh.emit(.lineupChanged(gameID: "g1", LobbyLineup(ruleSet: .wpaNine, tableSize: .nineFoot, seats: [[host], [nil]])))
        #expect(m.lineup?.seats == [[host], [nil]])
        mesh.emit(.lineupChanged(gameID: "g1", LobbyLineup(ruleSet: .wpaNine, tableSize: .nineFoot, seats: [[host], [kim]])))
        #expect(m.lineup?.rotation.map(\.name) == ["Sam", "Kim"])
        mesh.emit(.lineupChanged(gameID: "other", LobbyLineup(ruleSet: .barEight, tableSize: .sevenFoot, seats: [[nil], [nil]])))
        #expect(m.lineup?.ruleSet == .wpaNine)
    }

    @Test func leavingClearsTheLineup() {
        let (m, mesh) = make()
        m.appear()
        m.join(game)
        mesh.emit(.joined(gameID: "g1"))
        mesh.emit(.lineupChanged(gameID: "g1", LobbyLineup(ruleSet: .wpaNine, tableSize: .nineFoot, seats: [[host], [nil]])))
        m.backToList()
        #expect(m.lineup == nil)
    }

    @Test func permissionDeniedShowsUnavailable() {
        let (m, mesh) = make()
        m.appear()
        mesh.emit(.unavailable)
        #expect(m.state == .unavailable)
    }

    @Test func disappearingLeavesAndStopsBrowsing() {
        let (m, mesh) = make()
        m.appear()
        m.join(game)
        m.disappear()
        #expect(!mesh.browsing)
        #expect(mesh.leaveCount == 1)
    }

    @Test func cancelWhileJoiningLeaves() {
        let (m, mesh) = make()
        m.appear()
        m.join(game)
        m.backToList()
        #expect(mesh.leaveCount == 1)
        #expect(m.state == .searching)
    }
}

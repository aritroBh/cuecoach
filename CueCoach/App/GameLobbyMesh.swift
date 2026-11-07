import Foundation
import Rules

/// A game hosted on a nearby phone, as the Join screen lists it.
struct NearbyGame: Identifiable, Hashable, Sendable {
    var id: String
    var host: ShellPlayer?
    var ruleSet: RuleSetID
    var seatsFilled: Int
    var seatsTotal: Int
}

/// A phone that joined this host (one more camera angle).
struct NearbyPhone: Identifiable, Hashable, Sendable, Codable {
    var id: String
    var name: String?
}

enum LobbyEvent: Hashable, Sendable {
    case gamesChanged([NearbyGame])
    case joined(gameID: String)
    case rejectedFull(gameID: String)
    case hostLeft(gameID: String)
    case started(gameID: String, GameConfig)
    /// The host changed rules, table or seats (joiners mirror it while waiting).
    case lineupChanged(gameID: String, LobbyLineup)
    /// Local network permission denied or MPC failed to start.
    case unavailable
    /// Host side: phones that joined this game.
    case phonesChanged([NearbyPhone])
    /// Host side: a lineup/start message could not be sent (rejected by limits or MPC error).
    case sendFailed
}

/// What the app shell needs from the mesh to host or join a game (MultipeerConnectivity only, zero network).
/// The mesh module (`MeshSession`) implements it; until it merges, `OfflineGameLobby` stands in on device and
/// `FakeGameLobbyMesh` in tests and UI tests. Events are delivered on the main actor.
@MainActor protocol GameLobbyMesh: AnyObject {
    var onEvent: ((LobbyEvent) -> Void)? { get set }
    func browse()
    func stopBrowsing()
    func join(gameID: String)
    func leave()
    func host(_ advert: NearbyGame)
    func stopHosting()
    func publish(lineup: LobbyLineup)
    func announceStart(_ config: GameConfig)
}

/// One-phone mode: nothing nearby, hosting is silent. Everything works with one phone (SPEC §5.7).
@MainActor final class OfflineGameLobby: GameLobbyMesh {
    var onEvent: ((LobbyEvent) -> Void)?
    func browse() {}
    func stopBrowsing() {}
    func join(gameID: String) {}
    func leave() {}
    func host(_ advert: NearbyGame) {}
    func stopHosting() {}
    func publish(lineup: LobbyLineup) {}
    func announceStart(_ config: GameConfig) {}
}

/// Recording fake for unit tests; also scripted for XCUITests (`ShellLaunch`).
@MainActor final class FakeGameLobbyMesh: GameLobbyMesh {
    var onEvent: ((LobbyEvent) -> Void)?
    private(set) var browsing = false
    private(set) var hosting = false
    private(set) var joined: [String] = []
    private(set) var leaveCount = 0
    private(set) var advert: NearbyGame?
    private(set) var announced: GameConfig?
    private(set) var lineup: LobbyLineup?
    /// Scripted reactions (UI tests). Each runs after `delay` seconds.
    var onBrowse: [(Double, LobbyEvent)] = []
    var onJoin: [(Double, LobbyEvent)] = []
    var onHost: [(Double, LobbyEvent)] = []

    func emit(_ e: LobbyEvent) { onEvent?(e) }

    func browse() { browsing = true; play(onBrowse) }
    func stopBrowsing() { browsing = false }
    func join(gameID: String) { joined.append(gameID); play(onJoin) }
    func leave() { leaveCount += 1 }
    func host(_ advert: NearbyGame) {
        let first = !hosting
        hosting = true
        self.advert = advert
        if first { play(onHost) }
    }
    func stopHosting() { hosting = false }
    func publish(lineup: LobbyLineup) { self.lineup = lineup }
    func announceStart(_ config: GameConfig) { announced = config }

    private func play(_ script: [(Double, LobbyEvent)]) {
        for (delay, e) in script {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                self?.emit(e)
            }
        }
    }
}

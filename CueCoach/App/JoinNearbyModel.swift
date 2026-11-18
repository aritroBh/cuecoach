import Foundation
import Observation

/// Join nearby: browse games hosted on nearby phones, join one, wait for the host to start.
@MainActor @Observable
final class JoinNearbyModel {
    enum State: Hashable {
        case searching
        case joining(NearbyGame)
        case joined(NearbyGame)
        case full(NearbyGame)
        case hostLeft(NearbyGame)
        case unavailable
    }

    private(set) var state: State = .searching
    private(set) var games: [NearbyGame] = []
    /// The joined host's lineup, mirrored live while waiting.
    private(set) var lineup: LobbyLineup?
    @ObservationIgnored private let mesh: any GameLobbyMesh
    @ObservationIgnored var onStart: ((GameConfig) -> Void)?
    /// A duplicate start message must not open a second Live.
    @ObservationIgnored private var didStart = false

    init(mesh: any GameLobbyMesh) { self.mesh = mesh }

    func appear() {
        mesh.onEvent = { [weak self] in self?.handle($0) }
        state = .searching
        mesh.browse()
    }

    func disappear() {
        leaveIfInGame()
        mesh.stopBrowsing()
        mesh.onEvent = nil
    }

    func join(_ g: NearbyGame) {
        didStart = false
        state = .joining(g)
        mesh.join(gameID: g.id)
    }

    func backToList() {
        leaveIfInGame()
        lineup = nil
        state = .searching
    }

    var currentGame: NearbyGame? {
        switch state {
        case .joining(let g), .joined(let g), .full(let g), .hostLeft(let g): g
        case .searching, .unavailable: nil
        }
    }

    func handle(_ e: LobbyEvent) {
        switch e {
        case .gamesChanged(let list):
            games = list
        case .joined(let id):
            if case .joining(let g) = state, g.id == id { state = .joined(g) }
        case .rejectedFull(let id):
            if case .joining(let g) = state, g.id == id { state = .full(g) }
        case .hostLeft(let id):
            switch state {
            case .joining(let g) where g.id == id, .joined(let g) where g.id == id: state = .hostLeft(g)
            default: break
            }
        case .started(let id, let config):
            guard !didStart, case .joined(let g) = state, g.id == id else { return }
            didStart = true
            onStart?(config)
        case .unavailable:
            state = .unavailable
        case .lineupChanged(let id, let l):
            if currentGame?.id == id { lineup = l }
        case .phonesChanged, .sendFailed:
            break
        }
    }

    private func leaveIfInGame() {
        switch state {
        case .joining, .joined: mesh.leave()
        default: break
        }
    }
}

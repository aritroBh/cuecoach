#if DEBUG
import Foundation
import Geometry
import Rules
import Engine

/// Debug-only launch arguments for XCUITests (never used in release builds):
///   -appshell.uitest                in-memory roster (Ari, Sam, Ana, Bo), settings, isolated defaults
///   -appshell.fakeMesh=<scenario>   games | full | hostLeft | denied | host
///   -appshell.measured=<size>       sevenFoot | eightFoot | nineFoot (LiDAR stand-in)
///   -appshell.reduceMotion          force Reduce Motion
///   -appshell.demoShot              rate one shot ~2 s after a game starts (badge screenshot)
enum ShellLaunch {
    static func value(_ key: String, _ args: [String]) -> String? {
        args.first { $0.hasPrefix("-appshell.\(key)=") }.map { String($0.dropFirst("-appshell.\(key)=".count)) }
    }

    @MainActor static func environment(_ args: [String]) -> ShellEnvironment? {
        guard args.contains("-appshell.uitest") else { return nil }
        let suite = "cc.appshell.uitest"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let roster = InMemoryRoster([
            ShellPlayer(id: UUID(), name: "Ari", symbol: "hare.fill", colorName: "teal"),
            ShellPlayer(id: UUID(), name: "Sam", symbol: "bolt.fill", colorName: "orange"),
            ShellPlayer(id: UUID(), name: "Ana", symbol: "leaf.fill", colorName: "pink"),
            ShellPlayer(id: UUID(), name: "Bo", symbol: "flame.fill", colorName: "purple"),
        ])
        if let m = value("measured", args) { defaults.set(m, forKey: StoredTableMeasurement.key) }
        let env = ShellEnvironment(roster: roster, owners: InMemoryOwnerStore(owner: nil),
                                   settings: InMemorySettingsStore(hasRecognitionData: false),
                                   mesh: fakeMesh(value("fakeMesh", args)),
                                   measurement: StoredTableMeasurement(defaults: defaults), defaults: defaults)
        env.reduceMotion = args.contains("-appshell.reduceMotion")
        return env
    }

    @MainActor static func fakeMesh(_ scenario: String?) -> any GameLobbyMesh {
        guard let scenario else { return OfflineGameLobby() }
        let sam = ShellPlayer(id: UUID(), name: "Sam", symbol: "bolt.fill", colorName: "orange")
        let kim = ShellPlayer(id: UUID(), name: "Kim", symbol: "leaf.fill", colorName: "green")
        let g1 = NearbyGame(id: "g1", host: sam, ruleSet: .wpaNine, seatsFilled: 1, seatsTotal: 2)
        let g2 = NearbyGame(id: "g2", host: kim, ruleSet: .barEight, seatsFilled: 3, seatsTotal: 4)
        let cfg = GameConfig(ruleSet: .wpaNine, tableSize: .nineFoot,
                             teams: [[sam], [ShellPlayer(id: UUID(), name: "Ari", symbol: "hare.fill", colorName: "teal")]])
        let m = FakeGameLobbyMesh()
        let list: [(Double, LobbyEvent)] = [(0.8, .gamesChanged([g1, g2]))]
        switch scenario {
        case "games": m.onBrowse = list; m.onJoin = [(0.8, .joined(gameID: "g1")), (3.0, .started(gameID: "g1", cfg))]
        case "full": m.onBrowse = list; m.onJoin = [(0.8, .rejectedFull(gameID: "g1"))]
        case "hostLeft": m.onBrowse = list; m.onJoin = [(0.8, .joined(gameID: "g1")), (2.0, .hostLeft(gameID: "g1"))]
        case "denied": m.onBrowse = [(0.3, .unavailable)]
        case "host":
            m.onHost = [(1.0, .phonesChanged([NearbyPhone(id: "p1", name: "Sam's phone")])),
                        (2.0, .phonesChanged([NearbyPhone(id: "p1", name: "Sam's phone"), NearbyPhone(id: "p2", name: "Kim's phone")]))]
        default: break
        }
        return m
    }

    @MainActor static func demoShotIfRequested(_ game: GameSessionModel?) async {
        guard let game, ProcessInfo.processInfo.arguments.contains("-appshell.demoShot") else { return }
        try? await Task.sleep(for: .seconds(2))
        game.shotSettled(rating: .great, turnPasses: true)
    }
}
#endif

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
///   -appshell.realMesh              real MPC lobby + mesh (two-device XCUITest)
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
                                   mesh: args.contains("-appshell.realMesh")
                                       ? MPCGameLobby(localName: { value("name", args) ?? "Phone" })
                                       : fakeMesh(value("fakeMesh", args)),
                                   measurement: StoredTableMeasurement(defaults: defaults), defaults: defaults)
        env.reduceMotion = args.contains("-appshell.reduceMotion")
        if !args.contains("-appshell.realMesh") { env.meshFactory = nil }
        if let name = value("name", args) { _ = try? env.owners.createOwner(name: name, symbol: "person.fill", colorName: "blue") }
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
        case "games":
            let half = LobbyLineup(ruleSet: .wpaNine, tableSize: .nineFoot, seats: [[sam], [nil]])
            let full = LobbyLineup(ruleSet: .wpaNine, tableSize: .nineFoot, seats: cfg.teams.map { $0.map(Optional.some) })
            m.onBrowse = list
            m.onJoin = [(0.8, .joined(gameID: "g1")), (1.0, .lineupChanged(gameID: "g1", half)),
                        (2.5, .lineupChanged(gameID: "g1", full)), (5.0, .started(gameID: "g1", cfg))]
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

#if DEBUG
import SwiftUI
import UIKit

/// `-appshell.autopilot=host|join` (with -appshell.uitest -appshell.realMesh): drives the real MPC lobby
/// without touch input, printing each step to stdout (`devicectl device process launch --console`).
/// Used for the two-phone test when UI automation is unavailable on a phone.
enum ShellAutopilot {
    @MainActor static func run(env: ShellEnvironment, router: AppRouter) async {
        let args = ProcessInfo.processInfo.arguments
        guard let role = ShellLaunch.value("autopilot", args) else { return }
        func log(_ s: String) { print("AUTOPILOT \(role): \(s)"); fflush(stdout) }
        log("start")
        UIApplication.shared.isIdleTimerDisabled = true   // keep the phone awake for the unattended run
        if role == "host" {
            let m = env.setupModel()
            let r = env.roster.allPlayers()
            m.assign(r[0], to: SeatRef(team: 0, slot: 0))
            m.assign(r[1], to: SeatRef(team: 1, slot: 0))
            m.ruleSet = .wpaNine
            m.beginHosting()
            log("hosting \(m.advert.id) lineup \(m.rotationPreview.map { $0?.name ?? "-" })")
            var seen = 0
            for _ in 0..<480 {
                if m.joinedPhones.count != seen { seen = m.joinedPhones.count; log("phones \(m.joinedPhones.map { $0.name ?? "?" })") }
                if seen > 0 { break }
                try? await Task.sleep(for: .milliseconds(500))
            }
            guard seen > 0 else { log("FAIL no joiner"); return }
            try? await Task.sleep(for: .seconds(4))
            m.assign(r[2], to: SeatRef(team: 0, slot: 0))   // lineup change after the join must sync too
            log("changed seat A1 -> \(r[2].name)")
            try? await Task.sleep(for: .seconds(4))
            guard let cfg = m.start() else { log("FAIL start blocked"); return }
            log("started tag \(cfg.sessionTag.map(String.init) ?? "nil") rotation \(cfg.rotation.map(\.name))")
            router.startGame(cfg)
            m.endHosting()
            await reportMesh(router: router, log: log)
        } else {
            let j = JoinNearbyModel(mesh: env.mesh)
            j.onStart = { cfg in
                log("START received tag \(cfg.sessionTag.map(String.init) ?? "nil") rules \(cfg.ruleSet.rawValue) rotation \(cfg.rotation.map(\.name))")
                router.startGame(cfg)
            }
            j.appear()
            var joined = false
            var lastLineup: LobbyLineup?
            var lastState = j.state
            for _ in 0..<600 {
                if j.state != lastState { lastState = j.state; log("state \(j.state)") }
                if !joined, let g = j.games.first {
                    log("found \(g.host?.name ?? "?") \(g.ruleSet.rawValue) \(g.seatsFilled)/\(g.seatsTotal)")
                    j.join(g); joined = true
                }
                if j.lineup != lastLineup, let l = j.lineup {
                    lastLineup = l
                    log("lineup \(l.ruleSet.rawValue) \(l.rotation.map(\.name))")
                }
                if case .live? = router.stage { break }
                try? await Task.sleep(for: .milliseconds(500))
            }
            guard case .live? = router.stage else { log("FAIL never started (state \(j.state), games \(j.games.count))"); return }
            await reportMesh(router: router, log: log)
        }
    }

    @MainActor static func reportMesh(router: AppRouter, log: (String) -> Void) async {
        for i in 0..<30 {
            try? await Task.sleep(for: .seconds(1))
            if case .live(let s)? = router.stage, let link = s.game?.mesh {
                if link.peerCount > 1 || i == 29 { log("mesh peers \(link.peerCount)"); if link.peerCount > 1 { break } }
            }
        }
        log("done")
    }
}
#endif

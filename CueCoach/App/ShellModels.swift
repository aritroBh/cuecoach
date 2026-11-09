import Foundation
import Geometry
import Rules
import Training

/// A player who can take a seat: an on-device roster profile or a session guest.
/// Guests live only in memory for one game; they are never written to SwiftData.
struct ShellPlayer: Identifiable, Hashable, Sendable, Codable {
    var id: UUID
    var name: String
    var symbol: String
    var colorName: String
    var isGuest = false
}

/// Everything Live needs to run a game. Built by New game (host) or received from the host (joiner).
struct GameConfig: Hashable, Sendable, Codable {
    var ruleSet: RuleSetID
    var tableSize: TableSize
    /// `teams[team][slot]`, team 0 = A, 1 = B.
    var teams: [[ShellPlayer]]
    /// Mesh session for this game (MultipeerMeshSession `sessionTag`); nil = this phone only.
    var sessionTag: UInt16? = nil

    var playersPerTeam: Int { teams.map(\.count).max() ?? 0 }

    /// D17 shooting order: A1, B1, A2, B2, …
    var rotation: [ShellPlayer] {
        (0..<playersPerTeam).flatMap { slot in teams.compactMap { $0.indices.contains(slot) ? $0[slot] : nil } }
    }

    func team(of player: ShellPlayer) -> Int { teams.firstIndex { $0.contains(player) } ?? 0 }
}

/// Mirrors the capture worker's `LiveMode { case game; case training(level: Int) }` (D24) so the switch to
/// `LiveScreen(mode:)` is one line in `LiveScreenAdapter`.
enum ShellLiveMode: Hashable, Sendable {
    case game
    case training(level: Int)

    static func training(_ level: AssistLevel) -> ShellLiveMode { .training(level: level.rawValue) }

    /// Turn discs exist only in Game; Training is solo.
    var showsTurnChrome: Bool { self == .game }
}

/// App-wide defaults the setup screen starts from (Settings owns the values).
struct SetupDefaults: Equatable, Sendable {
    var ruleSet: RuleSetID = .barEight
    var manualTable: TableSize?

    static func fromSettings(_ d: UserDefaults = .standard) -> SetupDefaults {
        SetupDefaults(ruleSet: d.string(forKey: SettingsKeys.ruleSet).flatMap(RuleSetID.init(rawValue:)) ?? .barEight,
                      manualTable: d.string(forKey: SettingsKeys.tableSize).flatMap(TableSize.init(rawValue:)))
    }
}

enum SetupError: Error, Equatable { case blankName, notOwner }

/// Colours for avatars, in the order guests and new players take them.
enum ShellPalette {
    static let names = AX.avatarNames
    static let symbols = ["hare.fill", "bolt.fill", "leaf.fill", "flame.fill", "star.fill", "moon.fill",
                          "tortoise.fill", "bird.fill"]
}

/// The host's lineup as joiners see it while they wait (seats may be empty).
struct LobbyLineup: Hashable, Sendable, Codable {
    var ruleSet: RuleSetID
    var tableSize: TableSize
    var seats: [[ShellPlayer?]]
    /// D17 order of the seated players.
    var rotation: [ShellPlayer] {
        let n = seats.map(\.count).max() ?? 0
        return (0..<n).flatMap { slot in seats.compactMap { $0.indices.contains(slot) ? $0[slot] : nil } }
    }
}

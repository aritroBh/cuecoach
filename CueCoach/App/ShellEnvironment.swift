import Foundation
import Geometry
import Rules

/// Last table size the calibrator measured (LiDAR, D12). The Live owner writes `cc.table.measured`;
/// until then this returns nil and setup falls back to Settings' manual size, then 7 ft (D14).
struct StoredTableMeasurement: TableMeasurementSource {
    static let key = "cc.table.measured"
    var defaults: UserDefaults = .standard
    var measured: TableSize? { defaults.string(forKey: Self.key).flatMap(TableSize.init(rawValue:)) }
}

/// Dependencies the shell hands to its screens. Production = SwiftData + one-phone lobby; UI tests = in-memory fakes.
@MainActor final class ShellEnvironment {
    let roster: any RosterStore
    let owners: any OwnerStore
    let settings: any SettingsStore
    let mesh: any GameLobbyMesh
    let measurement: any TableMeasurementSource
    let defaults: UserDefaults
    var reduceMotion = false
    var noLoops = false
    var meshFactory: ((UInt16) -> any GameMeshLink)? = { MeshGameLink(sessionTag: $0) }

    init(roster: any RosterStore, owners: any OwnerStore, settings: any SettingsStore, mesh: any GameLobbyMesh,
         measurement: any TableMeasurementSource, defaults: UserDefaults) {
        self.roster = roster; self.owners = owners; self.settings = settings; self.mesh = mesh
        self.measurement = measurement; self.defaults = defaults
    }

    /// Launch outcome. The on-disk store failing to open is an error state: never a silent in-memory store whose
    /// games vanish on quit, and never an automatic delete of the store (review finding 6).
    enum Boot {
        case ready(ShellEnvironment)
        case storeUnavailable
        var environment: ShellEnvironment? { if case .ready(let e) = self { e } else { nil } }
    }

    /// `makeStack` is the seam tests use to make the store fail.
    static func production(makeStack: () throws -> PersistenceStack = { try PersistenceStack() }) -> Boot {
        guard let stack = try? makeStack() else { return .storeUnavailable }
        let owners = PersistenceOwnerStore(stack: stack)
        return .ready(ShellEnvironment(roster: PersistenceRoster(stack: stack), owners: owners,
                                       settings: PersistenceSettingsStore(stack: stack),
                                       mesh: MPCGameLobby(localName: { owners.owner?.name ?? "Phone" }),
                                       measurement: StoredTableMeasurement(), defaults: .standard))
    }

    static func current(_ args: [String] = ProcessInfo.processInfo.arguments) -> Boot {
        #if DEBUG
        if let env = ShellLaunch.environment(args) { return .ready(env) }
        #endif
        return production()
    }

    func setupModel() -> GameSetupModel {
        GameSetupModel(roster: roster, defaults: .fromSettings(defaults), measuredTable: measurement.measured, mesh: mesh)
    }
}

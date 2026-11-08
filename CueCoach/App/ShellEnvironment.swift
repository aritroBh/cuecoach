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

    static func production() -> ShellEnvironment {
        let stack = (try? PersistenceStack()) ?? (try! PersistenceStack(inMemory: true))
        let owners = PersistenceOwnerStore(stack: stack)
        return ShellEnvironment(roster: PersistenceRoster(stack: stack), owners: owners,
                                settings: PersistenceSettingsStore(stack: stack),
                                mesh: MPCGameLobby(localName: { owners.owner?.name ?? "Phone" }),
                                measurement: StoredTableMeasurement(), defaults: .standard)
    }

    static func current(_ args: [String] = ProcessInfo.processInfo.arguments) -> ShellEnvironment {
        #if DEBUG
        if let env = ShellLaunch.environment(args) { return env }
        #endif
        return production()
    }

    func setupModel() -> GameSetupModel {
        GameSetupModel(roster: roster, defaults: .fromSettings(defaults), measuredTable: measurement.measured, mesh: mesh)
    }
}

import Foundation
import Observation
import UIKit

/// The running game's mesh (real `MultipeerMeshSession`, tag agreed in the lobby). Phones in the roster are
/// camera angles; Live consumes the session once it is wired (see report: Live owner).
@MainActor protocol GameMeshLink: AnyObject {
    var peerCount: Int { get }
    /// True once the session has fully stopped (transport closed).
    var isStopped: Bool { get }
    func start()
    func stop()
}

@MainActor @Observable final class MeshGameLink: GameMeshLink {
    private(set) var peerCount = 1
    private(set) var isStopped = false
    @ObservationIgnored private let session: MultipeerMeshSession
    @ObservationIgnored private var task: Task<Void, Never>?

    init(sessionTag: UInt16) {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = UIDevice.current.batteryLevel
        let state = UIDevice.current.batteryState
        session = .multipeer(batteryPercent: level < 0 ? 50 : Int(level * 100),
                             onPower: state == .charging || state == .full, sessionTag: sessionTag)
    }

    func start() {
        guard task == nil else { return }
        let s = session
        task = Task { [weak self] in
            await s.start()
            for await u in s.updates {
                if case .rosterChanged(let roster) = u { self?.peerCount = max(1, roster.count) }
            }
        }
    }

    func stop() {
        task?.cancel()
        let s = session
        Task { [weak self] in
            await s.stop()
            self?.isStopped = true
        }
    }
}

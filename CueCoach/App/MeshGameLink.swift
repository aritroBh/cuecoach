import Foundation
import Observation
import UIKit

/// The running game's mesh (real `MultipeerMeshSession`, tag agreed in the lobby). Phones in the roster are
/// camera angles; Live consumes the session once it is wired (see report: Live owner).
/// The game log (INTERFACES "Shot log"): the host appends, every phone folds the committed prefix.
@MainActor protocol GameMeshLink: AnyObject {
    var peerCount: Int { get }
    /// True once the session has fully stopped (transport closed).
    var isStopped: Bool { get }
    /// This phone writes the log (a client's `append` is a proposal to the host).
    var isHost: Bool { get }
    var commitSeq: UInt64 { get }
    /// The log and its commit point, whenever either changes.
    var onCommittedLog: (@MainActor (_ log: [LogEntry], _ commitSeq: UInt64) -> Void)? { get set }
    func start()
    func stop()
    /// Host: append to the log. Client: send it to the host as a `.proposal`.
    func append(_ event: GameEvent)
}

@MainActor @Observable final class MeshGameLink: GameMeshLink {
    private(set) var peerCount = 1
    private(set) var isStopped = false
    @ObservationIgnored private let session: any MeshSession
    @ObservationIgnored private var task: Task<Void, Never>?
    // Plan 009 log members, stubbed until plan 010 forwards the session's log: nothing is appended or committed.
    let isHost = true
    let commitSeq: UInt64 = 0
    @ObservationIgnored var onCommittedLog: (@MainActor (_ log: [LogEntry], _ commitSeq: UInt64) -> Void)?
    func append(_ event: GameEvent) {}

    convenience init(sessionTag: UInt16) {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = UIDevice.current.batteryLevel
        let state = UIDevice.current.batteryState
        self.init(session: MultipeerMeshSession.multipeer(batteryPercent: level < 0 ? 50 : Int(level * 100),
                                                          onPower: state == .charging || state == .full,
                                                          sessionTag: sessionTag))
    }

    /// Test seam: any session (an in-process `MemoryHub` mesh in tests).
    init(session: any MeshSession) { self.session = session }

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

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
    /// `.host` only: false while discovering and as a client. Last values stay readable after `stop()`.
    private(set) var isHost = false
    /// The last commit point forwarded to `onCommittedLog`.
    private(set) var commitSeq: UInt64 = 0
    @ObservationIgnored var onCommittedLog: (@MainActor (_ log: [LogEntry], _ commitSeq: UInt64) -> Void)?

    @ObservationIgnored private var lastAppend: Task<Void, Never>?

    /// The session turns a client's append into a `.proposal` to the host. Appends reach it in call order.
    func append(_ event: GameEvent) {
        let s = session, prev = lastAppend
        lastAppend = Task { await prev?.value; await s.append(event) }
    }

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
                switch u {
                case .rosterChanged(let roster): self?.peerCount = max(1, roster.count)
                case .roleChanged(let role, _): self?.isHost = role == .host
                case .logChanged: await self?.forwardCommitted(from: s)
                default: break
                }
            }
        }
    }

    /// One fresh snapshot per `logChanged`, forwarded in order; a commit point not newer than the last is dropped.
    private func forwardCommitted(from s: any MeshSession) async {
        let snap = await s.snapshot()
        guard !Task.isCancelled, snap.commitSeq > commitSeq else { return }
        commitSeq = snap.commitSeq
        onCommittedLog?(snap.log.filter { $0.seq <= snap.commitSeq }, snap.commitSeq)
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

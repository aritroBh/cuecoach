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
    /// Teardown: wait (at most `seconds`) until this phone's appends are committed, then call `done`.
    func drainAppends(within seconds: Double, then done: @escaping @MainActor () -> Void)
}

extension GameMeshLink {
    func drainAppends(within seconds: Double, then done: @escaping @MainActor () -> Void) { done() }
}

@MainActor @Observable final class MeshGameLink: GameMeshLink {
    private(set) var peerCount = 1
    private(set) var isStopped = false
    @ObservationIgnored private let session: any MeshSession
    @ObservationIgnored private var task: Task<Void, Never>?
    /// The session's role as this link last heard it.
    private(set) var role: MeshRole = .discovering
    /// Writes the log: the host, or any phone while the role is unresolved (its appends wait in `queued`; a joiner
    /// then drops its own shots, D39). Last values stay readable after `stop()`.
    var isHost: Bool { if case .client = role { false } else { true } }
    /// Last log seq this link has seen in a snapshot (a processing barrier for tests).
    private(set) var handledLastSeq: UInt64 = 0
    /// The last commit point forwarded to `onCommittedLog`.
    private(set) var commitSeq: UInt64 = 0
    @ObservationIgnored var onCommittedLog: (@MainActor (_ log: [LogEntry], _ commitSeq: UInt64) -> Void)?

    /// Appends made before the role resolved, flushed in order once it does.
    @ObservationIgnored private var queued: [GameEvent] = []
    @ObservationIgnored private var lastAppend: Task<Void, Never>?
    @ObservationIgnored private var inFlight = 0
    /// Host: the newest seq its own appends reached. Committed once `commitSeq` covers it.
    @ObservationIgnored private var writtenSeq: UInt64 = 0
    private var hasUnconfirmed: Bool { !queued.isEmpty || inFlight > 0 || commitSeq < writtenSeq }

    /// The session turns a client's append into a `.proposal` to the host. Appends reach it in call order.
    func append(_ event: GameEvent) {
        if role == .discovering { queued.append(event) } else { send(event) }
    }

    private func send(_ event: GameEvent) {
        inFlight += 1
        let s = session, prev = lastAppend
        lastAppend = Task { [weak self] in
            await prev?.value
            await s.append(event)
            let snap = await s.snapshot()
            self?.sent(snap)
        }
    }

    private func sent(_ snap: MeshSnapshot) {
        inFlight -= 1
        if snap.role == .host, let last = snap.log.last?.seq { writtenSeq = max(writtenSeq, last) }
    }

    private func roleChanged(_ r: MeshRole) {
        role = r
        guard r != .discovering else { return }
        let early = queued
        queued = []
        for e in early {
            if case .client = r, e.isShotResult { continue }   // D39: the host rates every shot
            send(e)
        }
    }

    /// Bounded (D42: never stuck): after `seconds` it proceeds with what is committed.
    func drainAppends(within seconds: Double, then done: @escaping @MainActor () -> Void) {
        guard hasUnconfirmed else { done(); return }
        let end = Date().addingTimeInterval(seconds)
        Task { [weak self] in
            while let self, self.hasUnconfirmed, Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
            done()
        }
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
                case .roleChanged(let role, _): self?.roleChanged(role)
                case .logChanged: await self?.forwardCommitted(from: s)
                default: break
                }
            }
        }
    }

    /// One fresh snapshot per `logChanged`, forwarded in order; a commit point not newer than the last is dropped.
    private func forwardCommitted(from s: any MeshSession) async {
        let snap = await s.snapshot()
        guard !Task.isCancelled else { return }
        handledLastSeq = max(handledLastSeq, snap.log.last?.seq ?? 0)
        guard snap.commitSeq > commitSeq else { return }
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

private extension GameEvent {
    /// A shot's result, which only the host records (D39).
    var isShotResult: Bool {
        switch self {
        case .shot, .shotLost: true
        default: false
        }
    }
}

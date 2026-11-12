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
    /// This phone hosts and writes the log (a client's `append` is a proposal to the host).
    var isHost: Bool { get }
    var commitSeq: UInt64 { get }
    /// The log and its commit point, whenever either changes.
    var onCommittedLog: (@MainActor (_ log: [LogEntry], _ commitSeq: UInt64) -> Void)? { get set }
    func start()
    func stop()
    /// Host: append to the log. Client: send it to the host as a `.proposal`.
    func append(_ event: GameEvent)
    /// This phone is a joiner: it never records its own shot results (D39). False while the role is unresolved.
    var isJoiner: Bool { get }
    /// This phone's current members are a strict majority of the game's members (every phone seen in this game's
    /// roster), not of the shrunken commit quorum: an island (a lone survivor of two) has none. Plan 011 saves only with it.
    var hasGameQuorum: Bool { get }
    /// Teardown: returns once this phone's inputs are committed (a joiner also lets the host's commits go quiet),
    /// or at `deadline`.
    func drain(until deadline: Date) async
}

extension GameMeshLink {
    var isJoiner: Bool { !isHost }
    func drain(until deadline: Date) async {}
}

@MainActor @Observable final class MeshGameLink: GameMeshLink {
    private(set) var peerCount = 1
    private(set) var isStopped = false
    @ObservationIgnored private let session: any MeshSession
    @ObservationIgnored private var task: Task<Void, Never>?
    /// The session's role as this link last heard it (from `roleChanged` or the snapshot it forwards).
    private(set) var role: MeshRole = .discovering
    /// Only as `.host`, never while discovering: plan 011 saves when `isHost` and a majority. Readable after `stop()`.
    var isHost: Bool { role == .host }
    var isJoiner: Bool { if case .client = role { true } else { false } }
    var hasGameQuorum: Bool { members.count * 2 > gameMembers.count }
    /// Every phone seen in this game's roster (the game's members).
    private(set) var gameMembers: Set<PeerID> = []
    /// The roster as this link last heard it.
    private var members: [PeerID] = []
    /// Last log seq this link has seen in a snapshot (a processing barrier for tests).
    private(set) var handledLastSeq: UInt64 = 0
    /// The last commit point forwarded to `onCommittedLog`.
    private(set) var commitSeq: UInt64 = 0
    @ObservationIgnored var onCommittedLog: (@MainActor (_ log: [LogEntry], _ commitSeq: UInt64) -> Void)?

    /// Startup inputs made while discovering, flushed in order once the role resolves.
    @ObservationIgnored private var queued: [GameEvent] = []
    @ObservationIgnored private var lastAppend: Task<Void, Never>?
    /// Inputs this phone sent (appended or proposed) not yet seen in the committed log.
    @ObservationIgnored private var unconfirmed: [GameEvent] = []
    @ObservationIgnored private var lastCommitAdvance = Date.distantPast
    /// A joiner's drain ends once the host's commits stop advancing for this long.
    static let quietWindow = 0.3

    /// The session turns a client's append into a `.proposal` to the host. Appends reach it in call order.
    func append(_ event: GameEvent) {
        if role == .discovering { queued.append(event) } else { send(event) }
    }

    private func send(_ event: GameEvent) {
        unconfirmed.append(event)
        let s = session, prev = lastAppend
        lastAppend = Task { await prev?.value; await s.append(event) }
    }

    private func resolve(_ r: MeshRole) {
        guard r != role else { return }
        role = r
        guard r != .discovering else { return }
        let early = queued
        queued = []
        for e in early {
            if case .client = r, e.isShotResult { continue }   // D39: the host rates every shot
            send(e)
        }
    }

    /// Host: every local input committed. Joiner: every proposal seen committed, then the host's commits quiet for
    /// `quietWindow` with no uncommitted tail, so its final rating can land. Ends at `deadline` regardless.
    func drain(until deadline: Date) async {
        let began = Date()
        while !Task.isCancelled, Date() < deadline, !drained(since: began) {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func drained(since began: Date) -> Bool {
        guard queued.isEmpty, unconfirmed.isEmpty else { return false }
        guard isJoiner else { return true }
        return commitSeq >= handledLastSeq && Date().timeIntervalSince(max(lastCommitAdvance, began)) >= Self.quietWindow
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
                case .rosterChanged(let roster): self?.peerCount = max(1, roster.count); self?.see(roster)
                case .roleChanged(let role, _): self?.resolve(role)
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
        resolve(snap.role)
        see(snap.roster)
        handledLastSeq = max(handledLastSeq, snap.log.last?.seq ?? 0)
        guard snap.commitSeq > commitSeq else { return }
        for entry in snap.log where entry.seq > commitSeq && entry.seq <= snap.commitSeq {
            if let i = unconfirmed.firstIndex(of: entry.event) { unconfirmed.remove(at: i) }
        }
        commitSeq = snap.commitSeq
        lastCommitAdvance = Date()
        onCommittedLog?(snap.log.filter { $0.seq <= snap.commitSeq }, snap.commitSeq)
    }

    private func see(_ roster: [PeerID]) {
        members = roster
        gameMembers.formUnion(roster)
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

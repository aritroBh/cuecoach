import Foundation
import Rules

/// Read-only view of the session for UI and the debug HUD.
struct MeshSnapshot: Sendable {
    var role: MeshRole
    var term: UInt64
    var roster: [PeerID]
    var log: [LogEntry]
    var commitSeq: UInt64
    var phase: MeshPhase
    var clock: ClockEstimate?
    var undecodable: Int
    var ignoredMessages: Int
    var droppedRealtime: Int
}

/// App-facing mesh (INTERFACES "App-side protocols": `MeshSession`). Works with one phone: a lone phone
/// elects itself host and every call behaves the same.
protocol MeshSession: AnyObject, Sendable {
    nonisolated var localPeer: PeerID { get }
    nonisolated var updates: AsyncStream<MeshUpdate> { get }
    func start() async
    func stop() async
    /// Host appends to the replicated log; clients forward it to the host.
    func append(_ event: GameEvent) async
    func openRuleVote() async
    func castBallot(_ choice: RuleSetID) async
    func setPhase(_ phase: MeshPhase) async
    /// `captureTime` on this phone's host clock (mach absolute time, same clock as camera PTS).
    func sendTableState(_ frame: TableStateFrame) async
    func sendCalibration(_ report: CalibrationReport) async
    /// Offer this phone's view after balls settle; the host pulls the best one (D3).
    func offerClip(shotID: UUID, data: Data, viewScore: Double) async
    func snapshot() async -> MeshSnapshot
}

/// Drives `MeshNode` with a real transport and the host clock. All protocol logic lives in `MeshNode`;
/// this actor only encodes, paces (`OutboundQueue`), ticks and forwards updates.
actor MultipeerMeshSession: MeshSession {
    nonisolated let localPeer: PeerID
    nonisolated let updates: AsyncStream<MeshUpdate>
    private let continuation: AsyncStream<MeshUpdate>.Continuation
    private let transport: any MeshTransport
    private var node: MeshNode
    private var queue = OutboundQueue()
    private var tasks: [Task<Void, Never>] = []
    private var undecodable = 0
    private var running = false

    init(transport: any MeshTransport, status: PeerStatus, config: MeshConfig = MeshConfig()) {
        self.transport = transport
        localPeer = transport.localPeer
        node = MeshNode(id: transport.localPeer, status: status, config: config)
        (updates, continuation) = AsyncStream.makeStream(of: MeshUpdate.self, bufferingPolicy: .bufferingNewest(256))
    }

    /// Production wiring: Multipeer Connectivity, this device's class.
    static func multipeer(batteryPercent: Int, onPower: Bool) -> MultipeerMeshSession {
        MultipeerMeshSession(transport: MPCTransport(),
                             status: PeerStatus(deviceClass: DeviceClass.current, batteryPercent: batteryPercent,
                                                onPower: onPower))
    }

    /// Host clock in seconds: `CLOCK_UPTIME_RAW` = mach absolute time = `CMClockGetHostTimeClock`.
    nonisolated static func hostNow() -> Double { Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9 }
    private var now: Double { Self.hostNow() }

    func start() async {
        guard !running else { return }
        running = true
        apply(node.start(now: now))
        let events = transport.events
        tasks.append(Task { [weak self] in
            for await e in events {
                guard let self else { return }
                await self.handle(e)
            }
        })
        let interval = min(0.05, node.config.heartbeatInterval / 2)
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(interval))
            }
        })
        transport.start()
    }

    func stop() async {
        guard running else { return }
        running = false
        apply(node.leave(now: now))
        tasks.forEach { $0.cancel() }
        tasks = []
        transport.stop()
        continuation.finish()
    }

    func append(_ event: GameEvent) async { apply(node.append(event, now: now)) }
    func openRuleVote() async { apply(node.openRuleVote(now: now)) }
    func castBallot(_ choice: RuleSetID) async { apply(node.castBallot(choice, now: now)) }
    func setPhase(_ phase: MeshPhase) async { apply(node.setPhase(phase, now: now)) }
    func sendTableState(_ frame: TableStateFrame) async { apply(node.sendTableState(frame, now: now)) }
    func sendCalibration(_ report: CalibrationReport) async { apply(node.sendCalibration(report, now: now)) }
    func offerClip(shotID: UUID, data: Data, viewScore: Double) async {
        apply(node.offerClip(shotID: shotID, data: data, viewScore: viewScore, now: now))
    }

    func snapshot() async -> MeshSnapshot {
        MeshSnapshot(role: node.role, term: node.term, roster: node.roster, log: node.log, commitSeq: node.commitSeq,
                     phase: node.phase, clock: node.clock.estimate, undecodable: undecodable,
                     ignoredMessages: node.ignoredMessages, droppedRealtime: queue.droppedRealtime)
    }

    // MARK: private

    private func handle(_ e: TransportEvent) {
        guard running else { return }
        switch e {
        case .connected(let p): apply(node.peerConnected(p, now: now))
        case .disconnected(let p): apply(node.peerDisconnected(p, now: now))
        case .received(let data, let from):
            guard let env = try? MeshCodec.decode(data), env.sender == from else { undecodable += 1; return }
            apply(node.handle(env, now: now))
        case .failed: break   // one-phone mode keeps working; the lobby shows the permission glyph
        }
    }

    private func tick() {
        guard running else { return }
        apply(node.tick(now: now))
    }

    private func apply(_ step: MeshStep) {
        for u in step.updates { continuation.yield(u) }
        for out in step.outbound {
            let env = node.envelope(out.message, now: now)
            guard let data = try? MeshCodec.encode(env) else { continue }
            queue.enqueue(OutboundQueue.Item(to: out.to, lane: out.lane, data: data))
        }
        for item in queue.drain(now: now) {
            try? transport.send(item.data, to: item.to, channel: item.channel)
        }
    }
}

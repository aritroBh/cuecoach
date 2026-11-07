import Foundation
@testable import CueCoach

/// In-memory, virtual-time, fully connected network of `MeshNode`s (MPC is a full mesh).
/// Deterministic from its seed. Simulates per-link latency + jitter, unreliable-channel loss,
/// silent host death (no disconnect callback), disconnect callbacks, partitions and heals,
/// and a per-node local clock (offset + skew) so clock sync is exercised end to end.
/// Every message goes through `MeshCodec` so the codec is on the test path too.
final class SimNetwork {
    struct NodeBox {
        var node: MeshNode
        var clockOffset: Double
        var skew: Double
        var alive = true
        var updates: [MeshUpdate] = []
    }

    private struct Pending {
        var at: Double
        var order: Int
        var from: PeerID
        var to: PeerID
        var kind: Kind
        enum Kind { case data(Data), connected, disconnected }
    }

    var now = 0.0
    let tickInterval: Double
    var latency: Double
    var jitter: Double
    var unreliableLoss: Double
    /// MPC notices a dead peer after a few seconds; `nil` = never (silent death, heartbeat timeout only).
    var disconnectNoticeDelay: Double? = nil
    private(set) var boxes: [PeerID: NodeBox] = [:]
    private(set) var joinOrder: [PeerID] = []
    private var queue: [Pending] = []
    private var order = 0
    private var rng: SeededRNG
    private var lastDelivery: [String: Double] = [:]
    private var cut: Set<String> = []
    private var extraDelay: [String: Double] = [:]

    /// Make one direction of one link slower (e.g. a host → successor link through a wall).
    func slowLink(from a: PeerID, to b: PeerID, extra: Double) { extraDelay[key(a, b)] = extra }
    private var nextTick = 0.0
    /// Every delivered message, for property checks: (time, from, to, message, receiver's phase then).
    private(set) var delivered: [(t: Double, from: PeerID, to: PeerID, message: MeshMessage)] = []
    var recordDeliveries = false
    private(set) var undecodable = 0

    init(seed: UInt64 = 1, latency: Double = 0.005, jitter: Double = 0.002, unreliableLoss: Double = 0,
         tickInterval: Double = 0.05) {
        rng = SeededRNG(seed: seed)
        self.latency = latency
        self.jitter = jitter
        self.unreliableLoss = unreliableLoss
        self.tickInterval = tickInterval
    }

    func localTime(_ p: PeerID) -> Double {
        let b = boxes[p]!
        return b.clockOffset + (1 + b.skew) * now
    }

    @discardableResult
    func addNode(device: Int = 16, battery: Int = 80, onPower: Bool = false, clockOffset: Double = 0,
                 skew: Double = 0, config: MeshConfig = MeshConfig(), id: PeerID = PeerID()) -> PeerID {
        let status = PeerStatus(deviceClass: device, batteryPercent: battery, onPower: onPower)
        boxes[id] = NodeBox(node: MeshNode(id: id, status: status, config: config),
                            clockOffset: clockOffset, skew: skew)
        joinOrder.append(id)
        apply(id, boxes[id]!.node.start(now: localTime(id)))
        for other in boxes.keys where other != id && boxes[other]!.alive {
            schedule(from: id, to: other, kind: .connected, delay: 0.01)
            schedule(from: other, to: id, kind: .connected, delay: 0.01)
        }
        return id
    }

    func node(_ p: PeerID) -> MeshNode { boxes[p]!.node }
    func updates(_ p: PeerID) -> [MeshUpdate] { boxes[p]!.updates }
    var aliveIDs: [PeerID] { joinOrder.filter { boxes[$0]!.alive } }
    var hosts: [PeerID] { aliveIDs.filter { boxes[$0]!.node.role == .host } }

    /// App-level action on a node at the current time.
    func act(_ p: PeerID, _ f: (inout MeshNode, Double) -> MeshStep) {
        guard boxes[p]!.alive else { return }
        let t = localTime(p)
        let step = f(&boxes[p]!.node, t)
        apply(p, step)
    }

    func kill(_ p: PeerID) {
        boxes[p]!.alive = false
        queue.removeAll { $0.from == p || $0.to == p }
        if let d = disconnectNoticeDelay {
            for other in aliveIDs { schedule(from: p, to: other, kind: .disconnected, delay: d, force: true) }
        }
    }

    /// Cut every link between the two groups (no callbacks: looks like silence).
    func partition(_ a: [PeerID], _ b: [PeerID]) {
        for x in a { for y in b { cut.insert(key(x, y)); cut.insert(key(y, x)) } }
    }
    func heal() { cut.removeAll() }

    func run(for duration: Double) {
        let end = now + duration
        while true {
            queue.sort { ($0.at, $0.order) < ($1.at, $1.order) }
            let nextMsg = queue.first?.at ?? .infinity
            let t = min(nextMsg, nextTick)
            if t > end { break }
            now = t
            if nextMsg <= nextTick {
                deliver(queue.removeFirst())
            } else {
                for p in aliveIDs { apply(p, boxes[p]!.node.tick(now: localTime(p))) }
                nextTick += tickInterval
            }
        }
        now = end
    }

    // MARK: private

    private func key(_ a: PeerID, _ b: PeerID) -> String { "\(a.raw)>\(b.raw)" }

    private func schedule(from: PeerID, to: PeerID, kind: Pending.Kind, delay: Double, force: Bool = false) {
        var at = now + delay
        if case .data = kind, !force {
            // Reliable channel in MPC is ordered per link: never deliver before an earlier message.
            at = max(at, lastDelivery[key(from, to)] ?? 0)
            lastDelivery[key(from, to)] = at
        }
        order += 1
        queue.append(Pending(at: at, order: order, from: from, to: to, kind: kind))
    }

    private func apply(_ p: PeerID, _ step: MeshStep) {
        boxes[p]!.updates += step.updates
        for out in step.outbound {
            let env = boxes[p]!.node.envelope(out.message, now: localTime(p))
            let data = try! MeshCodec.encode(env)
            for to in out.to where to != p {
                guard boxes[to]?.alive == true, !cut.contains(key(p, to)) else { continue }
                if out.channel == .unreliable {
                    if Double.random(in: 0..<1, using: &rng) < unreliableLoss { continue }
                    let d = latency + Double.random(in: 0...jitter, using: &rng)
                    order += 1
                    queue.append(Pending(at: now + d, order: order, from: p, to: to, kind: .data(data)))
                } else {
                    schedule(from: p, to: to, kind: .data(data),
                             delay: latency + (extraDelay[key(p, to)] ?? 0) + Double.random(in: 0...jitter, using: &rng))
                }
            }
        }
    }

    private func deliver(_ m: Pending) {
        guard boxes[m.to]?.alive == true else { return }
        let t = localTime(m.to)
        switch m.kind {
        case .connected:
            guard boxes[m.from]?.alive == true else { return }
            apply(m.to, boxes[m.to]!.node.peerConnected(m.from, now: t))
        case .disconnected:
            apply(m.to, boxes[m.to]!.node.peerDisconnected(m.from, now: t))
        case .data(let data):
            guard !cut.contains(key(m.from, m.to)) else { return }
            guard let env = try? MeshCodec.decode(data) else { undecodable += 1; return }
            if recordDeliveries { delivered.append((now, m.from, m.to, env.message)) }
            apply(m.to, boxes[m.to]!.node.handle(env, now: t))
        }
    }
}

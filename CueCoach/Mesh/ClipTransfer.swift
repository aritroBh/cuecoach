import CryptoKit
import Foundation

/// Sends one clip in SHA-tagged chunks over `.reliable` with an app-level window (D3, mesh-identity.md §2.7).
/// MPC has no back-pressure, so at most `window` chunks are unacknowledged at once. Chunks leave only while
/// the host says balls are settled (or the game is over); during `.aiming` / `.inMotion` the sender pauses at
/// the chunk boundary and keeps its offset.
struct ClipSender: Sendable {
    /// 64 KiB per chunk keeps one envelope well under `MeshCodec.maxMessageBytes`.
    static let chunkSize = 64 * 1024
    static let window = 4

    let shotID: UUID
    let data: Data
    let chunkSize: Int
    let window: Int
    let total: Int
    private var pending: [Int]
    private(set) var inFlightIndices: Set<Int> = []
    private var acked: Set<Int> = []

    init(shotID: UUID, data: Data, chunkSize: Int = ClipSender.chunkSize, window: Int = ClipSender.window) {
        self.shotID = shotID
        self.data = data
        self.chunkSize = max(1, chunkSize)
        self.window = max(1, window)
        total = (data.count + self.chunkSize - 1) / self.chunkSize
        pending = Array(0..<total)
    }

    var inFlight: Int { inFlightIndices.count }
    var isAcknowledged: Bool { acked.count == total }
    var completion: ClipComplete { ClipComplete(shotID: shotID, sha256: Data(SHA256.hash(data: data))) }

    static func mayTransmit(_ phase: MeshPhase) -> Bool { phase == .settled || phase == .gameOver }

    mutating func nextChunks(phase: MeshPhase) -> [ClipChunk] {
        guard Self.mayTransmit(phase) else { return [] }
        var out: [ClipChunk] = []
        while inFlightIndices.count < window, !pending.isEmpty {
            let i = pending.removeFirst()
            inFlightIndices.insert(i)
            out.append(chunk(i))
        }
        return out
    }

    mutating func handle(_ ack: ClipChunkAck) {
        guard ack.shotID == shotID, inFlightIndices.remove(ack.index) != nil else { return }
        if ack.ok {
            acked.insert(ack.index)
        } else {
            pending.append(ack.index)
            pending.sort()
        }
    }

    /// Re-queue everything unacknowledged (e.g. after a host change).
    mutating func resendUnacked() {
        pending = (Set(pending).union(inFlightIndices)).sorted()
        inFlightIndices.removeAll()
    }

    private func chunk(_ i: Int) -> ClipChunk {
        let lo = data.startIndex + i * chunkSize
        let bytes = Data(data[lo..<min(lo + chunkSize, data.endIndex)])
        return ClipChunk(shotID: shotID, index: i, total: total, totalBytes: data.count, bytes: bytes,
                         sha256: Data(SHA256.hash(data: bytes)))
    }
}

/// Host side: verifies each chunk, reassembles, and checks the whole-clip hash.
struct ClipReceiver: Sendable {
    /// Hard cap so a bad peer can't make the host buffer unbounded memory. Clips are ≈ 4–10 MB (§2.7).
    static let maxClipBytes = 32 * 1024 * 1024

    let shotID: UUID
    private var total: Int?
    private var totalBytes: Int?
    private var chunks: [Int: Data] = [:]
    private var storedBytes = 0

    init(shotID: UUID) { self.shotID = shotID }

    var isComplete: Bool { total.map { chunks.count == $0 } ?? false }

    var assembled: Data? {
        guard isComplete, let total, let totalBytes else { return nil }
        var d = Data(capacity: totalBytes)
        for i in 0..<total { d.append(chunks[i]!) }
        return d.count == totalBytes ? d : nil
    }

    mutating func receive(_ c: ClipChunk) -> ClipChunkAck {
        let nack = ClipChunkAck(shotID: c.shotID, index: c.index, ok: false)
        // Every chunk carries ≥ 1 byte, so `total ≤ totalBytes`; and what is stored never exceeds the
        // declared size. Together they bound host memory by `maxClipBytes` whatever a peer sends.
        guard c.shotID == shotID, c.total >= 1, c.totalBytes >= 1, c.totalBytes <= Self.maxClipBytes,
              c.total <= c.totalBytes, (0..<c.total).contains(c.index), !c.bytes.isEmpty,
              c.bytes.count <= MeshCodec.maxMessageBytes,
              Data(SHA256.hash(data: c.bytes)) == c.sha256 else { return nack }
        if let total, total != c.total { return nack }
        if let totalBytes, totalBytes != c.totalBytes { return nack }
        let after = storedBytes - (chunks[c.index]?.count ?? 0) + c.bytes.count
        guard after <= c.totalBytes else { return nack }
        total = c.total
        totalBytes = c.totalBytes
        chunks[c.index] = c.bytes
        storedBytes = after
        return ClipChunkAck(shotID: c.shotID, index: c.index, ok: true)
    }

    /// True when every chunk arrived and the whole clip matches the sender's hash.
    func finish(_ c: ClipComplete) -> Bool {
        guard c.shotID == shotID, let d = assembled else { return false }
        return Data(SHA256.hash(data: d)) == c.sha256
    }
}

/// Outbound back-pressure for one transport. Three lanes, strict priority:
/// control (never dropped) > realtime (keeps only the newest `realtimeCapacity`; stale detections are
/// useless) > bulk (clip chunks; `isBulkCongested` tells the clip sender to stop producing).
/// A token-bucket pacer caps bytes/s so a clip can't starve detections on the shared radio.
struct OutboundQueue: Sendable {
    enum Lane: Sendable { case control, realtime, bulk }

    struct Item: Sendable {
        var to: [PeerID]
        var lane: Lane
        var data: Data
        var channel: MeshChannel { lane == .realtime ? .unreliable : .reliable }
    }

    let bytesPerSecond: Double
    let burst: Double
    let realtimeCapacity: Int
    let bulkHighWater: Int
    private var control: [Item] = []
    private var realtime: [Item] = []
    private var bulk: [Item] = []
    private var tokens: Double
    private var lastRefill: Double?
    private(set) var droppedRealtime = 0

    init(bytesPerSecond: Double = 2_000_000, burst: Double = 256 * 1024, realtimeCapacity: Int = 2,
         bulkHighWater: Int = 4 * ClipSender.chunkSize) {
        self.bytesPerSecond = bytesPerSecond
        self.burst = burst
        self.realtimeCapacity = max(1, realtimeCapacity)
        self.bulkHighWater = bulkHighWater
        tokens = burst
    }

    var bulkBytes: Int { bulk.reduce(0) { $0 + $1.data.count } }
    var isBulkCongested: Bool { bulkBytes > bulkHighWater }
    var isEmpty: Bool { control.isEmpty && realtime.isEmpty && bulk.isEmpty }

    mutating func enqueue(_ item: Item) {
        switch item.lane {
        case .control: control.append(item)
        case .bulk: bulk.append(item)
        case .realtime:
            realtime.append(item)
            if realtime.count > realtimeCapacity {
                droppedRealtime += realtime.count - realtimeCapacity
                realtime.removeFirst(realtime.count - realtimeCapacity)
            }
        }
    }

    /// Items allowed out now, in priority order. `allowBulk: false` (someone is aiming, D3) holds already
    /// queued clip chunks until the next settled window. Tokens may go negative (an oversize item is never starved;
    /// the debt is repaid before anything else leaves).
    mutating func drain(now: Double, allowBulk: Bool = true) -> [Item] {
        if let last = lastRefill { tokens = min(burst, tokens + max(0, now - last) * bytesPerSecond) }
        lastRefill = now
        var out: [Item] = []
        while tokens > 0, let next = popNext(allowBulk: allowBulk) {
            tokens -= Double(next.data.count)
            out.append(next)
        }
        return out
    }

    private mutating func popNext(allowBulk: Bool) -> Item? {
        if !control.isEmpty { return control.removeFirst() }
        if !realtime.isEmpty { return realtime.removeFirst() }
        if allowBulk, !bulk.isEmpty { return bulk.removeFirst() }
        return nil
    }
}

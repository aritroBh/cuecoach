import CryptoKit
import Foundation
import Testing
@testable import CueCoach

/// Clip transfer after balls settle, never while aiming (D3; mesh-identity.md §2.7).
@Suite struct ClipTransferTests {
    static let shot = UUID()

    static func clip(_ n: Int, seed: UInt64 = 1) -> Data {
        var rng = SeededRNG(seed: seed)
        return Data((0..<n).map { _ in UInt8.random(in: 0...255, using: &rng) })
    }

    @Test func chunksReassembleAndVerify() {
        let data = Self.clip(10_000)
        var s = ClipSender(shotID: Self.shot, data: data, chunkSize: 1000, window: 4)
        var r = ClipReceiver(shotID: Self.shot)
        while !s.isAcknowledged {
            let batch = s.nextChunks(phase: .settled)
            #expect(!batch.isEmpty)
            for c in batch { s.handle(r.receive(c)) }
        }
        #expect(r.finish(s.completion))
        #expect(r.assembled == data)
        #expect(s.completion.sha256 == Data(SHA256.hash(data: data)))
    }

    @Test func windowCapsChunksInFlight() {
        var s = ClipSender(shotID: Self.shot, data: Self.clip(10_000), chunkSize: 1000, window: 4)
        #expect(s.nextChunks(phase: .settled).count == 4)
        #expect(s.nextChunks(phase: .settled).isEmpty)   // all 4 unacked → no more
        #expect(s.inFlight == 4)
    }

    /// Property: zero chunks leave while anyone is aiming or balls are moving.
    @Test(arguments: [MeshPhase.aiming, .inMotion, .lobby])
    func noChunksOutsideSettledWindows(phase: MeshPhase) {
        var s = ClipSender(shotID: Self.shot, data: Self.clip(5000), chunkSize: 1000, window: 4)
        #expect(s.nextChunks(phase: phase).isEmpty)
        #expect(s.inFlight == 0)
    }

    /// Randomised phase sequence: offsets survive pauses across several settle windows, never a send while aiming.
    @Test(arguments: 0..<10)
    func pauseResumeAcrossSettleWindows(seed: Int) {
        var rng = SeededRNG(seed: UInt64(seed))
        let data = Self.clip(50_000, seed: UInt64(seed))
        var s = ClipSender(shotID: Self.shot, data: data, chunkSize: 1000, window: 4)
        var r = ClipReceiver(shotID: Self.shot)
        var steps = 0
        while !s.isAcknowledged && steps < 10_000 {
            steps += 1
            let phase: MeshPhase = [.aiming, .inMotion, .settled].randomElement(using: &rng)!
            let batch = s.nextChunks(phase: phase)
            if phase != .settled { #expect(batch.isEmpty) }
            for c in batch { s.handle(r.receive(c)) }
        }
        #expect(r.finish(s.completion))
        #expect(r.assembled == data)
    }

    @Test func corruptedChunkIsNackedAndResent() {
        let data = Self.clip(3000)
        var s = ClipSender(shotID: Self.shot, data: data, chunkSize: 1000, window: 4)
        var r = ClipReceiver(shotID: Self.shot)
        var batch = s.nextChunks(phase: .settled)
        batch[1].bytes[0] ^= 0xFF
        var nacks = 0
        for c in batch {
            let ack = r.receive(c)
            if !ack.ok { nacks += 1 }
            s.handle(ack)
        }
        #expect(nacks == 1)
        let resend = s.nextChunks(phase: .settled)
        #expect(resend.map(\.index) == [1])
        for c in resend { s.handle(r.receive(c)) }
        #expect(s.isAcknowledged && r.finish(s.completion) && r.assembled == data)
    }

    /// After a host change, unacked chunks go again (the new host may never have seen them).
    @Test func resendUnackedRequeuesInFlight() {
        var s = ClipSender(shotID: Self.shot, data: Self.clip(3000), chunkSize: 1000, window: 4)
        _ = s.nextChunks(phase: .settled)
        s.resendUnacked()
        #expect(s.inFlight == 0)
        #expect(s.nextChunks(phase: .settled).map(\.index) == [0, 1, 2])
    }

    @Test func receiverRejectsOversizeAndInconsistentChunks() {
        var r = ClipReceiver(shotID: Self.shot)
        let body = Data([1, 2, 3])
        let sha = Data(SHA256.hash(data: body))
        let huge = ClipChunk(shotID: Self.shot, index: 0, total: 1, totalBytes: ClipReceiver.maxClipBytes + 1,
                             bytes: body, sha256: sha)
        #expect(!r.receive(huge).ok)
        let wrongShot = ClipChunk(shotID: UUID(), index: 0, total: 1, totalBytes: 3, bytes: body, sha256: sha)
        #expect(!r.receive(wrongShot).ok)
        let badIndex = ClipChunk(shotID: Self.shot, index: 5, total: 1, totalBytes: 3, bytes: body, sha256: sha)
        #expect(!r.receive(badIndex).ok)
        let good = ClipChunk(shotID: Self.shot, index: 0, total: 1, totalBytes: 3, bytes: body, sha256: sha)
        #expect(r.receive(good).ok)
        let changedTotal = ClipChunk(shotID: Self.shot, index: 0, total: 2, totalBytes: 6, bytes: body, sha256: sha)
        #expect(!r.receive(changedTotal).ok)
        #expect(!r.finish(ClipComplete(shotID: Self.shot, sha256: Data(repeating: 0, count: 32))))
        #expect(r.finish(ClipComplete(shotID: Self.shot, sha256: sha)))
    }

    @Test func emptyClipCompletesImmediately() {
        var s = ClipSender(shotID: Self.shot, data: Data(), chunkSize: 1000, window: 4)
        #expect(s.isAcknowledged)
        #expect(s.nextChunks(phase: .settled).isEmpty)
    }
}

/// Outbound back-pressure: priorities, stale-realtime dropping, and a byte-rate pacer.
@Suite struct OutboundQueueTests {
    let p = PeerID()

    func item(_ lane: OutboundQueue.Lane, _ n: Int, tag: UInt8 = 0) -> OutboundQueue.Item {
        OutboundQueue.Item(to: [p], lane: lane, data: Data(repeating: tag, count: n))
    }

    @Test func controlBeatsRealtimeBeatsBulk() {
        var q = OutboundQueue(bytesPerSecond: 1_000_000, burst: 1_000_000)
        q.enqueue(item(.bulk, 10, tag: 3))
        q.enqueue(item(.realtime, 10, tag: 2))
        q.enqueue(item(.control, 10, tag: 1))
        let out = q.drain(now: 0)
        #expect(out.map { $0.data.first } == [1, 2, 3])
        #expect(out.map(\.channel) == [.reliable, .unreliable, .reliable])
    }

    @Test func realtimeKeepsOnlyNewestWhenFull() {
        var q = OutboundQueue(bytesPerSecond: 1_000_000, burst: 1_000_000, realtimeCapacity: 2)
        for t in 0..<5 { q.enqueue(item(.realtime, 10, tag: UInt8(t))) }
        #expect(q.droppedRealtime == 3)
        #expect(q.drain(now: 0).map { $0.data.first } == [3, 4])
    }

    @Test func controlIsNeverDropped() {
        var q = OutboundQueue(bytesPerSecond: 100, burst: 100)
        for t in 0..<50 { q.enqueue(item(.control, 50, tag: UInt8(t))) }
        var got: [UInt8] = []
        var now = 0.0
        while got.count < 50 && now < 100 { got += q.drain(now: now).compactMap { $0.data.first }; now += 0.5 }
        #expect(got == (0..<50).map(UInt8.init))
    }

    @Test func pacerLimitsBytesPerSecond() {
        var q = OutboundQueue(bytesPerSecond: 10_000, burst: 2_000)
        for _ in 0..<100 { q.enqueue(item(.bulk, 1_000)) }
        var sent = 0
        var t = 0.0
        while t <= 1.0 { sent += q.drain(now: t).reduce(0) { $0 + $1.data.count }; t += 0.01 }
        // ≈ burst + rate × 1 s
        #expect(sent >= 10_000 && sent <= 13_000, "sent \(sent)")
    }

    /// A message bigger than the burst still goes once the bucket is full (no starvation).
    @Test func oversizeItemNotStarved() {
        var q = OutboundQueue(bytesPerSecond: 1_000, burst: 500)
        q.enqueue(item(.bulk, 5_000))
        #expect(q.drain(now: 0).count == 1)
        q.enqueue(item(.bulk, 10))
        #expect(q.drain(now: 0.1).isEmpty)       // paid for the oversize item: bucket in debt
        #expect(q.drain(now: 6).count == 1)
    }

    @Test func bulkCongestionSignal() {
        var q = OutboundQueue(bytesPerSecond: 1, burst: 1, bulkHighWater: 3_000)
        q.enqueue(item(.bulk, 2_000))
        #expect(!q.isBulkCongested)
        q.enqueue(item(.bulk, 2_000))
        #expect(q.isBulkCongested)
    }
}

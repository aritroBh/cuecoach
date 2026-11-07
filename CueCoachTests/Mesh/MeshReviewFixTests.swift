import CryptoKit
import Foundation
import Testing
import Rules
@testable import CueCoach

/// Regression tests for the supervisor's review of the mesh module (one test group per finding).
@Suite struct MeshReviewFixTests {
    static func shot(_ n: Int) -> GameEvent { MeshNodeTests.shot(n) }

    static func env(_ node: MeshNode, from: PeerID, _ m: MeshMessage, seq: UInt64 = 1) -> MeshEnvelope {
        MeshEnvelope(version: .current, sessionID: node.sessionID, sender: from, seq: seq, sentAt: 0, message: m)
    }

    static func entry(_ seq: UInt64, term: UInt64 = 1) -> LogEntry {
        LogEntry(seq: seq, term: term, event: .shooterCorrection(shotID: UUID(), team: Int(seq % 2)))
    }

    static func succession(_ net: SimNetwork, _ ids: [PeerID]) -> [PeerID] {
        HostElection.succession(Dictionary(uniqueKeysWithValues: ids.map { ($0, net.node($0).status) }),
                                order: .deviceFirst)
    }

    // MARK: BLOCKER — a successor that lacks committed entries must not erase them

    @Test func committedEntryKnownOnlyToSurvivorSurvivesSuccessorWithShorterLog() {
        let (net, ids) = MeshNodeTests.mesh(3)
        let old = net.hosts.first!
        let succ = Self.succession(net, ids)[1]
        let other = ids.first { $0 != old && $0 != succ }!
        net.slowLink(from: old, to: succ, extra: 0.5)
        net.act(old) { m, t in m.append(Self.shot(1), now: t) }
        net.run(for: 0.4)                                    // a heartbeat has told `other` it is committed
        #expect(net.node(other).commitSeq == 1)
        #expect(net.node(succ).log.isEmpty)
        net.kill(old)
        net.run(for: 3)
        MeshNodeTests.expectConverged(net)
        #expect(net.hosts == [succ])
        #expect(net.node(succ).log.count == 1)
        #expect(net.node(other).log.count == 1)
    }

    /// The survivor holding the committed entry answers after `collectTimeout`: the new host must wait for
    /// a majority of the old roster before resuming.
    @Test func newHostWaitsForMajorityEvenPastCollectTimeout() {
        let (net, ids) = MeshNodeTests.mesh(3)
        let old = net.hosts.first!
        let succ = Self.succession(net, ids)[1]
        let other = ids.first { $0 != old && $0 != succ }!
        net.slowLink(from: old, to: succ, extra: 0.5)
        net.act(old) { m, t in m.append(Self.shot(1), now: t) }
        net.run(for: 0.4)
        net.kill(old)
        net.slowLink(from: other, to: succ, extra: 0.9)      // > collectTimeout (0.5 s)
        net.run(for: 4)
        MeshNodeTests.expectConverged(net)
        #expect(net.hosts == [succ])
        #expect(net.node(succ).log.count == 1)
        #expect(net.node(other).log.count == 1)
    }

    // MARK: MAJOR — `.leave` must not throw away the step it produced

    @Test func hostLeavingPromotesSuccessorWithRoleChangedUpdate() {
        let (net, ids) = MeshNodeTests.mesh(3)
        let old = net.hosts.first!
        let succ = Self.succession(net, ids)[1]
        net.act(old) { m, t in m.leave(now: t) }
        net.run(for: 0.05)
        net.kill(old)
        #expect(net.hosts == [succ])
        #expect(net.updates(succ).contains(.roleChanged(.host, term: net.node(succ).term)))
        net.run(for: 1)
        MeshNodeTests.expectConverged(net)
    }

    @Test func clientLeavingClosesVoteForEveryone() {
        let (net, ids) = MeshNodeTests.mesh(3)
        let host = net.hosts.first!
        let clients = ids.filter { $0 != host }
        net.act(host) { n, t in n.openRuleVote(now: t) }
        net.run(for: 0.2)
        net.act(host) { n, t in n.castBallot(.wpaNine, now: t) }
        net.act(clients[0]) { n, t in n.castBallot(.wpaNine, now: t) }
        net.run(for: 0.2)
        net.act(clients[1]) { n, t in n.leave(now: t) }
        net.run(for: 0.05)
        net.kill(clients[1])
        net.run(for: 0.3)
        #expect(net.updates(clients[0]).contains(.ruleVoteClosed(.wpaNine)))
    }

    // MARK: MAJOR — only the host writes; only survivors being collected may contribute tails

    @Test func hostIgnoresLogEntriesFromStrangersAndFromClients() {
        let (net, ids) = MeshNodeTests.mesh(2)
        let host = net.hosts.first!
        let client = ids.first { $0 != host }!
        let stranger = PeerID()
        net.act(host) { n, t in n.peerConnected(stranger, now: t) }
        let before = net.node(host).log
        net.act(host) { n, t in n.handle(Self.env(n, from: stranger, .logEntries([Self.entry(1)])), now: t) }
        net.act(host) { n, t in n.handle(Self.env(n, from: client, .logEntries([Self.entry(1)])), now: t) }
        #expect(net.node(host).log == before)
    }

    // MARK: MAJOR — separate tables must not merge

    @Test func sessionsWithDifferentTagsStayApart() {
        let net = SimNetwork()
        var t1 = MeshConfig(); t1.sessionTag = 1
        var t2 = MeshConfig(); t2.sessionTag = 2
        let a = [net.addNode(device: 15, config: t1), net.addNode(device: 18, config: t1)]
        let b = [net.addNode(device: 16, config: t2), net.addNode(device: 17, config: t2)]
        net.run(for: 3)
        #expect(net.hosts.count == 2)
        for p in a { #expect(Set(net.node(p).roster) == Set(a)) }
        for p in b { #expect(Set(net.node(p).roster) == Set(b)) }
    }

    @Test func mpcOnlyConnectsPeersOfTheSameSession() {
        let info = MPCTransport.discoveryInfo(sessionTag: 7)
        #expect(MPCTransport.sameSession(info, sessionTag: 7))
        #expect(!MPCTransport.sameSession(info, sessionTag: 8))
        #expect(!MPCTransport.sameSession(nil, sessionTag: 7))
        let ctx = MPCTransport.invitationContext(sessionTag: 7)
        #expect(MPCTransport.shouldAccept(connectedCount: 0, context: ctx, sessionTag: 7))
        #expect(!MPCTransport.shouldAccept(connectedCount: 0, context: ctx, sessionTag: 8))
        #expect(MPCTransport(localPeer: PeerID(), sessionTag: 7).sessionTag == 7)
    }

    // MARK: MAJOR — clips must not accumulate forever

    @Test func storedClipsAreBounded() {
        let (net, ids) = MeshNodeTests.mesh(2)
        let host = net.hosts.first!
        let client = ids.first { $0 != host }!
        for _ in 0..<20 {
            net.act(client) { n, t in n.offerClip(shotID: UUID(), data: Data(count: 1000), viewScore: 0.1, now: t) }
            net.act(host) { n, t in n.offerClip(shotID: UUID(), data: Data(count: 1000), viewScore: 0.1, now: t) }
        }
        net.run(for: 1)
        #expect(net.node(client).storedClipCount <= MeshConfig().maxStoredClips)
        #expect(net.node(host).storedClipCount <= MeshConfig().maxStoredClips)
    }

    @Test func clipIsReleasedAfterTransferAndAfterLosing() {
        let (net, ids) = MeshNodeTests.mesh(3)
        let host = net.hosts.first!
        let clients = ids.filter { $0 != host }
        let shotID = UUID()
        net.act(host) { n, t in n.setPhase(.settled, now: t) }
        net.run(for: 0.1)
        net.act(host) { n, t in n.offerClip(shotID: shotID, data: Data([1]), viewScore: 0.1, now: t) }
        net.act(clients[0]) { n, t in n.offerClip(shotID: shotID, data: Data([2, 2]), viewScore: 0.9, now: t) }
        net.act(clients[1]) { n, t in n.offerClip(shotID: shotID, data: Data([3]), viewScore: 0.2, now: t) }
        net.run(for: 2)
        #expect(net.updates(host).contains(.clipReceived(shotID: shotID, from: clients[0], data: Data([2, 2]))))
        #expect(net.node(host).storedClipCount == 0)       // lost the view decision
        #expect(net.node(clients[0]).storedClipCount == 0) // sent and acknowledged
    }

    // MARK: MAJOR — session-only profile summary (SPEC §5.7)

    @Test func profilesReachEveryMemberIncludingLateJoiners() {
        let (net, ids) = MeshNodeTests.mesh(3)
        for (i, p) in ids.enumerated() { net.act(p) { n, t in n.shareProfile(Data([UInt8(i)]), now: t) } }
        net.run(for: 0.5)
        for (i, p) in ids.enumerated() {
            for (j, q) in ids.enumerated() where q != p {
                #expect(net.node(p).profiles[q] == Data([UInt8(j)]), "\(i) lacks \(j)")
            }
        }
        let late = net.addNode(device: 15)
        net.act(late) { n, t in n.shareProfile(Data([9]), now: t) }
        net.run(for: 2.5)
        for (j, q) in ids.enumerated() { #expect(net.node(late).profiles[q] == Data([UInt8(j)])) }
        for p in ids { #expect(net.node(p).profiles[late] == Data([9])) }
        #expect(net.updates(late).contains(.profile(from: ids[0], Data([0]))))
    }

    @Test func oversizeProfileIsNotSent() {
        let (net, ids) = MeshNodeTests.mesh(2)
        let big = Data(count: MeshConfig().maxProfileBytes + 1)
        net.act(ids[0]) { n, t in n.shareProfile(big, now: t) }
        net.run(for: 0.3)
        #expect(net.node(ids[1]).profiles[ids[0]] == nil)
    }

    // MARK: MINOR — a welcome tells the app who is in the roster

    @Test func everyClientHearsTheRoster() {
        let (net, ids) = MeshNodeTests.mesh(3)
        for p in ids {
            let last = net.updates(p).compactMap { u -> [PeerID]? in
                if case .rosterChanged(let r) = u { r } else { nil }
            }.last
            #expect(last.map(Set.init) == Set(ids))
        }
    }

    // MARK: MINOR — duplicate or stale batches never truncate a client's log

    @Test func staleBatchDoesNotTruncateClientLog() {
        var node = MeshNode(status: PeerStatus(deviceClass: 15, batteryPercent: 50, onPower: false))
        let host = PeerID()
        _ = node.start(now: 0)
        _ = node.peerConnected(host, now: 0)
        let log = (1...5).map { Self.entry(UInt64($0)) }
        _ = node.handle(Self.env(node, from: host, .welcome(Welcome(term: 1, host: host, roster: [host, node.id],
                                                                   log: log, commitSeq: 5))), now: 0.01)
        #expect(node.log == log)
        let step = node.handle(Self.env(node, from: host, .logEntries(Array(log[0..<2])), seq: 2), now: 0.02)
        #expect(node.log == log)
        #expect(node.commitSeq <= node.lastSeq)
        #expect(!step.updates.contains(.logChanged(lastSeq: 2, commitSeq: 2)))
        // A real conflict (different entry at a seq) still replaces the tail.
        let replacement = Self.entry(4, term: 2)
        _ = node.handle(Self.env(node, from: host, .logEntries([replacement]), seq: 3), now: 0.03)
        #expect(node.log == Array(log[0..<3]) + [replacement])
        #expect(node.commitSeq <= node.lastSeq)
    }

    // MARK: MINOR — an isolated host cannot commit alone

    @Test func isolatedHostStopsCommittingWhileMajoritySideCommits() {
        let (net, ids) = MeshNodeTests.mesh(4)
        let old = net.hosts.first!
        let others = ids.filter { $0 != old }
        net.partition([old], others)
        net.run(for: 3)
        let before = net.node(old).commitSeq
        net.act(old) { m, t in m.append(Self.shot(1), now: t) }
        net.run(for: 0.5)
        #expect(net.node(old).commitSeq == before)
        let newHost = net.hosts.first { $0 != old }!
        net.act(newHost) { m, t in m.append(Self.shot(2), now: t) }
        net.run(for: 0.5)
        #expect(net.node(newHost).commitSeq == 1)
    }

    /// A lone survivor of a two-phone game keeps committing (one-phone mode).
    @Test func loneSurvivorOfTwoPhoneGameCommits() {
        let (net, ids) = MeshNodeTests.mesh(2)
        let old = net.hosts.first!
        let survivor = ids.first { $0 != old }!
        net.kill(old)
        net.run(for: 3)
        net.act(survivor) { m, t in m.append(Self.shot(1), now: t) }
        #expect(net.node(survivor).commitSeq == 1)
    }

    // MARK: MINOR — empty clips and request loops

    @Test func emptyClipNeverLoops() {
        let (net, ids) = MeshNodeTests.mesh(2)
        net.recordDeliveries = true
        let host = net.hosts.first!
        let client = ids.first { $0 != host }!
        let shotID = UUID()
        net.act(host) { n, t in n.setPhase(.settled, now: t) }
        net.run(for: 0.1)
        net.act(host) { n, t in n.offerClip(shotID: shotID, data: Data([5]), viewScore: 0.1, now: t) }
        net.act(client) { n, t in n.offerClip(shotID: shotID, data: Data(), viewScore: 0.9, now: t) }
        net.run(for: 3)
        let requests = net.delivered.filter { if case .clipRequest = $0.message { true } else { false } }
        #expect(requests.count <= 3)
        #expect(net.updates(host).contains(.clipReceived(shotID: shotID, from: host, data: Data([5]))))
    }

    // MARK: MINOR — receiver memory is bounded by the declared size

    @Test func receiverRejectsChunkCountsAndBytesBeyondDeclaredSize() {
        var r = ClipReceiver(shotID: ClipTransferTests.shot)
        func chunk(_ i: Int, total: Int, totalBytes: Int, _ bytes: Data) -> ClipChunk {
            ClipChunk(shotID: ClipTransferTests.shot, index: i, total: total, totalBytes: totalBytes, bytes: bytes,
                      sha256: Data(SHA256.hash(data: bytes)))
        }
        #expect(!r.receive(chunk(5, total: Int.max, totalBytes: 1, Data(count: 64))).ok)
        #expect(!r.receive(chunk(0, total: 1, totalBytes: 1, Data(count: 2))).ok)
        #expect(r.receive(chunk(0, total: 2, totalBytes: 3, Data(count: 2))).ok)
        #expect(!r.receive(chunk(1, total: 2, totalBytes: 3, Data(count: 2))).ok)  // 4 > 3 declared
        #expect(r.receive(chunk(1, total: 2, totalBytes: 3, Data(count: 1))).ok)
        #expect(r.assembled?.count == 3)
    }

    // MARK: MINOR — queued chunks wait while aiming; lost chunks are resent

    @Test func queuedBulkWaitsUntilTransmitAllowed() {
        var q = OutboundQueue(bytesPerSecond: 1_000_000, burst: 1_000_000)
        let p = PeerID()
        q.enqueue(.init(to: [p], lane: .bulk, data: Data(count: 10)))
        q.enqueue(.init(to: [p], lane: .control, data: Data(count: 10)))
        #expect(q.drain(now: 0, allowBulk: false).map(\.lane) == [.control])
        #expect(q.drain(now: 0.1, allowBulk: true).map(\.lane) == [.bulk])
    }

    @Test func unacknowledgedChunksAreResentAfterTimeout() {
        var node = MeshNode(status: PeerStatus(deviceClass: 15, batteryPercent: 50, onPower: false))
        let host = PeerID()
        let shotID = UUID()
        _ = node.start(now: 0)
        _ = node.peerConnected(host, now: 0)
        _ = node.handle(Self.env(node, from: host, .heartbeat(Heartbeat(term: 1, host: host, lastSeq: 0, commitSeq: 0,
                                                                          phase: .settled))), now: 0.01)
        _ = node.handle(Self.env(node, from: host, .heartbeat(Heartbeat(term: 1, host: host, lastSeq: 0, commitSeq: 0,
                                                                          phase: .settled)), seq: 2), now: 0.015)
        #expect(node.phase == .settled)
        _ = node.offerClip(shotID: shotID, data: Data(count: 10_000), viewScore: 1, now: 0.02)
        let first = node.handle(Self.env(node, from: host, .clipRequest(ClipRequest(shotID: shotID)), seq: 3), now: 0.03)
        #expect(first.outbound.contains { if case .clipChunk = $0.message { true } else { false } })
        // Keep the host alive, never ack: the in-flight chunk must go out again.
        var resent = false
        var t = 0.05
        var seq: UInt64 = 4
        while t < 0.03 + MeshConfig().clipAckTimeout + 0.5 {
            seq += 1
            _ = node.handle(Self.env(node, from: host, .heartbeat(Heartbeat(term: 1, host: host, lastSeq: 0,
                                                                              commitSeq: 0, phase: .settled)),
                                     seq: seq), now: t)
            let s = node.tick(now: t)
            if s.outbound.contains(where: { if case .clipChunk = $0.message { true } else { false } }) { resent = true }
            t += 0.05
        }
        #expect(resent)
    }
}

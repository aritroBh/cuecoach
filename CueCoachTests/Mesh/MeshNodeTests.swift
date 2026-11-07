import Foundation
import Testing
import Geometry
import Rules
@testable import CueCoach

/// Session protocol on the in-memory network: join, election, replication, host migration
/// ("killing host keeps game", SPEC Phase 5), clock sync, rule vote, clip transfer (D3).
@Suite struct MeshNodeTests {
    static func shot(_ n: Int) -> GameEvent {
        .shot(ShotRecord(shotID: UUID(), shooterTeam: n % 2, outcome: ShotOutcome(), postState: nil))
    }

    /// Device classes chosen so the expected winner is obvious: higher index = newer phone.
    static func mesh(_ n: Int, seed: UInt64 = 1, loss: Double = 0) -> (SimNetwork, [PeerID]) {
        let net = SimNetwork(seed: seed, unreliableLoss: loss)
        let ids = (0..<n).map { i in net.addNode(device: 15 + i % 4, battery: 30 + 7 * i) }
        net.run(for: 2.5)
        return (net, ids)
    }

    static func expectConverged(_ net: SimNetwork, sourceLocation: SourceLocation = #_sourceLocation) {
        let alive = net.aliveIDs
        #expect(net.hosts.count == 1, "hosts: \(net.hosts)", sourceLocation: sourceLocation)
        guard let host = net.hosts.first else { return }
        let hostLog = net.node(host).log
        for p in alive {
            let n = net.node(p)
            #expect(n.log == hostLog, "log of \(p) differs", sourceLocation: sourceLocation)
            #expect(n.hostID == host, sourceLocation: sourceLocation)
            #expect(n.term == net.node(host).term, sourceLocation: sourceLocation)
        }
    }

    // MARK: one phone

    @Test func onePhoneHostsAloneAndCommitsImmediately() {
        let (net, ids) = Self.mesh(1)
        let me = ids[0]
        #expect(net.node(me).role == .host)
        #expect(net.node(me).term == 1)
        net.act(me) { n, t in n.append(Self.shot(1), now: t) }
        #expect(net.node(me).log.count == 1)
        #expect(net.node(me).commitSeq == 1)
    }

    // MARK: join + election

    @Test(arguments: 2...8)
    func everyoneAgreesOnTheRankedHost(n: Int) {
        let (net, ids) = Self.mesh(n)
        Self.expectConverged(net)
        let statuses = Dictionary(uniqueKeysWithValues: ids.map { ($0, net.node($0).status) })
        #expect(net.hosts.first == HostElection.elect(statuses, order: .deviceFirst))
        for p in ids { #expect(Set(net.node(p).roster) == Set(ids)) }
    }

    @Test func ninthPhoneIsRejected() {
        let (net, ids) = Self.mesh(8)
        let ninth = net.addNode(device: 20)
        net.run(for: 2)
        #expect(net.updates(ninth).contains(.rejected(.sessionFull)))
        #expect(net.node(ninth).role != .host || net.hosts.count == 2) // it may host alone, never joins
        for p in ids { #expect(!net.node(p).roster.contains(ninth)) }
        #expect(net.node(ids[0]).roster.count == 8)
    }

    /// Hysteresis: a better phone arriving mid-game joins as a client; the sitting host keeps hosting.
    @Test func betterLatePhoneDoesNotStealHost() {
        let (net, _) = Self.mesh(2)
        let host = net.hosts.first!
        let late = net.addNode(device: 30, battery: 100)
        net.run(for: 2)
        Self.expectConverged(net)
        #expect(net.hosts == [host])
        #expect(net.node(late).role == .client(host: host))
    }

    @Test func lateJoinerGetsFullLog() {
        let (net, _) = Self.mesh(3)
        let host = net.hosts.first!
        for i in 0..<5 { net.act(host) { n, t in n.append(Self.shot(i), now: t) } }
        net.run(for: 0.5)
        _ = net.addNode(device: 15)
        net.run(for: 2)
        Self.expectConverged(net)
        #expect(net.node(host).log.count == 5)
    }

    @Test func versionMismatchIsRejected() {
        let net = SimNetwork()
        var old = MeshConfig()
        old.supportedMajors = [0]
        let a = net.addNode(device: 18)
        let b = net.addNode(device: 15, config: old)
        net.run(for: 3)
        #expect(net.updates(b).contains(.rejected(.versionTooOld)))
        #expect(!net.node(a).roster.contains(b))
    }

    // MARK: replication

    @Test func hostAppendsReplicateAndCommitByMajority() {
        let (net, _) = Self.mesh(5)
        let host = net.hosts.first!
        for i in 0..<3 { net.act(host) { n, t in n.append(Self.shot(i), now: t) } }
        #expect(net.node(host).commitSeq == 0) // nobody has acked yet
        net.run(for: 0.5)
        Self.expectConverged(net)
        for p in net.aliveIDs { #expect(net.node(p).commitSeq == 3) }
    }

    @Test func clientProposalIsAppendedByHost() {
        let (net, ids) = Self.mesh(3)
        let client = ids.first { net.node($0).role != .host }!
        let e = GameEvent.shooterCorrection(shotID: UUID(), team: 1)
        net.act(client) { n, t in n.append(e, now: t) }
        net.run(for: 0.5)
        Self.expectConverged(net)
        #expect(net.node(client).log.map(\.event) == [e])
    }

    // MARK: host migration

    @Test(arguments: 2...8)
    func killingHostKeepsGame(n: Int) {
        let (net, _) = Self.mesh(n)
        let old = net.hosts.first!
        for i in 0..<4 { net.act(old) { m, t in m.append(Self.shot(i), now: t) } }
        net.run(for: 0.5)
        let committed = net.node(old).log
        let oldTerm = net.node(old).term
        let expected = HostElection.succession(
            Dictionary(uniqueKeysWithValues: net.aliveIDs.map { ($0, net.node($0).status) }), order: .deviceFirst)[1]

        net.kill(old)
        net.run(for: MeshConfig().failTimeout + 0.5)   // migration gate: ≤ T_fail + 0.5 s
        if n == 1 { return }
        #expect(net.hosts == [expected])
        #expect(net.node(expected).term == oldTerm + 1)
        Self.expectConverged(net)
        #expect(Array(net.node(expected).log.prefix(4)) == committed)

        // The game goes on under the new host.
        net.act(expected) { m, t in m.append(Self.shot(9), now: t) }
        net.run(for: 0.5)
        Self.expectConverged(net)
        #expect(net.node(expected).log.count == 5)
        for p in net.aliveIDs { #expect(!net.node(p).roster.contains(old)) }
    }

    /// The successor missed an entry that the other client acked (so it was committed). The new host must
    /// recover it from the survivors' tails before resuming, not overwrite it.
    @Test func newHostRecoversCommittedEntryItNeverReceived() {
        let (net, ids) = Self.mesh(3)
        let old = net.hosts.first!
        let statuses = Dictionary(uniqueKeysWithValues: ids.map { ($0, net.node($0).status) })
        let succ = HostElection.succession(statuses, order: .deviceFirst)[1]
        net.slowLink(from: old, to: succ, extra: 0.5)
        net.act(old) { m, t in m.append(Self.shot(1), now: t) }
        net.run(for: 0.1)
        #expect(net.node(old).commitSeq == 1)       // host + the fast client
        #expect(net.node(succ).log.isEmpty)         // still in flight on the slow link
        net.kill(old)
        // A new event proposed the moment the new host takes over must not take seq 1.
        net.run(for: 1.6)
        if net.hosts == [succ] { net.act(succ) { m, t in m.append(Self.shot(2), now: t) } }
        net.run(for: 1.5)
        Self.expectConverged(net)
        #expect(net.hosts == [succ])
        #expect(net.node(succ).log.first?.event == net.node(ids.first { $0 != old && $0 != succ }!).log.first?.event)
        #expect(net.node(succ).log.count == 2)
        #expect(net.node(succ).log.first?.term == 1)
    }

    @Test func disconnectCallbackFailsOverFasterThanTimeout() {
        let (net, _) = Self.mesh(3)
        net.disconnectNoticeDelay = 0.2
        let old = net.hosts.first!
        net.kill(old)
        net.run(for: 0.5)
        #expect(net.hosts.count == 1 && net.hosts.first != old)
    }

    @Test func survivesSuccessiveHostDeaths() {
        let (net, _) = Self.mesh(8)
        var total = 0
        for round in 0..<5 {
            let h = net.hosts.first!
            for i in 0..<3 { net.act(h) { m, t in m.append(Self.shot(round * 10 + i), now: t) }; total += 1 }
            net.run(for: 0.5)
            net.kill(h)
            net.run(for: 2.5)
            Self.expectConverged(net)
            #expect(net.node(net.hosts.first!).log.count == total)
        }
        #expect(net.aliveIDs.count == 3)
    }

    /// Randomised kill-host sims: lossy realtime channel, jitter, events appended up to the instant of death.
    /// Invariant: every committed event survives on every phone, logs converge, one host.
    @Test(arguments: 0..<60)
    func randomKillHostNeverLosesCommittedEvents(seed: Int) {
        var rng = SeededRNG(seed: UInt64(seed) &* 7919)
        let n = Int.random(in: 2...8, using: &rng)
        let net = SimNetwork(seed: UInt64(seed), latency: Double.random(in: 0.002...0.03, using: &rng),
                             jitter: 0.01, unreliableLoss: 0.2)
        for _ in 0..<n {
            net.addNode(device: Int.random(in: 15...18, using: &rng), battery: Int.random(in: 5...100, using: &rng),
                        clockOffset: Double.random(in: -5...5, using: &rng))
        }
        net.run(for: 2.5)
        Self.expectConverged(net)
        let kills = Int.random(in: 1...max(1, n - 1), using: &rng)
        var committedEver: [LogEntry] = []
        for _ in 0..<kills {
            let h = net.hosts.first!
            for i in 0..<Int.random(in: 0...6, using: &rng) {
                net.act(h) { m, t in m.append(Self.shot(i), now: t) }
                net.run(for: Double.random(in: 0...0.05, using: &rng))
            }
            let c = net.node(h).log.prefix(Int(net.node(h).commitSeq))
            committedEver = Array(c)
            net.kill(h)
            net.run(for: 3)
            Self.expectConverged(net)
            let log = net.node(net.hosts.first!).log
            #expect(Array(log.prefix(committedEver.count)) == committedEver, "seed \(seed): committed entry lost")
        }
    }

    /// The old host comes back after a partition with a stale term: it steps down and adopts the new log.
    @Test func partitionedOldHostStepsDownOnHeal() {
        let (net, ids) = Self.mesh(3)
        let old = net.hosts.first!
        let others = ids.filter { $0 != old }
        net.act(old) { m, t in m.append(Self.shot(1), now: t) }
        net.run(for: 0.5)
        net.partition([old], others)
        net.act(old) { m, t in m.append(Self.shot(2), now: t) }   // provisional, never replicated
        net.run(for: 3)
        let newHost = net.hosts.first { $0 != old }!
        net.act(newHost) { m, t in m.append(Self.shot(3), now: t) }
        net.run(for: 0.5)
        net.heal()
        net.run(for: 2)
        Self.expectConverged(net)
        #expect(net.hosts == [newHost])
        #expect(net.node(old).role == .client(host: newHost))
        #expect(net.node(old).term == net.node(newHost).term)
        #expect(net.node(newHost).log.count == 2)
    }

    /// Lobby: two phones that each claimed hosting before seeing each other converge to the better one.
    @Test func splitLobbyResolvesToOneHost() {
        let net = SimNetwork()
        let a = net.addNode(device: 15)
        let b = net.addNode(device: 18)
        net.partition([a], [b])
        net.run(for: 2)
        #expect(net.hosts.count == 2)
        net.heal()
        net.run(for: 2)
        Self.expectConverged(net)
        #expect(net.hosts == [b])
    }

    // MARK: clock sync

    @Test func clientClockSyncsToHostAndDetectionsArriveInHostTime() {
        let net = SimNetwork(seed: 4, latency: 0.006, jitter: 0.004, unreliableLoss: 0.2)
        let host = net.addNode(device: 18, clockOffset: 1000)
        let client = net.addNode(device: 15, clockOffset: 3.7, skew: 40e-6)
        net.run(for: 8)
        #expect(net.node(client).hostID == host)
        let est = try! #require(net.node(client).clock.estimate)
        let truth = net.localTime(host) - net.localTime(client)
        #expect(abs(est.offset - truth) < 0.005, "offset error \(est.offset - truth)")
        #expect(est.latency > 0.004 && est.latency < 0.02)

        net.unreliableLoss = 0
        let captured = net.localTime(client)
        net.act(client) { n, t in
            n.sendTableState(TableStateFrame(captureTime: Int64(captured * 1e9), balls: []), now: t)
        }
        net.run(for: 0.1)
        let frames = net.updates(host).compactMap { u -> TableStateFrame? in
            if case .tableState(_, let f) = u { return f } else { return nil }
        }
        let f = try! #require(frames.last)
        let hostTimeAtCapture = net.localTime(host) - 0.1
        #expect(abs(Double(f.captureTime) / 1e9 - hostTimeAtCapture) < 0.005)
    }

    /// Without a clock fit a client's capture times are meaningless to the host's fusion: drop, don't guess.
    @Test func detectionsBeforeClockSyncAreDropped() {
        var node = MeshNode(status: PeerStatus(deviceClass: 15, batteryPercent: 50, onPower: false))
        let host = PeerID()
        _ = node.start(now: 0)
        _ = node.peerConnected(host, now: 0)
        let hb = MeshEnvelope(version: .current, sessionID: UUID(), sender: host, seq: 1, sentAt: 0,
                              message: .heartbeat(Heartbeat(term: 1, host: host, lastSeq: 0, commitSeq: 0,
                                                            phase: .aiming)))
        _ = node.handle(hb, now: 0.01)
        #expect(node.role == .client(host: host))
        let step = node.sendTableState(TableStateFrame(captureTime: 5, balls: []), now: 0.02)
        #expect(!step.outbound.contains { if case .tableState = $0.message { true } else { false } })
    }

    @Test func clockResetsAfterHostChange() {
        let (net, ids) = Self.mesh(3)
        let old = net.hosts.first!
        net.kill(old)
        net.run(for: 3)
        let newHost = net.hosts.first!
        let client = ids.first { $0 != old && $0 != newHost }!
        let est = try! #require(net.node(client).clock.estimate)
        let truth = net.localTime(newHost) - net.localTime(client)
        #expect(abs(est.offset - truth) < 0.005)
    }

    // MARK: rule vote

    @Test func ruleVoteMajorityWinsAndIsLogged() {
        let (net, ids) = Self.mesh(3)
        let host = net.hosts.first!
        net.act(host) { n, t in n.openRuleVote(now: t) }
        net.run(for: 0.2)
        let choices: [RuleSetID] = [.wpaNine, .wpaNine, .barEight]
        for (p, c) in zip(ids, choices) { net.act(p) { n, t in n.castBallot(c, now: t) } }
        net.run(for: 0.5)
        Self.expectConverged(net)
        #expect(net.node(host).log.map(\.event) == [.ruleSetChosen(.wpaNine)])
        for p in ids { #expect(net.updates(p).contains(.ruleVoteClosed(.wpaNine))) }
        for p in ids { #expect(net.updates(p).contains { if case .ruleVoteOpened = $0 { true } else { false } }) }
    }

    @Test func ruleVoteDeadlineWithoutBallotsUsesDefault() {
        let (net, _) = Self.mesh(2)
        let host = net.hosts.first!
        net.act(host) { n, t in n.openRuleVote(now: t) }
        net.run(for: MeshConfig().voteDeadline + 1)
        #expect(net.node(host).log.map(\.event) == [.ruleSetChosen(.barEight)])
    }

    // MARK: clips (D3)

    @Test func bestViewClipIsPulledOnlyWhileSettled() {
        let (net, ids) = Self.mesh(3)
        net.recordDeliveries = true
        let host = net.hosts.first!
        let clients = ids.filter { $0 != host }
        let shotID = UUID()
        let clip = Data((0..<2_000_000).map { UInt8($0 % 251) })   // ~31 chunks: can't finish before aiming
        net.act(host) { n, t in n.setPhase(.settled, now: t) }
        net.run(for: 0.1)
        net.act(host) { n, t in n.offerClip(shotID: shotID, data: Data([1]), viewScore: 0.3, now: t) }
        net.act(clients[0]) { n, t in n.offerClip(shotID: shotID, data: Data([2]), viewScore: 0.4, now: t) }
        net.act(clients[1]) { n, t in n.offerClip(shotID: shotID, data: clip, viewScore: 0.9, now: t) }
        net.run(for: 0.03)
        net.act(host) { n, t in n.setPhase(.aiming, now: t) }   // someone addresses the cue ball mid-transfer
        net.run(for: 2)
        let aimingFrom = net.now - 2
        let chunksDuringAim = net.delivered.filter {
            if case .clipChunk = $0.message, $0.t > aimingFrom + 0.05 { true } else { false }
        }
        #expect(chunksDuringAim.isEmpty, "\(chunksDuringAim.count) chunks sent while aiming")
        #expect(!net.updates(host).contains { if case .clipReceived = $0 { true } else { false } })

        net.act(host) { n, t in n.setPhase(.settled, now: t) }
        net.run(for: 3)
        let got = net.updates(host).compactMap { u -> (PeerID, Data)? in
            if case .clipReceived(let s, let from, let d) = u, s == shotID { (from, d) } else { nil }
        }
        #expect(got.count == 1)
        #expect(got.first?.0 == clients[1])
        #expect(got.first?.1 == clip)
    }

    @Test func hostsOwnClipNeedsNoTransfer() {
        let (net, ids) = Self.mesh(2)
        net.recordDeliveries = true
        let host = net.hosts.first!
        let client = ids.first { $0 != host }!
        let shotID = UUID()
        net.act(host) { n, t in n.setPhase(.settled, now: t) }
        net.act(host) { n, t in n.offerClip(shotID: shotID, data: Data([7, 7]), viewScore: 0.8, now: t) }
        net.act(client) { n, t in n.offerClip(shotID: shotID, data: Data([1]), viewScore: 0.8, now: t) } // tie → host
        net.run(for: 1)
        #expect(net.updates(host).contains(.clipReceived(shotID: shotID, from: host, data: Data([7, 7]))))
        #expect(!net.delivered.contains { if case .clipChunk = $0.message { true } else { false } })
    }

    // MARK: phases + calibration

    @Test func phaseAndCalibrationReachEveryone() {
        let (net, ids) = Self.mesh(3)
        let host = net.hosts.first!
        let client = ids.first { $0 != host }!
        net.act(host) { n, t in n.setPhase(.inMotion, now: t) }
        let report = CalibrationReport(homography: [1, 0, 0, 0, 1, 0, 0, 0, 1], residualPixels: 0.8,
                                       tableSize: .eightFoot)
        net.act(client) { n, t in n.sendCalibration(report, now: t) }
        net.run(for: 0.3)
        for p in ids { #expect(net.node(p).phase == .inMotion) }
        #expect(net.updates(host).contains(.calibration(from: client, report)))
    }

    /// Unknown future message types are ignored without breaking the session.
    @Test func unknownMessagesAreIgnoredAndCounted() {
        let (net, _) = Self.mesh(2)
        let host = net.hosts.first!
        let env = MeshEnvelope(version: ProtocolVersion(major: 1, minor: 5), sessionID: UUID(), sender: PeerID(),
                               seq: 1, sentAt: 0, message: .unknown(type: "future"))
        net.act(host) { n, t in n.handle(env, now: t) }
        #expect(net.node(host).ignoredMessages == 1)
        #expect(net.node(host).role == .host)
    }
}

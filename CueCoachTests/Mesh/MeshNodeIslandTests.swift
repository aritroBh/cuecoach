import Foundation
import Testing
import Geometry
import Rules
import Engine
@testable import CueCoach

/// Plan 013a (§2.5): losing the host keeps the game. Every phone keeps its own settles (the shot in flight is re-run
/// by the new host), a phone cut off from a majority is an island, and islands' shots merge on heal.
extension MeshNodeTests {
    static let pot1 = ShotOutcome(firstContact: BallID(1)!, pocketed: [BallID(1)!: .footLeft])
    static let miss1 = ShotOutcome(firstContact: BallID(1)!)

    /// A distinct table layout per physical shot `n` (balls well over a radius apart between layouts).
    static func layout(_ n: Int) -> TableState {
        let balls: [BallID: Vec2] = [.cue: Vec2(0.3 + 0.1 * Double(n), 0.5), BallID(1)!: Vec2(1.5, 0.2 + 0.05 * Double(n)),
                                     .eight: Vec2(1.9, 0.8)]
        return TableState(spec: TableSpec(size: .eightFoot), balls: balls.mapValues { BallState(position: $0) })
    }

    static func view(_ n: Int, outcome: ShotOutcome = pot1, isGuess: Bool = false) -> GameEvent {
        .shot(MeshShotRecord(shotID: UUID(), shooterTeam: 0, outcome: outcome, postState: nil, preState: layout(n),
                             isGuess: isGuess))
    }

    static func records(_ log: [LogEntry]) -> [MeshShotRecord] {
        log.compactMap { if case .shot(let r) = $0.event { r } else { nil } }
    }

    static func ids(_ e: GameEvent) -> UUID? { if case .shot(let r) = e { r.shotID } else { nil } }

    /// Phones see one physical shot: each settles its own view, stroke `ago` seconds before now on its own clock.
    static func see(_ net: SimNetwork, _ views: [(PeerID, GameEvent)], ago: Double = 1) {
        for (p, e) in views { net.act(p) { n, t in n.settled(e, strokeAt: t - ago, now: t) } }
    }

    /// Two phones with very different clocks: A (host, device 18) and B (device 15).
    static func pair() -> (SimNetwork, PeerID, PeerID) {
        let net = SimNetwork(seed: 13)
        let a = net.addNode(device: 18, clockOffset: 1000)
        let b = net.addNode(device: 15, clockOffset: 3.7, skew: 40e-6)
        net.run(for: 2.5)
        return (net, a, b)
    }

    /// Host (device 18, killed in the tests), successor (17), another client (15); clocks all differ.
    static func trio() -> (SimNetwork, host: PeerID, succ: PeerID, other: PeerID) {
        let net = SimNetwork(seed: 17)
        let h = net.addNode(device: 18, clockOffset: 500)
        let s = net.addNode(device: 17, clockOffset: -20, skew: 30e-6)
        let o = net.addNode(device: 15, clockOffset: 7)
        net.run(for: 2.5)
        return (net, h, s, o)
    }

    // MARK: island state

    @Test func islandStateIsReported() {
        let (net, a, b) = Self.pair()
        #expect(!net.node(a).isIsland && !net.node(b).isIsland)
        net.partition([a], [b])
        net.run(for: 3)
        #expect(net.node(a).isIsland, "a host without a majority")
        #expect(net.node(b).isIsland, "the claimant of a two-phone split")
        #expect(net.updates(a).contains(.island(true)) && net.updates(b).contains(.island(true)))
        net.heal()
        net.run(for: 2)
        #expect(!net.node(a).isIsland && !net.node(b).isIsland)
        for p in [a, b] {
            let last = net.updates(p).last { if case .island = $0 { true } else { false } }
            #expect(last == .island(false))
        }
    }

    @Test func aLoneOrMajorityPhoneIsNeverAnIsland() {
        let (one, ids) = Self.mesh(1)
        #expect(!one.node(ids[0]).isIsland)
        let (net, three) = Self.mesh(3)
        let old = net.hosts.first!
        net.kill(old)
        net.run(for: 3)
        for p in three where p != old { #expect(!net.node(p).isIsland, "two of three still commit") }
    }

    // MARK: every phone keeps its own settles

    @Test func hostSettleIsLoggedOnTheGameClock() throws {
        let (net, a, b) = Self.pair()
        Self.see(net, [(a, Self.view(1)), (b, Self.view(1))], ago: 2)
        net.run(for: 0.5)
        Self.expectConverged(net)
        let r = try #require(Self.records(net.node(a).log).first)
        #expect(Self.records(net.node(a).log).count == 1, "the client's own settle is kept, not logged")
        let stroke = try #require(r.strokeHostTime)
        #expect(abs(Double(stroke) / 1e9 - (net.localTime(a) - 2.5)) < 0.01, "host clock")
    }

    @Test func hostKilledMidShotTheNewHostAppendsItsOwnSettle() throws {
        let (net, h, s, o) = Self.trio()
        Self.see(net, [(h, Self.view(0)), (s, Self.view(0)), (o, Self.view(0))])
        net.run(for: 0.5)
        #expect(Self.records(net.node(s).log).count == 1)
        // Shot 1 settles on the clients; the host dies before logging it.
        let strokeOnHostClock = net.localTime(h) - 1
        Self.see(net, [(s, Self.view(1)), (o, Self.view(1))])
        net.kill(h)
        net.run(for: 3)
        Self.expectConverged(net)
        #expect(net.hosts == [s])
        let log = net.node(s).log
        #expect(Self.records(log).count == 2, "re-run once, from both survivors' settles")
        #expect(net.node(s).commitSeq == UInt64(log.count))
        let rerun = try #require(Self.records(log).last)
        #expect(rerun.preState == Self.layout(1))
        let stroke = try #require(rerun.strokeHostTime)
        #expect(abs(Double(stroke) / 1e9 - strokeOnHostClock) < 0.02, "stays on the first host's clock")
    }

    @Test func aShotTheDeadHostAlreadySentIsNotReRun() {
        let (net, h, s, o) = Self.trio()
        let mine = Self.view(1)
        Self.see(net, [(s, Self.view(1)), (o, Self.view(1))])
        Self.see(net, [(h, mine)])
        net.run(for: 0.008)                      // the entry reached the clients; the host dies before more
        net.kill(h)
        net.run(for: 3)
        Self.expectConverged(net)
        #expect(Self.records(net.node(s).log).map(\.shotID) == [Self.ids(mine)!])
    }

    @Test func noConfidentSettleBecomesAGap() throws {
        let (net, h, s, o) = Self.trio()
        Self.see(net, [(h, Self.view(0)), (s, Self.view(0)), (o, Self.view(0))])
        net.run(for: 0.5)
        Self.see(net, [(s, .shotLost(shotID: UUID(), shooterTeam: 1)), (o, .shotLost(shotID: UUID(), shooterTeam: 1))])
        net.kill(h)
        net.run(for: 3)
        Self.expectConverged(net)
        let events = net.node(s).log.map(\.event)
        #expect(events.count == 2)
        guard case .shotLost = try #require(events.last) else { Issue.record("not a gap: \(events)"); return }
    }

    @Test func oneConfidentSettleBeatsALostOne() {
        let (net, h, s, o) = Self.trio()
        Self.see(net, [(h, Self.view(0)), (s, Self.view(0)), (o, Self.view(0))])
        net.run(for: 0.5)
        let seen = Self.view(1)
        Self.see(net, [(s, .shotLost(shotID: UUID(), shooterTeam: 0)), (o, seen)])
        net.kill(h)
        net.run(for: 3)
        Self.expectConverged(net)
        let events = net.node(s).log.map(\.event)
        #expect(events.count == 2)
        #expect(events.last.flatMap(Self.ids) == Self.ids(seen))
    }

    @Test func aSettleTheHostAnsweredIsDropped() {
        let (net, a, b) = Self.pair()
        Self.see(net, [(b, Self.view(1))])                       // the host lost this one: it logs a gap
        net.act(a) { n, t in n.settled(.shotLost(shotID: UUID(), shooterTeam: 0), strokeAt: t - 1, now: t) }
        net.run(for: 0.5)
        Self.see(net, [(a, Self.view(2)), (b, Self.view(2))])
        net.run(for: 0.5)
        net.kill(a)
        net.run(for: 3)
        #expect(net.node(b).log.count == 2, "no re-run of shots the dead host had answered")
    }

    // MARK: island merge on heal (D44)

    /// Replaces plan 009's `partitionedOldHostStepsDownOnHeal` two-phone expectation: shots appended on either side
    /// of a split are kept, matched ones once. The claimant is a lone survivor of two, so it commits its own island
    /// shots alone (pre-existing rule, `loneSurvivorOfTwoPhoneGameCommits`); committed entries never change, so the
    /// other island's unmatched shots follow them and a disagreement with a committed shot is flagged, not replaced.
    @Test func twoPhoneSplitKeepsBothIslandsShotsOnHeal() throws {
        let (net, a, b) = Self.pair()
        Self.see(net, [(a, Self.view(0)), (b, Self.view(0))])
        net.run(for: 0.5)
        net.partition([a], [b])
        net.run(for: 3)
        #expect(net.node(a).isIsland && net.node(b).isIsland)
        let a1 = Self.view(1), b1 = Self.view(1)                        // both saw shot 1
        Self.see(net, [(a, a1), (b, b1)])
        net.run(for: 8)
        let a2 = Self.view(2)                                           // only A saw shot 2
        Self.see(net, [(a, a2)])
        net.run(for: 8)
        let b3 = Self.view(3)                                           // only B saw shot 3
        Self.see(net, [(b, b3)])
        net.run(for: 8)
        let a4 = Self.view(4, outcome: Self.pot1), b4 = Self.view(4, outcome: Self.miss1, isGuess: true)
        Self.see(net, [(a, a4), (b, b4)])                               // they disagree on shot 4
        net.run(for: 1)
        #expect(net.node(a).commitSeq == 1, "the old host has no majority (quorum 2 of 2): it commits nothing")
        #expect(net.node(b).commitSeq == net.node(b).lastSeq && net.node(b).lastSeq == 4,
                "the lone survivor of two commits alone (loneSurvivorOfTwoPhoneGameCommits)")
        net.heal()
        net.run(for: 3)
        Self.expectConverged(net)
        let host = try #require(net.hosts.first)
        #expect(host == b)
        let log = net.node(host).log
        #expect(net.node(host).commitSeq == UInt64(log.count), "the merged log commits")
        let shots = Self.folded(log).dropFirst()
        #expect(shots.map(\.preState) == [1, 3, 4, 2].map { Self.layout($0) }, "each physical shot once")
        #expect(shots.map(\.shotID) == [b1, b3, b4, a2].compactMap(Self.ids), "committed shots keep their place")
        #expect(shots.map(\.needsTap) == [false, false, true, false], "shot 4 disagrees with a committed shot")
    }

    /// Records folded by shotID: a repeated id is a flag amendment of the first (needsTap OR-ed), never a new shot.
    static func folded(_ log: [LogEntry]) -> [MeshShotRecord] {
        var out: [MeshShotRecord] = []
        for r in records(log) {
            if let i = out.firstIndex(where: { $0.shotID == r.shotID }) { out[i].needsTap = out[i].needsTap || r.needsTap }
            else { out.append(r) }
        }
        return out
    }

    // MARK: Codex 013a review

    /// Isolate one client of three: the other two commit; the isolated phone claims a higher term and wins the heal.
    static func isolatedClientWins(minority: [GameEvent] = [], majority: GameEvent? = nil,
                                   majorityGap: Bool = false) -> (SimNetwork, host: PeerID, succ: PeerID, other: PeerID) {
        let (net, h, s, o) = trio()
        Self.see(net, [(h, Self.view(0)), (s, Self.view(0)), (o, Self.view(0))])
        net.run(for: 0.5)
        net.partition([o], [h, s])
        net.run(for: 3)
        for e in minority { Self.see(net, [(o, e)]) }
        if let majority { Self.see(net, [(h, majority)]) }
        if majorityGap { Self.see(net, [(h, .shotLost(shotID: UUID(), shooterTeam: 0))]) }
        net.run(for: 1)
        return (net, h, s, o)
    }

    /// P1-1: the winner of the heal pulls the other side's committed entries, not only its tail.
    @Test func anIsolatedClientThatWinsTheTermKeepsTheMajoritysCommittedShots() throws {
        let x = Self.view(1)
        let (net, h, s, o) = Self.isolatedClientWins(majority: x)
        #expect(net.node(h).commitSeq == 2 && net.node(s).commitSeq == 2, "the majority committed shot 1")
        #expect(net.node(o).term > net.node(h).term)
        net.heal()
        net.run(for: 3)
        Self.expectConverged(net)
        #expect(net.hosts == [o])
        let log = net.node(o).log
        #expect(Self.folded(log).map(\.shotID).contains(Self.ids(x)!), "a committed shot never disappears")
        #expect(net.node(o).commitSeq == UInt64(log.count))
    }

    /// P1-2: a commit drops only the kept settle it answers; another kept settle survives for the re-run.
    @Test func aLaterCommitNeverDropsAnotherKeptSettle() {
        let (net, a, b) = Self.pair()
        net.slowLink(from: a, to: b, extra: 0.6)
        let x1 = Self.view(1)
        Self.see(net, [(a, x1), (b, Self.view(1))])
        net.run(for: 0.3)
        let x2 = Self.view(2)                                  // the host missed shot 2
        net.act(b) { n, t in n.settled(x2, strokeAt: t - 0.2, now: t) }
        net.run(for: 2)                                        // shot 1's commit reaches B after B kept shot 2
        net.kill(a)
        net.run(for: 3)
        #expect(Self.folded(net.node(b).log).map(\.preState) == [1, 2].map { Self.layout($0) })
    }

    /// P1-3: a settle that arrives after its shot committed is never re-run by a new host.
    @Test func aLateSettleOfACommittedShotIsNotReRun() {
        let (net, a, b) = Self.pair()
        Self.see(net, [(a, Self.view(1))], ago: 1)
        net.run(for: 0.5)
        Self.see(net, [(b, Self.view(1))], ago: 1.5)          // same stroke, settled late on B
        net.run(for: 0.5)
        net.kill(a)
        net.run(for: 3)
        #expect(Self.records(net.node(b).log).count == 1)
    }

    /// P1-4: entries a heal adds commit only once a majority of the current roster holds them.
    @Test func mergedEntriesCommitOnlyOnceReplicated() {
        let (net, a, b) = Self.pair()
        net.partition([a], [b])
        net.run(for: 3)
        Self.see(net, [(a, Self.view(1))])
        net.run(for: 5)
        Self.see(net, [(b, Self.view(2))])
        net.run(for: 1)
        net.slowLink(from: b, to: a, extra: 0.4)               // B's welcome reaches A late
        let pre = net.node(b).lastSeq
        #expect(net.node(b).commitSeq == pre, "the lone survivor committed its own island shot")
        net.heal()
        var sawMerge = false
        for _ in 0..<600 {
            net.run(for: 0.005)
            let nb = net.node(b), na = net.node(a)
            if nb.lastSeq > pre { sawMerge = true }
            let committed = Array(nb.log.prefix(Int(nb.commitSeq)))
            if nb.commitSeq > pre {
                #expect(Array(na.log.prefix(committed.count)) == committed, "committed before A holds it")
            }
        }
        #expect(sawMerge)
        Self.expectConverged(net)
    }

    /// P1-4: an acknowledgement for an entry the host has since replaced does not count.
    @Test func anAckForAReplacedEntryIsIgnored() {
        var host = MeshNode(status: PeerStatus(deviceClass: 18, batteryPercent: 50, onPower: false))
        let c = PeerID()
        _ = host.start(now: 0)
        _ = host.tick(now: 1.1)
        #expect(host.isHost)
        _ = host.peerConnected(c, now: 1.1)
        func env(_ m: MeshMessage) -> MeshEnvelope {
            MeshEnvelope(version: .current, sessionID: host.sessionID, sender: c, seq: 1, sentAt: 0, message: m)
        }
        _ = host.handle(env(.hello(Hello(deviceClass: 15, batteryPercent: 50, onPower: false,
                                         supportedMajors: ProtocolVersion.supportedMajors))), now: 1.2)
        _ = host.append(Self.view(1), now: 1.3)
        #expect(host.commitSeq == 0)
        _ = host.handle(env(.logAck(LogAck(term: host.term, upTo: 1, epoch: 9))), now: 1.4)
        #expect(host.commitSeq == 0, "an ack for another version of seq 1")
        _ = host.handle(env(.logAck(LogAck(term: host.term, upTo: 1, epoch: host.log[0].epoch))), now: 1.5)
        #expect(host.commitSeq == 1)
    }

    /// P1-5: a rewrite that keeps the log length and commit point is still reported (`logChanged`).
    @Test func aSameLengthRewriteIsReported() {
        let (net, h, s, o) = Self.isolatedClientWins(minority: [Self.view(1)], majority: Self.view(1))
        let before = net.node(o).log
        net.heal()
        var last: [PeerID: (log: [LogEntry], reports: Int)] = [:]
        func reports(_ p: PeerID) -> Int { net.updates(p).filter { if case .logChanged = $0 { true } else { false } }.count }
        for p in [h, s, o] { last[p] = (net.node(p).log, reports(p)) }
        for _ in 0..<1000 {
            net.run(for: 0.002)
            for p in [h, s, o] {
                let now = (net.node(p).log, reports(p))
                if now.0 != last[p]!.log { #expect(now.1 > last[p]!.reports, "\(p) changed its log silently") }
                last[p] = now
            }
        }
        #expect(net.node(o).log != before && net.node(o).log.count == before.count, "the scenario is a same-length rewrite")
    }

    /// P1-6: a logged gap keeps its stroke time, so it reconciles with a confident view of the same stroke.
    @Test func aGapAndAConfidentViewOfOneStrokeBecomeOneShot() {
        let x = Self.view(1)
        let (net, _, _, o) = Self.isolatedClientWins(minority: [.shotLost(shotID: UUID(), shooterTeam: 0)], majority: x)
        net.heal()
        net.run(for: 3)
        Self.expectConverged(net)
        let events = net.node(o).log.map(\.event)
        #expect(events.count == 2)
        #expect(Self.ids(events.last!) == Self.ids(x), "the confident view, no gap")
    }

    @Test func twoGapsOfOneStrokeBecomeOne() {
        let (net, a, b) = Self.pair()
        net.partition([a], [b])
        net.run(for: 3)
        Self.see(net, [(a, .shotLost(shotID: UUID(), shooterTeam: 0)), (b, .shotLost(shotID: UUID(), shooterTeam: 0))])
        net.run(for: 1)
        net.heal()
        net.run(for: 3)
        Self.expectConverged(net)
        let gaps = net.node(b).log.filter { if case .shotLost = $0.event { true } else { false } }
        #expect(gaps.count == 1)
        if case .shotLost(_, _, let t) = gaps.first?.event { #expect(t != nil, "a logged gap keeps its stroke") }
    }

    /// P1-7: a committed shot that a returning island saw differently is flagged (an amendment with needsTap).
    @Test func aCommittedShotTheReturningIslandDisagreesWithIsFlagged() throws {
        let x = Self.view(1, outcome: Self.pot1)
        let (net, _, _, o) = Self.isolatedClientWins(minority: [Self.view(1, outcome: Self.miss1)], majority: x)
        net.heal()
        net.run(for: 3)
        Self.expectConverged(net)
        let shots = Self.folded(net.node(o).log)
        #expect(shots.count == 2)
        let one = try #require(shots.last)
        #expect(one.shotID == Self.ids(x) && one.outcome == Self.pot1, "the committed shot stays")
        #expect(one.needsTap)
    }

    /// P2-8: a phone that never had a clock fit has no game time: its re-run (and later host settles) are untimed.
    @Test func aSuccessorWithoutAClockFitStampsNoTime() throws {
        let net = SimNetwork(seed: 23, unreliableLoss: 1)      // time pings never arrive: no fit
        let a = net.addNode(device: 18, clockOffset: 1000)
        let b = net.addNode(device: 15, clockOffset: 3.7)
        net.run(for: 2.5)
        Self.see(net, [(b, Self.view(1))])
        net.kill(a)
        net.run(for: 3)
        Self.see(net, [(b, Self.view(2))])
        net.run(for: 0.2)
        let rs = Self.records(net.node(b).log)
        #expect(rs.count == 2)
        #expect(rs.allSatisfy { $0.strokeHostTime == nil }, "no fabricated game time: \(rs.map(\.strokeHostTime))")
    }

    @Test func islandTapsAndGapsSurviveTheMerge() {
        let (net, a, b) = Self.pair()
        net.partition([a], [b])
        net.run(for: 3)
        let tap = GameEvent.nextShooter(team: 1)
        Self.see(net, [(a, Self.view(1))])
        net.act(a) { n, t in n.append(tap, now: t) }
        net.run(for: 5)
        Self.see(net, [(b, Self.view(2))])
        net.run(for: 1)
        net.heal()
        net.run(for: 3)
        Self.expectConverged(net)
        let events = net.node(net.hosts.first!).log.map(\.event)
        #expect(events.count == 3)
        #expect(events.firstIndex(of: tap).map { $0 > 0 } == true, "a tap follows the shot before it on its island")
    }

    /// The link toggles every 0.5–3 s for two simulated minutes while both phones keep settling shots. Committed shots
    /// keep their place (Codex 013a P1-4), so the other island's shots may follow later ones: no order is asserted.
    @Test(arguments: 0..<6)
    func flappingLinkNeverDuplicatesAShot(seed: Int) {
        var rng = SeededRNG(seed: UInt64(seed) &* 31 &+ 5)
        let net = SimNetwork(seed: UInt64(seed))
        let a = net.addNode(device: 18, clockOffset: 100)
        let b = net.addNode(device: 15, clockOffset: -3, skew: 20e-6)
        net.run(for: 2.5)
        var physical: [UUID: Int] = [:]
        var cut = false, nextToggle = 0.0, nextShot = 0.0, shot = 0, toggles = 0
        while net.now < 122.5 {
            if net.now >= nextToggle {
                if cut { net.heal() } else { net.partition([a], [b]) }
                cut.toggle()
                toggles += 1
                nextToggle = net.now + Double.random(in: 0.5...3, using: &rng)
            }
            if net.now >= nextShot {
                shot += 1
                for p in [a, b] where Double.random(in: 0..<1, using: &rng) < 0.8 {
                    let v = Self.view(shot % 12)
                    physical[Self.ids(v)!] = shot
                    Self.see(net, [(p, v)])
                }
                nextShot = net.now + Double.random(in: 4...9, using: &rng)
            }
            net.run(for: 0.25)
        }
        net.heal()
        net.run(for: 6)
        Self.expectConverged(net)
        let logged = Self.records(net.node(net.hosts.first!).log).compactMap { physical[$0.shotID] }
        #expect(logged.count == Set(logged).count, "seed \(seed): a shot was logged twice: \(logged)")
        #expect(net.node(a).term <= UInt64(toggles + 2))
    }
}

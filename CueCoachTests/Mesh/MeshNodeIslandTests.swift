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
    /// of a split are kept, matched ones once.
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
        #expect(net.node(a).commitSeq == 1, "the old host's island never commits (a lone claimant may, alone)")
        net.heal()
        net.run(for: 3)
        Self.expectConverged(net)
        let host = try #require(net.hosts.first)
        let log = net.node(host).log
        #expect(net.node(host).commitSeq == UInt64(log.count), "the merged log commits")
        let shots = Self.records(log).dropFirst()
        #expect(shots.map(\.preState) == [1, 2, 3, 4].map { Self.layout($0) }, "each physical shot once, in order")
        #expect(Set([a1, b1].compactMap(Self.ids)).contains(shots.first!.shotID))
        #expect(shots.dropFirst().first?.shotID == Self.ids(a2) && shots.dropFirst(2).first?.shotID == Self.ids(b3))
        let fourth = try #require(shots.last)
        #expect(fourth.shotID == Self.ids(a4), "the confident view wins")
        #expect(fourth.needsTap)
        #expect(shots.dropLast().allSatisfy { !$0.needsTap })
        #expect(net.node(a).role == .client(host: b) || net.node(b).role == .client(host: a))
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

    /// The link toggles every 0.5–3 s for two simulated minutes while both phones keep settling shots.
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
        #expect(logged == logged.sorted(), "seed \(seed): shots out of order")
        #expect(net.node(a).term <= UInt64(toggles + 2))
    }
}

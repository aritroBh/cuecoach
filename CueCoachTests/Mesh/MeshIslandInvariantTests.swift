import Foundation
import Testing
import Geometry
import Rules
import Engine
@testable import CueCoach

/// Codex 013a review 3: the four scenarios it found, and a randomized invariant sim over host kills, splits and heals,
/// slow links, lost pings, late settles and phones with no clock.
extension MeshNodeTests {
    // MARK: the four scenarios

    /// Finding 1: H dies without logging a shot; O's retained view reaches the successor S, which merges and commits
    /// it; then S's own late view of that stroke settles. It is absorbed, not appended.
    @Test func aLateViewOfAShotRecoveredInThisTermIsNotAppended() {
        let (net, h, s, o) = Self.trio()
        Self.see(net, [(o, Self.view(1))], ago: 1)
        net.run(for: 0.2)
        net.kill(h)
        net.run(for: 3)
        #expect(net.hosts == [s])
        #expect(Self.folded(net.node(s).log).count == 1 && net.node(s).commitSeq == 1, "o's view recovered and committed")
        Self.see(net, [(s, Self.view(1))], ago: 4.2)        // the same stroke, settled late on S
        net.run(for: 0.5)
        Self.expectConverged(net)
        #expect(Self.folded(net.node(s).log).count == 1)
        #expect(net.updates(s).contains { if case .settleAbsorbed = $0 { true } else { false } })
    }

    /// Finding 2: C and D hold timed views; successor B has no game clock; D adopts B straight from B's claim, before
    /// its own failure detector fires. D's retained view keeps its game time, so it matches C's (one shot), and when
    /// B dies too D does not append it again.
    @Test func aRetainedViewKeepsItsGameTimeAcrossADirectAdoption() {
        let net = SimNetwork(seed: 31)
        var slow = MeshConfig()
        slow.failTimeout = 3
        let a = net.addNode(device: 18, clockOffset: 1000)
        let b = net.addNode(device: 17, clockOffset: 40)
        let c = net.addNode(device: 15, clockOffset: -3)
        let d = net.addNode(device: 16, clockOffset: 9, config: slow)
        net.noClock = [b]
        net.run(for: 2.5)
        #expect(net.node(c).clock.estimate != nil && net.node(d).clock.estimate != nil)
        // C's id sorts first, so B keeps C's record and D's retained view must match it by stroke, not by id.
        func view(_ id: String) -> GameEvent {
            .shot(MeshShotRecord(shotID: UUID(uuidString: id)!, shooterTeam: 0, outcome: Self.pot1, postState: nil,
                                 preState: Self.layout(1)))
        }
        Self.see(net, [(c, view("00000000-0000-0000-0000-000000000001")),
                       (d, view("FFFFFFFF-0000-0000-0000-000000000001"))])   // A never logs it
        net.run(for: 0.2)
        net.kill(a)
        net.run(for: 2.2)
        #expect(net.hosts == [b])
        #expect(net.node(d).role == .client(host: b), "D adopted B from its claim")
        net.run(for: 1.5)
        #expect(Self.folded(net.node(b).log).count == 1, "C's and D's views are one shot")
        net.kill(b)
        net.run(for: 4)
        Self.expectConverged(net)
        #expect(Self.folded(net.node(net.hosts.first!).log).count == 1, "not appended again by the next host")
    }

    /// Finding 3: the winner committed S unflagged; the returning phone's log holds S itself flagged (an earlier heal
    /// flagged it in place, timed). The flag survives onto the committed S.
    @Test func aTimedFlaggedFirstOccurrenceFlagsTheCommittedShot() throws {
        var w = MeshNode(status: PeerStatus(deviceClass: 18, batteryPercent: 50, onPower: false))
        let r = PeerID()
        _ = w.start(now: 0)
        _ = w.tick(now: 1.1)
        try #require(w.isHost)
        _ = w.settled(Self.view(1), strokeAt: 0.5, now: 1.2)
        _ = w.settled(Self.view(2), strokeAt: 1.0, now: 1.3)
        #expect(w.commitSeq == 2)
        guard case .shot(var s) = w.log[0].event else { Issue.record("no shot"); return }
        #expect(s.strokeHostTime != nil)
        s.needsTap = true
        _ = w.peerConnected(r, now: 1.4)
        _ = w.handle(Self.env(w, from: r, .islandLog(IslandLog(commitSeq: 0, entries: [LogEntry(seq: 1, term: 1, event: .shot(s))],
                                                               last: true))), now: 1.5)
        _ = w.handle(Self.env(w, from: r, Self.hello(15)), now: 1.6)
        #expect(Self.folded(w.log).first?.needsTap == true)
        #expect(Self.folded(w.log).count == 2)
    }

    // Finding 4 is `MeshGameLinkTests.aSuppressedLateSettleClearsTheDrain` (it needs the link).

    // MARK: randomized invariants

    struct Stroke { var time: Double; var layout: [BallID: Vec2]; var outcome: ShotOutcome }

    /// Seeded, bounded (≤ 4 phones, ≤ 14 strokes). Phones settle every stroke late (a view, or a gap), hosts die,
    /// the table splits and heals, links slow down, pings get lost, one phone may never get a clock.
    /// After quiescence: every stroke appears exactly once; no phone's committed prefix ever shrank or changed; all
    /// phones agree; no two phones ever hold different committed entries; any stroke the surviving phones' logs ever
    /// recorded two ways keeps `needsTap`; every settle a host took is in its
    /// log or reported absorbed (so no drain waits for its deadline).
    @Test(arguments: 0..<300)
    func randomLossSplitsAndLateSettlesKeepEveryStrokeOnce(seed: Int) {
        func expect(_ ok: Bool, _ message: @autoclosure () -> String) { if !ok { Issue.record(Comment(rawValue: message())) } }
        var rng = SeededRNG(seed: UInt64(seed) &* 2_654_435_761 &+ 17)
        func uuid() -> UUID {   // seeded ids: the run (elections, tie-breaks) is reproducible
            UUID(uuid: (UInt8.random(in: 0...255, using: &rng), UInt8.random(in: 0...255, using: &rng), UInt8.random(in: 0...255, using: &rng),
                        UInt8.random(in: 0...255, using: &rng), UInt8.random(in: 0...255, using: &rng), UInt8.random(in: 0...255, using: &rng),
                        UInt8.random(in: 0...255, using: &rng), UInt8.random(in: 0...255, using: &rng), UInt8.random(in: 0...255, using: &rng),
                        UInt8.random(in: 0...255, using: &rng), UInt8.random(in: 0...255, using: &rng), UInt8.random(in: 0...255, using: &rng),
                        UInt8.random(in: 0...255, using: &rng), UInt8.random(in: 0...255, using: &rng), UInt8.random(in: 0...255, using: &rng),
                        UInt8.random(in: 0...255, using: &rng)))
        }
        let n = Int.random(in: 2...4, using: &rng)
        let net = SimNetwork(seed: UInt64(seed), latency: Double.random(in: 0.002...0.02, using: &rng), jitter: 0.01,
                             unreliableLoss: 0.1, tickInterval: 0.1)
        let ids = (0..<n).map { i in
            net.addNode(device: 18 - i, battery: Int.random(in: 20...100, using: &rng),
                        clockOffset: Double.random(in: -50...50, using: &rng),
                        skew: Double.random(in: -50e-6...50e-6, using: &rng), id: PeerID(uuid()))
        }
        let clockless = n > 2 && Bool.random(using: &rng)
        if clockless { net.noClock = [ids[Int.random(in: 1..<n, using: &rng)]] }
        net.run(for: 2.5)

        var t = net.now + 1
        let strokes: [Stroke] = (0..<Int.random(in: 6...14, using: &rng)).map { _ in
            defer { t += Double.random(in: 3...5, using: &rng) }
            var layout: [BallID: Vec2] = [:]
            for b in [0, 1, 2, 3, 4, 8] {
                layout[BallID(b)!] = Vec2(Double.random(in: 0.1...2.1, using: &rng), Double.random(in: 0.1...1.0, using: &rng))
            }
            let k = Int.random(in: 1...7, using: &rng)
            return Stroke(time: t, layout: layout,
                          outcome: Bool.random(using: &rng) ? ShotOutcome(firstContact: BallID(k)!, pocketed: [BallID(k)!: .sideLeft])
                                                            : ShotOutcome(firstContact: BallID(k)!))
        }
        let spec = TableSpec(size: .eightFoot)
        var owner: [UUID: Int] = [:]                     // view / gap id → stroke
        var pending: [(at: Double, peer: PeerID, event: GameEvent, stroke: Double)] = []
        var hostTook: [(peer: PeerID, id: UUID)] = []
        var committed: [PeerID: [GameEvent]] = [:]
        var outcomesSeen: [PeerID: [Int: Set<ShotOutcome>]] = [:]   // per phone: a dead phone's records die with it
        var next = 0, kills = 0
        var healAt: Double?
        let end = strokes.last!.time + 3

        func check() {
            let committedNow = net.aliveIDs.map { net.node($0).log.prefix(Int(net.node($0).commitSeq)).map(\.event) }
            for x in committedNow {
                for y in committedNow {
                    let m = min(x.count, y.count)
                    expect(Array(x.prefix(m)) == Array(y.prefix(m)), "seed \(seed): two phones committed different entries")
                }
            }
            for p in net.aliveIDs {
                let node = net.node(p)
                let now = node.log.prefix(Int(node.commitSeq)).map(\.event)
                if let before = committed[p] {
                    expect(Array(now.prefix(before.count)) == before, "seed \(seed): \(p)'s committed prefix changed")
                }
                committed[p] = now
                for case .shot(let r) in node.log.map(\.event) {
                    if let k = owner[r.shotID] { outcomesSeen[p, default: [:]][k, default: []].insert(r.outcome) }
                }
            }
        }

        while net.now < end {
            if next < strokes.count, net.now >= strokes[next].time {
                let s = strokes[next]
                for p in net.aliveIDs {
                    let gap = !clockless && Double.random(in: 0..<1, using: &rng) < 0.2
                    let id = uuid()
                    owner[id] = next
                    let e: GameEvent
                    if gap {
                        e = .shotLost(shotID: id, shooterTeam: 0)
                    } else {
                        var o = s.outcome
                        if Double.random(in: 0..<1, using: &rng) < 0.1 {
                            o = o.pocketed.isEmpty ? ShotOutcome(firstContact: o.firstContact, pocketed: [o.firstContact!: .footRight])
                                                   : ShotOutcome(firstContact: o.firstContact)
                        }
                        let noise = TableSpec.ballRadius / 3
                        let pre = s.layout.mapValues { v in
                            BallState(position: v + Vec2(Double.random(in: -noise...noise, using: &rng),
                                                         Double.random(in: -noise...noise, using: &rng)))
                        }
                        e = .shot(MeshShotRecord(shotID: id, shooterTeam: 0, outcome: o, postState: nil,
                                                 preState: TableState(spec: spec, balls: pre)))
                    }
                    pending.append((s.time + Double.random(in: 0.1...2.5, using: &rng), p, e, s.time))
                }
                next += 1
            }
            for (i, f) in pending.enumerated().reversed() where net.now >= f.at {
                pending.remove(at: i)
                guard net.aliveIDs.contains(f.peer) else { continue }
                let ago = net.now - f.stroke
                let id = IslandHeal.id(f.event)!
                if net.node(f.peer).isHost { hostTook.append((f.peer, id)) }
                net.act(f.peer) { node, lt in node.settled(f.event, strokeAt: lt - ago, now: lt) }
            }
            if let h = healAt, net.now >= h { net.heal(); healAt = nil }
            let alive = net.aliveIDs
            if kills < n - 1, alive.count > 1, Double.random(in: 0..<1, using: &rng) < 0.03 * 0.05,
               let victim = net.hosts.randomElement(using: &rng) {
                net.kill(victim)
                kills += 1
            }
            if healAt == nil, alive.count > 1, Double.random(in: 0..<1, using: &rng) < 0.05 * 0.05 {
                let shuffled = alive.shuffled(using: &rng)
                let k = Int.random(in: 1..<shuffled.count, using: &rng)
                net.partition(Array(shuffled[..<k]), Array(shuffled[k...]))
                healAt = net.now + Double.random(in: 0.5...10, using: &rng)
            }
            if Double.random(in: 0..<1, using: &rng) < 0.02 * 0.05, alive.count > 1 {
                let pair = alive.shuffled(using: &rng)
                net.slowLink(from: pair[0], to: pair[1], extra: Double.random(in: 0.05...0.4, using: &rng))
            }
            net.run(for: 0.05)
            check()
        }
        net.heal()
        for _ in 0..<160 { net.run(for: 0.05); check() }

        // All phones agree.
        expect(net.hosts.count == 1, "seed \(seed): \(net.hosts.count) hosts")
        if let h = net.hosts.first {
            for p in net.aliveIDs { expect(net.node(p).log == net.node(h).log, "seed \(seed): \(p)'s log differs") }
        }
        guard let host = net.hosts.first else { return }
        let log = net.node(host).log
        // Every stroke exactly once (a shot id and its needsTap amendments count once).
        var entities: [Int: Set<UUID>] = [:]
        for e in log.map(\.event) {
            if let id = IslandHeal.id(e), let k = owner[id] { entities[k, default: []].insert(id) }
        }
        for k in strokes.indices {
            expect(entities[k]?.count == 1, "seed \(seed): stroke \(k) appears \(entities[k]?.count ?? 0) times")
        }
        // Disagreements keep needsTap.
        let folded = Self.folded(log)
        for r in folded {
            guard let k = owner[r.shotID] else { continue }
            let seen = net.aliveIDs.reduce(into: Set<ShotOutcome>()) { $0.formUnion(outcomesSeen[$1]?[k] ?? []) }
            guard seen.count > 1 else { continue }
            expect(r.needsTap, "seed \(seed): stroke \(k) was recorded two ways but is not flagged")
        }
        // Every settle a host took is logged or reported absorbed.
        for (p, id) in hostTook where net.aliveIDs.contains(p) {
            let logged = net.node(p).log.contains { IslandHeal.id($0.event) == id }
            let absorbed = net.updates(p).contains(.settleAbsorbed(shotID: id))
            expect(logged || absorbed, "seed \(seed): a host settle was neither logged nor absorbed")
        }
    }
}

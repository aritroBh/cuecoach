import Foundation
import Testing
import Geometry
import Rules
@testable import CueCoach

/// `waitUntil` on the main actor: the conditions read the main-actor links. Bounded poll, 20 ms steps.
@MainActor func poll(_ timeout: Double = 5, _ cond: @MainActor () async -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if await cond() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await cond()
}

/// Plan 010: the shipping `MeshGameLink` over real `MultipeerMeshSession`s on one in-process `MemoryHub`.
@MainActor
@Suite(.serialized) struct MeshGameLinkTests {
    @MainActor final class Seen {
        var calls: [(log: [LogEntry], commitSeq: UInt64)] = []
        var events: [GameEvent] { calls.last?.log.map(\.event) ?? [] }
    }

    static func session(_ hub: MemoryHub, device: Int, config: MeshConfig = MeshSessionTests.fast) -> MultipeerMeshSession {
        MultipeerMeshSession(transport: MemoryTransport(hub: hub),
                             status: PeerStatus(deviceClass: device, batteryPercent: 80, onPower: false), config: config)
    }

    static func link(_ s: MultipeerMeshSession) -> (MeshGameLink, Seen) {
        let l = MeshGameLink(session: s)
        let seen = Seen()
        l.onCommittedLog = { log, seq in seen.calls.append((log, seq)) }
        l.start()
        return (l, seen)
    }

    static func shot(team: Int = 0) -> GameEvent {
        .shot(MeshShotRecord(shotID: UUID(), shooterTeam: team, outcome: ShotOutcome(firstContact: BallID(1)!),
                             postState: nil))
    }

    /// Host (device 18) and joiner (device 16), roles settled on both sessions.
    static func pair(_ hub: MemoryHub, config: MeshConfig = MeshSessionTests.fast)
        async -> (host: (MeshGameLink, Seen, MultipeerMeshSession), joiner: (MeshGameLink, Seen, MultipeerMeshSession)) {
        let hs = session(hub, device: 18, config: config), js = session(hub, device: 16, config: config)
        let (h, hSeen) = link(hs), (j, jSeen) = link(js)
        let formed = await poll {
            let (sh, sj) = (await hs.snapshot(), await js.snapshot())
            return sh.role == .host && sh.roster.count == 2 && sj.role == .client(host: hs.localPeer)
        }
        #expect(formed)
        return ((h, hSeen, hs), (j, jSeen, js))
    }

    @Test func hostAppendReachesTheJoinersCallbackOnceCommitted() async {
        let hub = MemoryHub()
        let (host, joiner) = await Self.pair(hub)
        let e = Self.shot()
        host.0.append(e)
        #expect(await poll(2) { joiner.1.events.last == e })
        let last = joiner.1.calls.last
        #expect(last.map { c in c.log.allSatisfy { $0.seq <= c.commitSeq } } == true)
        #expect(last?.log.last.map { $0.seq <= last!.commitSeq } == true)
        #expect(joiner.0.commitSeq == last?.commitSeq)
        host.0.stop(); joiner.0.stop()
    }

    @Test func uncommittedEntriesAreNeverForwarded() async {
        var slow = MeshSessionTests.fast
        slow.failTimeout = 30                       // the cut-off joiner stays in the roster: no majority for the host
        let hub = MemoryHub()
        let (host, joiner) = await Self.pair(hub, config: slow)
        hub.kill(joiner.2.localPeer)
        let before = host.1.calls.count
        let e = Self.shot()
        host.0.append(e)
        #expect(await poll(2) { await host.2.snapshot().log.contains { $0.event == e } })
        try? await Task.sleep(for: .milliseconds(400))
        #expect(await host.2.snapshot().commitSeq == 0)
        #expect(!host.1.calls.dropFirst(before).contains { $0.log.contains { $0.event == e } })
        #expect(host.0.commitSeq == 0)
        host.0.stop(); joiner.0.stop()
    }

    @Test func clientAppendBecomesAProposalTheHostCommits() async {
        let hub = MemoryHub()
        let (host, joiner) = await Self.pair(hub)
        let e = GameEvent.nextShooter(team: 1)       // D41 disc tap on the joiner
        joiner.0.append(e)
        #expect(await poll(2) { host.1.events.last == e })
        #expect(await poll(2) { joiner.1.events.last == e })
        host.0.stop(); joiner.0.stop()
    }

    @Test func isHostFollowsRoleChanges() async {
        let hub = MemoryHub()
        let sessions = (0..<3).map { Self.session(hub, device: 15 + $0) }
        let links = sessions.map { Self.link($0).0 }
        #expect(await poll {
            let role = await sessions[0].snapshot().role
            return links[2].isHost && !links[1].isHost && !links[0].isHost && role == .client(host: sessions[2].localPeer)
        })
        links[2].stop()
        hub.kill(sessions[2].localPeer)
        #expect(await poll { links[1].isHost })
        #expect(!links[0].isHost)
        links.forEach { $0.stop() }
    }

    @Test func callbacksArriveInCommitOrder() async {
        let hub = MemoryHub()
        let (host, joiner) = await Self.pair(hub)
        let burst = (0..<30).map { _ in Self.shot() }
        burst.forEach(host.0.append)
        #expect(await poll(2) { joiner.0.commitSeq == 30 && host.0.commitSeq == 30 })
        for seen in [host.1, joiner.1] {
            let seqs = seen.calls.map(\.commitSeq)
            #expect(zip(seqs, seqs.dropFirst()).allSatisfy { $0 < $1 })
            #expect(seen.events == burst)
        }
        host.0.stop(); joiner.0.stop()
    }

    @Test func stopEndsForwarding() async {
        let hub = MemoryHub()
        let (host, joiner) = await Self.pair(hub)
        let first = Self.shot()
        host.0.append(first)
        #expect(await poll(2) { joiner.1.events.last == first })
        let kept = joiner.0.commitSeq
        joiner.0.stop()
        #expect(await poll(2) { joiner.0.isStopped })
        let count = joiner.1.calls.count
        let second = Self.shot()
        host.0.append(second)
        #expect(await poll(2) { host.1.events.last == second })
        #expect(joiner.1.calls.count == count)
        #expect(joiner.0.commitSeq == kept)          // plan 011 reads it after stop
        host.0.stop()
    }

    @Test func twoGameSessionsAgreeOnShotsAndTurn() async {
        let a = ShellPlayer(id: UUID(), name: "A", symbol: "hare.fill", colorName: "teal")
        let b = ShellPlayer(id: UUID(), name: "B", symbol: "bolt.fill", colorName: "orange")
        let config = GameConfig(ruleSet: .barEight, tableSize: .eightFoot, teams: [[a], [b]])
        let hub = MemoryHub()
        let (host, joiner) = await Self.pair(hub)
        let hostGame = GameSessionModel(config: config), joinerGame = GameSessionModel(config: config)
        hostGame.mesh = host.0
        joinerGame.mesh = joiner.0
        let pot = ShotOutcome(firstContact: BallID(1)!, pocketed: [BallID(1)!: .footLeft])
        hostGame.shotSettled(SettledShot(rating: .best, turnPasses: false, outcome: pot))
        joinerGame.shotSettled(SettledShot(rating: .blunder, turnPasses: true, outcome: ShotOutcome()))  // D39: dropped
        #expect(await poll(2) { hostGame.shots.count == 1 && joinerGame.shots.count == 1 })
        hostGame.shotSettled(SettledShot(rating: .mistake, turnPasses: true, outcome: ShotOutcome(firstContact: BallID(2)!)))
        #expect(await poll(2) { hostGame.shots.count == 2 && joinerGame.shots.count == 2 })
        #expect(joinerGame.shots.map(\.id) == hostGame.shots.map(\.id))
        #expect(joinerGame.shots.map(\.rating) == [.best, .mistake])
        #expect(hostGame.shots.map(\.rating) == [.best, .mistake])
        #expect(joinerGame.shootingTeam == 1 && hostGame.shootingTeam == 1)
        host.0.stop(); joiner.0.stop()
    }
}

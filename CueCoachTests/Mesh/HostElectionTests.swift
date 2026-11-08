import Foundation
import Testing
@testable import CueCoach

/// Deterministic host election (SPEC §5.7 "newest device / highest battery"; mesh-identity.md §2.4).
@Suite struct HostElectionTests {
    static func peer(_ n: Int) -> PeerID {
        PeerID(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!)
    }
    static func st(_ device: Int, _ battery: Int, power: Bool = false) -> PeerStatus {
        PeerStatus(deviceClass: device, batteryPercent: battery, onPower: power)
    }

    @Test func newestDeviceWinsUnderDeviceFirst() {
        let c = [Self.peer(1): Self.st(16, 95), Self.peer(2): Self.st(18, 30)]
        #expect(HostElection.elect(c, order: .deviceFirst) == Self.peer(2))
    }

    @Test func highestBatteryWinsUnderBatteryFirst() {
        let c = [Self.peer(1): Self.st(16, 95), Self.peer(2): Self.st(18, 30)]
        #expect(HostElection.elect(c, order: .batteryFirst) == Self.peer(1))
    }

    @Test func defaultOrderIsSpecLiteralDeviceFirst() {
        #expect(ElectionOrder.default == .deviceFirst)
    }

    @Test func batteryIsBucketedSoSmallDifferencesFallThroughToPeerID() {
        // 81 % and 88 % share the 80 % bucket → tie → lowest PeerID wins.
        let c = [Self.peer(5): Self.st(18, 88), Self.peer(3): Self.st(18, 81)]
        #expect(HostElection.elect(c, order: .deviceFirst) == Self.peer(3))
        #expect(HostElection.batteryBucket(88) == 8 && HostElection.batteryBucket(100) == 10)
    }

    @Test func onPowerBreaksBucketTie() {
        let c = [Self.peer(1): Self.st(18, 50), Self.peer(2): Self.st(18, 55, power: true)]
        #expect(HostElection.elect(c, order: .deviceFirst) == Self.peer(2))
    }

    @Test func emptyHasNoHost() {
        #expect(HostElection.elect([:], order: .deviceFirst) == nil)
    }

    /// Every phone must compute the same host and succession from the same gossip, whatever the order.
    @Test(arguments: 0..<50)
    func sameInputsSameResultAnyOrder(seed: Int) {
        var rng = SeededRNG(seed: UInt64(seed))
        var c: [PeerID: PeerStatus] = [:]
        for i in 0..<Int.random(in: 1...8, using: &rng) {
            c[Self.peer(i + 1)] = Self.st(Int.random(in: 15...18, using: &rng), Int.random(in: 0...100, using: &rng))
        }
        let ranked = HostElection.succession(c, order: .deviceFirst)
        let shuffled = Dictionary(uniqueKeysWithValues: c.shuffled(using: &rng).map { ($0.key, $0.value) })
        #expect(HostElection.succession(shuffled, order: .deviceFirst) == ranked)
        #expect(ranked.count == c.count && Set(ranked) == Set(c.keys))
        #expect(ranked.first == HostElection.elect(c, order: .deviceFirst))
    }

    // MARK: terms

    @Test func higherTermAlwaysWins() {
        let c = [Self.peer(1): Self.st(18, 90), Self.peer(2): Self.st(15, 10)]
        #expect(HostElection.claimWins(term: 5, claimant: Self.peer(2), over: 4, incumbent: Self.peer(1),
                                      statuses: c, order: .deviceFirst))
    }

    @Test func staleTermLoses() {
        let c = [Self.peer(1): Self.st(15, 10), Self.peer(2): Self.st(18, 90)]
        #expect(!HostElection.claimWins(term: 3, claimant: Self.peer(2), over: 4, incumbent: Self.peer(1),
                                       statuses: c, order: .deviceFirst))
    }

    /// Two phones that claimed the same term (split view) resolve to the better-ranked one, everywhere.
    @Test func equalTermResolvedByRank() {
        let c = [Self.peer(1): Self.st(15, 10), Self.peer(2): Self.st(18, 90)]
        #expect(HostElection.claimWins(term: 4, claimant: Self.peer(2), over: 4, incumbent: Self.peer(1),
                                      statuses: c, order: .deviceFirst))
        #expect(!HostElection.claimWins(term: 4, claimant: Self.peer(1), over: 4, incumbent: Self.peer(2),
                                       statuses: c, order: .deviceFirst))
        #expect(!HostElection.claimWins(term: 4, claimant: Self.peer(2), over: 4, incumbent: Self.peer(2),
                                       statuses: c, order: .deviceFirst))
    }

    // MARK: device class

    @Test func deviceClassFromMachineIdentifier() {
        #expect(DeviceClass.rank(machine: "iPhone16,2") == 16)   // 15 Pro Max
        #expect(DeviceClass.rank(machine: "iPhone18,2") == 18)   // 17 Pro Max
        #expect(DeviceClass.rank(machine: "arm64") == 0)         // simulator / unknown → lowest
        #expect(DeviceClass.rank(machine: "iPad14,1") == 0)
    }
}

/// Heartbeat-gap failure detection (mesh-identity.md §2.5).
@Suite struct FailureDetectorTests {
    let p = HostElectionTests.peer(1)
    let q = HostElectionTests.peer(2)

    @Test func aliveUntilTimeoutThenDead() {
        var f = FailureDetector(timeout: 1.5)
        f.heard(p, at: 10)
        #expect(f.isAlive(p, now: 11.4))
        #expect(!f.isSuspect(p, now: 10.7))
        #expect(f.isSuspect(p, now: 10.8))
        #expect(!f.isAlive(p, now: 11.6))
        #expect(f.alive(now: 11.4) == [p])
    }

    @Test func gapShorterThanTimeoutNeverFlags() {
        var f = FailureDetector(timeout: 1.5)
        var t = 0.0
        while t < 60 { f.heard(p, at: t); #expect(f.isAlive(p, now: t + 1.4)); t += 1.4 }
    }

    @Test func unknownPeerIsNotAliveAndForgetRemoves() {
        var f = FailureDetector(timeout: 1.5)
        #expect(!f.isAlive(q, now: 0))
        f.heard(q, at: 0)
        f.forget(q)
        #expect(!f.isAlive(q, now: 0.1))
    }

    @Test func outOfOrderTimestampsDoNotRewind() {
        var f = FailureDetector(timeout: 1.5)
        f.heard(p, at: 10)
        f.heard(p, at: 5)
        #expect(f.isAlive(p, now: 11.4))
    }
}

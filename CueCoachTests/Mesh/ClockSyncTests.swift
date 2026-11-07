import Foundation
import Testing
@testable import CueCoach

/// NTP-style client ↔ host clock sync (RFC 5905 §8; mesh-identity.md §4).
@Suite struct ClockSyncTests {
    /// Simulated link. Local clock = real time; host clock = offset + (1 + skew) · real.
    struct Link {
        var offset: Double = 0.250
        var skew: Double = 0
        var up: Double = 0.004
        var down: Double = 0.004
        var jitterMean: Double = 0          // exponential jitter, each direction
        var loss: Double = 0
        var spikeRate: Double = 0           // AWDL channel-hop style delay spikes
        var spike: Double = 0.050
        var stepAt: Double? = nil           // host clock jumps by `stepSize` at this real time
        var stepSize: Double = 0.050

        func host(_ t: Double) -> Double {
            offset + (1 + skew) * t + ((stepAt.map { t >= $0 } ?? false) ? stepSize : 0)
        }
        func trueOffset(at t: Double) -> Double { host(t) - t }

        func delay(_ base: Double, _ rng: inout SeededRNG) -> Double {
            var d = base
            if jitterMean > 0 { d += -jitterMean * log(max(Double.random(in: 0..<1, using: &rng), 1e-12)) }
            if Double.random(in: 0..<1, using: &rng) < spikeRate { d += spike }
            return d
        }

        /// One ping at real time `t`, or nil if lost.
        func ping(at t: Double, _ rng: inout SeededRNG) -> ClockSample? {
            if Double.random(in: 0..<1, using: &rng) < loss { return nil }
            let arrive = t + delay(up, &rng)
            let reply = arrive + 0.0001
            let back = reply + delay(down, &rng)
            return ClockSample(t0: ns(t), t1: ns(host(arrive)), t2: ns(host(reply)), t3: ns(back))
        }
    }

    static func ns(_ s: Double) -> Int64 { Int64((s * 1e9).rounded()) }

    @Test func sampleFormulaMatchesRFC5905() {
        // t0=0, t1=110 ms, t2=111 ms, t3=21 ms → θ = ((110-0)+(111-21))/2 = 100 ms, δ = 21 - 1 = 20 ms
        let s = ClockSample(t0: 0, t1: 110_000_000, t2: 111_000_000, t3: 21_000_000)
        #expect(abs(s.offset - 0.100) < 1e-9)
        #expect(abs(s.delay - 0.020) < 1e-9)
    }

    @Test func noSamplesNoEstimate() {
        let e = ClockSyncEstimator()
        #expect(e.estimate == nil)
        #expect(e.hostTime(fromLocal: 5) == nil)
    }

    @Test func symmetricLinkIsExact() {
        var rng = SeededRNG(seed: 1)
        let link = Link()
        var e = ClockSyncEstimator()
        for i in 0..<16 { if let s = link.ping(at: Double(i) * 0.02, &rng) { e.add(s) } }
        let est = try! #require(e.estimate)
        #expect(abs(est.offset - 0.250) < 1e-6)
        #expect(abs(est.latency - 0.004) < 1e-4)
    }

    /// Burst at join on a hostile link: asymmetry 2 ms up / 9 ms down, jitter, 20 % loss, spikes.
    @Test(arguments: 0..<20)
    func burstOnHostileLinkWithinFiveMs(seed: Int) {
        var rng = SeededRNG(seed: UInt64(seed))
        let link = Link(up: 0.002, down: 0.009, jitterMean: 0.002, loss: 0.2, spikeRate: 0.1)
        var e = ClockSyncEstimator()
        for i in 0..<16 { if let s = link.ping(at: Double(i) * 0.02, &rng) { e.add(s) } }
        let est = try! #require(e.estimate)
        #expect(abs(est.offset - link.trueOffset(at: 0.3)) <= 0.005)
        #expect(est.uncertainty > 0)
    }

    /// 1 Hz pings for two minutes, 50 ppm skew: the drift fit keeps the error ≤ 2 ms.
    @Test func tracksFiftyPpmSkew() {
        var rng = SeededRNG(seed: 7)
        let link = Link(skew: 50e-6, jitterMean: 0.002, loss: 0.1, spikeRate: 0.05)
        var e = ClockSyncEstimator()
        var errors: [Double] = []
        for i in 0..<120 {
            let t = Double(i)
            if let s = link.ping(at: t, &rng) { e.add(s) }
            if i >= 30, let h = e.hostTime(fromLocal: Self.ns(t + 0.5)) {
                errors.append(abs(Double(h) / 1e9 - link.host(t + 0.5)))
            }
        }
        errors.sort()
        let p95 = errors[Int(Double(errors.count) * 0.95)]
        #expect(p95 <= 0.002, "p95 \(p95)")
        #expect(abs(try! #require(e.estimate).skew - 50e-6) < 30e-6)
    }

    /// A persistent > 10 ms host-clock step resets the fit instead of averaging it away.
    @Test func persistentStepResetsFit() {
        var rng = SeededRNG(seed: 3)
        let link = Link(jitterMean: 0.001, stepAt: 40, stepSize: 0.050)
        var e = ClockSyncEstimator()
        for i in 0..<52 { if let s = link.ping(at: Double(i), &rng) { e.add(s) } }
        let est = try! #require(e.estimate)
        #expect(abs(est.offset - link.trueOffset(at: 51)) < 0.005)
    }

    /// A single spike sample must not move the estimate.
    @Test func singleOutlierIgnored() {
        var e = ClockSyncEstimator()
        for i in 0..<20 {
            let t = Self.ns(Double(i))
            e.add(ClockSample(t0: t, t1: t + 104_000_000, t2: t + 104_100_000, t3: t + 8_100_000))
        }
        let before = try! #require(e.estimate).offset
        let t = Self.ns(20)
        e.add(ClockSample(t0: t, t1: t + 350_000_000, t2: t + 350_100_000, t3: t + 400_100_000)) // θ 150 ms, δ 400 ms
        #expect(abs(try! #require(e.estimate).offset - before) < 1e-4)
    }

    @Test func hostTimeConversionAndReset() {
        var e = ClockSyncEstimator()
        e.add(ClockSample(t0: 0, t1: 1_002_000_000, t2: 1_002_000_000, t3: 4_000_000))
        #expect(e.hostTime(fromLocal: 10_000_000) == 1_010_000_000)
        #expect(e.localTime(fromHost: 1_010_000_000) == 10_000_000)
        e.reset()
        #expect(e.estimate == nil)
    }
}

import Foundation
import Testing
@testable import Training

/// Deterministic PRNG for reproducible synthetic data.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func gaussian() -> Double {
        let u1 = Double.random(in: Double.ulpOfOne..<1, using: &self)
        let u2 = Double.random(in: 0..<1, using: &self)
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
    /// Student-t with 2 degrees of freedom: heavy tails, finite median.
    mutating func heavyTailed() -> Double {
        let z = gaussian(); let g1 = gaussian(), g2 = gaussian(); let c = g1 * g1 + g2 * g2
        return z / (c / 2).squareRoot()
    }
}

/// Runs `n` attempts on all axes; returns the first attempt index (1-based) at which each
/// (axis, direction) became active, if ever.
func simulate(seed: UInt64, attempts n: Int, bias: [BiasAxis: Double] = [:], noise: Double = 1,
              heavy: Bool = false) -> [BiasKey: Int] {
    var rng = SplitMix64(seed: seed)
    var d = BiasDetector()
    var first: [BiasKey: Int] = [:]
    for i in 1...n {
        for a in BiasAxis.allCases {
            let e = (heavy ? rng.heavyTailed() : rng.gaussian()) * noise + (bias[a] ?? 0)
            d.observe(a, error: e)
        }
        for b in d.activeBiases() where first[b.key] == nil { first[b.key] = i }
    }
    return first
}

@Suite("BiasDetector — sequential sign test (SPEC §10, Phase 8 acceptance)")
struct BiasDetectorTests {
    // MARK: Unit behaviour

    @Test func quietWhenEmpty() {
        #expect(BiasDetector().activeBiases().isEmpty)
    }
    @Test func neverFiresBeforeMinimumAttemptsEvenOnHugeBias() {
        var d = BiasDetector()
        for _ in 0..<(BiasDetector.Config.standard.minimumAttempts - 1) {
            d.observe(.speed, error: 50)
            #expect(d.activeBiases().isEmpty)
        }
    }
    @Test func minimumAttemptsBindsEvenWithALowThreshold() {
        let cfg = BiasDetector.Config(deadZone: 0, alternativeP: 0.75, threshold: 0.5, cap: 10, minimumAttempts: 8)
        var d = BiasDetector(config: cfg)
        for i in 1...8 {
            d.observe(.cut, error: 1)
            #expect(d.activeBiases().isEmpty == (i < 8), "attempt \(i)")
        }
    }
    @Test func standardConfigNeedsAtLeastEightStraightAttempts() {
        let c = BiasDetector.Config.standard
        #expect(c.threshold / log(c.alternativeP / 0.5) >= 8)
    }
    @Test func consistentSameSignFiresWithRightAxisAndDirection() {
        var d = BiasDetector()
        var firedAt: Int?
        for i in 1...40 {
            d.observe(.cut, error: 1.0)
            if firedAt == nil, !d.activeBiases().isEmpty { firedAt = i }
        }
        let firedAtValue = try! #require(firedAt)
        #expect(firedAtValue >= 8)
        #expect(d.activeBiases().map(\.key) == [BiasKey(axis: .cut, direction: .positive)])
        let b = d.activeBiases()[0]
        #expect(b.meanError == 1.0)
        #expect(b.evidence >= 1)
    }
    @Test func negativeDirection() {
        var d = BiasDetector()
        for _ in 0..<40 { d.observe(.speed, error: -0.8) }
        #expect(d.activeBiases().map(\.key) == [BiasKey(axis: .speed, direction: .negative)])
    }
    @Test func deadZoneObservationsAreNeutral() {
        var d = BiasDetector()
        for _ in 0..<500 { d.observe(.side, error: 0.1) }   // tiny consistent errors: not actionable
        #expect(d.activeBiases().isEmpty)
    }
    @Test func nonFiniteObservationsIgnored() {
        var d = BiasDetector()
        for _ in 0..<100 { d.observe(.spin, error: .nan); d.observe(.spin, error: .infinity) }
        #expect(d.activeBiases().isEmpty)
        #expect(d.statistic(.spin, .positive) == 0)
    }
    @Test func alternatingSignsNeverFire() {
        var d = BiasDetector()
        for i in 0..<1000 { d.observe(.cut, error: i.isMultiple(of: 2) ? 1 : -1) }
        #expect(d.activeBiases().isEmpty)
    }
    @Test func correctedPlayerGoesQuietAgain() {
        var d = BiasDetector()
        for _ in 0..<40 { d.observe(.cut, error: 1) }
        #expect(!d.activeBiases().isEmpty)
        for _ in 0..<12 { d.observe(.cut, error: -1) }
        #expect(d.activeBiases().isEmpty)
    }
    @Test func evidenceIsCappedSoLongHabitsCanBeUnlearned() {
        var d = BiasDetector()
        for _ in 0..<1000 { d.observe(.cut, error: 1) }
        #expect(d.activeBiases()[0].evidence <= BiasDetector.Config.standard.cap + 1e-9)
        for _ in 0..<12 { d.observe(.cut, error: -1) }
        #expect(d.activeBiases().isEmpty)
    }
    @Test func deterministicForSameSeed() {
        #expect(simulate(seed: 42, attempts: 80, bias: [.side: 0.7])
                == simulate(seed: 42, attempts: 80, bias: [.side: 0.7]))
    }
    @Test func resetClearsOneAxisOnly() {
        var d = BiasDetector()
        for _ in 0..<40 { d.observe(.cut, error: 1); d.observe(.speed, error: 1) }
        d.reset(.cut)
        #expect(d.activeBiases().map(\.key.axis) == [.speed])
        #expect(d.statistic(.cut, .positive) == 0)
    }
    @Test func strongestEvidenceFirst() {
        var d = BiasDetector()
        for i in 0..<60 {
            d.observe(.speed, error: 1)                         // every time
            d.observe(.cut, error: i % 6 == 0 ? -1 : 1)         // mostly
        }
        let keys = d.activeBiases().map(\.key.axis)
        #expect(keys == [.speed, .cut])
    }
    @Test func scaleInvariant() {
        // Errors and dead zone both ×100: identical decisions.
        var a = BiasDetector(), b = BiasDetector(config: .standard.scaled(by: 100))
        var rng = SplitMix64(seed: 3)
        for _ in 0..<80 {
            let e = rng.gaussian() + 0.8
            a.observe(.cut, error: e); b.observe(.cut, error: e * 100)
        }
        #expect(a.activeBiases().map(\.key) == b.activeBiases().map(\.key))
    }
    @Test func codableRoundTrip() throws {
        var d = BiasDetector()
        for _ in 0..<20 { d.observe(.cut, error: 1) }
        let back = try JSONDecoder().decode(BiasDetector.self, from: JSONEncoder().encode(d))
        #expect(back == d)
    }

    // MARK: Phase 8 acceptance — many seeds

    static let seeds = 1000

    @Test func firesOnSyntheticBiasedData_eachAxisAndDirection() {
        for axis in BiasAxis.allCases {
            for sign in [1.0, -1.0] {
                let want = BiasKey(axis: axis, direction: sign > 0 ? .positive : .negative)
                var hits = 0, wrong = 0
                for s in 0..<200 {
                    let f = simulate(seed: UInt64(s) &+ 10_000, attempts: 60, bias: [axis: sign])
                    if f[want] != nil { hits += 1 }
                    if f[BiasKey(axis: axis, direction: want.direction.opposite)] != nil { wrong += 1 }
                }
                #expect(hits >= 196, "\(want): \(hits)/200")   // ≥98% power at 1σ bias, 60 attempts
                #expect(wrong == 0, "\(want): opposite fired \(wrong)")
            }
        }
    }
    @Test func detectionPowerAndFalsePositiveRateReport() {
        var falseAny = 0, falsePerKey = 0, detected = 0, delays: [Int] = []
        var heavyFalse = 0, heavyDetected = 0
        for s in 0..<Self.seeds {
            let seed = UInt64(s)
            // Unbiased: 100 attempts, 5 axes, 2 directions each.
            let q = simulate(seed: seed, attempts: 100)
            if !q.isEmpty { falseAny += 1 }
            falsePerKey += q.count
            // Biased cut (+1σ) with the other axes unbiased.
            let b = simulate(seed: seed &+ 1_000_000, attempts: 60, bias: [.cut: 1])
            if let t = b[BiasKey(axis: .cut, direction: .positive)] { detected += 1; delays.append(t) }
            // Heavy-tailed noise (t, 2 dof).
            if !simulate(seed: seed &+ 2_000_000, attempts: 100, heavy: true).isEmpty { heavyFalse += 1 }
            if simulate(seed: seed &+ 3_000_000, attempts: 60, bias: [.speed: 1], heavy: true)[
                BiasKey(axis: .speed, direction: .positive)] != nil { heavyDetected += 1 }
        }
        let n = Double(Self.seeds)
        let perKeyFPR = Double(falsePerKey) / (n * Double(BiasAxis.allCases.count * 2))
        let anyFPR = Double(falseAny) / n
        let power = Double(detected) / n
        delays.sort()
        let median = delays.isEmpty ? -1 : delays[delays.count / 2]
        print("BIAS-REPORT seeds=\(Self.seeds) perAxisDirFPR@100=\(perKeyFPR) anyOf10FPR@100=\(anyFPR) "
              + "power@1σ,60=\(power) medianDelay=\(median) heavyFPR@100=\(Double(heavyFalse) / n) "
              + "heavyPower=\(Double(heavyDetected) / n)")
        #expect(perKeyFPR <= 0.01)
        #expect(anyFPR <= 0.08)
        #expect(power >= 0.98)
        #expect(median >= 8 && median <= 40)
        #expect(Double(heavyFalse) / n <= 0.08)
        #expect(Double(heavyDetected) / n >= 0.9)
    }
    @Test func quietOnUnbiasedData_typicalDrillSession() {
        // A drill tracks ≤3 axes; a session is ~50 attempts. Quiet in ≥97% of seeds.
        var quiet = 0
        for s in 0..<Self.seeds {
            var rng = SplitMix64(seed: UInt64(s) &+ 5_000_000)
            var d = BiasDetector(); var fired = false
            for _ in 0..<50 {
                for a in DrillID.increasingCuts.trackedAxes.sorted(by: { $0.rawValue < $1.rawValue }) {
                    d.observe(a, error: rng.gaussian())
                }
                if !d.activeBiases().isEmpty { fired = true }
            }
            if !fired { quiet += 1 }
        }
        print("BIAS-REPORT drillSession quiet=\(quiet)/\(Self.seeds)")
        #expect(Double(quiet) / Double(Self.seeds) >= 0.97)
    }
}

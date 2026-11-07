import Foundation

/// Counter-based RNG for Monte Carlo with common random numbers (engine.md §6.3).
///
/// The root noise for sample `i` depends only on (engine seed, quantised state hash, stream, i), so every
/// candidate sees the same z for the same sample index (CRN). Odd samples are the antithetic copy of the
/// preceding even sample. Mixing is SplitMix64's finaliser chained per field (not XOR).
public struct EngineRNG: Hashable, Codable, Sendable {
    public let seed: UInt64
    public init(seed: UInt64) { self.seed = seed }

    @inline(__always) static func splitmix(_ x: UInt64) -> UInt64 {
        var z = x &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Chained mixer over any number of fields.
    public static func mix(_ fields: UInt64...) -> UInt64 {
        var h: UInt64 = 0x243F_6A88_85A3_08D3
        for f in fields { h = splitmix(h ^ splitmix(f)) }
        return h
    }

    /// Uniform in the open interval (0, 1) from 53 random bits.
    @inline(__always) static func unit(_ x: UInt64) -> Double {
        (Double(x >> 11) + 0.5) * (1.0 / 9_007_199_254_740_992.0)
    }

    /// Four independent standard normals for (state, stream, sample). Odd samples are antithetic.
    public func normals(state: UInt64, stream: UInt32, sample: Int) -> SIMD4<Double> {
        if sample & 1 == 1 { return -normals(state: state, stream: stream, sample: sample - 1) }
        let base = EngineRNG.mix(seed, state, UInt64(stream), UInt64(sample))
        var u = [Double](repeating: 0, count: 4)
        var h = base
        for k in 0..<4 { h = EngineRNG.splitmix(h &+ UInt64(k)); u[k] = EngineRNG.unit(h) }
        // Box–Muller, two pairs.
        let r1 = (-2 * log(u[0])).squareRoot(), t1 = 2 * Double.pi * u[1]
        let r2 = (-2 * log(u[2])).squareRoot(), t2 = 2 * Double.pi * u[3]
        return SIMD4(r1 * cos(t1), r1 * sin(t1), r2 * cos(t2), r2 * sin(t2))
    }
}

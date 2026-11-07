import Foundation

/// One ping/pong exchange, host-clock nanoseconds (RFC 5905 §8).
/// t0 = client send, t1 = host receive, t2 = host send, t3 = client receive.
struct ClockSample: Hashable, Sendable {
    var t0: Int64
    var t1: Int64
    var t2: Int64
    var t3: Int64

    /// θ = ((t1 − t0) + (t2 − t3)) / 2, seconds. Host clock minus local clock.
    var offset: Double { (Double(t1 - t0) + Double(t2 - t3)) / 2e9 }
    /// δ = (t3 − t0) − (t2 − t1), seconds. Round-trip network delay.
    var delay: Double { (Double(t3 - t0) - Double(t2 - t1)) / 1e9 }
    /// Local time the offset is best attributed to (midpoint), seconds.
    var localMid: Double { (Double(t0) + Double(t3)) / 2e9 }
}

struct ClockEstimate: Hashable, Sendable {
    /// Host minus local, seconds, at the newest sample.
    var offset: Double
    /// One-way latency estimate (min round trip / 2), seconds.
    var latency: Double
    /// Error bound estimate: min δ / 2 (worst-case asymmetry) + residual σ, seconds.
    var uncertainty: Double
    /// Host-clock rate relative to local (dimensionless; 50 ppm = 5e-5).
    var skew: Double
}

/// Clock filter + weighted drift fit (mesh-identity.md §4):
/// last `window` samples → drop δ > 3 × median(δ) → lowest-delay quartile → weighted LSQ θ(t) = a + b·t,
/// weight ∝ 1/δ². A persistent step > 10 ms (4 consecutive good samples) resets the history.
struct ClockSyncEstimator: Sendable {
    let window: Int
    static let stepThreshold = 0.010
    static let stepRun = 4
    /// Skew is only fitted once samples span this many seconds (a short burst can't resolve ppm drift).
    static let minSkewSpan = 10.0

    private(set) var samples: [ClockSample] = []
    private var fit: Fit?

    private struct Fit: Sendable {
        var a: Double, b: Double, tRef: Double, latency: Double, sigma: Double, tLast: Double
        func offset(at t: Double) -> Double { a + b * (t - tRef) }
    }

    init(window: Int = 64) { self.window = window }

    var estimate: ClockEstimate? {
        fit.map { ClockEstimate(offset: $0.offset(at: $0.tLast), latency: $0.latency,
                                uncertainty: $0.latency + $0.sigma, skew: $0.b) }
    }

    mutating func reset() {
        samples.removeAll()
        fit = nil
    }

    mutating func add(_ s: ClockSample) {
        guard s.delay >= 0, s.t3 >= s.t0 else { return } // impossible sample
        samples.append(s)
        if samples.count > window { samples.removeFirst(samples.count - window) }
        detectStep()
        fit = Self.fit(samples)
    }

    /// Host time for a local timestamp, ns.
    func hostTime(fromLocal t: Int64) -> Int64? {
        guard let fit else { return nil }
        let ts = Double(t) / 1e9
        return t + Int64((fit.offset(at: ts) * 1e9).rounded())
    }

    /// Local time for a host timestamp, ns.
    func localTime(fromHost h: Int64) -> Int64? {
        guard let fit else { return nil }
        var l = Double(h) / 1e9 - fit.offset(at: Double(h) / 1e9)
        l = Double(h) / 1e9 - fit.offset(at: l)
        return h - Int64((fit.offset(at: l) * 1e9).rounded())
    }

    // MARK: private

    private mutating func detectStep() {
        let n = Self.stepRun
        guard samples.count >= n + 4 else { return }
        let older = Array(samples.dropLast(n))
        guard let base = Self.fit(older) else { return }
        let recent = samples.suffix(n)
        let minDelay = older.map(\.delay).min() ?? 0
        let residuals = recent.compactMap { s -> Double? in
            s.delay <= 2 * minDelay + 0.002 ? s.offset - base.offset(at: s.localMid) : nil
        }
        guard residuals.count == n else { return }
        if residuals.allSatisfy({ $0 > Self.stepThreshold }) || residuals.allSatisfy({ $0 < -Self.stepThreshold }) {
            samples = Array(recent)
        }
    }

    private static func fit(_ all: [ClockSample]) -> Fit? {
        guard !all.isEmpty else { return nil }
        let delays = all.map(\.delay).sorted()
        let median = delays[delays.count / 2]
        var kept = all.filter { $0.delay <= max(3 * median, delays[0]) }
        kept.sort { $0.delay < $1.delay }
        let keep = max(min(kept.count, 4), kept.count / 4)
        kept = Array(kept.prefix(keep))

        let w = kept.map { 1 / pow(max($0.delay, 1e-4), 2) }
        let t = kept.map(\.localMid)
        let y = kept.map(\.offset)
        let sw = w.reduce(0, +)
        let tRef = zip(w, t).map(*).reduce(0, +) / sw
        let yBar = zip(w, y).map(*).reduce(0, +) / sw
        var b = 0.0
        let span = (t.max() ?? 0) - (t.min() ?? 0)
        if kept.count >= 4, span >= minSkewSpan {
            var sxy = 0.0, sxx = 0.0
            for i in kept.indices {
                sxy += w[i] * (t[i] - tRef) * (y[i] - yBar)
                sxx += w[i] * (t[i] - tRef) * (t[i] - tRef)
            }
            if sxx > 0 { b = sxy / sxx }
        }
        var ss = 0.0
        for i in kept.indices {
            let r = y[i] - (yBar + b * (t[i] - tRef))
            ss += w[i] * r * r
        }
        let sigma = (ss / sw).squareRoot()
        return Fit(a: yBar, b: b, tRef: tRef, latency: (kept.first?.delay ?? 0) / 2, sigma: sigma,
                   tLast: all.map(\.localMid).max() ?? tRef)
    }
}

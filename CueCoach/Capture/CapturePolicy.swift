import Foundation

/// Picks the camera format and perception rate from what the device offers and its thermal state.
/// Max quality while cool; step down before the overlay would drop below 24 fps (SPEC Phase 9).
enum CapturePolicy {
    struct Format: Equatable, Sendable {
        var width: Int, height: Int, fps: Int
        var pixels: Int { width * height }
    }

    enum Tier: Int, Comparable, Sendable {
        case max = 0, high, sustained, survival
        static func < (a: Tier, b: Tier) -> Bool { a.rawValue < b.rawValue }

        init(_ t: ProcessInfo.ThermalState) {
            switch t {
            case .nominal: self = .max
            case .fair: self = .high
            case .serious: self = .sustained
            default: self = .survival
            }
        }
    }

    /// - max/high: 4K when it keeps ≥ 30 fps, else the best 60 fps format.
    /// - sustained: best ≤ 1920-wide format at ≥ 30 fps (60 preferred).
    /// - survival: smallest format at ≥ 30 fps.
    static func choose(_ formats: [Format], tier: Tier, fourK: Format? = nil) -> Format? {
        let ok = formats.filter { $0.fps >= 30 }
        guard !ok.isEmpty else { return formats.max { $0.fps < $1.fps } }
        switch tier {
        case .max, .high:
            if let k = fourK, k.fps >= 30, k.width >= 3840 { return k }
            if let k = ok.filter({ $0.width >= 3840 }).max(by: { $0.fps < $1.fps }) { return k }
            return best60(ok) ?? ok.max { $0.pixels < $1.pixels }
        case .sustained:
            let small = ok.filter { $0.width <= 1920 }
            return best60(small) ?? small.max { $0.pixels < $1.pixels } ?? ok.min { $0.pixels < $1.pixels }
        case .survival:
            return ok.min { ($0.pixels, -$0.fps) < ($1.pixels, -$1.fps) }
        }
    }

    private static func best60(_ f: [Format]) -> Format? {
        f.filter { $0.fps >= 60 }.max { $0.pixels < $1.pixels }
    }

    /// Minimum seconds between detector runs per tier (detector ≤ 30 Hz, then 20, 15, 10).
    static func detectInterval(_ tier: Tier) -> Double {
        switch tier {
        case .max: 1.0 / 30
        case .high: 1.0 / 30
        case .sustained: 1.0 / 15
        case .survival: 1.0 / 10
        }
    }

    /// Working width for detection: more pixels from a 4K source while cool.
    static func detectWidth(source: Int, tier: Tier) -> Int {
        switch tier {
        case .max: source >= 3840 ? 1280 : 960
        case .high: 960
        case .sustained, .survival: 800
        }
    }
}

import CoreML
import Foundation
import Testing
@testable import CueCoach

/// Plan 003: warm ball-model latency, split into letterbox and predict, per compute-units setting. Runs on the
/// simulator and on a phone with an in-repo frame (no Mac-only files). Gates only on device (SPEC §perf, 33 ms).
@Suite(.serialized)
struct BallModelLatencyTests {
    static let warmUp = 10
    static let timed = 60

    static var platform: String {
        #if targetEnvironment(simulator)
        "simulator"
        #else
        "device"
        #endif
    }

    static func percentile(_ xs: [Double], _ p: Double) -> Double {
        let s = xs.sorted()
        return s[min(s.count - 1, Int((Double(s.count - 1) * p).rounded()))]
    }

    static func name(_ u: MLComputeUnits) -> String {
        switch u {
        case .all: "all"
        case .cpuAndNeuralEngine: "cpuAndNeuralEngine"
        case .cpuOnly: "cpuOnly"
        case .cpuAndGPU: "cpuAndGPU"
        @unknown default: "unknown"
        }
    }

    @Test(arguments: [MLComputeUnits.all, .cpuAndNeuralEngine, .cpuOnly])
    func warmLatency(_ units: MLComputeUnits) throws {
        let model = try CoreMLBallInference(bundle: .main, computeUnits: units)
        let scene = SyntheticTableScene.demo()
        let cg = try #require(scene.render())
        let px = try #require(PixelImage(cgImage: cg))

        for _ in 0..<Self.warmUp { _ = model.infer(px) }

        var lb: [Double] = [], pred: [Double] = [], total: [Double] = []
        var minDetections = Int.max
        for _ in 0..<Self.timed {
            let dets = try #require(model.infer(px))
            minDetections = min(minDetections, dets.count)
            lb.append(model.lastLetterboxMs)
            pred.append(model.lastInferenceMs)
            total.append(model.lastLetterboxMs + model.lastInferenceMs)
        }
        let f = { (x: Double) in String(format: "%.1f", x) }
        print("[latency] \(Self.name(units)) letterbox p50/p95 \(f(Self.percentile(lb, 0.5)))/\(f(Self.percentile(lb, 0.95))) ms"
              + " predict p50/p95 \(f(Self.percentile(pred, 0.5)))/\(f(Self.percentile(pred, 0.95))) ms"
              + " total p50/p95 \(f(Self.percentile(total, 0.5)))/\(f(Self.percentile(total, 0.95))) ms"
              + " platform \(Self.platform)")

        // The demo has 6 balls: ≥ 5 proves the model really ran (plan 004 covers the case where it doesn't).
        #expect(minDetections >= 5, "\(Self.name(units)): \(minDetections) detections")
        #expect(lb.allSatisfy { $0 > 0 }, "letterbox time not recorded")
        #if !targetEnvironment(simulator)
        if units == .all { #expect(Self.percentile(total, 0.95) < 33, "device total p95 over the 30 fps budget") }
        #endif
    }
}

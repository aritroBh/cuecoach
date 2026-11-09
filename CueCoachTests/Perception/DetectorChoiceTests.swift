import Foundation
import Testing
@testable import CueCoach

/// D32: the app's default ball detector is the one the virtual-sim benchmark picked, built by the same factory the
/// benchmark harness uses (docs/research/detector-benchmark.md).
struct DetectorChoiceTests {
    @Test func benchmarkWinnerIsTheHybridDetector() {
        #expect(DetectorChoice.benchmarkWinner == .hybrid)
    }

    @Test func defaultFactoryBuildsTheBenchmarkWinner() throws {
        let suite = try #require(UserDefaults(suiteName: "DetectorChoiceTests"))
        suite.removePersistentDomain(forName: "DetectorChoiceTests")
        let d = try #require(PerceptionPipeline.defaultDetector(defaults: suite) as? HybridBallDetector)
        #expect(d.model != nil, "the winner needs the bundled model")
        #expect(abs(d.minInterval - 1.0 / 30) < 1e-9)
        #expect(DetectorChoice(of: d) == DetectorChoice.benchmarkWinner)
    }

    @Test func everyCandidateBuildsTheDetectorTheBenchmarkScored() {
        #expect(DetectorChoice.classical.make() is ClassicalBallDetector)
        let model = DetectorChoice.model.make() as? HybridBallDetector
        #expect(model?.minInterval == 0 && model?.model != nil)
        #expect(DetectorChoice(of: DetectorChoice.model.make()) == .model)
        #expect(DetectorChoice(of: DetectorChoice.classical.make()) == .classical)
    }

    /// The bundled weights are the ones that won the benchmark (metadata written by tools/detector/export_coreml.py).
    @Test func bundledModelIsTheBenchmarkedWeights() throws {
        let url = try #require(Bundle.main.url(forResource: "BallDetector", withExtension: "json"))
        let meta = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(meta["weights"] as? String == DetectorChoice.benchmarkWeights)
        #expect(meta["benchmark"] as? String == "d32-virtual-sim-v1")
        #expect((meta["classes"] as? [String])?.count == 16)
    }

    @Test func classicalOverrideStillForcesClassicalOnly() throws {
        let suite = try #require(UserDefaults(suiteName: "DetectorChoiceTests.override"))
        suite.set(true, forKey: "cc.detector.classical")
        defer { suite.removePersistentDomain(forName: "DetectorChoiceTests.override") }
        let d = try #require(PerceptionPipeline.defaultDetector(defaults: suite) as? HybridBallDetector)
        #expect(d.model == nil)
    }
}

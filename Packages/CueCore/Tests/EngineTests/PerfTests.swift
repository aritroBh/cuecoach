import Foundation
import Testing
import Geometry
import Physics
import Rules
@testable import Engine

// Release perf: CUECORE_PERF=1 swift test -c release -Xswiftc -enable-testing --filter PerfTests
// Engine-only numbers on the build machine. The phone gate (iPhone 15 Pro Max, Eval < 3 s) is measured on device.
private let perfOn = ProcessInfo.processInfo.environment["CUECORE_PERF"] == "1"

private func seconds(_ d: Duration) -> Double { Double(d.components.seconds) + Double(d.components.attoseconds) * 1e-18 }

@Suite(.enabled(if: perfOn), .serialized) struct PerfTests {
    @Test func midGame10_candidateEvaluation() async {
        let (s, g) = Fx.midGame10()
        let clock = ContinuousClock()
        let gen = CandidateGenerator(rules: RulesEngine(ruleSet: g.ruleSet))
        var genTimes: [Double] = []
        for _ in 0..<20 { let t0 = clock.now; _ = gen.generate(s, g); genTimes.append(seconds(clock.now - t0)) }
        let cands = gen.generate(s, g)

        func run(_ budget: EngineBudget, n: Int) async -> ([Double], Evaluation) {
            var times: [Double] = []
            var last: Evaluation?
            for k in 0..<n {
                let engine = ShotEngine(seed: UInt64(k), budget: budget)
                let t0 = clock.now
                last = await engine.evaluate(s, g, skill: .amateur)
                times.append(seconds(clock.now - t0))
            }
            return (times.sorted(), last!)
        }
        let cores = ProcessInfo.processInfo.activeProcessorCount
        var two = EngineBudget.standard; two.maxParallel = 2
        var one = EngineBudget.standard; one.maxParallel = 1
        let (tAll, e) = await run(.standard, n: 10)
        let (t2, _) = await run(two, n: 5)
        let (t1, _) = await run(one, n: 3)
        let perSim = t1[t1.count / 2] / Double(e.stats.sims)
        print("""
        PERF midGame10 (8-ball, cue + 9 OBs) cores=\(cores)
        PERF candidates=\(cands.count) arms=\(e.stats.arms) sims/eval=\(e.stats.sims)
        PERF generate median=\(String(format: "%.2f", genTimes.sorted()[10] * 1000)) ms
        PERF evaluate threads=\(cores) median=\(String(format: "%.0f", tAll[5] * 1000)) ms p90=\(String(format: "%.0f", tAll[9] * 1000)) ms
        PERF evaluate threads=2 median=\(String(format: "%.0f", t2[2] * 1000)) ms
        PERF evaluate threads=1 median=\(String(format: "%.0f", t1[1] * 1000)) ms → \(String(format: "%.3f", perSim * 1000)) ms per sim incl. scoring
        PERF best=\(e.ranked[0].candidate.kind) \(e.ranked[0].candidate.objectBall.map { "\($0)" } ?? "-")→\(e.ranked[0].candidate.pocket.map { "\($0)" } ?? "-") ev=\(String(format: "%.3f", e.ranked[0].ev)) wp=\(String(format: "%.3f", e.winProbability))
        """)
        #expect(t2[2] < 3.0)                     // spec Phase-2 gate, on the build machine at c = 2
    }
}

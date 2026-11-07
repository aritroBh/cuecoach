import Foundation
import Geometry
import Testing
@testable import Training

@Suite("Feedback — big-picture, never numeric (SPEC §2, §10)")
struct FeedbackTests {
    @Test func everyAxisAndDirectionHasADistinctCorrection() {
        var seen = Set<Correction>()
        for a in BiasAxis.allCases {
            for d in BiasDirection.allCases { seen.insert(Correction(for: BiasKey(axis: a, direction: d))) }
        }
        #expect(seen.count == BiasAxis.allCases.count * 2)
        #expect(Set(Correction.allCases) == seen)
    }
    @Test func correctionsPointAgainstTheBias() {
        #expect(Correction(for: .init(axis: .cut, direction: .positive)) == .hitThicker)   // overcut
        #expect(Correction(for: .init(axis: .cut, direction: .negative)) == .hitThinner)   // undercut
        #expect(Correction(for: .init(axis: .side, direction: .positive)) == .favorLeft)   // misses right
        #expect(Correction(for: .init(axis: .side, direction: .negative)) == .favorRight)
        #expect(Correction(for: .init(axis: .speed, direction: .positive)) == .softer)     // too hard
        #expect(Correction(for: .init(axis: .speed, direction: .negative)) == .firmer)
        #expect(Correction(for: .init(axis: .cueBallDistance, direction: .positive)) == .shorter)
        #expect(Correction(for: .init(axis: .cueBallDistance, direction: .negative)) == .longer)
        #expect(Correction(for: .init(axis: .spin, direction: .positive)) == .lessSpin)
        #expect(Correction(for: .init(axis: .spin, direction: .negative)) == .moreSpin)
    }
    @Test func labelsAreAtMostTwoWordsAndNeverNumeric() {
        let forbidden = CharacterSet.decimalDigits.union(CharacterSet(charactersIn: "°%.,:;/+-"))
        for c in Correction.allCases {
            let l = c.label
            #expect(!l.isEmpty)
            #expect(l.split(separator: " ").count <= 2, "\(l)")
            #expect(l.rangeOfCharacter(from: forbidden) == nil, "\(l)")
            #expect(l.count <= 14, "\(l)")
            for unit in ["deg", "percent", "mm", "cm", "inch", "tip"] { #expect(!l.lowercased().contains(unit)) }
        }
    }
    @Test func visualsAreTheSpecVisuals() {
        #expect(Correction.hitThicker.visual == .averageLineVsCorrect)
        #expect(Correction.hitThinner.visual == .averageLineVsCorrect)
        #expect(Correction.favorLeft.visual == .missHeatmap)
        #expect(Correction.softer.visual == .arrow(.softer))
        #expect(Correction.firmer.visual == .arrow(.harder))
        #expect(Correction.shorter.visual == .arrow(.shorter))
        #expect(Correction.longer.visual == .arrow(.longer))
        #expect(Correction.lessSpin.visual == .spinDotVsIntended)
    }
    @Test func strengthIsCoarse() {
        let dz = BiasDetector.Config.standard.deadZone
        #expect(BiasStrength(meanError: 1.5 * dz, deadZone: dz) == .slight)
        #expect(BiasStrength(meanError: -3 * dz, deadZone: dz) == .clear)
        #expect(BiasStrength(meanError: 10 * dz, deadZone: dz) == .strong)
        #expect(BiasStrength.allCases == [.slight, .clear, .strong])
    }
}

@Suite("FeedbackCoach — one correction at a time")
struct FeedbackCoachTests {
    @Test func quietUntilABiasIsConfident() {
        var c = FeedbackCoach(drill: .increasingCuts)
        for _ in 0..<7 { c.record([.cut: 1]) }
        #expect(c.current == nil)
    }
    @Test func surfacesOneCorrection() {
        var c = FeedbackCoach(drill: .increasingCuts)
        for _ in 0..<40 { c.record([.cut: 1, .speed: 1, .side: 0]) }
        let f = try! #require(c.current)
        #expect([Correction.hitThicker, .softer].contains(f.correction))
    }
    @Test func ignoresAxesTheDrillDoesNotTrack() {
        var c = FeedbackCoach(drill: .straightIn)            // no cut, no spin
        for _ in 0..<100 { c.record([.cut: 2, .spin: 2]) }
        #expect(c.current == nil)
    }
    @Test func currentCorrectionIsStickyWhileStillTrue() {
        var c = FeedbackCoach(drill: .increasingCuts)
        for _ in 0..<30 { c.record([.speed: 1]) }
        #expect(c.current?.correction == .softer)
        // A stronger cut bias appears; the coach doesn't switch mid-lesson.
        for _ in 0..<40 { c.record([.speed: 1, .cut: 3]) }
        #expect(c.current?.correction == .softer)
    }
    @Test func movesOnWhenFixed() {
        var c = FeedbackCoach(drill: .increasingCuts)
        for _ in 0..<30 { c.record([.speed: 1, .cut: -1]) }
        let first = try! #require(c.current?.correction)
        let fixAxis: BiasAxis = first == .softer ? .speed : .cut
        for _ in 0..<20 { c.record([fixAxis: (fixAxis == .speed ? -1 : 1), (fixAxis == .speed ? .cut : .speed): (fixAxis == .speed ? -1 : 1)]) }
        #expect(c.current != nil && c.current?.correction != first)
    }
    @Test func dismissClearsAndRequiresFreshEvidence() {
        var c = FeedbackCoach(drill: .increasingCuts)
        for _ in 0..<30 { c.record([.speed: 1]) }
        c.dismiss()
        #expect(c.current == nil)
        c.record([.speed: 1])
        #expect(c.current == nil)
    }
    @Test func feedbackCarriesNoTextBeyondLabel() {
        var c = FeedbackCoach(drill: .spinControl)
        for _ in 0..<40 { c.record([.spin: 1]) }
        let f = try! #require(c.current)
        #expect(f.label == "Less spin")
        #expect(f.visual == .spinDotVsIntended)
    }
    @Test func neverNumericAcrossRandomSessions() {
        var rng = SplitMix64(seed: 99)
        for drill in DrillID.allCases {
            var c = FeedbackCoach(drill: drill)
            for _ in 0..<200 {
                var obs: [BiasAxis: Double] = [:]
                for a in BiasAxis.allCases { obs[a] = rng.gaussian() * 3 + 0.9 }
                c.record(obs)
                if let f = c.current { #expect(f.label.rangeOfCharacter(from: .decimalDigits) == nil) }
            }
        }
    }
    @Test func quietOnUnbiasedPracticeForEveryDrill() {
        var fired = 0, sessions = 0
        for drill in DrillID.allCases {
            for s in 0..<300 {
                var rng = SplitMix64(seed: UInt64(s) &+ 77_000)
                var c = FeedbackCoach(drill: drill, config: .standard); sessions += 1   // σ-unit noise
                var any = false
                for _ in 0..<50 {
                    var obs: [BiasAxis: Double] = [:]
                    for a in BiasAxis.allCases { obs[a] = rng.gaussian() }
                    c.record(obs)
                    if c.current != nil { any = true }
                }
                if any { fired += 1 }
            }
        }
        print("BIAS-REPORT coach unbiased 50-attempt sessions fired=\(fired)/\(sessions)")
        #expect(Double(fired) / Double(sessions) <= 0.03)
    }
}

@Suite("Drill setup ghosts (SPEC §10)")
struct SetupMatchTests {
    let ghosts = [Vec2(0.5, 0.5), Vec2(1.0, 0.6)]
    @Test func ghostTurnsGreenWhenARealBallSitsOnIt() {
        let m = SetupMatcher.match(ghosts: ghosts, detected: [Vec2(0.51, 0.5)], tolerance: 0.02)
        #expect(m == [true, false])
        #expect(!SetupMatcher.isReady(m))
    }
    @Test func allMatchedIsReady() {
        let m = SetupMatcher.match(ghosts: ghosts, detected: [Vec2(1.0, 0.61), Vec2(0.5, 0.49)], tolerance: 0.02)
        #expect(SetupMatcher.isReady(m))
    }
    @Test func oneBallCannotSatisfyTwoGhosts() {
        let close = [Vec2(0.5, 0.5), Vec2(0.51, 0.5)]
        let m = SetupMatcher.match(ghosts: close, detected: [Vec2(0.505, 0.5)], tolerance: 0.02)
        #expect(m.filter { $0 }.count == 1)
    }
    @Test func assignmentIsNotGreedyByGhostOrder() {
        // Greedy by ghost order would give ball A to ghost 0 and leave ghost 1 empty.
        let g = [Vec2(0.0, 0.0), Vec2(0.03, 0.0)]
        let m = SetupMatcher.match(ghosts: g, detected: [Vec2(0.015, 0.0), Vec2(-0.015, 0.0)], tolerance: 0.02)
        #expect(m == [true, true])
    }
    @Test func emptyGhostsAreNotReady() {
        #expect(!SetupMatcher.isReady(SetupMatcher.match(ghosts: [], detected: [], tolerance: 0.02)))
    }
}

@Suite("Training isolation (SPEC §4, Phase 8)")
struct TrainingIsolationTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    @Test func trainingSourcesNeverImportCompetitiveModules() throws {
        let dir = Self.root.appending(path: "Sources/Training")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)
        for f in files {
            let src = try String(contentsOf: f, encoding: .utf8)
            for m in ["Stats", "Rules", "Engine"] {
                #expect(!src.contains("import \(m)"), "\(f.lastPathComponent) imports \(m)")
            }
        }
    }
    @Test func packageTrainingTargetHasNoCompetitiveDependencies() throws {
        let pkg = try String(contentsOf: Self.root.appending(path: "Package.swift"), encoding: .utf8)
        let line = try #require(pkg.split(separator: "\n").first { $0.contains(".target(name: \"Training\"") })
        #expect(!line.contains("Stats") && !line.contains("Rules") && !line.contains("Engine"))
    }
}

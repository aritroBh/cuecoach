import Foundation
import Geometry
import simd
import Testing
@testable import CueCoach

/// Off-preset (measured) sizes exist for tables outside the presets (a 6 ft bar box, a 10 ft). Between the smallest
/// and largest preset, a size that snaps to none means the frames disagree (dist-2.0m seed 3: 7 ft full fits plus
/// tracked fits 10 cm long fused to 2.19 m, between 7 and 8 ft): never lock it.
struct AutoTableBetweenPresetsTests {
    static func m(length L: Double, snapped: TableSize?, i: Int) -> AutoTableMeasurement {
        AutoTableMeasurement(center: SIMD3(0.001 * Double(i % 3), 0.79, 0), axis: SIMD3(1, 0, 0), up: SIMD3(0, 1, 0),
                             measuredLength: L, measuredWidth: L / 2, snapped: snapped, cameraPosition: SIMD3(0, 2.2, -0.6))
    }

    /// Cross-vendor review (Grok 4.7): an unsnapped fit between presets is no size vote (it is as far from one
    /// neighbour as from the other), but it is pose evidence. 7 ft fits among them decide the size once there are
    /// enough of them, and the pose's measured size comes from those votes, so the adapter trusts it.
    @Test func betweenPresetFitsAbstainAndTheMeasuredPresetLocks() throws {
        var f = AutoTableFusion()
        for i in 0..<30 {
            f.add(i % 10 == 0 ? Self.m(length: TableSize.sevenFoot.playingLength, snapped: .sevenFoot, i: i)
                              : Self.m(length: 2.186, snapped: nil, i: i))
        }
        #expect(f.locked)
        let p = try #require(f.fused)
        #expect(p.snappedSize == .sevenFoot)
        #expect(AutoTableLocating.sizeIsTrusted(p))
    }

    /// One preset vote among abstaining fits is not enough to decide a size.
    @Test func aSinglePresetVoteAmongAbstainersNeverLocks() {
        var f = AutoTableFusion()
        for i in 0..<30 {
            f.add(i == 0 ? Self.m(length: TableSize.sevenFoot.playingLength, snapped: .sevenFoot, i: i)
                         : Self.m(length: 2.186, snapped: nil, i: i))
        }
        #expect(!f.locked)
    }

    @Test func betweenPresetFitsAloneNeverLock() {
        var f = AutoTableFusion()
        for i in 0..<30 { f.add(Self.m(length: 2.186, snapped: nil, i: i)) }
        #expect(!f.locked)
    }

    /// Grok 4.7: a 7 ft lock must stay published (adapter-trusted) after the window fills with between-preset fits.
    @Test func aLockStaysTrustedAfterBetweenPresetFitsFillTheWindow() throws {
        var f = AutoTableFusion()
        for i in 0..<15 { f.add(Self.m(length: TableSize.sevenFoot.playingLength, snapped: .sevenFoot, i: i)) }
        #expect(f.locked)
        for i in 0..<40 {
            f.add(Self.m(length: 2.186, snapped: nil, i: i))
            let p = try #require(f.fused)
            #expect(p.snappedSize == .sevenFoot)
            #expect(AutoTableLocating.sizeIsTrusted(p), "frame \(i): measured \(p.measuredLength) no longer trusted")
        }
    }

    /// Grok 4.7 r2: locked 8 ft, abstainers fill the window, then ONE borderline 8 ft snap (2.21 m, inside 6 % of
    /// 8 ft but past the ambiguity line) arrives. Below minSizeVotes it must not overwrite the lock's measured size,
    /// or the adapter stops trusting the lock and later abstainers freeze the bad value.
    @Test func aLoneBorderlineSnapWhileLockedNeverPoisonsTheMeasuredSize() throws {
        var f = AutoTableFusion()
        let eight = TableSize.eightFoot.playingLength
        for i in 0..<15 { f.add(Self.m(length: eight, snapped: .eightFoot, i: i)) }
        #expect(f.locked)
        for i in 0..<40 { f.add(Self.m(length: 2.40, snapped: nil, i: i)) }
        f.add(Self.m(length: 2.21, snapped: .eightFoot, i: 99))
        for i in 0..<20 {
            let p = try #require(f.fused)
            #expect(p.snappedSize == .eightFoot)
            #expect(AutoTableLocating.sizeIsTrusted(p), "step \(i): measured \(p.measuredLength) no longer trusted")
            f.add(Self.m(length: 2.40, snapped: nil, i: 200 + i))
        }
    }

    @Test(arguments: [1.70, 2.85])
    func offPresetTablesOutsideThePresetsStillLock(length: Double) {
        var f = AutoTableFusion()
        for i in 0..<30 { f.add(Self.m(length: length, snapped: nil, i: i)) }
        #expect(f.locked)
        #expect(abs((f.fused?.spec.length ?? 0) - length) < 0.01)
    }

    @Test func aLockedPresetIsNeverReplacedByASizeBetweenPresets() {
        var f = AutoTableFusion()
        for i in 0..<15 { f.add(Self.m(length: TableSize.sevenFoot.playingLength, snapped: .sevenFoot, i: i)) }
        #expect(f.locked)
        let gen = f.generation
        for i in 0..<40 { f.add(Self.m(length: 2.186, snapped: nil, i: i)) }
        #expect(f.fused?.snappedSize == .sevenFoot)
        #expect(f.generation == gen)
    }
}

/// D36: a size chosen in game setup or Settings is a prior (snap to it within 6 %, never lock a different preset without
/// measured evidence); a steady table between presets gets a size hint, not "step back". (D36 A, the 2 % snap, is
/// blocked: the -O matrix locked five preset scenes at measured lengths 2.1–5.7 % off; see plans/005.)
struct AutoTableUnlistedSizeTests {
    /// A frame as the detector reports it: the per-frame verdict decides its snap.
    static func m(length L: Double, i: Int) -> AutoTableMeasurement {
        let snapped: TableSize?
        if case .preset(let s) = AutoRectFitter.sizeVerdict(length: L, width: L / 2) { snapped = s } else { snapped = nil }
        return AutoTableBetweenPresetsTests.m(length: L, snapped: snapped, i: i)
    }

    static func fused(_ lengths: [Double], prior: TableSize? = nil) -> AutoTableFusion {
        var c = AutoFusionConfig()
        c.prior = prior
        var f = AutoTableFusion(config: c)
        for (i, L) in lengths.enumerated() { f.add(Self.m(length: L, i: i)) }
        return f
    }

    /// Per-frame fits are ±5 % on length at shallow views: noisy preset tables lock as their preset.
    @Test(arguments: [TableSize.sevenFoot, .eightFoot, .nineFoot])
    func noisyPresetFitsStillLockAsThePreset(size: TableSize) throws {
        var rng = AutoTestRNG(seed: 5)
        let L = size.playingLength
        let f = Self.fused((0..<30).map { _ in L * (1 + rng.uniform(-0.035, 0.035)) })
        #expect(f.locked)
        #expect(f.fused?.snappedSize == size)
    }

    /// D46: 86″ and Pro 8 sit 2.3 % apart, inside the per-frame ambiguity margin's reach, so noisy fits of them lock
    /// as themselves when the player picked the size (the prior, D36 C).
    @Test(arguments: [TableSize.eightySixInch, .proEight])
    func noisyFitsOfAChosenNewPresetLockAsIt(size: TableSize) throws {
        var rng = AutoTestRNG(seed: 5)
        let L = size.playingLength
        let f = Self.fused((0..<30).map { _ in L * (1 + rng.uniform(-0.035, 0.035)) }, prior: size)
        #expect(f.locked)
        #expect(f.fused?.snappedSize == size)
    }

    /// 2.11 m sits between 7 ft and 86″ (D46), within 6 % of both and nearly as close to each: no preset.
    @Test func anInSpanUnlistedSizeTellsTheUserItsTheSize() {
        let f = Self.fused(Array(repeating: 2.11, count: 30))
        #expect(!f.locked)
        #expect(f.sizeBetweenPresets)
        #expect(AutoTableLocating.convergingFailure(spread: 0.005, awaitingSize: true, sizeBetweenPresets: true) == .unusualSize)
        // Only guessed sizes (or unsteady corners) still ask for a look at the whole table / a steady hand.
        #expect(AutoTableLocating.convergingFailure(spread: 0.005, awaitingSize: true, sizeBetweenPresets: false) == .partialTable)
        #expect(AutoTableLocating.convergingFailure(spread: 0.03, awaitingSize: true, sizeBetweenPresets: true) == .unstable)
        #expect(AutoTableLocating.convergingFailure(spread: 0.005, awaitingSize: false, sizeBetweenPresets: false) == nil)
    }

    @Test func aGuessOnlyWindowIsNotCalledBetweenPresets() {
        var f = AutoTableFusion()
        for i in 0..<30 {
            var m = AutoTableBetweenPresetsTests.m(length: 2.18, snapped: .eightFoot, i: i)
            m.sizeMeasured = false
            f.add(m)
        }
        #expect(!f.sizeBetweenPresets)
    }

    @Test func theSizeHintIsARuler() {
        #expect(LockFailure.unusualSize.symbol == "ruler")
        #expect(CoachingSymbol.of(failure: .unusualSize, locked: false) == "ruler")
    }

    @Test func aChosenSizeIsThePrior() throws {
        // 8 ft chosen: a Pro-8-ish measurement and one in the middle between 7 and 8 ft both lock as 8 ft.
        for L in [2.30, 2.235, 2.20] {
            let f = Self.fused(Array(repeating: L, count: 30), prior: .eightFoot)
            #expect(f.locked, "\(L)")
            let p = try #require(f.fused)
            #expect(p.snappedSize == .eightFoot, "\(L)")
            #expect(AutoTableLocating.sizeIsTrusted(p, prior: .eightFoot), "\(L)")
        }
        // 7 ft chosen but an 8 ft table measured: never 7 ft.
        let g = Self.fused(Array(repeating: 2.34, count: 30), prior: .sevenFoot)
        #expect(g.fused?.snappedSize != .sevenFoot)
        #expect(g.locked && g.fused?.snappedSize == .eightFoot)
    }

    /// A prior never stands in for measurement: guessed sizes alone still never lock.
    @Test func aPriorIsNoSizeEvidence() {
        var c = AutoFusionConfig()
        c.prior = .eightFoot
        var f = AutoTableFusion(config: c)
        for i in 0..<30 {
            var m = AutoTableBetweenPresetsTests.m(length: 2.337, snapped: .eightFoot, i: i)
            m.sizeMeasured = false
            f.add(m)
        }
        #expect(!f.locked)
    }

    /// Cross-vendor review (Grok 4.7): a fit 8 ft and 9 ft both claim within 6 % (≈ 2.41–2.46 m) is `.ambiguous` and
    /// was dropped before fusion, so the chosen size never voted. One of the ambiguous presets as prior settles it;
    /// a prior that is not one of them changes nothing.
    @Test func aPriorSettlesAnAmbiguousFitOnlyBetweenItsCandidates() {
        let L = 2.435, W = L / 2
        #expect(AutoRectFitter.sizeVerdict(length: L, width: W) == .ambiguous)
        #expect(AutoRectFitter.sizeVerdict(length: L, width: W, prior: .eightFoot) == .preset(.eightFoot))
        #expect(AutoRectFitter.sizeVerdict(length: L, width: W, prior: .nineFoot) == .preset(.nineFoot))
        #expect(AutoRectFitter.sizeVerdict(length: L, width: W, prior: .sevenFoot) == .ambiguous)
        // Never touches an unambiguous verdict.
        #expect(AutoRectFitter.sizeVerdict(length: 2.34, width: 1.17, prior: .nineFoot) == .preset(.eightFoot))
        #expect(AutoRectFitter.sizeVerdict(length: 2.18, width: 1.09, prior: .eightFoot) == .preset(.eightySixInch))
        #expect(AutoRectFitter.sizeVerdict(length: 1.80, width: 0.90, prior: .sevenFoot) == .measured)
    }

    /// Steady four-rail fits measuring ≈ 2.435 m (8 ft read ~4 % long, or 9 ft read ~4 % short). The rendered table
    /// really is 2.435 m, so a preset-size rectangle misses its rails by ~5 cm and the per-frame reprojection gate
    /// would drop every frame; it is opened here to stand in for a preset table whose free fit is biased but still
    /// reprojects (the matrix bias). What is under test is the size verdict → fusion vote, not that gate.
    static func overlapRun(prior: TableSize?) -> AutoRun {
        var scene = AutoSyntheticScene()
        scene.lengthOverride = 2.435
        var c = ClassicalAutoTableLocator.Config()
        c.maxFrameRMS = 1000
        c.fusion.prior = prior
        return autoRun(scene, elevation: 40, frames: 18, locator: ClassicalAutoTableLocator(config: c))
    }

    /// Rendered end to end: steady four-rail fits in the 8/9 ft overlap reach fusion and settle on the chosen size.
    /// (Whether they then lock also needs steady corners: a fixed 8 ft rectangle on this 2.435 m render jitters
    /// ~2 cm, past the stability gate, while 9 ft holds ~1 cm and locks. That is the synthetic size mismatch, not
    /// the size logic, so the lock itself is asserted only where the geometry allows it.)
    @Test(arguments: [TableSize.eightFoot, .nineFoot])
    func anOverlapTableSettlesOnTheChosenSize(prior: TableSize) throws {
        let run = Self.overlapRun(prior: prior)
        #expect(!run.perFrame.contains { $0.frame.rejection == "size ambiguous" })
        #expect(!run.estimate.frame.awaitingSize)
        let p = try #require(run.estimate.pose)
        #expect(p.snappedSize == prior)
        #expect(AutoTableLocating.sizeIsTrusted(p, prior: prior))
        if prior == .nineFoot { #expect(run.estimate.state == .locked) }
    }

    /// …and with no size chosen they stay ambiguous and never lock.
    @Test func anOverlapTableWithoutAPriorNeverLocks() {
        let run = Self.overlapRun(prior: nil)
        #expect(run.lockedAtFrame == nil)
        #expect(run.perFrame.contains { $0.frame.rejection == "size ambiguous" })
    }

    /// Rendered end to end: an in-span 2.11 m table (between 7 ft and 86″) waits with the between-presets flag set.
    @Test func renderedBetweenPresetsTableWaitsWithTheSizeHint() throws {
        var scene = AutoSyntheticScene()
        scene.lengthOverride = 2.11
        let run = autoRun(scene, elevation: 40, frames: 18)
        #expect(run.estimate.state != .locked)
        #expect(run.estimate.frame.sizeBetweenPresets)
    }
}

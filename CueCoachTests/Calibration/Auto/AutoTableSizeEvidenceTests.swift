import Foundation
import Geometry
import simd
import Testing
@testable import CueCoach

/// A corner-anchored partial fit picks its preset by how well each preset's outline fills the cloth mask: a guess,
/// not a measurement (felt-tan seed 10: tan cloth over maple rails filled a 9 ft outline on an 8 ft table). Fusion
/// takes pose from such frames but never size: a lock's size needs frames that measured it.
struct AutoTableSizeEvidenceTests {
    static func m(_ size: TableSize, measured: Bool, visible: Double = 0.9, i: Int = 0) -> AutoTableMeasurement {
        var m = AutoTableMeasurement(center: SIMD3(0.001 * Double(i % 3), 0.79, 0), axis: SIMD3(1, 0, 0), up: SIMD3(0, 1, 0),
                                     measuredLength: size.playingLength, measuredWidth: size.playingLength / 2,
                                     snapped: size, cameraPosition: SIMD3(0, 2.2, -0.6))
        m.visibleLengthFraction = measured ? 1 : visible
        m.sizeMeasured = measured
        return m
    }

    @Test func guessedSizesAloneNeverLock() {
        var f = AutoTableFusion()
        for i in 0..<30 { f.add(Self.m(.nineFoot, measured: false, i: i)) }
        #expect(!f.locked)
        #expect(!f.sizeBacked)
    }

    @Test func aGuessLocksOnceAMeasuredFrameAgrees() {
        var f = AutoTableFusion()
        for i in 0..<30 { f.add(Self.m(.nineFoot, measured: i % 10 == 0, i: i)) }
        #expect(f.locked)
        #expect(f.fused?.snappedSize == .nineFoot)
    }

    /// Guesses outnumber measurements 4:1 but cast no size vote: the measured preset wins or nothing locks.
    @Test func guessesNeverOutvoteMeasurements() {
        var f = AutoTableFusion()
        for i in 0..<30 { f.add(Self.m(i % 5 == 0 ? .eightFoot : .nineFoot, measured: i % 5 == 0, i: i)) }
        if f.locked { #expect(f.fused?.snappedSize == .eightFoot) }
        #expect(f.fused?.snappedSize == .eightFoot)
    }

    /// Locked on a measured size, a run of guessed frames for another preset never changes it.
    @Test func guessesNeverChangeALockedSize() {
        var f = AutoTableFusion()
        for i in 0..<15 { f.add(Self.m(.eightFoot, measured: true, i: i)) }
        #expect(f.locked)
        let gen = f.generation
        for i in 0..<40 { f.add(Self.m(.nineFoot, measured: false, i: i)) }
        #expect(f.fused?.snappedSize == .eightFoot)
        #expect(f.generation == gen)
    }

    /// bar-rive-combo seed 5 (after the first cut of this fix): corner fits guessing 7 ft on a 9 ft table, each centred
    /// for a 7 ft rectangle, plus one measured 9 ft frame. Size came from the measured frame, centre from the guesses:
    /// a 9 ft pose 25 cm off locked. A guessed frame is pose evidence only under its own preset.
    @Test func guessesForAnotherPresetGiveNoPose() {
        var f = AutoTableFusion()
        let shift = (TableSize.nineFoot.playingLength - TableSize.sevenFoot.playingLength) / 2
        for i in 0..<30 {
            if i % 6 == 0 {
                f.add(Self.m(.nineFoot, measured: true, i: i))
            } else {
                var g = Self.m(.sevenFoot, measured: false, i: i)
                g.center.x -= shift   // anchored at the near corner, centred for 7 ft
                f.add(g)
            }
        }
        if f.locked, let p = f.fused {
            #expect(p.snappedSize == .nineFoot)
            #expect(abs(p.center.x) < 0.02, "locked a 9 ft pose centred for 7 ft: \(p.center.x)")
        }
    }

    /// Cross-vendor review (GLM-5): a stale held size must not survive once a new preset is *measured*. Locked 9 ft,
    /// the window fills with 8 ft guesses (held, as it must be), then measured 8 ft frames arrive: adopted with a new
    /// generation.
    @Test func aMeasuredNewPresetIsAdoptedAfterGuessesFilledTheWindow() {
        var f = AutoTableFusion()
        for i in 0..<15 { f.add(Self.m(.nineFoot, measured: true, i: i)) }
        #expect(f.locked)
        let gen = f.generation
        for i in 0..<30 { f.add(Self.m(.eightFoot, measured: false, i: i)) }
        #expect(f.fused?.snappedSize == .nineFoot)
        for i in 0..<30 { f.add(Self.m(.eightFoot, measured: true, i: i)) }
        #expect(f.fused?.snappedSize == .eightFoot)
        #expect(f.generation > gen)
    }

    /// Same, with the measured 8 ft frames sparse among guesses (one in three).
    @Test func sparseMeasurementsStillReplaceAHeldSize() {
        var f = AutoTableFusion()
        for i in 0..<15 { f.add(Self.m(.nineFoot, measured: true, i: i)) }
        for i in 0..<90 { f.add(Self.m(.eightFoot, measured: i % 3 == 0, i: i)) }
        #expect(f.fused?.snappedSize == .eightFoot)
    }
}

/// A three-rail fit (one rail dropped) measures one axis from its two opposite rails and sizes the other at 2:1 —
/// a measurement, unlike a corner guess, but 8 and 9 ft overlap within 6 % (2.39–2.48 m), where a slightly biased
/// axis picks one of two presets by a 2 % margin. Cross-vendor review (GLM-5): it measures the size only if its axis
/// alone leaves exactly one preset, the corner-partial rule.
struct AutoTableThreeRailSizeTests {
    @Test(arguments: [(2.032, true), (2.337, true), (2.54, true), (2.43, false), (2.40, false), (2.17, false)])
    func threeRailSizeIsMeasuredOnlyWhenOnePresetFits(length: Double, measured: Bool) {
        #expect(AutoRectFitter.uniquePreset(length: length) == measured, "\(length)")
    }
}


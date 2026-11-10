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

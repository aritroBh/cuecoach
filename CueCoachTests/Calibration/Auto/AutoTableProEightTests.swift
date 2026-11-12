import Foundation
import Geometry
import Testing
@testable import CueCoach

/// D46: Pro 8 (88″) and 86″ are presets. D50: with no size picked, auto snaps only to 7/8/9 ft (the old rules); Pro 8
/// and 86″ are lock candidates only when picked. Precedence (D36 C): a chosen size wins whenever the measurement is
/// within 6 % of it; with no choice (or one more than 6 % off) the nearest candidate wins.
struct AutoTableProEightTests {
    static func locked(at L: Double, prior: TableSize?) throws -> AutoTablePose {
        let f = AutoTableUnlistedSizeTests.fused(Array(repeating: L, count: 30), prior: prior)
        #expect(f.locked, "\(L) prior \(String(describing: prior))")
        let p = try #require(f.fused)
        #expect(AutoTableLocating.sizeIsTrusted(p, prior: prior), "\(L): measured \(p.measuredLength) not trusted")
        return p
    }

    /// D50: no choice → 7/8/9 ft only. A Pro 8 measured exactly still locks as 8 ft (4.4 % off, the old rule).
    @Test func withNoChoiceOnlyTheStandardPresetsLock() throws {
        #expect(try Self.locked(at: 2.235, prior: nil).snappedSize == .eightFoot)
        #expect(try Self.locked(at: 2.337, prior: nil).snappedSize == .eightFoot)
    }

    /// D50: an 86″ table with no choice sits between 7 and 8 ft (> 6 % from both): it waits with the size hint.
    @Test func withNoChoiceAnEightySixInchTableIsBetweenPresets() {
        let f = AutoTableUnlistedSizeTests.fused(Array(repeating: 86 * 0.0254, count: 30))
        #expect(!f.locked)
        #expect(f.sizeBetweenPresets)
    }

    @Test func aChosenSizeWinsWithinItsSnap() throws {
        #expect(try Self.locked(at: 2.25, prior: .eightFoot).snappedSize == .eightFoot)
        #expect(try Self.locked(at: 2.30, prior: .proEight).snappedSize == .proEight)
        #expect(try Self.locked(at: 2.20, prior: .eightySixInch).snappedSize == .eightySixInch)
    }

    @Test func aChosenSizeMoreThanSixPercentOffDoesNotWin() throws {
        // Pro 8 chosen, a 9 ft table measured (13.6 % off): the measurement wins.
        #expect(try Self.locked(at: 2.54, prior: .proEight).snappedSize == .nineFoot)
    }

    /// Per-frame verdicts: the nearest preset, and a chosen size settles a near tie between its own candidates.
    @Test func perFrameVerdicts() {
        #expect(AutoRectFitter.sizeVerdict(length: 2.235, width: 1.1175) == .preset(.eightFoot))
        #expect(AutoRectFitter.sizeVerdict(length: 2.184, width: 1.092) == .measured)
        #expect(AutoRectFitter.sizeVerdict(length: 2.235, width: 1.1175, prior: .proEight) == .preset(.proEight))
        #expect(AutoRectFitter.sizeVerdict(length: 2.184, width: 1.092, prior: .eightySixInch) == .preset(.eightySixInch))
        // A picked Pro 8 does not make 86″ a candidate.
        #expect(AutoRectFitter.sizeVerdict(length: 2.184, width: 1.092, prior: .proEight) == .preset(.proEight))
        #expect(AutoRectFitter.sizeVerdict(length: 2.285, width: 1.1425, prior: .proEight) == .preset(.proEight))
        #expect(AutoRectFitter.sizeVerdict(length: 2.285, width: 1.1425, prior: .eightFoot) == .preset(.eightFoot))
    }

    /// D50: one-axis sizing, the ambiguity check and the measured-size base preset use the same candidates.
    @Test func otherSizeChecksUseTheSameCandidates() {
        #expect(AutoRectFitter.uniquePreset(length: 2.235))
        #expect(!AutoRectFitter.uniquePreset(length: 2.235, prior: .proEight))
        #expect(!SizeAmbiguity.isAmbiguous(measuredLength: 2.25, snapped: .eightFoot))
        #expect(SizeAmbiguity.isAmbiguous(measuredLength: 2.25, snapped: .eightFoot, prior: .proEight))
        #expect(AutoRectFitter.snap(length: 2.184, width: 1.092).size == .sevenFoot)
        #expect(AutoRectFitter.snap(length: 2.184, width: 1.092, prior: .eightySixInch).size == .eightySixInch)
        #expect(TableSizing.snap(length: 2.235, width: 1.1175).size == .eightFoot)
    }
}

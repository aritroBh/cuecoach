import Foundation
import Geometry
import Testing
@testable import CueCoach

/// D46: Pro 8 (88″) and 86″ are presets. Precedence (D36 C): a chosen size wins whenever the measurement is within 6 %
/// of it; with no choice (or one more than 6 % off) the nearest preset wins.
struct AutoTableProEightTests {
    static func locked(at L: Double, prior: TableSize?) throws -> AutoTablePose {
        let f = AutoTableUnlistedSizeTests.fused(Array(repeating: L, count: 30), prior: prior)
        #expect(f.locked, "\(L) prior \(String(describing: prior))")
        let p = try #require(f.fused)
        #expect(AutoTableLocating.sizeIsTrusted(p, prior: prior), "\(L): measured \(p.measuredLength) not trusted")
        return p
    }

    @Test func withNoChoiceTheNearestPresetLocks() throws {
        #expect(try Self.locked(at: 2.235, prior: nil).snappedSize == .proEight)
        #expect(try Self.locked(at: 2.337, prior: nil).snappedSize == .eightFoot)
        #expect(try Self.locked(at: 86 * 0.0254, prior: nil).snappedSize == .eightySixInch)
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
        #expect(AutoRectFitter.sizeVerdict(length: 2.235, width: 1.1175) == .preset(.proEight))
        #expect(AutoRectFitter.sizeVerdict(length: 2.184, width: 1.092) == .preset(.eightySixInch))
        #expect(AutoRectFitter.sizeVerdict(length: 2.285, width: 1.1425, prior: .proEight) == .preset(.proEight))
        #expect(AutoRectFitter.sizeVerdict(length: 2.285, width: 1.1425, prior: .eightFoot) == .preset(.eightFoot))
    }
}

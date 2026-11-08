import Foundation
import Geometry
import simd
import Testing
@testable import CueCoach

/// Round 3: size evidence must be unambiguous before it can lock (VirtualTable light-cueShadow seed 12).
@Suite("AutoTableLocator — round 3")
struct AutoTableR3Tests {

    @Test func cleanMeasurementsSnapToTheirPreset() {
        for s in TableSize.allCases {
            let L = s.playingLength * 1.008
            #expect(AutoRectFitter.sizeVerdict(length: L, width: L / 2) == .preset(s))
        }
    }

    @Test func offPresetTwoToOneTableKeepsItsMeasuredSize() {
        #expect(AutoRectFitter.sizeVerdict(length: 1.80, width: 0.90) == .measured)
    }

    @Test func cueShadowShortenedNineFootIsNotASize() {
        // r5 matrix, seed 12: the shadow edge stood in for the foot rail. Free fit 2.36 × 1.255 m:
        // (L + 2W)/2 = 2.435 sits midway between 8 ft (2.337) and 9 ft (2.54), and L/W = 1.88 is not 2:1.
        #expect(AutoRectFitter.sizeVerdict(length: 2.36, width: 1.255) == .ambiguous)
        // A grazing end view measures the length ±5 % (baseline seed 10: 2.44 × 1.163 m on an 8 ft): still a size.
        #expect(AutoRectFitter.sizeVerdict(length: 2.44, width: 1.163) == .preset(.eightFoot))
        // Grossly off 2:1 (a rail edge that is no rail) gives no size at all.
        #expect(AutoRectFitter.sizeVerdict(length: 2.0, width: 1.27) == .notTwoToOne)
        // Even at 2:1, a size midway between two presets is ambiguous, never a confident snap.
        #expect(AutoRectFitter.sizeVerdict(length: 2.435, width: 2.435 / 2) == .ambiguous)
        #expect(AutoRectFitter.sizeVerdict(length: 2.42, width: 1.21) == .ambiguous)
    }
}

/// Codex r6: the adapter must not accept a locked pose whose fused size evidence sits between two presets.
struct AutoAdapterSizeTrustTests {
    static func pose(measuredLength L: Double, measuredWidth W: Double, snapped: TableSize?) -> AutoTablePose {
        let spec = snapped.map { TableSpec(size: $0) } ?? { var s = TableSpec(size: .nineFoot); s.length = L; s.width = L / 2; return s }()
        return AutoTablePose(tableToWorld: matrix_identity_double4x4, spec: spec, snappedSize: snapped,
                             measuredLength: L, measuredWidth: W)
    }

    @Test func lockedPoseBetweenEightAndNineIsNotTrusted() {
        // Seed 12: fused free fit 2.36 × 1.255 m snapped to 8 ft → D12 estimate 2.435 m, midway to 9 ft.
        #expect(!AutoTableLocating.sizeIsTrusted(Self.pose(measuredLength: 2.36, measuredWidth: 1.255, snapped: .eightFoot)))
    }

    @Test func cleanLocksAreTrusted() {
        for s in TableSize.allCases {
            let L = s.playingLength * 1.005
            #expect(AutoTableLocating.sizeIsTrusted(Self.pose(measuredLength: L, measuredWidth: L / 2, snapped: s)))
        }
        #expect(AutoTableLocating.sizeIsTrusted(Self.pose(measuredLength: 1.80, measuredWidth: 0.90, snapped: nil)))
    }
}

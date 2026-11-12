import Foundation
import Geometry
import simd
import Testing
@testable import CueCoach

/// Round 3: size evidence must be unambiguous before it can lock (VirtualTable light-cueShadow seed 12).
@Suite("AutoTableLocator — round 3")
struct AutoTableR3Tests {

    /// D50: with no size picked only 7/8/9 ft are snap candidates; Pro 8 / 86″ verdicts are in AutoTableProEightTests.
    @Test func cleanMeasurementsSnapToTheirPreset() {
        for s in [TableSize.sevenFoot, .eightFoot, .nineFoot] {
            let L = s.playingLength * 1.008
            #expect(AutoRectFitter.sizeVerdict(length: L, width: L / 2) == .preset(s))
        }
    }

    @Test func offPresetTwoToOneTableKeepsItsMeasuredSize() {
        #expect(AutoRectFitter.sizeVerdict(length: 1.80, width: 0.90) == .measured)
    }

    @Test func aTwoToOneThingSmallerThanABarBoxIsNoTable() {
        // VirtualTable bar-rive-combo seeds 12/19: a 1.40 × 0.70 m 2:1 patch locked 1.8 m off.
        #expect(AutoRectFitter.sizeVerdict(length: 1.40, width: 0.70) == .implausibleSize)
        #expect(AutoRectFitter.sizeVerdict(length: 3.2, width: 1.6) == .implausibleSize)
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

/// An occluder (torso, cue shadow, person) splits the cloth: the table is the largest component plus the
/// large pieces right next to it, not the largest piece alone.
struct AutoTableComponentTests {
    static func mask(_ w: Int, _ h: Int, _ rects: [(Int, Int, Int, Int)]) -> AutoMask {
        var b = [UInt8](repeating: 0, count: w * h)
        for (x0, y0, x1, y1) in rects { for y in y0..<y1 { for x in x0..<x1 { b[y * w + x] = 1 } } }
        return AutoMask(width: w, height: h, stride: 4, bits: b)
    }

    @Test func splitClothIsMergedAcrossAnOccluder() {
        // Cloth 10…90 × 20…60 cut by a 6-cell occluder band at x 46…52; a far rug at 100…115.
        let m = Self.mask(120, 80, [(10, 20, 46, 60), (52, 20, 90, 60), (100, 5, 115, 15)])
        let (t, n) = AutoClothSegmenter.tableComponent(m, maxGap: 10, minFraction: 0.15)
        #expect(n == 36 * 40 + 38 * 40)
        #expect(t.bits[30 * 120 + 20] == 1 && t.bits[30 * 120 + 80] == 1)
        #expect(t.bits[10 * 120 + 105] == 0)
    }

    @Test func smallOrDistantPiecesStayOut() {
        let m = Self.mask(120, 80, [(10, 20, 60, 60), (63, 20, 66, 23), (90, 20, 118, 60)])
        let (t, n) = AutoClothSegmenter.tableComponent(m, maxGap: 10, minFraction: 0.15)
        #expect(n == 50 * 40)
        #expect(t.bits[21 * 120 + 64] == 0)   // too small
        #expect(t.bits[30 * 120 + 100] == 0)  // 30 cells away
    }
}

/// ARKit often finds the floor before a low-texture cloth (VirtualTable felt-grey: the plane hint under the image
/// centre was the floor, so the cloth model was learned from the floor). LiDAR sees the table level anyway.
struct AutoTableFloorHintTests {
    @Test func floorPlaneHintIsCorrectedToTheTableLevel() throws {
        let scene = AutoSyntheticScene()
        let run = autoRun(scene, elevation: 35, frames: 14, planeBias: -scene.clothHeight)
        let cam = scene.camera(elevationDeg: 35)
        let f = scene.frame(cameraToWorld: cam, seed: 3)
        let levels = AutoPlaneRefiner.horizontalLevels(depth: f.depth!, camera: AutoCamera(intrinsics: f.intrinsics, cameraToWorld: cam),
                                                       imageWidth: f.image.width, imageHeight: f.image.height)
        print("[autocal] floor hint: levels \(levels.map { ($0.level, $0.share) }), rejections \(run.perFrame.map { $0.frame.rejection ?? "ok" })")
        let pose = try #require(run.estimate.pose)
        #expect(run.estimate.state == .locked)
        #expect(AutoTestMetrics.maxCornerError(pose.corners, scene.trueCorners) < 0.01)
    }

    @Test func greyClothWithAFloorHintLocks() throws {
        var scene = AutoSyntheticScene()
        scene.feltColor = (150, 150, 146)
        scene.floorColor = (120, 120, 118)
        let run = autoRun(scene, elevation: 35, frames: 14, planeBias: -scene.clothHeight)
        if let pose = run.estimate.pose, run.estimate.state == .locked {
            #expect(AutoTestMetrics.maxCornerError(pose.corners, scene.trueCorners) < 0.02)
        }
        #expect(run.estimate.state == .locked)
    }
}

/// A cue lying along one rail must not block the lock or change the size (regression guard; the three-rail
/// refit itself is exercised by the VirtualTable light-lamp replays).
struct AutoTableBadRailTests {
    @Test func aCueAlongOneRailDoesNotBlockTheLock() throws {
        var scene = AutoSyntheticScene()
        let L = scene.spec.length, W = scene.spec.width
        // A cue lying on the cloth 3 cm inside the far long rail, most of its length.
        scene.occluders = [(0.25, L - 0.25, W - 0.05, W - 0.03, 0.0, 0.025)]
        let run = autoRun(scene, elevation: 35, frames: 16)
        let pose = try #require(run.estimate.pose)
        let err = AutoTestMetrics.maxCornerError(pose.corners, scene.trueCorners)
        print("[autocal] cue along a rail: \(run.estimate.state), err \(err * 1000) mm, dropped \(run.perFrame.compactMap(\.frame.droppedRail).count), rejections \(Set(run.perFrame.compactMap(\.frame.rejection)))")
        #expect(run.estimate.state == .locked)
        #expect(pose.snappedSize == scene.size)
        #expect(err < 0.015)
    }
}

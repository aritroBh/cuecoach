import Foundation
import Testing
@testable import Training

@Suite("DrillID catalogue (SPEC §10)")
struct DrillCatalogueTests {
    @Test func catalogueMatchesSpecExactly() {
        #expect(DrillID.allCases == [.straightIn, .increasingCuts, .long, .rail, .sidePocket,
                                     .positionPlay, .spinControl, .banks])
    }
    @Test func onlyPositionPlayHasGlowingZone() {
        for d in DrillID.allCases { #expect(d.hasPositionZone == (d == .positionPlay)) }
    }
    @Test func everyDrillTracksAtLeastOneBiasAxis() {
        for d in DrillID.allCases { #expect(!d.trackedAxes.isEmpty, "\(d)") }
    }
    @Test func cueBallAndSpinAxesTrackedOnlyWhereTheDrillControlsThem() {
        #expect(DrillID.positionPlay.trackedAxes.contains(.cueBallDistance))
        #expect(DrillID.spinControl.trackedAxes.contains(.spin))
        #expect(!DrillID.straightIn.trackedAxes.contains(.cut))   // no cut on a straight-in
        #expect(!DrillID.straightIn.trackedAxes.contains(.spin))
        #expect(DrillID.increasingCuts.trackedAxes.contains(.cut))
        #expect(DrillID.long.trackedAxes.contains(.speed))
    }
    @Test func codableRoundTripIsStable() throws {
        for d in DrillID.allCases {
            let data = try JSONEncoder().encode(d)
            #expect(try JSONDecoder().decode(DrillID.self, from: data) == d)
        }
        #expect(String(data: try JSONEncoder().encode(DrillID.sidePocket), encoding: .utf8) == "\"sidePocket\"")
    }
}

@Suite("AssistLevel (SPEC §10, D1)")
struct AssistLevelTests {
    @Test func fourLevelsOrderedByLessAssist() {
        #expect(AssistLevel.allCases.map(\.rawValue) == [1, 2, 3, 4])
        #expect(AssistLevel.full < AssistLevel.objectLineOnly)
        #expect(AssistLevel.ghostOnly < AssistLevel.none)
        #expect(AssistLevel(rawValue: 0) == nil && AssistLevel(rawValue: 5) == nil)
    }
    @Test func level1ShowsAllLinesSpinAndPower() {
        let e = AssistLevel.full.visibleWhileAiming(in: .increasingCuts)
        #expect(e == [.liveAimLine, .cueToGhostLine, .ghostBall, .objectToPocketLine,
                      .cueAfterContactLine, .spinDot, .powerMeter])
    }
    @Test func level2ShowsObjectToPocketOnly() {
        #expect(AssistLevel.objectLineOnly.visibleWhileAiming(in: .long) == [.objectToPocketLine])
    }
    @Test func level3ShowsGhostCircleOnly() {
        #expect(AssistLevel.ghostOnly.visibleWhileAiming(in: .banks) == [.ghostBall])
    }
    @Test func level4ShowsNothingWhileAimingInAnyDrill_D1() {
        for d in DrillID.allCases { #expect(AssistLevel.none.visibleWhileAiming(in: d).isEmpty, "\(d)") }
    }
    @Test func positionZoneAddedAtLevels1to3InPositionPlayOnly() {
        for l in [AssistLevel.full, .objectLineOnly, .ghostOnly] {
            #expect(l.visibleWhileAiming(in: .positionPlay).contains(.positionZone))
            #expect(!l.visibleWhileAiming(in: .straightIn).contains(.positionZone))
        }
        #expect(!AssistLevel.none.visibleWhileAiming(in: .positionPlay).contains(.positionZone))
    }
    @Test func suggestedShotAvailableExactlyAtLevels1to3_D1() {
        #expect(AssistLevel.allCases.filter(\.showsSuggestedShot) == [.full, .objectLineOnly, .ghostOnly])
    }
    @Test func everyLevelRevealsTheFullOverlayAfterTheShot() {
        for l in AssistLevel.allCases {
            for d in DrillID.allCases {
                let after = l.visibleAfterShot(in: d)
                #expect(after.isSuperset(of: AssistLevel.full.visibleWhileAiming(in: d)))
                #expect(after.contains(.positionZone) == d.hasPositionZone)
            }
        }
    }
    @Test func assistIsMonotone_higherLevelNeverShowsMore() {
        for d in DrillID.allCases {
            let counts = AssistLevel.allCases.map { $0.visibleWhileAiming(in: d).count }
            #expect(counts == counts.sorted(by: >), "\(d): \(counts)")
        }
    }
    @Test func stepping() {
        #expect(AssistLevel.full.harder == .objectLineOnly)
        #expect(AssistLevel.none.harder == nil)
        #expect(AssistLevel.full.easier == nil)
        #expect(AssistLevel.none.easier == .ghostOnly)
    }
}

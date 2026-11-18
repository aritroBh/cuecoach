import Foundation
import Testing
import Training
@testable import CueCoach

@MainActor
@Suite struct TrainingPickerModelTests {
    func defaults() -> UserDefaults {
        let name = "cc.appshell.tests.\(UUID().uuidString)"
        return UserDefaults(suiteName: name)!
    }

    @Test func listsEveryDrillInCatalogueOrder() {
        let m = TrainingPickerModel(defaults: defaults())
        #expect(m.drills == DrillID.allCases)
    }

    @Test func defaultsToFirstDrillLevelOne() {
        let m = TrainingPickerModel(defaults: defaults())
        #expect(m.drill == .straightIn)
        #expect(m.level == .full)
    }

    @Test func remembersLastDrillAndLevel() {
        let d = defaults()
        let m = TrainingPickerModel(defaults: d)
        m.drill = .banks
        m.level = .none
        let again = TrainingPickerModel(defaults: d)
        #expect(again.drill == .banks)
        #expect(again.level == .none)
    }

    @Test func levelFourShowsNothingWhileAiming() {
        let m = TrainingPickerModel(defaults: defaults())
        m.level = .none
        #expect(m.previewElements.isEmpty)
        m.level = .objectLineOnly
        #expect(m.previewElements == [.objectToPocketLine])
    }

    @Test func levelSketchesFollowTheSelectedDrill() {
        let m = TrainingPickerModel(defaults: defaults())
        m.drill = .positionPlay
        #expect(m.sketch(for: .ghostOnly).contains(.positionZone))
        #expect(m.sketch(for: .none).isEmpty)          // D1: level 4 shows nothing, not even the zone
        m.drill = .straightIn
        #expect(!m.sketch(for: .ghostOnly).contains(.positionZone))
    }

    @Test func lineThreeOnlyPreviewsInPositionPlay() {
        // D24: Training shows Lines 1 and 2; Line 3 (cue-ball path) only for position play.
        let m = TrainingPickerModel(defaults: defaults())
        m.drill = .long
        #expect(!m.sketch(for: .full).contains(.cueAfterContactLine))
        m.drill = .positionPlay
        #expect(m.sketch(for: .full).contains(.cueAfterContactLine))
    }

    @Test func everyDrillHasAShortNameAndSymbol() {
        for d in DrillID.allCases {
            let n = TrainingPickerModel.name(d)
            #expect(!n.isEmpty)
            #expect(n.split(separator: " ").count <= 2)
            #expect(!TrainingPickerModel.symbol(d).isEmpty)
        }
    }

    @Test func startHandsDrillAndLevel() {
        let m = TrainingPickerModel(defaults: defaults())
        var got: (DrillID, AssistLevel)?
        m.onStart = { got = ($0, $1) }
        m.drill = .rail
        m.level = .ghostOnly
        m.start()
        #expect(got?.0 == .rail)
        #expect(got?.1 == .ghostOnly)
    }
}

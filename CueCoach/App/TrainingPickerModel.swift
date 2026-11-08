import Foundation
import Observation
import Training

/// Training: pick a drill and an assist level (D1: level 4 hides everything while aiming).
@MainActor @Observable
final class TrainingPickerModel {
    static let drillKey = "cc.training.lastDrill"
    static let levelKey = "cc.training.lastLevel"

    let drills = DrillID.allCases
    var drill: DrillID { didSet { defaults.set(drill.rawValue, forKey: Self.drillKey) } }
    var level: AssistLevel { didSet { defaults.set(level.rawValue, forKey: Self.levelKey) } }
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored var onStart: ((DrillID, AssistLevel) -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        drill = defaults.string(forKey: Self.drillKey).flatMap(DrillID.init(rawValue:)) ?? .straightIn
        level = AssistLevel(rawValue: defaults.integer(forKey: Self.levelKey)) ?? .full
    }

    /// What this level draws while aiming in the chosen drill (drives the level preview sketch).
    var previewElements: Set<OverlayElement> { sketch(for: level) }

    /// What `level` draws while aiming in the selected drill (each level disc's sketch).
    /// D24: Line 3 (cue-ball path) only in position play; the Training module's AssistLevel policy still
    /// includes it at level 1 for every drill (reported to its owner), so the preview applies D24 here.
    func sketch(for level: AssistLevel) -> Set<OverlayElement> {
        var e = level.visibleWhileAiming(in: drill)
        if !drill.hasPositionZone { e.remove(.cueAfterContactLine) }
        return e
    }

    func start() { onStart?(drill, level) }

    static func name(_ d: DrillID) -> String {
        switch d {
        case .straightIn: "Straight in"
        case .increasingCuts: "Cuts"
        case .long: "Long shots"
        case .rail: "Rail shots"
        case .sidePocket: "Side pocket"
        case .positionPlay: "Position"
        case .spinControl: "Spin"
        case .banks: "Banks"
        }
    }

    static func symbol(_ d: DrillID) -> String {
        switch d {
        case .straightIn: "arrow.up"
        case .increasingCuts: "arrow.up.right"
        case .long: "arrow.up.to.line"
        case .rail: "rectangle.portrait"
        case .sidePocket: "circle.lefthalf.filled"
        case .positionPlay: "scope"
        case .spinControl: "arrow.trianglehead.2.clockwise.rotate.90"
        case .banks: "arrow.turn.up.right"
        }
    }

    static func levelName(_ l: AssistLevel) -> String {
        switch l {
        case .full: "All lines"
        case .objectLineOnly: "Pocket line"
        case .ghostOnly: "Ghost ball"
        case .none: "No help"
        }
    }
}

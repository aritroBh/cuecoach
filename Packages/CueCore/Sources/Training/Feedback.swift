/// The visual that carries a correction (SPEC §10: average line vs correct line, miss heatmap, arrow).
public enum FeedbackVisual: Equatable, Hashable, Sendable, Codable {
    case averageLineVsCorrect
    case missHeatmap
    case arrow(ArrowDirection)
    case spinDotVsIntended     // habitual strike dot next to the intended one
}

public enum ArrowDirection: String, Equatable, Hashable, Sendable, Codable {
    case softer, harder, shorter, longer
}

/// A general, big-picture correction. Never a micro-adjustment, never a number.
public enum Correction: String, CaseIterable, Hashable, Sendable, Codable {
    case hitThicker, hitThinner, favorLeft, favorRight, softer, firmer, shorter, longer, lessSpin, moreSpin

    /// The correction that counters a detected bias.
    public init(for key: BiasKey) {
        let pos = key.direction == .positive
        switch key.axis {
        case .cut: self = pos ? .hitThicker : .hitThinner        // overcut → thicker
        case .side: self = pos ? .favorLeft : .favorRight        // misses right → favor left
        case .speed: self = pos ? .softer : .firmer
        case .cueBallDistance: self = pos ? .shorter : .longer
        case .spin: self = pos ? .lessSpin : .moreSpin
        }
    }

    /// ≤ 2 words (SPEC §2 badge rule), no digits or units.
    public var label: String {
        switch self {
        case .hitThicker: "Hit thicker"
        case .hitThinner: "Hit thinner"
        case .favorLeft: "Favor left"
        case .favorRight: "Favor right"
        case .softer: "Softer"
        case .firmer: "Firmer"
        case .shorter: "Stop shorter"
        case .longer: "Roll further"
        case .lessSpin: "Less spin"
        case .moreSpin: "More spin"
        }
    }

    public var visual: FeedbackVisual {
        switch self {
        case .hitThicker, .hitThinner: .averageLineVsCorrect
        case .favorLeft, .favorRight: .missHeatmap
        case .softer: .arrow(.softer)
        case .firmer: .arrow(.harder)
        case .shorter: .arrow(.shorter)
        case .longer: .arrow(.longer)
        case .lessSpin, .moreSpin: .spinDotVsIntended
        }
    }
}

/// Coarse size of a tendency — drives glow intensity / how far apart the lines are drawn.
public enum BiasStrength: Int, CaseIterable, Comparable, Hashable, Sendable, Codable {
    case slight, clear, strong
    public static func < (a: BiasStrength, b: BiasStrength) -> Bool { a.rawValue < b.rawValue }

    /// Buckets |mean error| in multiples of the dead zone: < 2× slight, < 6× clear, else strong.
    public init(meanError: Double, deadZone: Double) {
        let m = abs(meanError) / max(deadZone, .ulpOfOne)
        self = m < 2 ? .slight : (m < 6 ? .clear : .strong)
    }
}

public struct Feedback: Equatable, Sendable {
    public var bias: BiasKey
    public var correction: Correction
    public var strength: BiasStrength
    public var label: String { correction.label }
    public var visual: FeedbackVisual { correction.visual }
}

/// Watches one drill and surfaces one correction at a time (SPEC §10). A correction stays up
/// while its bias is still detected; when it goes away (or is dismissed) the next one may appear.
public struct FeedbackCoach: Sendable {
    public let drill: DrillID
    public private(set) var detector: BiasDetector
    public private(set) var current: Feedback?

    public init(drill: DrillID, config: BiasDetector.Config = .standard) {
        self.drill = drill
        self.detector = BiasDetector(config: config)
    }

    /// One attempt's signed errors (sign convention: `BiasAxis`). Untracked axes are ignored.
    public mutating func record(_ errors: [BiasAxis: Double]) {
        for a in BiasAxis.allCases where drill.trackedAxes.contains(a) {
            if let e = errors[a] { detector.observe(a, error: e) }
        }
        let active = detector.activeBiases()
        if let c = current, let still = active.first(where: { $0.key == c.bias }) {
            current = feedback(still)          // sticky; refresh strength
        } else {
            current = active.first.map(feedback)
        }
    }

    /// The player has seen the correction; its axis needs fresh evidence to come back.
    public mutating func dismiss() {
        if let c = current { detector.reset(c.bias.axis) }
        current = nil
    }

    private func feedback(_ b: DetectedBias) -> Feedback {
        Feedback(bias: b.key, correction: Correction(for: b.key),
                 strength: BiasStrength(meanError: b.meanError, deadZone: detector.config.deadZone))
    }
}

/// A tendency the feedback engine can detect (SPEC §10).
///
/// Error contract: each observed error is **actual − intended**, in the axis `unit`.
/// Sign: **positive** = overcut / miss right / too hard / cue ball long / more spin than intended;
/// negative is the opposite.
///
/// | axis | unit | meaning |
/// |---|---|---|
/// | cut | rad | cut angle actually hit − cut angle needed |
/// | side | m | lateral miss of the object ball at the pocket mouth (shooter's right = +) |
/// | speed | ratio | cue-ball launch speed / intended speed − 1 |
/// | cueBallDistance | m | cue-ball rest distance along its path past (+) or short of (−) the target |
/// | spin | R | |tip offset| − |intended tip offset|, in ball radii |
public enum BiasAxis: String, Codable, Sendable, CaseIterable, Hashable {
    case cut, side, speed, cueBallDistance, spin

    public var unit: String {
        switch self {
        case .cut: "rad"
        case .side, .cueBallDistance: "m"
        case .speed: "ratio"
        case .spin: "R"
        }
    }

    /// Typical per-attempt noise (1σ) of a club player, in `unit`. The detector's `standard`
    /// config is tuned in σ units, so `Config.standard.scaled(by: typicalNoise)` is the per-axis
    /// config. PROVISIONAL engineering estimates — retune from recorded training data.
    public var typicalNoise: Double {
        switch self {
        case .cut: 0.035              // ≈ 2°
        case .side: 0.03              // 3 cm at the pocket
        case .speed: 0.15             // ±15 % of intended speed
        case .cueBallDistance: 0.30   // 30 cm
        case .spin: 0.15              // 0.15 ball radii of tip offset
        }
    }
}

/// A tendency the feedback engine can detect (SPEC §10).
/// Sign convention for observed errors: **positive** = overcut / miss right / too hard /
/// cue ball long / more spin than intended; negative is the opposite.
public enum BiasAxis: String, Codable, Sendable, CaseIterable, Hashable {
    case cut, side, speed, cueBallDistance, spin
}

import Foundation
import Geometry
import Physics

/// Execution-noise model (engine.md §5.1): independent Gaussians on cue-ball direction (rad), relative
/// speed, and tip offset (ball radii). Tier values follow engine.md UD-E4's proposal (55 / 75 / 90% on a
/// 1 m / 1 m / 30° corner cut) and are sim-calibrated placeholders until Phase-3 real shots.
public struct SkillModel: Hashable, Codable, Sendable {
    /// σ of the cue-ball launch direction, radians.
    public var sigmaAim: Double
    /// σ of launch speed as a fraction of the intended speed.
    public var sigmaSpeedRel: Double
    /// σ of each tip-offset axis, in ball radii.
    public var sigmaTip: Double

    public init(sigmaAim: Double, sigmaSpeedRel: Double, sigmaTip: Double) {
        self.sigmaAim = sigmaAim
        self.sigmaSpeedRel = sigmaSpeedRel
        self.sigmaTip = sigmaTip
    }

    static let degree = Double.pi / 180
    public static let beginner = SkillModel(sigmaAim: 0.11 * degree, sigmaSpeedRel: 0.12, sigmaTip: 0.12)
    public static let amateur = SkillModel(sigmaAim: 0.071 * degree, sigmaSpeedRel: 0.08, sigmaTip: 0.0875)
    public static let strong = SkillModel(sigmaAim: 0.05 * degree, sigmaSpeedRel: 0.05, sigmaTip: 0.05)
    /// Reference skill for baseline P(make) (RATINGS UD-8) and the default for new players.
    public static let reference = amateur

    /// Per-player execution noise learned from competitive pot history (SPEC §5.5(2)).
    /// Returns `.reference` until `attempts >= minAttempts`, then Bayesian-shrinks toward 0.55 and interpolates
    /// monotonically across `[.beginner, .amateur, .strong]`.
    public static func learned(attempts: Int, makes: Int, minAttempts: Int = 12) -> SkillModel {
        guard attempts >= max(1, minAttempts) else { return .reference }
        let clampedMakes = Double(max(0, min(makes, attempts)))
        let priorWeight = 6.0
        let p = (clampedMakes + priorWeight * 0.55) / (Double(attempts) + priorWeight)
        func lerp(_ a: SkillModel, _ b: SkillModel, _ t: Double) -> SkillModel {
            let u = min(1.0, max(0.0, t))
            return SkillModel(
                sigmaAim: a.sigmaAim + (b.sigmaAim - a.sigmaAim) * u,
                sigmaSpeedRel: a.sigmaSpeedRel + (b.sigmaSpeedRel - a.sigmaSpeedRel) * u,
                sigmaTip: a.sigmaTip + (b.sigmaTip - a.sigmaTip) * u)
        }
        if p <= 0.55 {
            return lerp(.beginner, .amateur, (p - 0.30) / 0.25)
        } else {
            return lerp(.amateur, .strong, (p - 0.55) / 0.25)
        }
    }

    /// Mean execution noise across a lineup (falls back to `.reference` when empty).
    public static func averaged(_ models: [SkillModel]) -> SkillModel {
        guard !models.isEmpty else { return .reference }
        let n = Double(models.count)
        return SkillModel(
            sigmaAim: models.reduce(0) { $0 + $1.sigmaAim } / n,
            sigmaSpeedRel: models.reduce(0) { $0 + $1.sigmaSpeedRel } / n,
            sigmaTip: models.reduce(0) { $0 + $1.sigmaTip } / n)
    }

    /// Tip offsets beyond this radius miscue (engine.md §5.1).
    public static let miscueRadius = 0.5

    /// The stroke actually executed for standard-normal noise `z` = (aim, speed, tip side, tip vertical).
    public func perturbed(_ s: Stroke, noise z: SIMD4<Double>) -> Stroke {
        var direction = s.direction.rotated(by: sigmaAim * z.x)
        var speed = max(0.01, s.speed * (1 + sigmaSpeedRel * z.y))
        var tip = s.tipOffset + Vec2(sigmaTip * z.z, sigmaTip * z.w)
        if tip.length > SkillModel.miscueRadius {
            // Miscue: the tip slides off; most energy is lost and the ball squirts.
            tip = tip.normalized * (SkillModel.miscueRadius * 0.999)
            speed *= 0.3
            direction = direction.rotated(by: (z.z >= 0 ? 1 : -1) * 5 * SkillModel.degree)
        }
        return Stroke(direction: direction, speed: speed, tipOffset: tip)
    }
}

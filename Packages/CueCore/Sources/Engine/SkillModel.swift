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

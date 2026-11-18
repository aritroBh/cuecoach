import Foundation
import Geometry
import Physics

/// Closed-form P(make) (engine.md §4.3, Quick tier): TP 3.4 gain × skill σ against the pocket window.
/// Execution noise only; perception error stays out (engine.md §4.3).
enum AnalyticP {
    static let degree = Double.pi / 180
    /// Extra angular spread a rail adds to an object ball's bank angle (placeholder, gate-tuned).
    static let bankRailSigma = 0.5 * degree
    /// Extra spread a rail adds to the cue ball's direction on a kick.
    static let kickRailSigma = 0.25 * degree
    static let maxCut = 80 * degree

    @inline(__always) static func window(_ halfAngle: Double, sigma: Double) -> Double {
        guard halfAngle > 0 else { return 0 }
        guard sigma > 1e-15 else { return 1 }
        return erf(halfAngle / (sigma * 2.0.squareRoot()))
    }

    static func halfAngle(_ pocket: Pocket, spec: TableSpec, from q: Vec2, travel: Double, approach: Vec2) -> Double {
        atan(EngineGeometry.pocketHalfWidth(pocket, spec: spec, approach: approach) / max(travel, 0.02))
    }

    static func direct(cue c: Vec2, object o: Vec2, pocket p: Pocket, spec: TableSpec, skill: SkillModel) -> Double {
        let pc = spec.pocketCenter(p)
        let cut = EngineGeometry.cutAngle(cue: c, object: o, pocket: pc)
        guard cut < maxCut else { return 0 }
        let g = EngineGeometry.throwGain(distance: o.distance(to: c), cut: cut)
        let dp = o.distance(to: pc)
        return window(halfAngle(p, spec: spec, from: o, travel: dp, approach: pc - o), sigma: g * skill.sigmaAim)
    }

    static func combo(cue c: Vec2, first t: Vec2, second o: Vec2, pocket p: Pocket, spec: TableSpec,
                      skill: SkillModel) -> Double {
        let pc = spec.pocketCenter(p)
        let ghost2 = AimGeometry.ghostBall(object: o, pocket: pc)
        let cut2 = EngineGeometry.angleBetween(ghost2 - t, pc - o)
        let ghost1 = AimGeometry.ghostBall(object: t, pocket: ghost2)
        let cut1 = EngineGeometry.angleBetween(ghost1 - c, ghost2 - t)
        guard cut1 < 70 * degree, cut2 < 70 * degree else { return 0 }
        let g = EngineGeometry.throwGain(distance: t.distance(to: c), cut: cut1)
            * EngineGeometry.throwGain(distance: o.distance(to: t), cut: cut2)
        return window(halfAngle(p, spec: spec, from: o, travel: o.distance(to: pc), approach: pc - o),
                      sigma: g * skill.sigmaAim)
    }

    /// Object ball off `rail` into `p`. `bankPoint` is where the OB centre meets the rail line.
    static func bank(cue c: Vec2, object o: Vec2, pocket p: Pocket, rail: Rail, spec: TableSpec,
                     skill: SkillModel) -> Double {
        let pc = spec.pocketCenter(p)
        let pm = EngineGeometry.mirror(pc, across: rail, spec: spec)
        guard let bp = EngineGeometry.railPoint(from: o, toMirrored: pm, rail: rail, spec: spec) else { return 0 }
        let ghost = AimGeometry.ghostBall(object: o, pocket: pm)
        let cut = EngineGeometry.angleBetween(ghost - c, pm - o)
        guard cut < 70 * degree else { return 0 }
        let g = EngineGeometry.throwGain(distance: o.distance(to: c), cut: cut)
        let sigma = ((g * skill.sigmaAim) * (g * skill.sigmaAim) + bankRailSigma * bankRailSigma).squareRoot()
        return window(halfAngle(p, spec: spec, from: bp, travel: o.distance(to: pm), approach: pc - bp), sigma: sigma)
    }

    /// Cue ball off `rail`, then pots `o` in `p`.
    static func kickPot(cue c: Vec2, object o: Vec2, pocket p: Pocket, rail: Rail, spec: TableSpec,
                        skill: SkillModel) -> Double {
        let pc = spec.pocketCenter(p)
        let ghost = AimGeometry.ghostBall(object: o, pocket: pc)
        let gm = EngineGeometry.mirror(ghost, across: rail, spec: spec)
        guard let rp = EngineGeometry.railPoint(from: c, toMirrored: gm, rail: rail, spec: spec) else { return 0 }
        let cut = EngineGeometry.angleBetween(ghost - rp, pc - o)
        guard cut < 70 * degree else { return 0 }
        let g = EngineGeometry.throwGain(distance: c.distance(to: gm), cut: cut)
        let sigma = g * (skill.sigmaAim * skill.sigmaAim + kickRailSigma * kickRailSigma).squareRoot()
        return window(halfAngle(p, spec: spec, from: o, travel: o.distance(to: pc), approach: pc - o), sigma: sigma)
    }

    /// P(the cue ball hits `o` at all) on a one-rail kick at its centre.
    static func kickHit(cue c: Vec2, object o: Vec2, rail: Rail, spec: TableSpec, skill: SkillModel) -> Double {
        let om = EngineGeometry.mirror(o, across: rail, spec: spec)
        let travel = c.distance(to: om)
        let sigma = (skill.sigmaAim * skill.sigmaAim + kickRailSigma * kickRailSigma).squareRoot()
        return window(atan(1.8 * EngineGeometry.R / max(travel, 0.02)), sigma: sigma)
    }

    /// Cue-ball launch speed (m/s) needed to send the OB `obTravel` metres and arrive with some pace.
    /// Sliding → rolling at 5/7 for both balls, rolling deceleration μr·g, cos(cut) transfer, rail loss.
    static func requiredSpeed(cueTravel d1: Double, obTravel d2: Double, cut: Double, rails: Int = 0,
                              params: PhysicsParams = .standard) -> Double {
        let a = params.rollingFriction * params.gravity
        let railLoss = pow(params.cushionRestitution, Double(rails))
        let vObRoll = (2 * a * d2 + 0.35 * 0.35).squareRoot() / railLoss
        let vOb0 = vObRoll * 7 / 5
        let vContact = vOb0 / max(0.2, cos(cut) * 0.975)
        return 7.0 / 5.0 * (vContact * vContact + 2 * a * d1).squareRoot()
    }
}

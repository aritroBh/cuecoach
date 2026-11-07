import Foundation
import Geometry
import Physics

/// Closed-form table geometry used by candidate generation and analytic P(make).
enum EngineGeometry {
    static let R = TableSpec.ballRadius

    /// True when a ball moving from `a` to `b` passes no blocker centre closer than 2R (ball–ball contact).
    /// `margin` widens the capsule (engine.md §4.3 perception margin).
    static func pathClear(from a: Vec2, to b: Vec2, blockers: [Vec2], margin: Double = 0) -> Bool {
        let d = b - a
        let len2 = d.lengthSquared
        let r = 2 * R + margin
        for c in blockers {
            let t = len2 == 0 ? 0 : max(0, min(1, (c - a).dot(d) / len2))
            if t == 0 && (c - a).dot(d) < 0 { continue }            // behind the start
            let p = a + d * t
            if (c - p).lengthSquared < r * r - 1e-12 { return false }
        }
        return true
    }

    /// Cut angle (rad, unsigned) for cue → ghost and object → pocket.
    static func cutAngle(cue: Vec2, object: Vec2, pocket: Vec2) -> Double {
        let ghost = AimGeometry.ghostBall(object: object, pocket: pocket)
        return angleBetween(ghost - cue, pocket - object)
    }

    static func angleBetween(_ u: Vec2, _ v: Vec2) -> Double {
        let lu = u.length, lv = v.length
        guard lu > 0, lv > 0 else { return 0 }
        return acos(max(-1, min(1, u.dot(v) / (lu * lv))))
    }

    /// Signed angle from u to v in (-π, π].
    static func signedAngle(from u: Vec2, to v: Vec2) -> Double { atan2(u.cross(v), u.dot(v)) }

    /// Mirror a point across the line a ball centre reaches at the rail (cushion nose + R).
    static func mirror(_ p: Vec2, across rail: Rail, spec: TableSpec) -> Vec2 {
        switch rail {
        case .left: Vec2(p.x, 2 * R - p.y)
        case .right: Vec2(p.x, 2 * (spec.width - R) - p.y)
        case .head: Vec2(2 * R - p.x, p.y)
        case .foot: Vec2(2 * (spec.length - R) - p.x, p.y)
        case .cornerJaw, .sideJaw: p
        }
    }

    /// Point where the straight line a → b crosses the rail's ball-centre line (a and b on opposite sides).
    static func railPoint(from a: Vec2, toMirrored b: Vec2, rail: Rail, spec: TableSpec) -> Vec2? {
        let d = b - a
        let t: Double
        switch rail {
        case .left: guard d.y != 0 else { return nil }; t = (R - a.y) / d.y
        case .right: guard d.y != 0 else { return nil }; t = (spec.width - R - a.y) / d.y
        case .head: guard d.x != 0 else { return nil }; t = (R - a.x) / d.x
        case .foot: guard d.x != 0 else { return nil }; t = (spec.length - R - a.x) / d.x
        case .cornerJaw, .sideJaw: return nil
        }
        guard t > 0, t < 1 else { return nil }
        let p = a + d * t
        switch rail {
        case .left, .right:
            // Away from the corners and from the side pocket on this rail.
            return p.x > 0.1 && p.x < spec.length - 0.1 && abs(p.x - spec.length / 2) > 0.08 ? p : nil
        default:
            return p.y > 0.1 && p.y < spec.width - 0.1 ? p : nil
        }
    }

    static let railsAll: [Rail] = [.foot, .head, .left, .right]

    /// Rails that form a pocket's jaws (banks off these into that pocket aren't generated).
    static func rails(of pocket: Pocket) -> [Rail] {
        switch pocket {
        case .footLeft: [.foot, .left]
        case .footRight: [.foot, .right]
        case .headLeft: [.head, .left]
        case .headRight: [.head, .right]
        case .sideLeft: [.left]
        case .sideRight: [.right]
        }
    }

    /// TP 3.4 linearised gain: OB direction error per unit CB direction error, g = d / (2R cos φ).
    static func throwGain(distance d: Double, cut phi: Double) -> Double {
        d / (2 * R * max(0.05, cos(phi)))
    }

    /// Effective half-width (m) of the window the OB centre must pass through at the pocket, given the
    /// approach direction (engine.md §4.3; TP A.13 seed, ±29 mm corner at a straight approach).
    static func pocketHalfWidth(_ pocket: Pocket, spec: TableSpec, approach: Vec2) -> Double {
        let a = approach.normalized
        if pocket.isSide {
            // Facing straight in along ±y gives the widest window; it closes past ~55°.
            let dev = acos(min(1, abs(a.y)))
            let limit = 55 * Double.pi / 180
            guard dev < limit else { return 0 }
            return 0.036 * cos(dev * (Double.pi / 2) / limit * 0.9)
        }
        // Corner: the bisector points diagonally into the pocket.
        let c = spec.pocketCenter(pocket)
        let bis = Vec2(c.x == 0 ? -1 : 1, c.y == 0 ? -1 : 1).normalized
        let dev = acos(max(-1, min(1, a.dot(bis))))
        let limit = 50 * Double.pi / 180
        guard dev < limit else { return 0.008 }
        return 0.029 * (0.45 + 0.55 * cos(dev * (Double.pi / 2) / limit))
    }

    /// Standard normal CDF.
    static func phi(_ x: Double) -> Double { 0.5 * erfc(-x / 2.0.squareRoot()) }
}

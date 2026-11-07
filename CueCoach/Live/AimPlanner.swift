import Foundation
import Geometry

/// Suggested spin as a cue-ball tip offset: x = side (right +), y = vertical (follow +, draw −), |·| ≤ 0.5.
/// Shown as a dot on a cue-ball face; never as numbers.
struct SpinSuggestion: Sendable, Equatable {
    var tip: Vec2
    static let stun = SpinSuggestion(tip: .zero)
    static let follow = SpinSuggestion(tip: Vec2(0, 0.4))
    static let draw = SpinSuggestion(tip: Vec2(0, -0.4))
}

/// Ghost-ball aim suggestion (v0 geometry; CueCore Physics replaces the predictor).
struct AimSuggestion: Sendable, Equatable {
    var cue: Vec2
    var object: Vec2
    var ghost: Vec2
    var pocket: Pocket
    var pocketPoint: Vec2
    /// Cut angle in radians (0 = straight in), measured on the throw-compensated contact line.
    var cut: Double
    /// Throw compensation applied (radians).
    var throwAngle: Double
    /// 0…1, higher = easier. Drives colour (green / yellow / red), never shown as a number.
    var ease: Double
    /// Line 3: cue-ball path after contact for the suggested spin (table points, starts at the ghost).
    var cuePath: [Vec2]
    var spin: SpinSuggestion
    /// Suggested power, 1…5 (a 5-step meter).
    var power: Int
    /// Line 2 polyline (object ball → pocket). Geometric: a straight segment; physics: the simulated path.
    var objectPath: [Vec2] = []
    /// Simulated outcome when previewed with physics (nil = geometric only).
    var outcome: ShotPreview.Outcome? = nil
}

/// Swappable shot model: SPEC §5.4 Physics plugs in here later.
protocol ShotPredictor: Sendable {
    /// Object-ball throw (radians) for a cut; positive = thrown toward the cue ball's travel side.
    func throwAngle(cut: Double, spin: SpinSuggestion) -> Double
    /// Cue-ball direction after contact, as an angle from the original cue direction toward the tangent side.
    func cueDeflection(cut: Double, spin: SpinSuggestion) -> Double
}

/// Geometric approximations (Dr. Dave): stun → tangent line; natural roll → tanθ = sinφcosφ / (sin²φ + 2/5)
/// (≈30° near half-ball); draw mirrored past the tangent line. Cut-induced throw peaks at a few degrees.
struct GeometricShotPredictor: ShotPredictor {
    var maxThrow = 0.07  // rad ≈ 4°

    func throwAngle(cut: Double, spin: SpinSuggestion) -> Double { maxThrow * sin(2 * min(cut, .pi / 2)) }

    func cueDeflection(cut phi: Double, spin: SpinSuggestion) -> Double {
        let tangent = .pi / 2 - phi
        let roll = atan2(sin(phi) * cos(phi), sin(phi) * sin(phi) + 0.4)
        if spin.tip.y > 0.1 { return roll }
        if spin.tip.y < -0.1 { return 2 * tangent - roll }
        return tangent
    }
}

enum AimPlanner {
    static let maxCut = 75.0 * .pi / 180

    static func ghostBall(object: Vec2, pocket: Vec2) -> Vec2 {
        object - (pocket - object).normalized * (2 * TableSpec.ballRadius)
    }

    /// Best (object ball, pocket) for the cue ball, or nil if nothing is makeable.
    /// - objects: target candidates. - blockers: every other ball on the table (illegal / unknown included);
    ///   a shot whose cue path or object path is obstructed by any ball is never suggested.
    static func suggest(cue: Vec2, objects: [Vec2], blockers: [Vec2] = [], spec: TableSpec,
                        predictor: any ShotPredictor = GeometricShotPredictor()) -> AimSuggestion? {
        candidates(cue: cue, objects: objects, blockers: blockers, spec: spec, predictor: predictor, limit: 1).first
    }

    /// Every makeable (object, pocket) pair, easiest first.
    static func candidates(cue: Vec2, objects: [Vec2], blockers: [Vec2] = [], spec: TableSpec,
                           predictor: any ShotPredictor = GeometricShotPredictor(), limit: Int = 5) -> [AimSuggestion] {
        let R = TableSpec.ballRadius
        var all: [AimSuggestion] = []
        for (oi, obj) in objects.enumerated() {
            for pocket in spec.pockets {
                let pp = aimPoint(pocket, spec: spec)
                let want = pp - obj
                guard want.length > 1e-6 else { continue }
                let u = want.normalized
                // Uncompensated geometry first, then rotate the contact line against the throw.
                let g0 = obj - u * (2 * R)
                let shot0 = g0 - cue
                guard shot0.length > R else { continue }
                let cut0 = acos(max(-1, min(1, shot0.normalized.dot(u))))
                guard cut0 < maxCut else { continue }
                let side: Double = shot0.cross(u) >= 0 ? 1 : -1   // which way the cut goes
                let th = predictor.throwAngle(cut: cut0, spin: .stun)
                let contact = u.rotated(by: side * th)  // throw pulls the path back onto u
                let ghost = obj - contact * (2 * R)
                let shot = ghost - cue
                guard shot.length > R else { continue }
                let cut = acos(max(-1, min(1, shot.normalized.dot(contact))))
                guard cut < maxCut else { continue }
                if pocket.isSide {
                    let inward = Vec2(0, pocket == .sideLeft ? -1 : 1)
                    if u.dot(inward) < cos(60 * .pi / 180) { continue }
                }
                let others = objects.enumerated().filter { $0.offset != oi }.map(\.element) + blockers
                guard clear(from: cue, to: ghost, of: others, radius: 2 * R),
                      clear(from: obj, to: pp, of: others + [cue], radius: 2 * R) else { continue }
                let distance = shot.length + want.length
                let ease = max(0, cos(cut)) * exp(-distance / 2.5)
                let (spin, path) = chooseSpin(cueDir: shot.normalized, contact: contact, cut: cut, ghost: ghost,
                                              spec: spec, predictor: predictor)
                all.append(AimSuggestion(cue: cue, object: obj, ghost: ghost, pocket: pocket, pocketPoint: pp, cut: cut,
                                         throwAngle: th, ease: ease, cuePath: path, spin: spin,
                                         power: power(distance: distance, cut: cut, spin: spin),
                                         objectPath: [obj, pp]))
            }
        }
        return Array(all.sorted { $0.ease > $1.ease }.prefix(limit))
    }

    /// Prefer stun, then follow, then draw: the first whose cue path avoids every pocket (no scratch).
    static func chooseSpin(cueDir: Vec2, contact: Vec2, cut: Double, ghost: Vec2, spec: TableSpec,
                           predictor: any ShotPredictor) -> (SpinSuggestion, [Vec2]) {
        let options: [SpinSuggestion] = [.stun, .follow, .draw]
        var first: (SpinSuggestion, [Vec2])?
        for s in options {
            let path = cuePath(cueDir: cueDir, contact: contact, cut: cut, ghost: ghost, spin: s, spec: spec,
                               predictor: predictor)
            if first == nil { first = (s, path) }
            if !scratches(path, spec: spec) { return (s, path) }
        }
        return first!
    }

    static func cuePath(cueDir: Vec2, contact: Vec2, cut: Double, ghost: Vec2, spin: SpinSuggestion, spec: TableSpec,
                        predictor: any ShotPredictor) -> [Vec2] {
        let theta = predictor.cueDeflection(cut: cut, spin: spin)
        // Tangent side: the side of the contact line the cue ball leaves on.
        let toward: Double = cueDir.cross(contact) >= 0 ? -1 : 1
        var dir = cueDir.rotated(by: toward * theta)
        if cut < 1e-3 && spin.tip.y < -0.1 { dir = -cueDir }
        if cut < 1e-3 && abs(spin.tip.y) <= 0.1 { return [ghost] }  // straight stun: the cue ball stops
        let length = spin.tip.y > 0.1 ? 0.9 : 0.6
        return [ghost, clipToTable(from: ghost, dir: dir, maxLength: length, spec: spec)]
    }

    static func clipToTable(from p: Vec2, dir: Vec2, maxLength: Double, spec: TableSpec) -> Vec2 {
        let R = TableSpec.ballRadius
        var t = maxLength
        if dir.x > 1e-9 { t = min(t, (spec.length - R - p.x) / dir.x) }
        if dir.x < -1e-9 { t = min(t, (R - p.x) / dir.x) }
        if dir.y > 1e-9 { t = min(t, (spec.width - R - p.y) / dir.y) }
        if dir.y < -1e-9 { t = min(t, (R - p.y) / dir.y) }
        return p + dir * max(0, t)
    }

    static func scratches(_ path: [Vec2], spec: TableSpec) -> Bool {
        guard path.count >= 2 else { return false }
        for p in spec.pockets {
            let c = spec.pocketCenter(p)
            if !clear(from: path[0], to: path[path.count - 1], of: [c], radius: 0.09) { return true }
        }
        return false
    }

    static func power(distance: Double, cut: Double, spin: SpinSuggestion) -> Int {
        var p = 1 + distance / 0.9
        if cut > 45 * .pi / 180 { p += 1 }
        if spin.tip.y < -0.1 { p += 1 }
        return max(1, min(5, Int(p.rounded())))
    }

    /// Point a ball centre aims for: a little inside the capture point.
    static func aimPoint(_ p: Pocket, spec: TableSpec) -> Vec2 {
        let c = spec.pocketCenter(p)
        let toward = (Vec2(spec.length / 2, spec.width / 2) - c).normalized
        return c + toward * (p.isSide ? 0.0 : 0.02)
    }

    /// True if the segment a→b keeps at least `radius` from every centre in `balls`.
    static func clear(from a: Vec2, to b: Vec2, of balls: [Vec2], radius: Double) -> Bool {
        let ab = b - a, len2 = ab.lengthSquared
        for c in balls {
            let t = len2 > 0 ? max(0, min(1, (c - a).dot(ab) / len2)) : 0
            if (a + ab * t).distance(to: c) < radius - 1e-9 { return false }
        }
        return true
    }
}

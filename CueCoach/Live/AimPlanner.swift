import Foundation
import Geometry

/// Ghost-ball aim suggestion (v0, geometric only; Physics/Engine replace it).
struct AimSuggestion: Sendable, Equatable {
    var cue: Vec2
    var object: Vec2
    var ghost: Vec2
    var pocket: Pocket
    var pocketPoint: Vec2
    /// Cut angle in radians (0 = straight in).
    var cut: Double
    /// 0…1, higher = easier. Drives colour (green / yellow / red), never shown as a number.
    var ease: Double
}

enum AimPlanner {
    static let maxCut = 75.0 * .pi / 180

    static func ghostBall(object: Vec2, pocket: Vec2) -> Vec2 {
        object - (pocket - object).normalized * (2 * TableSpec.ballRadius)
    }

    /// Best (object ball, pocket) pair for the cue ball, or nil if nothing is makeable.
    static func suggest(cue: Vec2, objects: [Vec2], spec: TableSpec) -> AimSuggestion? {
        let R = TableSpec.ballRadius
        var best: AimSuggestion?
        for (oi, obj) in objects.enumerated() {
            for pocket in spec.pockets {
                let pp = aimPoint(pocket, spec: spec)
                let ghost = ghostBall(object: obj, pocket: pp)
                let shot = ghost - cue, path = pp - obj
                guard shot.length > R, path.length > 1e-6 else { continue }
                let cosCut = shot.normalized.dot(path.normalized)
                let cut = acos(max(-1, min(1, cosCut)))
                guard cut < maxCut else { continue }
                // Side pockets reject shallow approach angles.
                if pocket.isSide {
                    let inward = Vec2(0, pocket == .sideLeft ? -1 : 1)
                    if path.normalized.dot(inward) < cos(60 * .pi / 180) { continue }
                }
                let others = objects.enumerated().filter { $0.offset != oi }.map(\.element)
                guard clear(from: cue, to: ghost, of: others, radius: 2 * R),
                      clear(from: obj, to: pp, of: others + [cue], radius: 2 * R) else { continue }
                let distance = shot.length + path.length
                let ease = max(0, cos(cut)) * exp(-distance / 2.5)
                if best == nil || ease > best!.ease {
                    best = AimSuggestion(cue: cue, object: obj, ghost: ghost, pocket: pocket, pocketPoint: pp,
                                         cut: cut, ease: ease)
                }
            }
        }
        return best
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

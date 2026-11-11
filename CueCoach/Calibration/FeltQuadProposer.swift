import Foundation
import Geometry

/// Why the table isn't locked yet (shown as a glyph; logged in the dev HUD).
enum LockFailure: String, Sendable, Equatable {
    case noPlane        // ARKit hasn't found a horizontal surface
    case noFelt         // no uniform cloth region at the image centre
    case partialTable   // the cloth runs off the image edge: step back / tilt
    case tooFar         // the cloth is a small part of the image: move closer
    case tooClose       // the cloth fills the frame on 3+ sides
    case badShape       // quad doesn't validate as a table
    case unstable       // estimates still disagree frame to frame: hold steady
    case unusualSize    // the whole table is in view but its size sits between the presets (D36)
}

struct FeltAnalysis: Sendable {
    var quad: [Vec2]?
    var failure: LockFailure?
}

/// Auto calibration proposal: segment the cloth by chromaticity relative to the cloth at the image centre
/// (works for green, blue, red or grey felt and tolerates lamp hotspots), take the region containing the
/// centre, and fit a quadrilateral to its outline. Corners are the felt boundary (cushion tops included),
/// in source-image pixels.
enum FeltQuadProposer {
    static func propose(_ full: PixelImage) -> [Vec2]? { analyze(full).quad }

    static func analyze(_ full: PixelImage) -> FeltAnalysis {
        let k = max(1, full.width / 480)   // ~480 px analysis: corner precision ≈ 1 cm at 3 m
        let img = full.decimated(by: k)
        let w = img.width, h = img.height
        guard w > 16, h > 16 else { return FeltAnalysis(quad: nil, failure: .noFelt) }

        // 1. Reference cloth colour: median of the central 30–70 % window.
        var rs: [Int] = [], gs: [Int] = [], bs: [Int] = []
        for y in (h * 3 / 10)..<(h * 7 / 10) {
            for x in (w * 3 / 10)..<(w * 7 / 10) {
                let p = img.pixel(x, y); rs.append(Int(p.0)); gs.append(Int(p.1)); bs.append(Int(p.2))
            }
        }
        func med(_ a: [Int]) -> Double { Double(a.sorted()[a.count / 2]) }
        let rr = med(rs), rg = med(gs), rb = med(bs), rsum = rr + rg + rb
        guard rsum > 45 else { return FeltAnalysis(quad: nil, failure: .noFelt) }
        let cr = rr / rsum, cg = rg / rsum

        // 2. Cloth mask: same chromaticity (tolerance grows under bright lamp hotspots), wide brightness band.
        var mask = [Bool](repeating: false, count: w * h)
        var centreHits = 0, centreAll = 0
        for y in 0..<h {
            for x in 0..<w {
                let p = img.pixel(x, y)
                let r = Double(p.0), g = Double(p.1), b = Double(p.2), sum = r + g + b
                guard sum > 30 else { continue }
                let kk = sum / rsum
                guard kk > 0.35, kk < 2.8 else { continue }
                let tol = 0.04 + 0.05 * max(0, kk - 1)
                let on = hypot(r / sum - cr, g / sum - cg) < tol
                mask[y * w + x] = on
                if x >= w * 3 / 10 && x < w * 7 / 10 && y >= h * 3 / 10 && y < h * 7 / 10 {
                    centreAll += 1; if on { centreHits += 1 }
                }
            }
        }
        // The centre must be mostly one uniform cloth.
        guard centreAll > 0, Double(centreHits) / Double(centreAll) > 0.5 else {
            return FeltAnalysis(quad: nil, failure: .noFelt)
        }

        // 3. Connected components; keep the one covering the most centre pixels.
        var label = [Int32](repeating: 0, count: w * h)
        var sizes: [Int32: Int] = [:], centreCount: [Int32: Int] = [:]
        var next: Int32 = 1
        var stack: [Int] = []
        for i in 0..<(w * h) where mask[i] && label[i] == 0 {
            var size = 0, inCentre = 0
            stack.append(i); label[i] = next
            while let j = stack.popLast() {
                size += 1
                let x = j % w, y = j / w
                if x >= w * 3 / 10 && x < w * 7 / 10 && y >= h * 3 / 10 && y < h * 7 / 10 { inCentre += 1 }
                for n in [x > 0 ? j - 1 : -1, x < w - 1 ? j + 1 : -1, y > 0 ? j - w : -1, y < h - 1 ? j + w : -1]
                where n >= 0 && mask[n] && label[n] == 0 {
                    label[n] = next; stack.append(n)
                }
            }
            sizes[next] = size; centreCount[next] = inCentre
            next += 1
        }
        guard let bestID = centreCount.max(by: { $0.value < $1.value })?.key, let size = sizes[bestID] else {
            return FeltAnalysis(quad: nil, failure: .noFelt)
        }
        let areaFrac = Double(size) / Double(w * h)
        if areaFrac < 0.04 { return FeltAnalysis(quad: nil, failure: .tooFar) }

        // 4. Boundary samples + which image edges the cloth touches.
        var boundary: [Vec2] = []
        var touch = [0, 0, 0, 0]   // left, right, top, bottom (pixels of cloth on that edge)
        for y in 0..<h {
            var lo = -1, hi = -1
            for x in 0..<w where label[y * w + x] == bestID { if lo < 0 { lo = x }; hi = x }
            if lo >= 0 { boundary.append(Vec2(Double(lo), Double(y))); boundary.append(Vec2(Double(hi), Double(y))) }
            if lo == 0 { touch[0] += 1 }
            if hi == w - 1 { touch[1] += 1 }
        }
        for x in 0..<w {
            var lo = -1, hi = -1
            for y in 0..<h where label[y * w + x] == bestID { if lo < 0 { lo = y }; hi = y }
            if lo >= 0 { boundary.append(Vec2(Double(x), Double(lo))); boundary.append(Vec2(Double(x), Double(hi))) }
            if lo == 0 { touch[2] += 1 }
            if hi == h - 1 { touch[3] += 1 }
        }
        let edgeLen = [h, h, w, w]
        let cut = (0..<4).filter { Double(touch[$0]) > 0.08 * Double(edgeLen[$0]) }.count
        // Cloth on three or four edges: too close — step back (Codex r5: not "no felt"). Exception: a dark,
        // colourless region filling the frame is the room (floor/wall), not cloth.
        if cut >= 3 {
            let refHSV = ColorMath.hsv(UInt8(rr), UInt8(rg), UInt8(rb))
            if cut == 4 && rsum < 150 && refHSV.s < 0.2 { return FeltAnalysis(quad: nil, failure: .noFelt) }
            return FeltAnalysis(quad: nil, failure: .tooClose)
        }
        if cut >= 1 { return FeltAnalysis(quad: nil, failure: .partialTable) }

        let hull = convexHull(boundary)
        guard hull.count >= 4, var quad = sidesQuad(hull) ?? reduceToQuad(hull) else {
            return FeltAnalysis(quad: nil, failure: .badShape)
        }
        quad = refineWithLines(quad, boundary: boundary) ?? quad
        return FeltAnalysis(quad: quad.map { p in
            let (sx, sy) = img.toSource(p.x, p.y)
            return Vec2(sx, sy)
        }, failure: nil)
    }

    /// Andrew's monotone chain; counter-clockwise in a y-down image appears clockwise on screen.
    static func convexHull(_ pts: [Vec2]) -> [Vec2] {
        let p = pts.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        guard p.count >= 3 else { return p }
        func cross(_ o: Vec2, _ a: Vec2, _ b: Vec2) -> Double { (a - o).cross(b - o) }
        var lower: [Vec2] = [], upper: [Vec2] = []
        for q in p {
            while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], q) <= 0 { lower.removeLast() }
            lower.append(q)
        }
        for q in p.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], q) <= 0 { upper.removeLast() }
            upper.append(q)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }

    /// Group consecutive hull edges with similar direction; the 4 longest groups are the table sides
    /// (short groups are corners cut by pockets). Intersect neighbouring sides.
    static func sidesQuad(_ hull: [Vec2], angleTol: Double = 8 * .pi / 180) -> [Vec2]? {
        let n = hull.count
        guard n >= 4 else { return nil }
        struct Group { var pts: [Vec2]; var length: Double; var dir: Vec2 }
        var edges: [(a: Vec2, b: Vec2)] = (0..<n).map { (hull[$0], hull[($0 + 1) % n]) }
        // Start at the edge with the largest turn before it, so no group wraps around.
        func ang(_ e: (a: Vec2, b: Vec2)) -> Double { (e.b - e.a).angle }
        func turn(_ i: Int) -> Double {
            let d = abs(ang(edges[i]) - ang(edges[(i + n - 1) % n])).truncatingRemainder(dividingBy: 2 * .pi)
            return min(d, 2 * .pi - d)
        }
        let start = (0..<n).max { turn($0) < turn($1) }!
        edges = Array(edges[start...] + edges[..<start])
        var groups: [Group] = []
        for e in edges {
            let d = e.b - e.a, len = d.length
            guard len > 0 else { continue }
            if var g = groups.last {
                let diff = abs(g.dir.angle - d.angle).truncatingRemainder(dividingBy: 2 * .pi)
                if min(diff, 2 * .pi - diff) < angleTol {
                    g.pts.append(e.b); g.length += len
                    g.dir = (g.pts.last! - g.pts.first!).normalized
                    groups[groups.count - 1] = g
                    continue
                }
            }
            groups.append(Group(pts: [e.a, e.b], length: len, dir: d / len))
        }
        guard groups.count >= 4 else { return nil }
        let keep = groups.indices.sorted { groups[$0].length > groups[$1].length }.prefix(4).sorted()
        let sides = keep.map { groups[$0] }
        var out: [Vec2] = []
        for i in 0..<4 {
            let l1 = sides[(i + 3) % 4], l2 = sides[i]
            let p1 = l1.pts.first!, d1 = l1.dir, p2 = l2.pts.first!, d2 = l2.dir
            let den = d1.cross(d2)
            guard abs(den) > 1e-6 else { return nil }
            let t = (p2 - p1).cross(d2) / den
            out.append(p1 + d1 * t)
        }
        return out
    }

    /// Repeatedly drop the hull vertex whose removal loses the least area.
    static func reduceToQuad(_ hull: [Vec2]) -> [Vec2]? {
        var poly = hull
        while poly.count > 4 {
            var bestI = 0, bestA = Double.infinity
            for i in poly.indices {
                let a = poly[(i + poly.count - 1) % poly.count], b = poly[i], c = poly[(i + 1) % poly.count]
                let area = abs((b - a).cross(c - a)) / 2
                if area < bestA { bestA = area; bestI = i }
            }
            poly.remove(at: bestI)
        }
        return poly.count == 4 ? poly : nil
    }

    /// Fit a line to the boundary points near each quad side (ignoring the corner/pocket thirds),
    /// then intersect neighbouring lines. Recovers corners cut off by pockets.
    static func refineWithLines(_ quad: [Vec2], boundary: [Vec2]) -> [Vec2]? {
        var lines: [(p: Vec2, d: Vec2)] = []
        for i in 0..<4 {
            let a = quad[i], b = quad[(i + 1) % 4]
            let ab = b - a, len = ab.length
            guard len > 4 else { return nil }
            let u = ab / len, n = u.perpendicular
            let near = boundary.filter { q in
                let t = (q - a).dot(u) / len
                return t > 0.15 && t < 0.85 && abs((q - a).dot(n)) < max(3, len * 0.04)
            }
            guard near.count >= 6 else { return nil }
            lines.append(fitLine(near))
        }
        var out: [Vec2] = []
        for i in 0..<4 {
            let l1 = lines[(i + 3) % 4], l2 = lines[i]
            let den = l1.d.cross(l2.d)
            guard abs(den) > 1e-6 else { return nil }
            let t = (l2.p - l1.p).cross(l2.d) / den
            let p = l1.p + l1.d * t
            // Keep refinement only if it stays near the coarse corner.
            guard p.distance(to: quad[i]) < 0.25 * (quad[(i + 1) % 4] - quad[i]).length else { return nil }
            out.append(p)
        }
        return out
    }

    static func fitLine(_ pts: [Vec2]) -> (p: Vec2, d: Vec2) {
        let c = pts.reduce(Vec2.zero, +) / Double(pts.count)
        var sxx = 0.0, sxy = 0.0, syy = 0.0
        for q in pts { let d = q - c; sxx += d.x * d.x; sxy += d.x * d.y; syy += d.y * d.y }
        let theta = 0.5 * atan2(2 * sxy, sxx - syy)
        return (c, Vec2(cos(theta), sin(theta)))
    }
}

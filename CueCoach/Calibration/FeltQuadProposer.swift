import Foundation
import Geometry

/// Auto calibration proposal: find the cloth (dominant saturated hue around the image centre),
/// take its largest connected region, and fit a quadrilateral to its outline.
/// Returns the 4 corners of the felt boundary (cushion tops included) in source-image pixels.
enum FeltQuadProposer {
    static func propose(_ full: PixelImage) -> [Vec2]? {
        let k = max(1, full.width / 320)
        let img = full.decimated(by: k)
        let w = img.width, h = img.height
        guard w > 16, h > 16 else { return nil }

        // 1. Dominant hue in the central region.
        var hist = [Double](repeating: 0, count: 72)
        for y in (h * 3 / 10)..<(h * 7 / 10) {
            for x in (w * 3 / 10)..<(w * 7 / 10) {
                let p = img.pixel(x, y)
                let c = ColorMath.hsv(p.0, p.1, p.2)
                if c.s > 0.22 && c.v > 0.12 { hist[min(71, Int(c.h / 5))] += c.s }
            }
        }
        guard let peak = hist.indices.max(by: { hist[$0] < hist[$1] }), hist[peak] > 0 else { return nil }
        // Refine hue as the weighted mean of the peak ±2 bins.
        var hx = 0.0, hy = 0.0
        for d in -2...2 {
            let b = (peak + d + 72) % 72, a = (Double(b) * 5 + 2.5) * .pi / 180
            hx += hist[b] * cos(a); hy += hist[b] * sin(a)
        }
        var feltHue = atan2(hy, hx) * 180 / .pi
        if feltHue < 0 { feltHue += 360 }

        // 2. Felt mask.
        var mask = [Bool](repeating: false, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let p = img.pixel(x, y)
                let c = ColorMath.hsv(p.0, p.1, p.2)
                mask[y * w + x] = c.s > 0.18 && c.v > 0.1 && ColorMath.hueDistance(c.h, feltHue) < 20
            }
        }

        // 3. Largest 4-connected component.
        var label = [Int32](repeating: 0, count: w * h)
        var best = (id: Int32(0), size: 0)
        var next: Int32 = 1
        var stack: [Int] = []
        for i in 0..<(w * h) where mask[i] && label[i] == 0 {
            var size = 0
            stack.append(i); label[i] = next
            while let j = stack.popLast() {
                size += 1
                let x = j % w, y = j / w
                for n in [x > 0 ? j - 1 : -1, x < w - 1 ? j + 1 : -1, y > 0 ? j - w : -1, y < h - 1 ? j + w : -1]
                where n >= 0 && mask[n] && label[n] == 0 {
                    label[n] = next; stack.append(n)
                }
            }
            if size > best.size { best = (next, size) }
            next += 1
        }
        guard best.size > w * h / 20 else { return nil }

        // 4. Boundary samples: extreme pixels per row and per column.
        var boundary: [Vec2] = []
        for y in 0..<h {
            var lo = -1, hi = -1
            for x in 0..<w where label[y * w + x] == best.id { if lo < 0 { lo = x }; hi = x }
            if lo >= 0 { boundary.append(Vec2(Double(lo), Double(y))); boundary.append(Vec2(Double(hi), Double(y))) }
        }
        for x in 0..<w {
            var lo = -1, hi = -1
            for y in 0..<h where label[y * w + x] == best.id { if lo < 0 { lo = y }; hi = y }
            if lo >= 0 { boundary.append(Vec2(Double(x), Double(lo))); boundary.append(Vec2(Double(x), Double(hi))) }
        }
        let hull = convexHull(boundary)
        guard hull.count >= 4 else { return nil }
        guard var quad = reduceToQuad(hull) else { return nil }
        quad = refineWithLines(quad, boundary: boundary) ?? quad
        return quad.map { p in
            let (sx, sy) = img.toSource(p.x, p.y)
            return Vec2(sx, sy)
        }
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

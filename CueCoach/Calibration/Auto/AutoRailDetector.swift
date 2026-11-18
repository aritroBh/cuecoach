import Foundation
import simd

/// One rail's outer felt boundary (felt → wood) in the image.
struct AutoRailEdge: Sendable {
    var line: AutoLine
    /// Sub-pixel edge samples on the line (RANSAC inliers).
    var points: [AutoP2]
    var attempted: Int
    var rms: Double
}

/// Coarse quad from the cloth mask, then sub-pixel rail lines from colour profiles across the boundary.
enum AutoRailDetector {
    /// Four coarse rail lines (consecutive around the quad) from the mask's outer boundary.
    /// `accept(quad)` vets a candidate quad of image corners (e.g. "is it a 2:1 rectangle on the table plane?").
    /// Among the hull's longest straight runs, the 4 (in hull order) with the most total length whose quad is
    /// accepted win; an occluder's silhouette on the hull is then rejected for not being a rail.
    static func coarseLines(boundary pts: [AutoP2], stride s: Int, rng: inout AutoRandom,
                            accept: (([AutoP2]) -> Bool)? = nil) -> [AutoLine]? {
        guard pts.count >= 40 else { return nil }
        // The hull bridges inward intrusions (people, glare, cues), so its long sides lie on the rails.
        let hull = AutoPolygon.convexHull(pts)
        guard let groups = AutoPolygon.sideGroups(hull, maxGroups: 7), groups.count >= 4 else { return nil }
        var sides = Array(groups.indices.sorted { simd_length(groups[$0].1 - groups[$0].0) > simd_length(groups[$1].1 - groups[$1].0) }
            .prefix(4).sorted().map { groups[$0] })
        if let accept, groups.count > 4 {
            var best: (score: Double, sides: [(AutoP2, AutoP2)])?
            let n = groups.count
            for i in 0..<n { for j in (i + 1)..<n { for k in (j + 1)..<n { for l in (k + 1)..<n {
                let g = [groups[i], groups[j], groups[k], groups[l]]
                let ls = g.compactMap { AutoLine(through: $0.0, $0.1) }
                guard ls.count == 4, let q = corners(ls) else { continue }
                let score = g.reduce(0.0) { $0 + simd_length($1.1 - $1.0) }
                if score > (best?.score ?? 0), accept(q) { best = (score, g) }
            } } } }
            // No physically plausible quad among the hull runs (e.g. an occluder's outline): reject the frame.
            guard let b = best else { return nil }
            sides = b.sides
        } else if let accept {
            let ls = sides.compactMap { AutoLine(through: $0.0, $0.1) }
            guard ls.count == 4, let q = corners(ls), accept(q) else { return nil }
        }
        var lines: [AutoLine] = []
        let tol = 1.6 * Double(s)
        for (a, b) in sides {
            guard let l0 = AutoLine(through: a, b) else { return nil }
            let dir = b - a, len = simd_length(dir)
            guard len > 8 * Double(s) else { return nil }
            let u = dir / len
            var near: [AutoP2] = []
            for p in pts {
                let t = simd_dot(p - a, u) / len
                if t > 0.08 && t < 0.92 && abs(l0.distance(p)) < tol { near.append(p) }
            }
            guard let r = AutoRansac.line(near, tolerance: Double(s), rng: &rng) else { return nil }
            lines.append(r.line)
        }
        return lines
    }

    static func corners(_ lines: [AutoLine]) -> [AutoP2]? {
        guard lines.count == 4 else { return nil }
        var out: [AutoP2] = []
        for i in 0..<4 {
            guard let p = lines[(i + 3) % 4].intersect(lines[i]) else { return nil }
            out.append(p)
        }
        return out
    }

    /// Sub-pixel refinement. For samples along each rail, read a colour profile across the line,
    /// estimate the inner (cloth) and outer colours from its ends, project every sample onto the
    /// inner–outer colour axis (linear in edge coverage) and take the 0.5 crossing.
    /// `corners[i]` starts rail `i`. `radius` = half profile length (px).
    static func refine(_ img: AutoRGBImage, model: AutoClothModel, corners q: [AutoP2], radius: Double,
                       rng: inout AutoRandom) -> [AutoRailEdge]? {
        guard q.count == 4 else { return nil }
        let centroid = (q[0] + q[1] + q[2] + q[3]) / 4
        var edges: [AutoRailEdge] = []
        for i in 0..<4 {
            let a = q[i], b = q[(i + 1) % 4]
            let d = b - a, len = simd_length(d)
            guard len > 20 else { return nil }
            let u = d / len
            var nrm = AutoP2(-u.y, u.x)
            if simd_dot(nrm, (a + b) / 2 - centroid) < 0 { nrm = -nrm }  // outward
            guard let e = refineSegment(img, model: model, from: a, to: b, outward: nrm, radius: radius, rng: &rng) else { return nil }
            edges.append(e)
        }
        return edges
    }

    /// Sub-pixel felt → wood edge along one rail segment `a`→`b`; `outward` points from the cloth to the wood.
    static func refineSegment(_ img: AutoRGBImage, model: AutoClothModel, from a: AutoP2, to b: AutoP2, outward nrm: AutoP2,
                              radius: Double, rng: inout AutoRandom) -> AutoRailEdge? {
        let w = img.width, h = img.height
        let ds = 0.5
        let nS = Int((2 * radius / ds).rounded()) + 1
        var prof = [Float](repeating: 0, count: nS * 3)
        let d = b - a, len = simd_length(d)
        guard len > 20 else { return nil }
        let u = d / len
        do {
            let step = max(2.0, len / 160)
            var samples: [AutoP2] = []
            var attempted = 0
            var t = 0.06 * len
            img.rgb.withUnsafeBufferPointer { px in
                @inline(__always) func bilinear(_ x: Double, _ y: Double, _ o: Int) -> Bool {
                    guard x >= 0, y >= 0, x < Double(w - 1), y < Double(h - 1) else { return false }
                    let x0 = Int(x), y0 = Int(y)
                    let fx = Float(x - Double(x0)), fy = Float(y - Double(y0))
                    let i00 = (y0 * w + x0) * 3, i10 = i00 + 3, i01 = i00 + w * 3, i11 = i01 + 3
                    for c in 0..<3 {
                        let top = Float(px[i00 + c]) * (1 - fx) + Float(px[i10 + c]) * fx
                        let bot = Float(px[i01 + c]) * (1 - fx) + Float(px[i11 + c]) * fx
                        prof[o + c] = top * (1 - fy) + bot * fy
                    }
                    return true
                }
                while t < 0.94 * len {
                    defer { t += step }
                    attempted += 1
                    let base = a + u * t
                    var ok = true
                    for k in 0..<nS {
                        let s = -radius + Double(k) * ds
                        let p = base + nrm * s
                        if !bilinear(p.x, p.y, k * 3) { ok = false; break }
                    }
                    guard ok else { continue }
                    let quarter = max(2, nS / 5)
                    var A = SIMD3<Float>(0, 0, 0), B = SIMD3<Float>(0, 0, 0)
                    for k in 0..<quarter {
                        A += SIMD3(prof[k * 3], prof[k * 3 + 1], prof[k * 3 + 2])
                        let j = nS - 1 - k
                        B += SIMD3(prof[j * 3], prof[j * 3 + 1], prof[j * 3 + 2])
                    }
                    A /= Float(quarter); B /= Float(quarter)
                    guard model.isCloth(A.x, A.y, A.z), !model.isCloth(B.x, B.y, B.z) else { continue }
                    let ab = A - B
                    let ab2 = simd_dot(ab, ab)
                    // Contrast relative to the cloth's brightness: 25 levels in a lit room, less in a dim one.
                    let lum = (A.x + A.y + A.z) / 3
                    let minContrast = max(8, min(25, 0.35 * lum))
                    guard ab2 > minContrast * minContrast else { continue }
                    // Last sample (scanning outward) still on the cloth side.
                    var last = -1
                    var prev: Float = 1
                    var crossings = 0
                    for k in 0..<nS {
                        let c = SIMD3(prof[k * 3], prof[k * 3 + 1], prof[k * 3 + 2])
                        let v = simd_dot(c - B, ab) / ab2
                        if v >= 0.5 { last = k }
                        if (prev >= 0.5) != (v >= 0.5) { crossings += 1 }
                        prev = v
                    }
                    guard last >= 0, last < nS - 1, crossings <= 3 else { continue }
                    let c0 = SIMD3(prof[last * 3], prof[last * 3 + 1], prof[last * 3 + 2])
                    let c1 = SIMD3(prof[(last + 1) * 3], prof[(last + 1) * 3 + 1], prof[(last + 1) * 3 + 2])
                    let v0 = Double(simd_dot(c0 - B, ab) / ab2), v1 = Double(simd_dot(c1 - B, ab) / ab2)
                    let f = v0 - v1 > 1e-6 ? (v0 - 0.5) / (v0 - v1) : 0.5
                    let s = -radius + (Double(last) + f) * ds
                    samples.append(base + nrm * s)
                }
            }
            guard let r = AutoRansac.line(samples, tolerance: 1.2, rng: &rng),
                  r.inliers.count >= 12, Double(r.inliers.count) >= 0.25 * Double(attempted) else { return nil }
            return AutoRailEdge(line: r.line, points: r.inliers.map { samples[$0] }, attempted: attempted, rms: r.rms)
        }
    }
}

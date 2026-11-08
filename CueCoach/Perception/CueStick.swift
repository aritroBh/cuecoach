import Foundation
import Geometry

/// The player's cue as seen this frame, in table coordinates.
struct CueObservation: Sendable, Equatable {
    /// Unit direction the cue points (from the butt toward the cue ball).
    var direction: Vec2
    /// Distance from the cue-ball centre back to the nearest point of the stick (m).
    var tipDistance: Double
    var confidence: Double
}

/// Finds the cue stick near the cue ball: non-felt pixels in an annulus around the cue ball
/// (other balls masked out) → RANSAC line in table coordinates that passes by the cue ball.
/// Wrists from Vision body pose (source pixels) break ties toward the shooter's line.
struct CueLineDetector: Sendable {
    var inner = 2.0          // × ball radius
    var outer = 0.75         // m
    var inlierBand = 0.011   // m
    var passBy = 1.6         // × ball radius: the line must pass this close to the cue-ball centre
    var minExtent = 0.12     // m of stick visible
    var iterations = 160
    /// A cue addressing the ball has its tip this close (backswing included); farther lines are table structure.
    var maxTipDistance = 0.22
    var minConfidence = 0.35

    func detect(in img: PixelImage, geometry geo: FrameGeometry, cue: Vec2, others: [Vec2],
                wrists: [Vec2] = []) -> CueObservation? {
        let R = TableSpec.ballRadius, spec = geo.spec
        let inv = geo.ballInverse
        // Pixel window: project the annulus' bounding square.
        let corners = [Vec2(-outer, -outer), Vec2(outer, -outer), Vec2(outer, outer), Vec2(-outer, outer)]
            .compactMap { geo.ball.apply(cue + $0) }
        guard corners.count == 4 else { return nil }
        let xs = corners.map { img.toWorking($0.x, $0.y).0 }, ys = corners.map { img.toWorking($0.x, $0.y).1 }
        let x0 = max(0, Int(xs.min()!)), x1 = min(img.width - 1, Int(xs.max()!))
        let y0 = max(0, Int(ys.min()!)), y1 = min(img.height - 1, Int(ys.max()!))
        guard x0 < x1, y0 < y1 else { return nil }

        // Felt reference: median of in-annulus pixels.
        var samples: [(Vec2, (UInt8, UInt8, UInt8))] = []
        samples.reserveCapacity((x1 - x0) * (y1 - y0) / 2)
        for y in y0...y1 {
            for x in x0...x1 {
                let (sx, sy) = img.toSource(Double(x), Double(y))
                guard let t = inv.apply(Vec2(sx, sy)) else { continue }
                let d = t.distance(to: cue)
                guard d > inner * R, d < outer,
                      t.x > -0.01, t.y > -0.01, t.x < spec.length + 0.01, t.y < spec.width + 0.01,
                      !others.contains(where: { $0.distance(to: t) < 1.4 * R }) else { continue }
                samples.append((t, img.pixel(x, y)))
            }
        }
        guard samples.count > 50 else { return nil }
        func med(_ k: Int) -> Double {
            var h = [Int](repeating: 0, count: 256)
            for s in samples { h[Int(k == 0 ? s.1.0 : k == 1 ? s.1.1 : s.1.2)] += 1 }
            var acc = 0
            for (v, c) in h.enumerated() { acc += c; if acc * 2 >= samples.count { return Double(v) } }
            return 0
        }
        let fr = med(0), fg = med(1), fb = med(2)
        let fsum = max(30, fr + fg + fb)
        var pts: [Vec2] = samples.compactMap { s in
            let r = Double(s.1.0), g = Double(s.1.1), b = Double(s.1.2), sum = r + g + b
            let k = sum / fsum
            let chroma = sum > 60 ? hypot(r / sum - fr / fsum, g / sum - fg / fsum) : 0
            return (k > 1.45 || k < 0.45 || chroma > 0.07) ? s.0 : nil
        }
        guard pts.count >= 20 else { return nil }
        if pts.count > 1500 { let k = pts.count / 1500 + 1; pts = stride(from: 0, to: pts.count, by: k).map { pts[$0] } }
        let wristTable = wrists.compactMap { inv.apply($0) }

        // RANSAC: lines that pass by the cue ball.
        var rng = SystemRandomNumberGenerator()
        var best: (score: Double, u: Vec2, inl: [Double])?
        for _ in 0..<iterations {
            let a = pts[Int.random(in: 0..<pts.count, using: &rng)], b = pts[Int.random(in: 0..<pts.count, using: &rng)]
            let d = b - a
            guard d.length > 0.04 else { continue }
            let u = d.normalized, n = u.perpendicular
            guard abs((cue - a).dot(n)) < passBy * R else { continue }
            var ts: [Double] = []
            for p in pts where abs((p - a).dot(n)) < inlierBand { ts.append((p - cue).dot(u)) }
            guard ts.count >= 15 else { continue }
            // Stick lies on one side of the cue ball.
            let neg = ts.filter { $0 < 0 }, pos = ts.filter { $0 > 0 }
            let side = neg.count >= pos.count ? neg : pos
            guard let lo = side.min(), let hi = side.max(), hi - lo >= minExtent else { continue }
            var score = Double(side.count)
            if !wristTable.isEmpty {
                let near = wristTable.contains { w in abs((w - a).dot(n)) < 0.15 }
                score *= near ? 1.5 : 0.8
            }
            if best == nil || score > best!.score { best = (score, neg.count >= pos.count ? u : -u, side) }
        }
        guard let best else { return nil }
        // `best.u` is oriented so the stick lies at negative t: it points from the stick toward the cue ball.
        let tip = best.inl.map(abs).min() ?? 0
        let expected = max(1, (best.inl.map(abs).max()! - tip) / 0.004)  // ~1 inlier per 4 mm of stick
        let confidence = min(1, Double(best.inl.count) / expected)
        guard tip <= maxTipDistance, confidence >= minConfidence else { return nil }
        return CueObservation(direction: best.u, tipDistance: tip, confidence: confidence)
    }
}

/// Smooths the cue direction (circular EMA) and detects the stroke: the tip closing on the cue ball fast.
struct CueAimTracker: Sendable {
    var smoothing = 0.35
    var strokeSpeed = 0.35      // m/s toward the cue ball
    var holdSeconds = 1.0

    private(set) var direction: Vec2?
    private(set) var lastSeen: Double?
    private(set) var lastStroke: Double?
    private var lastTip: (d: Double, t: Double)?

    /// Feed one observation (or nil). Returns true on the frame a stroke is detected.
    mutating func update(_ o: CueObservation?, at t: Double) -> Bool {
        guard let o, o.confidence > 0.2 else {
            if let s = lastSeen, t - s > holdSeconds { direction = nil; lastTip = nil }
            return false
        }
        lastSeen = t
        if let d = direction {
            let a = atan2(d.y, d.x), b = atan2(o.direction.y, o.direction.x)
            var diff = b - a
            while diff > .pi { diff -= 2 * .pi }
            while diff < -.pi { diff += 2 * .pi }
            let na = a + smoothing * diff
            direction = Vec2(cos(na), sin(na))
        } else {
            direction = o.direction
        }
        var stroke = false
        if let p = lastTip, t > p.t {
            let closing = (p.d - o.tipDistance) / (t - p.t)
            if closing > strokeSpeed && o.tipDistance < 0.12 && (lastStroke.map { t - $0 > 0.8 } ?? true) {
                stroke = true
                lastStroke = t
            }
        }
        lastTip = (o.tipDistance, t)
        return stroke
    }

    /// Cue seen recently (so shot starts should be preceded by a stroke).
    func cueVisible(at t: Double) -> Bool { lastSeen.map { t - $0 < holdSeconds } ?? false }
    func strokeRecent(at t: Double, within w: Double = 0.7) -> Bool { lastStroke.map { t - $0 <= w } ?? false }
}

/// The player's live aim: the cue-ball ray to the first ball it would hit (ghost ball), or the cushion.
struct LiveAimTrace: Sendable, Equatable {
    var cue: Vec2
    var end: Vec2
    var hitIndex: Int?
    var ghost: Vec2?
    /// Object-ball departure direction (along the line of centres) when a ball is hit.
    var objectDirection: Vec2?

    static func trace(cue: Vec2, direction d: Vec2, balls: [Vec2], spec: TableSpec) -> LiveAimTrace {
        let R = TableSpec.ballRadius, u = d.normalized
        var bestT = Double.infinity, bestI: Int?
        for (i, b) in balls.enumerated() {
            // |cue + u t − b| = 2R
            let f = cue - b
            let bq = f.dot(u), c = f.lengthSquared - 4 * R * R
            // Frozen to (or, through detector noise, overlapping) the cue ball and ahead of it: hit at once.
            if c <= 0 {
                if bq < 0 && 0 < bestT { bestT = 0; bestI = i }
                continue
            }
            let disc = bq * bq - c
            guard disc >= 0 else { continue }
            let t = -bq - disc.squareRoot()
            if t >= 0 && t < bestT { bestT = t; bestI = i }
        }
        let wall = AimPlanner.clipToTable(from: cue, dir: u, maxLength: 4, spec: spec)
        if let i = bestI, bestT < cue.distance(to: wall) || bestT == 0 {
            let ghost = cue + u * bestT
            return LiveAimTrace(cue: cue, end: ghost, hitIndex: i, ghost: ghost,
                                objectDirection: (balls[i] - ghost).normalized)
        }
        return LiveAimTrace(cue: cue, end: wall, hitIndex: nil, ghost: nil, objectDirection: nil)
    }

    /// 0…1: how close the live aim is to the suggested ghost-ball line (1 = on it). Drives the visual merge.
    static func convergence(live: Vec2, cue: Vec2, suggestedGhost: Vec2, tolerance: Double = 6 * .pi / 180) -> Double {
        let s = (suggestedGhost - cue).normalized
        let ang = acos(max(-1, min(1, live.normalized.dot(s))))
        return max(0, 1 - ang / tolerance)
    }
}

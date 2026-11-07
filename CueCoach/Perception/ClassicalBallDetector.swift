import Foundation
import Geometry

/// v0 ball detector: no ML. Inside the calibrated cloth, mark pixels that differ from the felt,
/// find disc-shaped peaks at the ball size predicted by the homography, then classify by colour.
struct ClassicalBallDetector: BallDetector {
    var minCoverage = 0.72
    var minDiscFill = 0.68

    func detect(in img: PixelImage, geometry geo: FrameGeometry) -> [BallDetection] {
        let w = img.width, h = img.height
        guard w > 8, h > 8 else { return [] }
        let spec = geo.spec, R = TableSpec.ballRadius
        let clothInv = geo.clothInverse, ballInv = geo.ballInverse
        let centreW = geo.cloth.w(Vec2(spec.length / 2, spec.width / 2))
        guard centreW != 0 else { return [] }
        let sgn: Double = centreW > 0 ? 1 : -1

        // 1. Region: working pixels whose cloth-plane point lies on the table (plus a ball radius).
        var region = [UInt8](repeating: 0, count: w * h)
        var regionCount = 0
        let (x0, x1, y0, y1) = bounds(geo: geo, img: img)
        if x0 <= x1 && y0 <= y1 {
            for y in y0...y1 {
                for x in x0...x1 {
                    let (sx, sy) = img.toSource(Double(x), Double(y))
                    guard let t = clothInv.apply(Vec2(sx, sy)), geo.cloth.w(t) * sgn > 0 else { continue }
                    if t.x >= -R && t.x <= spec.length + R && t.y >= -R && t.y <= spec.width + R {
                        region[y * w + x] = 1; regionCount += 1
                    }
                }
            }
        }
        guard regionCount > 100 else { return [] }

        // 2. Felt reference: per-channel median of region pixels.
        let felt = medianColor(img, region: region, step: 3)
        let feltSum = max(30, Double(Int(felt.0) + Int(felt.1) + Int(felt.2)))
        let fr = Double(felt.0) / feltSum, fg = Double(felt.1) / feltSum
        let feltHSV = ColorMath.hsv(felt.0, felt.1, felt.2)

        // 3. Ball mask.
        var mask = [UInt8](repeating: 0, count: w * h)
        img.rgb.withUnsafeBufferPointer { px in
            for i in 0..<(w * h) where region[i] != 0 {
                let r = Double(px[i * 3]), g = Double(px[i * 3 + 1]), b = Double(px[i * 3 + 2])
                let sum = r + g + b
                let k = sum / feltSum
                var ball = k > 1.6 || k < 0.42
                if !ball && sum > 60 {
                    let dr = r / sum - fr, dg = g / sum - fg
                    ball = (dr * dr + dg * dg).squareRoot() > 0.07
                }
                if ball { mask[i] = 1 }
            }
        }

        // 4. Summed-area table.
        let sat = SummedArea(mask: mask, width: w, height: h)

        // 5. Expected ball radius (working px) on a coarse grid.
        let cell = 8
        let gw = (w + cell - 1) / cell, gh = (h + cell - 1) / cell
        var rgrid = [Double](repeating: 0, count: gw * gh)
        for gy in 0..<gh {
            for gx in 0..<gw {
                let (sx, sy) = img.toSource(Double(gx * cell + cell / 2), Double(gy * cell + cell / 2))
                guard let t = ballInv.apply(Vec2(sx, sy)), geo.ball.w(t) * sgn > 0 else { continue }
                rgrid[gy * gw + gx] = R * geo.ball.maxScale(at: t) / img.scale
            }
        }
        func radius(_ x: Int, _ y: Int) -> Double { rgrid[(y / cell) * gw + (x / cell)] }

        // 6. Candidates.
        struct Cand { var x: Int; var y: Int; var score: Double; var r: Double }
        var cands: [Cand] = []
        for y in 0..<h {
            for x in 0..<w where mask[y * w + x] != 0 {
                let r = radius(x, y)
                guard r >= 1.5 else { continue }
                let a = max(1, Int((0.7 * r).rounded()))
                let c = sat.coverage(x - a, y - a, x + a, y + a)
                guard c >= minCoverage else { continue }
                let b = max(a + 1, Int((0.9 * r).rounded()))
                let c2 = sat.coverage(x - b, y - b, x + b, y + b)
                cands.append(Cand(x: x, y: y, score: c + c2, r: r))
            }
        }
        cands.sort { $0.score > $1.score }

        // 7. Greedy NMS with centroid refinement and shape checks.
        var out: [BallDetection] = []
        var accepted: [(Double, Double, Double)] = []
        for cnd in cands {
            if accepted.contains(where: { hypot($0.0 - Double(cnd.x), $0.1 - Double(cnd.y)) < 1.2 * $0.2 }) { continue }
            var cx = Double(cnd.x), cy = Double(cnd.y)
            let r = cnd.r
            for _ in 0..<3 { (cx, cy) = centroid(mask: mask, w: w, h: h, cx: cx, cy: cy, r: r) }
            if accepted.contains(where: { hypot($0.0 - cx, $0.1 - cy) < 1.4 * max(r, $0.2) }) { continue }
            let fill = discFill(mask: mask, w: w, h: h, cx: cx, cy: cy, r: 0.85 * r)
            guard fill >= minDiscFill else { continue }
            guard ringGaps(mask: mask, region: region, w: w, h: h, cx: cx, cy: cy, r: 1.4 * r) >= 2 else { continue }
            let (sx, sy) = img.toSource(cx, cy)
            guard let t = ballInv.apply(Vec2(sx, sy)) else { continue }
            guard t.x >= 0.6 * R, t.x <= spec.length - 0.6 * R, t.y >= 0.6 * R, t.y <= spec.width - 0.6 * R
            else { continue }
            if spec.pockets.contains(where: { t.distance(to: spec.pocketCenter($0)) < ($0.isSide ? 0.045 : 0.055) }) {
                continue
            }
            accepted.append((cx, cy, r))
            let cls = classify(img, cx: cx, cy: cy, r: 0.8 * r, feltHSV: feltHSV)
            let conf = min(1, max(0, (fill - 0.6) / 0.4)) * (cls.kind == .unknown ? 0.6 : 1)
            out.append(BallDetection(imagePoint: Vec2(sx, sy), tablePoint: t, radiusPx: r * img.scale,
                                     confidence: conf, kind: cls.kind, tentativeNumber: cls.number))
            if out.count >= 24 { break }
        }
        return out
    }

    // MARK: - Helpers

    private func bounds(geo: FrameGeometry, img: PixelImage) -> (Int, Int, Int, Int) {
        let R = TableSpec.ballRadius, s = geo.spec
        let pts = [Vec2(-R, -R), Vec2(-R, s.width + R), Vec2(s.length + R, s.width + R), Vec2(s.length + R, -R)]
        let centreW = geo.cloth.w(Vec2(s.length / 2, s.width / 2))
        var xs: [Double] = [], ys: [Double] = []
        for p in pts {
            guard geo.cloth.w(p) * centreW > 0, let q = geo.cloth.apply(p) else {
                return (0, img.width - 1, 0, img.height - 1)  // corner behind camera: scan everything
            }
            let (wx, wy) = img.toWorking(q.x, q.y)
            xs.append(wx); ys.append(wy)
        }
        let x0 = max(0, Int(xs.min()!.rounded(.down))), x1 = min(img.width - 1, Int(xs.max()!.rounded(.up)))
        let y0 = max(0, Int(ys.min()!.rounded(.down))), y1 = min(img.height - 1, Int(ys.max()!.rounded(.up)))
        return (x0, x1, y0, y1)
    }

    private func medianColor(_ img: PixelImage, region: [UInt8], step: Int) -> (UInt8, UInt8, UInt8) {
        var hr = [Int](repeating: 0, count: 256), hg = hr, hb = hr
        var n = 0
        var i = 0
        while i < img.width * img.height {
            if region[i] != 0 {
                hr[Int(img.rgb[i * 3])] += 1; hg[Int(img.rgb[i * 3 + 1])] += 1; hb[Int(img.rgb[i * 3 + 2])] += 1
                n += 1
            }
            i += step
        }
        func med(_ hist: [Int]) -> UInt8 {
            var acc = 0
            for (v, c) in hist.enumerated() { acc += c; if acc * 2 >= n { return UInt8(v) } }
            return 0
        }
        return (med(hr), med(hg), med(hb))
    }

    private func centroid(mask: [UInt8], w: Int, h: Int, cx: Double, cy: Double, r: Double) -> (Double, Double) {
        var sx = 0.0, sy = 0.0, n = 0.0
        let ri = Int(r.rounded(.up)), r2 = r * r
        let ix = Int(cx.rounded()), iy = Int(cy.rounded())
        for y in max(0, iy - ri)...min(h - 1, iy + ri) {
            for x in max(0, ix - ri)...min(w - 1, ix + ri) where mask[y * w + x] != 0 {
                let dx = Double(x) - cx, dy = Double(y) - cy
                if dx * dx + dy * dy <= r2 { sx += Double(x); sy += Double(y); n += 1 }
            }
        }
        return n > 0 ? (sx / n, sy / n) : (cx, cy)
    }

    private func discFill(mask: [UInt8], w: Int, h: Int, cx: Double, cy: Double, r: Double) -> Double {
        var on = 0.0, all = 0.0
        let ri = Int(r.rounded(.up)), r2 = r * r
        let ix = Int(cx.rounded()), iy = Int(cy.rounded())
        for y in (iy - ri)...(iy + ri) {
            for x in (ix - ri)...(ix + ri) {
                let dx = Double(x) - cx, dy = Double(y) - cy
                guard dx * dx + dy * dy <= r2 else { continue }
                all += 1
                if x >= 0, y >= 0, x < w, y < h, mask[y * w + x] != 0 { on += 1 }
            }
        }
        return all > 0 ? on / all : 0
    }

    /// Directions (of 24) where the ring at radius r is not ball: isolated balls have many, a hand has none.
    private func ringGaps(mask: [UInt8], region: [UInt8], w: Int, h: Int, cx: Double, cy: Double, r: Double) -> Int {
        var gaps = 0
        for k in 0..<24 {
            let a = Double(k) * .pi / 12
            let x = Int((cx + r * cos(a)).rounded()), y = Int((cy + r * sin(a)).rounded())
            if x < 0 || y < 0 || x >= w || y >= h || region[y * w + x] == 0 || mask[y * w + x] == 0 { gaps += 1 }
        }
        return gaps
    }

    private func classify(_ img: PixelImage, cx: Double, cy: Double, r: Double,
                          feltHSV: (h: Double, s: Double, v: Double)) -> (kind: BallKind, number: Int?) {
        var white = 0.0, black = 0.0, colored = 0.0, all = 0.0
        var hx = 0.0, hy = 0.0, vsum = 0.0
        let ri = Int(r.rounded(.up)), r2 = r * r
        let ix = Int(cx.rounded()), iy = Int(cy.rounded())
        let whiteV = max(0.45, feltHSV.v * 1.25), blackV = max(0.18, feltHSV.v * 0.45)
        for y in max(0, iy - ri)...min(img.height - 1, iy + ri) {
            for x in max(0, ix - ri)...min(img.width - 1, ix + ri) {
                let dx = Double(x) - cx, dy = Double(y) - cy
                guard dx * dx + dy * dy <= r2 else { continue }
                let p = img.pixel(x, y)
                let c = ColorMath.hsv(p.0, p.1, p.2)
                all += 1
                if c.s < 0.3 && c.v > whiteV { white += 1 }
                else if c.v < blackV { black += 1 }
                else if c.s >= 0.35 && c.v >= 0.2 && ColorMath.hueDistance(c.h, feltHSV.h) > 20 {
                    colored += 1
                    hx += cos(c.h * .pi / 180); hy += sin(c.h * .pi / 180); vsum += c.v
                }
            }
        }
        guard all > 0 else { return (.unknown, nil) }
        let fw = white / all, fb = black / all, fc = colored / all
        if fw > 0.6 { return (.cue, 0) }
        if fb > 0.45 { return (.eight, 8) }
        guard fc >= 0.15 else { return (.unknown, nil) }
        var hue = atan2(hy, hx) * 180 / .pi
        if hue < 0 { hue += 360 }
        let v = vsum / colored
        let stripe = fw >= 0.18
        let base = BallColor.number(hue: hue, value: v)
        return (stripe ? .stripe : .solid, base.map { stripe ? $0 + 8 : $0 })
    }
}

/// Standard ball colour code: 1 yellow, 2 blue, 3 red, 4 purple, 5 orange, 6 green, 7 maroon (+8 stripes).
enum BallColor {
    static func number(hue: Double, value: Double) -> Int? {
        switch hue {
        case 340..<360, 0..<12: value < 0.45 ? 7 : 3
        case 12..<38: value < 0.45 ? 7 : 5
        case 38..<70: 1
        case 70..<165: 6
        case 165..<255: 2
        case 255..<340: 4
        default: nil
        }
    }
}

/// Integral image over a 0/1 mask.
struct SummedArea {
    let w: Int, h: Int
    private var s: [Int32]

    init(mask: [UInt8], width: Int, height: Int) {
        w = width; h = height
        s = [Int32](repeating: 0, count: (width + 1) * (height + 1))
        for y in 0..<height {
            var row: Int32 = 0
            for x in 0..<width {
                row += Int32(mask[y * width + x])
                s[(y + 1) * (width + 1) + x + 1] = s[y * (width + 1) + x + 1] + row
            }
        }
    }

    /// Fraction of set pixels in the inclusive box (clipped; outside counts as unset).
    func coverage(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> Double {
        let area = Double((x1 - x0 + 1) * (y1 - y0 + 1))
        let a = max(0, x0), b = max(0, y0), c = min(w - 1, x1), d = min(h - 1, y1)
        guard a <= c, b <= d else { return 0 }
        let sum = s[(d + 1) * (w + 1) + c + 1] - s[b * (w + 1) + c + 1] - s[(d + 1) * (w + 1) + a] + s[b * (w + 1) + a]
        return Double(sum) / area
    }
}

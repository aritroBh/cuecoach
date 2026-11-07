import Foundation
import simd

/// Per-scene cloth colour model: robust centre + spread of chromaticity (r/S, g/S) and brightness,
/// learned from the image centre (gated to the LiDAR table plane when depth is available).
/// Chromaticity is shading-invariant, so lamp falloff and soft shadows stay "cloth"; glare (neutral),
/// wood, pockets and people do not.
struct AutoClothModel: Sendable {
    var m1: Float, m2: Float, s1: Float, s2: Float
    /// Median brightness (r+g+b)/3.
    var mI: Float
    var maxDistance: Float = 4.0

    @inline(__always) func distance(_ r: Float, _ g: Float, _ b: Float) -> Float {
        let s = r + g + b
        if s < 45 { return 99 }
        let d1 = (r / s - m1) / s1, d2 = (g / s - m2) / s2
        return (d1 * d1 + d2 * d2).squareRoot()
    }

    @inline(__always) func isCloth(_ r: Float, _ g: Float, _ b: Float) -> Bool {
        let i = (r + g + b) / 3
        return i > 0.3 * mI && i < 2.0 * mI && distance(r, g, b) < maxDistance
    }

    /// Learn from coarse-grid samples. `accept(x, y)` (working pixels) gates candidate samples.
    static func learn(_ img: AutoRGBImage, stride s: Int, accept: ((Int, Int) -> Bool)? = nil) -> AutoClothModel? {
        let w = img.width, h = img.height
        var c1: [Float] = [], c2: [Float] = [], ii: [Float] = []
        c1.reserveCapacity(4096); c2.reserveCapacity(4096); ii.reserveCapacity(4096)
        let step = max(1, s / 2) * 2
        img.rgb.withUnsafeBufferPointer { p in
            for y in Swift.stride(from: h * 3 / 10, to: h * 7 / 10, by: step) {
                for x in Swift.stride(from: w * 3 / 10, to: w * 7 / 10, by: step) {
                    if let a = accept, !a(x, y) { continue }
                    let o = (y * w + x) * 3
                    let r = Float(p[o]), g = Float(p[o + 1]), b = Float(p[o + 2])
                    let sum = r + g + b
                    guard sum >= 60 else { continue }
                    c1.append(r / sum); c2.append(g / sum); ii.append(sum / 3)
                }
            }
        }
        guard c1.count >= 40 else { return nil }
        func med(_ v: [Float]) -> Float { let s = v.sorted(); return s[s.count / 2] }
        var m1 = med(c1), m2 = med(c2)
        // Keep the dominant cluster (balls, glare and chalk marks are minorities), then re-estimate.
        func spread(_ v: [Float], _ m: Float) -> Float { max(0.008, 1.4826 * med(v.map { abs($0 - m) })) }
        var s1 = spread(c1, m1), s2 = spread(c2, m2)
        var keep: [Int] = []
        for i in c1.indices {
            let d1 = (c1[i] - m1) / s1, d2 = (c2[i] - m2) / s2
            if d1 * d1 + d2 * d2 < 9 { keep.append(i) }
        }
        guard keep.count >= c1.count / 3 else { return nil }
        let k1 = keep.map { c1[$0] }, k2 = keep.map { c2[$0] }, ki = keep.map { ii[$0] }
        m1 = med(k1); m2 = med(k2)
        s1 = max(0.01, spread(k1, m1)); s2 = max(0.01, spread(k2, m2))
        let mI = med(ki)
        // A grey cloth has no chroma to lock onto; its "model" would match floors and walls.
        let neutral = abs(m1 - 1 / 3) + abs(m2 - 1 / 3)
        guard neutral > 0.04 else { return nil }
        return AutoClothModel(m1: m1, m2: m2, s1: s1, s2: s2, mI: mI)
    }
}

/// Binary mask on a coarse grid (working pixel = grid · stride).
struct AutoMask: Sendable {
    var width: Int
    var height: Int
    var stride: Int
    var bits: [UInt8]
}

enum AutoClothSegmenter {
    /// Cloth mask on a stride-`s` grid. `gate(x, y)` (working pixels) can veto pixels (LiDAR off-plane).
    static func mask(_ img: AutoRGBImage, model: AutoClothModel, stride s: Int,
                     gate: [UInt8]? = nil, gateWidth: Int = 0, gateHeight: Int = 0) -> AutoMask {
        let gw = img.width / s, gh = img.height / s
        var bits = [UInt8](repeating: 0, count: gw * gh)
        let w = img.width
        img.rgb.withUnsafeBufferPointer { p in
            bits.withUnsafeMutableBufferPointer { out in
                for gy in 0..<gh {
                    let y = gy * s
                    let gRow = gate != nil ? (y * gateHeight / img.height) * gateWidth : 0
                    for gx in 0..<gw {
                        let x = gx * s
                        if let g = gate, g[gRow + x * gateWidth / w] == 0 { continue }
                        let o = (y * w + x) * 3
                        if model.isCloth(Float(p[o]), Float(p[o + 1]), Float(p[o + 2])) { out[gy * gw + gx] = 1 }
                    }
                }
            }
        }
        return AutoMask(width: gw, height: gh, stride: s, bits: bits)
    }

    /// 3×3 cross opening (erode, then dilate): removes speckle and thin bridges (cue sticks).
    /// Neighbours outside the image are ignored, so cloth reaching the frame edge stays on the edge
    /// (the "cloth touches frame" check in `boundary` depends on it).
    static func open(_ m: AutoMask) -> AutoMask {
        let w = m.width, h = m.height
        var er = [UInt8](repeating: 0, count: w * h)
        var out = [UInt8](repeating: 0, count: w * h)
        m.bits.withUnsafeBufferPointer { b in
            er.withUnsafeMutableBufferPointer { e in
                for y in 0..<h {
                    for x in 0..<w {
                        let i = y * w + x
                        guard b[i] != 0 else { continue }
                        if x > 0 && b[i - 1] == 0 { continue }
                        if x < w - 1 && b[i + 1] == 0 { continue }
                        if y > 0 && b[i - w] == 0 { continue }
                        if y < h - 1 && b[i + w] == 0 { continue }
                        e[i] = 1
                    }
                }
            }
        }
        er.withUnsafeBufferPointer { e in
            out.withUnsafeMutableBufferPointer { o in
                for y in 0..<h {
                    for x in 0..<w {
                        let i = y * w + x
                        if e[i] != 0 || (x > 0 && e[i - 1] != 0) || (x < w - 1 && e[i + 1] != 0)
                            || (y > 0 && e[i - w] != 0) || (y < h - 1 && e[i + w] != 0) { o[i] = 1 }
                    }
                }
            }
        }
        return AutoMask(width: w, height: h, stride: m.stride, bits: out)
    }

    /// Largest 4-connected component (mask with only that component set), and its pixel count.
    static func largestComponent(_ m: AutoMask) -> (AutoMask, Int) {
        let w = m.width, h = m.height, n = w * h
        var label = [Int32](repeating: 0, count: n)
        var stack = [Int32](); stack.reserveCapacity(n / 4)
        var best: Int32 = 0, bestSize = 0
        var next: Int32 = 1
        m.bits.withUnsafeBufferPointer { b in
            label.withUnsafeMutableBufferPointer { lab in
                for i in 0..<n where b[i] != 0 && lab[i] == 0 {
                    var size = 0
                    lab[i] = next; stack.append(Int32(i))
                    while let jj = stack.popLast() {
                        let j = Int(jj)
                        size += 1
                        let x = j % w
                        if x > 0, b[j - 1] != 0, lab[j - 1] == 0 { lab[j - 1] = next; stack.append(Int32(j - 1)) }
                        if x < w - 1, b[j + 1] != 0, lab[j + 1] == 0 { lab[j + 1] = next; stack.append(Int32(j + 1)) }
                        if j >= w, b[j - w] != 0, lab[j - w] == 0 { lab[j - w] = next; stack.append(Int32(j - w)) }
                        if j < n - w, b[j + w] != 0, lab[j + w] == 0 { lab[j + w] = next; stack.append(Int32(j + w)) }
                    }
                    if size > bestSize { bestSize = size; best = next }
                    next += 1
                }
            }
        }
        var out = [UInt8](repeating: 0, count: n)
        for i in 0..<n where label[i] == best && best != 0 { out[i] = 1 }
        return (AutoMask(width: w, height: h, stride: m.stride, bits: out), bestSize)
    }

    /// Outer boundary pixels (set pixels with an unset 4-neighbour), in working pixels.
    /// Also returns how many component pixels touch the image border.
    static func boundary(_ m: AutoMask) -> (points: [AutoP2], borderTouches: Int) {
        let w = m.width, h = m.height, s = Double(m.stride)
        var pts: [AutoP2] = []
        var border = 0
        m.bits.withUnsafeBufferPointer { b in
            for y in 0..<h {
                for x in 0..<w {
                    let i = y * w + x
                    guard b[i] != 0 else { continue }
                    if x == 0 || y == 0 || x == w - 1 || y == h - 1 { border += 1; continue }
                    if b[i - 1] == 0 || b[i + 1] == 0 || b[i - w] == 0 || b[i + w] == 0 {
                        pts.append(AutoP2(Double(x) * s, Double(y) * s))
                    }
                }
            }
        }
        return (pts, border)
    }
}

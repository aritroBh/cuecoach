import CoreGraphics
import CoreVideo
import Foundation
import Geometry
import simd
@testable import CueCoach

/// Tile-binned ray caster for `VTScene`. Renders the colour image a 1920×1440 ARKit capture would give after
/// FrameTap's stride-2 point sampling (working pixel (x, y) = source pixel (2x, 2y)), plus LiDAR-like depth.
struct VTRenderer: Sendable {
    let scene: VTScene
    let camera: CameraModel          // intrinsics at source resolution
    let width: Int, height: Int      // working image
    let sourceScale: Double          // source px per working px (2 for 1920 → 960)

    static let tile = 32
    private static let noise: [Float] = {
        var r = VTRandom(seed: 77)
        return (0..<8192).map { _ in Float(r.gauss()) }
    }()

    // Per-frame prepared data.
    private let origin: SIMD3<Double>
    private let r0: SIMD3<Double>, r1: SIMD3<Double>, r2: SIMD3<Double>
    private let localOrigin: [SIMD3<Double>]
    private let rotT: [simd_double3x3]
    private let tileStart: [Int32]
    private let tileItems: [Int32]
    private let tilesX: Int
    private let casters: [Int]

    init(scene: VTScene, camera: CameraModel, width: Int = 960, height: Int = 720, sourceScale: Double = 2) {
        self.scene = scene; self.camera = camera; self.width = width; self.height = height; self.sourceScale = sourceScale
        let m = camera.cameraToWorld
        origin = camera.position
        r0 = SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z)
        r1 = SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z)
        r2 = SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z)
        localOrigin = scene.boxes.map { $0.rot.transpose * (camera.position - $0.center) }
        rotT = scene.boxes.map { $0.rot.transpose }
        casters = scene.boxes.indices.filter { scene.boxes[$0].castsShadow }
        let T = Self.tile
        let tx = (width + T - 1) / T, ty = (height + T - 1) / T
        tilesX = tx
        var bins = [[Int32]](repeating: [], count: tx * ty)
        func bbox(_ pts: [SIMD3<Double>]) -> (Int, Int, Int, Int) {
            var x0 = Double.infinity, y0 = Double.infinity, x1 = -Double.infinity, y1 = -Double.infinity
            let w2c = camera.worldToCamera
            for p in pts {
                let c = w2c * SIMD4(p, 1)
                if c.z > -0.02 { return (0, 0, tx - 1, ty - 1) }
                guard let px = camera.project(p) else { return (0, 0, tx - 1, ty - 1) }
                let x = px.x / sourceScale, y = px.y / sourceScale
                x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
            }
            let a = Int(((x0 - 2) / Double(T)).rounded(.down)), b = Int(((y0 - 2) / Double(T)).rounded(.down))
            let c = Int(((x1 + 2) / Double(T)).rounded(.down)), d = Int(((y1 + 2) / Double(T)).rounded(.down))
            return (max(0, a), max(0, b), min(tx - 1, c), min(ty - 1, d))
        }
        func add(_ item: Int32, _ bb: (Int, Int, Int, Int)) {
            guard bb.0 <= bb.2, bb.1 <= bb.3 else { return }
            for y in bb.1...bb.3 { for x in bb.0...bb.2 { bins[y * tx + x].append(item) } }
        }
        for (i, b) in scene.boxes.enumerated() {
            var pts: [SIMD3<Double>] = []
            for sx in [-1.0, 1.0] { for sy in [-1.0, 1.0] { for sz in [-1.0, 1.0] {
                pts.append(b.center + b.rot * (b.half * SIMD3(sx, sy, sz)))
            } } }
            add(Int32(i), bbox(pts))
        }
        for (i, s) in scene.spheres.enumerated() {
            var pts: [SIMD3<Double>] = []
            for sx in [-1.0, 1.0] { for sy in [-1.0, 1.0] { for sz in [-1.0, 1.0] {
                pts.append(s.center + SIMD3(sx, sy, sz) * s.radius)
            } } }
            add(Int32(-(i + 1)), bbox(pts))
        }
        var start: [Int32] = [0], items: [Int32] = []
        for b in bins { items.append(contentsOf: b); start.append(Int32(items.count)) }
        tileStart = start; tileItems = items
    }

    struct Hit {
        var t: Double
        var normal: SIMD3<Double>
        var albedo: VTColor
        var texture: VTTexture
        var local: SIMD3<Double>      // box-local hit point (wood grain)
        var item: Int32               // box ≥ 0, sphere < 0, room = Int32.max
        var floor = false
    }

    /// World direction (unnormalised, camera z = −1) through a source pixel.
    @inline(__always) func direction(sourceX sx: Double, sourceY sy: Double) -> SIMD3<Double> {
        let k = camera.intrinsics
        return r0 * ((sx - k.cx) / k.fx) + r1 * (-(sy - k.cy) / k.fy) - r2
    }

    @inline(__always) private func hitBox(_ i: Int, _ d: SIMD3<Double>, tMax: Double) -> (Double, Int, Double)? {
        let b = scene.boxes[i]
        let o = localOrigin[i], dl = rotT[i] * d
        var tmin = 1e-4, tmax = tMax, axis = -1, sign = 0.0
        for a in 0..<3 {
            let h = b.half[a], oa = o[a], da = dl[a]
            if abs(da) < 1e-12 {
                if abs(oa) > h { return nil }
                continue
            }
            let inv = 1 / da
            var t1 = (-h - oa) * inv, t2 = (h - oa) * inv
            if t1 > t2 { swap(&t1, &t2) }
            if t1 > tmin { tmin = t1; axis = a; sign = da > 0 ? -1 : 1 }
            if t2 < tmax { tmax = t2 }
            if tmin > tmax { return nil }
        }
        return axis < 0 ? nil : (tmin, axis, sign)   // axis < 0: origin inside the box → ignore
    }

    @inline(__always) private func hitSphere(_ i: Int, _ d: SIMD3<Double>, tMax: Double) -> Double? {
        let s = scene.spheres[i]
        let oc = origin - s.center
        let a = simd_dot(d, d), b = simd_dot(oc, d), c = simd_dot(oc, oc) - s.radius * s.radius
        let disc = b * b - a * c
        guard disc > 0 else { return nil }
        let t = (-b - disc.squareRoot()) / a
        return t > 1e-4 && t < tMax ? t : nil
    }

    private func roomHit(_ d: SIMD3<Double>) -> (Double, SIMD3<Double>, Bool) {
        var best = Double.infinity, n = SIMD3<Double>(0, 1, 0), floor = false
        for a in 0..<3 {
            let da = d[a]
            guard abs(da) > 1e-12 else { continue }
            let t = da > 0 ? (scene.roomMax[a] - origin[a]) / da : (scene.roomMin[a] - origin[a]) / da
            if t > 0 && t < best {
                best = t
                var nn = SIMD3<Double>(0, 0, 0); nn[a] = da > 0 ? -1 : 1
                n = nn; floor = a == 1 && da < 0
            }
        }
        return (best, n, floor)
    }

    /// Nearest hit along `d` using the tile at working pixel (wx, wy); `binned: false` tests everything.
    func cast(_ d: SIMD3<Double>, wx: Int, wy: Int, binned: Bool = true) -> Hit {
        let (tr, nr, fl) = roomHit(d)
        var best = tr, item = Int32.max, axis = 0, sign = 0.0
        func test(_ it: Int32) {
            if it >= 0 {
                if let h = hitBox(Int(it), d, tMax: best) { best = h.0; item = it; axis = h.1; sign = h.2 }
            } else if let t = hitSphere(Int(-it - 1), d, tMax: best) { best = t; item = it }
        }
        if binned {
            let tx = min(tilesX - 1, max(0, wx / Self.tile)), ty = max(0, wy / Self.tile)
            let ti = min(tileStart.count - 2, ty * tilesX + tx)
            for k in Int(tileStart[ti])..<Int(tileStart[ti + 1]) { test(tileItems[k]) }
        } else {
            for i in scene.boxes.indices { test(Int32(i)) }
            for i in scene.spheres.indices { test(Int32(-(i + 1))) }
        }
        if item == Int32.max {
            return Hit(t: tr, normal: nr, albedo: fl ? scene.floorAlbedo : scene.wallAlbedo,
                       texture: fl ? scene.floorTexture : .plain, local: origin + d * tr, item: item, floor: fl)
        }
        if item >= 0 {
            let b = scene.boxes[Int(item)]
            var nl = SIMD3<Double>(0, 0, 0); nl[axis] = sign
            let local = localOrigin[Int(item)] + rotT[Int(item)] * d * best
            return Hit(t: best, normal: b.rot * nl, albedo: b.albedo, texture: b.texture, local: local, item: item)
        }
        let s = scene.spheres[Int(-item - 1)]
        let p = origin + d * best
        let n = (p - s.center) / s.radius
        let k = simd_dot(n, s.axis)
        let white = s.stripe ? abs(k) > 0.55 : k > 0.86
        let alb = white ? VTColor(0.94, 0.93, 0.88) : s.albedo
        return Hit(t: best, normal: n, albedo: alb, texture: s.stripe ? .ballStripe : .ballSolid, local: n, item: item)
    }

    @inline(__always) private static func hash(_ x: Int, _ y: Int) -> Double {
        var h = UInt64(bitPattern: Int64(x &* 73856093 ^ y &* 19349663))
        h = (h ^ (h >> 13)) &* 0x5bd1e995
        h ^= h >> 15
        return Double(h & 0xffff) / 65535 * 2 - 1
    }

    private func occluded(_ p: SIMD3<Double>, _ q: SIMD3<Double>) -> Bool {
        let d = q - p
        for i in casters {
            let b = scene.boxes[i]
            let o = b.rot.transpose * (p - b.center), dl = b.rot.transpose * d
            var tmin = 1e-4, tmax = 1.0, hit = true
            for a in 0..<3 {
                let h = b.half[a]
                if abs(dl[a]) < 1e-12 { if abs(o[a]) > h { hit = false; break }; continue }
                var t1 = (-h - o[a]) / dl[a], t2 = (h - o[a]) / dl[a]
                if t1 > t2 { swap(&t1, &t2) }
                tmin = max(tmin, t1); tmax = min(tmax, t2)
                if tmin > tmax { hit = false; break }
            }
            if hit { return true }
        }
        return false
    }

    /// Shaded colour (0…1+, before exposure) of a hit.
    func shade(_ h: Hit, _ d: SIMD3<Double>) -> VTColor {
        let p = origin + d * h.t
        var alb = h.albedo
        switch h.texture {
        case .felt: alb *= 1 + 0.035 * Self.hash(Int((p.x * 250).rounded(.down)), Int((p.z * 250).rounded(.down)))
        case .wood:
            let l = h.local
            let along = abs(l.x) > abs(l.y) ? l.x : l.y, across = abs(l.x) > abs(l.y) ? l.y : l.x
            alb *= 1 + 0.08 * sin(along * 70 + 3 * sin(across * 40))
        case .floorPlanks:
            let plank = Int((p.z / 0.14).rounded(.down))
            let f = p.z / 0.14 - Double(plank)
            alb *= (1 + 0.15 * Self.hash(plank, Int((p.x / 1.2 + Double(plank) * 0.37).rounded(.down)))) * (f < 0.05 ? 0.6 : 1)
        case .carpet: alb *= 1 + 0.14 * Self.hash(Int((p.x * 120).rounded(.down)), Int((p.z * 120).rounded(.down)))
        case .concrete: alb *= 1 + 0.06 * Self.hash(Int((p.x * 40).rounded(.down)), Int((p.z * 40).rounded(.down)))
        default: break
        }
        let n = h.normal
        let L = scene.lighting
        var light = L.ambient + L.sunColor * max(0, -simd_dot(n, L.sunDir))
        var spec = 0.0
        let isBall = h.item < 0 && h.item != Int32.max
        let v = -simd_normalize(d)
        for lamp in L.lamps {
            let toL = lamp.position - p
            let d2 = simd_length_squared(toL)
            let l = toL / d2.squareRoot()
            let ndl = simd_dot(n, l)
            guard ndl > 0 else { continue }
            let cone = min(1, max(0, (l.y - (lamp.coneCos - 0.25)) / 0.25))
            guard cone > 0 else { continue }
            if L.shadows && !casters.isEmpty && occluded(p + n * 1e-3, lamp.position) { continue }
            light += lamp.color * (lamp.power * ndl * cone / d2)
            if isBall {
                let hv = simd_normalize(l + v)
                spec += pow(max(0, simd_dot(n, hv)), 60) * lamp.power / d2 * 0.6
            }
        }
        if isBall && L.lamps.isEmpty {
            let hv = simd_normalize(-L.sunDir + v)
            spec += pow(max(0, simd_dot(n, hv)), 60) * 0.5
        }
        return alb * light + VTColor(repeating: spec)
    }

    /// Interleaved RGB8 working image.
    func renderRGB(seed: UInt64) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: width * height * 3)
        let L = scene.lighting
        let sigma = Float(L.noiseSigma), exposure = L.exposure
        let noise = Self.noise
        var rs = VTRandom(seed: seed)
        let k = camera.intrinsics
        out.withUnsafeMutableBufferPointer { o in
            for y in 0..<height {
                var ni = Int(rs.next() & 8191)
                let sy = Double(y) * sourceScale
                for x in 0..<width {
                    let sx = Double(x) * sourceScale
                    let d = direction(sourceX: sx, sourceY: sy)
                    let h = cast(d, wx: x, wy: y)
                    var c = shade(h, d) * exposure
                    // Lens vignetting.
                    let ux = (sx - k.cx) / k.width, uy = (sy - k.cy) / k.width
                    c *= 1 - 0.35 * (ux * ux + uy * uy)
                    let i = (y * width + x) * 3
                    for ch in 0..<3 {
                        ni = (ni &+ 2731) & 8191
                        let val = Float(min(1.2, c[ch]) * 255) + noise[ni] * sigma
                        o[i + ch] = UInt8(max(0, min(255, val)))
                    }
                }
            }
        }
        return out
    }

    /// LiDAR-like depth (metres along the view axis) + ARKit-style confidence, pixel-aligned with the image.
    func renderDepth(width dw: Int = 256, height dh: Int = 192, seed: UInt64) -> AutoDepthMap {
        var rng = VTRandom(seed: seed)
        var z = [Float](repeating: 0, count: dw * dh)
        var conf = [UInt8](repeating: 2, count: dw * dh)
        let k = camera.intrinsics
        for v in 0..<dh {
            for u in 0..<dw {
                let sx = (Double(u) + 0.5) * k.width / Double(dw) - 0.5
                let sy = (Double(v) + 0.5) * k.height / Double(dh) - 0.5
                let d = direction(sourceX: sx, sourceY: sy)
                let h = cast(d, wx: Int(sx / sourceScale), wy: Int(sy / sourceScale))
                let i = v * dw + u
                let depth = h.t
                var hole = depth > 5 || rng.chance(0.02)
                if h.item >= 0 && h.item != Int32.max && scene.boxes[Int(h.item)].lidarHole { hole = true }
                let grazing = abs(simd_dot(h.normal, simd_normalize(d))) < 0.15
                if grazing && rng.chance(0.5) { hole = true }
                if hole { z[i] = 0; conf[i] = 0; continue }
                let lum = simd_dot(h.albedo, VTColor(0.3, 0.59, 0.11))
                var sigma = 0.004 + 0.004 * depth
                if lum < 0.1 { sigma *= 3; conf[i] = 1 }
                z[i] = Float(depth + rng.gauss() * sigma)
            }
        }
        // Depth edges come back medium confidence (ARKit smooths across them).
        for v in 1..<(dh - 1) {
            for u in 1..<(dw - 1) {
                let i = v * dw + u
                guard conf[i] == 2 else { continue }
                let c = z[i]
                if abs(z[i - 1] - c) > 0.08 || abs(z[i + 1] - c) > 0.08 || abs(z[i - dw] - c) > 0.08 || abs(z[i + dw] - c) > 0.08 {
                    conf[i] = 1
                }
            }
        }
        return AutoDepthMap(width: dw, height: dh, depth: z, confidence: conf)
    }

    /// Surface under a source pixel (plane-anchor simulation, ground-truth visibility).
    func surface(atSourceX sx: Double, sourceY sy: Double) -> (VTSurface, SIMD3<Double>) {
        let d = direction(sourceX: sx, sourceY: sy)
        let h = cast(d, wx: 0, wy: 0, binned: false)
        let p = origin + d * h.t
        if h.floor { return (.floor, p) }
        if h.item >= 0 && h.item != Int32.max { return (scene.boxes[Int(h.item)].surface, p) }
        return (.none, p)
    }
}

// MARK: - Image plumbing

enum VTImageIO {
    /// BGRA CVPixelBuffer from RGB8 (what FrameTap converts from).
    static func pixelBuffer(rgb: [UInt8], width: Int, height: Int) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &pb) == kCVReturnSuccess,
              let buf = pb else { return nil }
        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        guard let base = CVPixelBufferGetBaseAddress(buf) else { return nil }
        let rb = CVPixelBufferGetBytesPerRow(buf)
        let dst = base.assumingMemoryBound(to: UInt8.self)
        rgb.withUnsafeBufferPointer { s in
            for y in 0..<height {
                let row = dst + y * rb
                for x in 0..<width {
                    let i = (y * width + x) * 3, o = x * 4
                    row[o] = s[i + 2]; row[o + 1] = s[i + 1]; row[o + 2] = s[i]; row[o + 3] = 255
                }
            }
        }
        return buf
    }

    static func cgImage(rgb: [UInt8], width: Int, height: Int) -> CGImage? {
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0..<(width * height) {
            rgba[i * 4] = rgb[i * 3]; rgba[i * 4 + 1] = rgb[i * 3 + 1]; rgba[i * 4 + 2] = rgb[i * 3 + 2]
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

import Foundation
import Geometry
import simd
@testable import CueCoach

// Virtual table simulator (QA only). A small analytic 3D world — room, pool table(s), balls, clutter,
// people, lights — that a ray caster turns into ARKit-like frames (RGB + LiDAR depth + plane anchors + pose).
// World = ARKit world: metres, gravity-aligned, +y up. Table coords = TableFrame convention:
// x head → foot along the length, y across, z up, origin at the head-left cushion-nose corner, cloth z = 0.

/// Deterministic RNG (splitmix64).
struct VTRandom: Sendable {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 &+ 0x2545F4914F6CDD1D }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func uniform() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func uniform(_ a: Double, _ b: Double) -> Double { a + (b - a) * uniform() }
    mutating func uniform(_ r: ClosedRange<Double>) -> Double { uniform(r.lowerBound, r.upperBound) }
    mutating func gauss() -> Double {
        let u1 = max(uniform(), 1e-12), u2 = uniform()
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
    mutating func chance(_ p: Double) -> Bool { uniform() < p }
    mutating func pick<T>(_ a: [T]) -> T { a[Int(next() % UInt64(a.count))] }
}

typealias VTColor = SIMD3<Double>   // display-referred albedo, 0…1

enum VTTexture: UInt8, Sendable { case plain, felt, wood, floorPlanks, carpet, concrete, ballStripe, ballSolid }

/// What a surface is, for plane anchors and ground truth.
enum VTSurface: Hashable, Sendable {
    case none
    case cloth(Int)      // table index (0 = the target table)
    case coffee
    case floor
}

/// Oriented box.
struct VTBox: Sendable {
    var center: SIMD3<Double>
    /// Local → world rotation (columns = the box's local axes in world).
    var rot: simd_double3x3
    var half: SIMD3<Double>
    var albedo: VTColor
    var texture: VTTexture = .plain
    var surface: VTSurface = .none
    var castsShadow = false
    /// LiDAR returns nothing useful (glass, very dark felt pockets).
    var lidarHole = false
}

struct VTSphere: Sendable {
    var center: SIMD3<Double>
    var radius: Double
    var albedo: VTColor
    var stripe: Bool
    var axis: SIMD3<Double>
}

/// A point light (pool-table lamp shade) with a downward cone.
struct VTLamp: Sendable {
    var position: SIMD3<Double>
    var color: VTColor
    var power: Double          // irradiance at 1 m on-axis
    var coneCos: Double        // full intensity inside, fades to 0 at coneCos - 0.25
}

struct VTLighting: Sendable {
    var ambient: VTColor
    var sunDir: SIMD3<Double>  // direction the light travels (pointing down)
    var sunColor: VTColor
    var lamps: [VTLamp] = []
    var exposure: Double = 1
    var noiseSigma: Double = 3   // 8-bit units
    var shadows = false
}

/// Ground truth for one table.
struct VTTableTruth: Sendable {
    var size: TableSize
    var spec: TableSpec
    var tableToWorld: simd_double4x4
    var cushion: Double
    var railWood: Double
    var railTop: Double

    var center: SIMD3<Double> { world(spec.length / 2, spec.width / 2, 0) }
    var xAxis: SIMD3<Double> { SIMD3(tableToWorld.columns.0.x, tableToWorld.columns.0.y, tableToWorld.columns.0.z) }
    var yAxis: SIMD3<Double> { SIMD3(tableToWorld.columns.1.x, tableToWorld.columns.1.y, tableToWorld.columns.1.z) }
    var clothHeight: Double { tableToWorld.columns.3.y }
    /// Nose corners at cloth height, TableFrame.corners order.
    var corners: [SIMD3<Double>] {
        let L = spec.length, W = spec.width
        return [world(0, 0, 0), world(0, W, 0), world(L, W, 0), world(L, 0, 0)]
    }
    /// Outer edge of the rail wood (footprint half-sizes from the centre).
    var outerHalf: SIMD2<Double> { SIMD2(spec.length / 2 + cushion + railWood, spec.width / 2 + cushion + railWood) }

    func world(_ x: Double, _ y: Double, _ z: Double) -> SIMD3<Double> {
        let w = tableToWorld * SIMD4(x, y, z, 1)
        return SIMD3(w.x, w.y, w.z)
    }
}

/// The whole world for one run.
struct VTScene: Sendable {
    var boxes: [VTBox] = []
    var spheres: [VTSphere] = []
    var roomMin = SIMD3<Double>(-6, 0, -6)
    var roomMax = SIMD3<Double>(6, 3.2, 6)
    var floorAlbedo: VTColor = VTColor(0.35, 0.3, 0.26)
    var floorTexture: VTTexture = .floorPlanks
    var wallAlbedo: VTColor = VTColor(0.45, 0.4, 0.36)
    var lighting: VTLighting
    var tables: [VTTableTruth] = []
    /// Moving occluders (people/arms): indices into `boxes` with a sway per second.
    var swaying: [(index: Int, axis: SIMD3<Double>, amplitude: Double, period: Double)] = []

    func at(time t: Double) -> VTScene {
        guard !swaying.isEmpty else { return self }
        var s = self
        for sw in swaying { s.boxes[sw.index].center += sw.axis * (sw.amplitude * sin(2 * .pi * t / sw.period)) }
        return s
    }
}

// MARK: - Builders

enum VTBuild {
    static func yawRot(_ yaw: Double) -> simd_double3x3 {
        let ex = SIMD3(cos(yaw), 0, sin(yaw)), ez = SIMD3<Double>(0, 1, 0)
        let ey = simd_cross(ez, ex)
        // Table local axes: x = length, y = across, z = up → world columns.
        return simd_double3x3(columns: (ex, ey, ez))
    }

    /// Box from table-local min/max corners (axis-aligned in the table frame).
    static func tableBox(_ t: VTTableTruth, _ lo: SIMD3<Double>, _ hi: SIMD3<Double>, _ c: VTColor,
                         _ tex: VTTexture = .plain, surface: VTSurface = .none, extraYaw: Double = 0,
                         hole: Bool = false) -> VTBox {
        let mid = (lo + hi) / 2
        let r3 = simd_double3x3(columns: (t.xAxis, t.yAxis, SIMD3(0, 1, 0)))
        var rot = r3
        if extraYaw != 0 {
            let ca = cos(extraYaw), sa = sin(extraYaw)
            let a = t.xAxis * ca + t.yAxis * sa, b = -t.xAxis * sa + t.yAxis * ca
            rot = simd_double3x3(columns: (a, b, SIMD3(0, 1, 0)))
        }
        return VTBox(center: t.world(mid.x, mid.y, mid.z), rot: rot, half: (hi - lo) / 2, albedo: c, texture: tex,
                     surface: surface, lidarHole: hole)
    }

    /// Pool table geometry: bed, cushions, rails, pockets, diamonds, apron, legs.
    static func table(_ t: VTTableTruth, index: Int, felt: VTColor, rail: VTColor) -> [VTBox] {
        let L = t.spec.length, W = t.spec.width, c = t.cushion, r = t.railWood, top = t.railTop
        let noseTop = top - 0.002
        var b: [VTBox] = []
        // Bed cloth.
        b.append(tableBox(t, SIMD3(0, 0, -0.06), SIMD3(L, W, 0), felt, .felt, surface: .cloth(index)))
        // Cushions (felt), split at the side pockets.
        let cush = felt * 0.97
        b.append(tableBox(t, SIMD3(-c, 0, -0.06), SIMD3(0, W, noseTop), cush, .felt))
        b.append(tableBox(t, SIMD3(L, 0, -0.06), SIMD3(L + c, W, noseTop), cush, .felt))
        for (y0, y1) in [(-c, 0.0), (W, W + c)] {
            b.append(tableBox(t, SIMD3(0, y0, -0.06), SIMD3(L / 2, y1, noseTop), cush, .felt))
            b.append(tableBox(t, SIMD3(L / 2, y0, -0.06), SIMD3(L, y1, noseTop), cush, .felt))
        }
        // Rails (wood) all round.
        let o = c + r
        b.append(tableBox(t, SIMD3(-o, -o, -0.22), SIMD3(L + o, -c, top), rail, .wood))
        b.append(tableBox(t, SIMD3(-o, W + c, -0.22), SIMD3(L + o, W + o, top), rail, .wood))
        b.append(tableBox(t, SIMD3(-o, -c, -0.22), SIMD3(-c, W + c, top), rail, .wood))
        b.append(tableBox(t, SIMD3(L + c, -c, -0.22), SIMD3(L + o, W + c, top), rail, .wood))
        // Pockets: near-black openings that eat the cushion corner and part of the rail.
        let pk = VTColor(0.05, 0.05, 0.05)
        let m = t.spec.cornerMouth
        for (x, y) in [(0.0, 0.0), (0.0, W), (L, W), (L, 0.0)] {
            let dx = x == 0 ? -1.0 : 1.0, dy = y == 0 ? -1.0 : 1.0
            let cx = x + dx * c * 0.75, cy = y + dy * c * 0.75
            var bx = tableBox(t, SIMD3(cx - m / 2, cy - m / 2, -0.10), SIMD3(cx + m / 2, cy + m / 2, top + 0.002), pk,
                              extraYaw: .pi / 4, hole: true)
            bx.surface = .none
            b.append(bx)
        }
        let sm = t.spec.sideMouth
        for y in [-c * 0.8, W + c * 0.8] {
            b.append(tableBox(t, SIMD3(L / 2 - sm / 2, y - c * 0.7, -0.10), SIMD3(L / 2 + sm / 2, y + c * 0.7, top + 0.002),
                              pk, hole: true))
        }
        // Diamonds (mother of pearl) on the rail tops.
        let pearl = VTColor(0.9, 0.88, 0.82)
        let midRail = c + r / 2
        for k in 1...7 where k != 4 {
            let x = L * Double(k) / 8
            for y in [-midRail, W + midRail] {
                b.append(tableBox(t, SIMD3(x - 0.012, y - 0.006, top), SIMD3(x + 0.012, y + 0.006, top + 0.002), pearl))
            }
        }
        for k in 1...3 {
            let y = W * Double(k) / 4
            for x in [-midRail, L + midRail] {
                b.append(tableBox(t, SIMD3(x - 0.006, y - 0.012, top), SIMD3(x + 0.006, y + 0.012, top + 0.002), pearl))
            }
        }
        // Apron/body and legs.
        let body = rail * 0.7
        b.append(tableBox(t, SIMD3(-o + 0.03, -o + 0.03, -0.32), SIMD3(L + o - 0.03, W + o - 0.03, -0.22), body, .wood))
        let h = t.clothHeight
        for (x, y) in [(0.15, 0.15), (0.15, W - 0.15), (L - 0.15, W - 0.15), (L - 0.15, 0.15), (L / 2, 0.15), (L / 2, W - 0.15)] {
            b.append(tableBox(t, SIMD3(x - 0.07, y - 0.07, -h), SIMD3(x + 0.07, y + 0.07, -0.32), body))
        }
        return b
    }

    static let ballColors: [VTColor] = [
        VTColor(0.94, 0.93, 0.88),                                  // 0 cue
        VTColor(0.92, 0.75, 0.10), VTColor(0.10, 0.22, 0.65), VTColor(0.80, 0.12, 0.10), VTColor(0.35, 0.15, 0.50),
        VTColor(0.92, 0.42, 0.08), VTColor(0.06, 0.42, 0.22), VTColor(0.45, 0.10, 0.10), VTColor(0.07, 0.07, 0.08),
    ]

    /// Balls 0…15 (n of them), racked at the foot spot or scattered.
    static func balls(_ t: VTTableTruth, count n: Int, racked: Bool, rng: inout VTRandom) -> [VTSphere] {
        let R = TableSpec.ballRadius, L = t.spec.length, W = t.spec.width
        var pos: [Vec2] = []
        if racked {
            pos.append(Vec2(L * 0.25 + rng.uniform(-0.05, 0.05), W / 2 + rng.uniform(-0.1, 0.1)))  // cue at the head spot
            let apex = Vec2(L * 0.75, W / 2), d = 2 * R + 0.0005
            outer: for row in 0..<5 {
                for k in 0...row {
                    if pos.count >= n { break outer }
                    pos.append(Vec2(apex.x + Double(row) * d * 0.866, apex.y + (Double(k) - Double(row) / 2) * d))
                }
            }
        } else {
            var tries = 0
            while pos.count < n && tries < 400 {
                tries += 1
                let p = Vec2(rng.uniform(R + 0.01, L - R - 0.01), rng.uniform(R + 0.01, W - R - 0.01))
                if pos.allSatisfy({ $0.distance(to: p) > 2.05 * R }) { pos.append(p) }
            }
        }
        return pos.enumerated().map { i, p in
            let num = i
            let col = ballColors[num <= 8 ? num : num - 8]
            let ax = simd_normalize(SIMD3(rng.gauss(), rng.gauss(), rng.gauss()))
            return VTSphere(center: t.world(p.x, p.y, R), radius: R, albedo: col, stripe: num > 8, axis: ax)
        }
    }
}

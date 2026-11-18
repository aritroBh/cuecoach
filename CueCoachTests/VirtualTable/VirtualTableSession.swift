import Foundation
import Geometry
import simd
@testable import CueCoach

// Conditions, camera trajectories and ARKit plane-anchor behaviour for the virtual table.

enum VTFelt: String, CaseIterable, Sendable {
    case green, blue, red, grey, tan
    var color: VTColor {
        switch self {
        case .green: VTColor(0.11, 0.44, 0.25)
        case .blue: VTColor(0.10, 0.30, 0.60)
        case .red: VTColor(0.52, 0.11, 0.12)
        case .grey: VTColor(0.42, 0.43, 0.45)
        case .tan: VTColor(0.66, 0.55, 0.38)
        }
    }
}

enum VTLight: String, CaseIterable, Sendable { case even, lamp, dim, neon, cueShadow }
enum VTClutter: String, CaseIterable, Sendable { case none, secondTable, coffeeTable, people, railObjects }
enum VTPath: String, CaseIterable, Sendable { case endPan, sideWalk, partial, sideStatic }

struct VTCondition: Sendable {
    var name: String
    var axis: String
    var felt: VTFelt = .green
    var light: VTLight = .even
    var clutter: [VTClutter] = []
    var paths: [VTPath] = [.endPan, .sideWalk]
    /// Horizontal distance from the camera to the nearest rail (m).
    var distance: ClosedRange<Double> = 1.0...2.2
    /// Fixed camera depression angle (deg); nil = aim at the table centre from the sampled distance.
    var elevation: ClosedRange<Double>? = nil
    var fps: [Int] = [30, 60]
    /// Phone held portrait (nil = 60 % portrait).
    var portrait: Bool? = nil

    static let baseline = VTCondition(name: "baseline", axis: "baseline")

    /// One-factor-at-a-time matrix around the baseline (green felt, even light, no clutter, 1–2.2 m).
    static var matrix: [VTCondition] {
        var out = [baseline]
        for f in VTFelt.allCases where f != .green { var c = baseline; c.name = "felt-\(f.rawValue)"; c.axis = "felt"; c.felt = f; out.append(c) }
        for l in VTLight.allCases where l != .even { var c = baseline; c.name = "light-\(l.rawValue)"; c.axis = "lighting"; c.light = l; out.append(c) }
        for k in VTClutter.allCases where k != .none { var c = baseline; c.name = "clutter-\(k.rawValue)"; c.axis = "clutter"; c.clutter = [k]; out.append(c) }
        for d in [1.0, 2.0, 3.0] { var c = baseline; c.name = "dist-\(d)m"; c.axis = "distance"; c.distance = (d - 0.1)...(d + 0.1); out.append(c) }
        for e in [25.0, 45.0, 60.0] {
            var c = baseline; c.name = "elev-\(Int(e))deg"; c.axis = "elevation"; c.elevation = (e - 3)...(e + 3)
            c.paths = [.sideStatic]; out.append(c)
        }
        for p in [VTPath.endPan, .sideWalk, .partial] { var c = baseline; c.name = "path-\(p.rawValue)"; c.axis = "trajectory"; c.paths = [p]; out.append(c) }
        for p in [true, false] { var c = baseline; c.name = p ? "hold-portrait" : "hold-landscape"; c.axis = "orientation"; c.portrait = p; out.append(c) }
        for f in [30, 60] { var c = baseline; c.name = "fps-\(f)"; c.axis = "frame rate"; c.fps = [f]; out.append(c) }
        var bar = baseline
        bar.name = "bar-rive-combo"; bar.axis = "combo"; bar.light = .lamp; bar.clutter = [.secondTable, .people, .railObjects]
        out.append(bar)
        return out
    }
}

/// Camera motion a real user makes while the app looks for the table.
struct VTTrajectory: Sendable {
    var kind: VTPath
    var start: SIMD3<Double>
    var velocity: SIMD3<Double> = .zero
    var target: SIMD3<Double>
    /// Fixed depression (rad) instead of aiming at the target height.
    var fixedPitch: Double?
    var panAmp: Double, panPeriod: Double, panPhase: Double
    var portrait: Bool
    var roll: Double
    var tremor: SIMD4<Double>
    var walkLimit: (SIMD3<Double>, SIMD3<Double>)?

    func position(_ t: Double) -> SIMD3<Double> {
        var p = start + velocity * t
        if let (a, b) = walkLimit {
            // Ping-pong along the walk segment.
            let ab = b - a, len = simd_length(ab)
            if len > 1e-6 {
                let s = simd_dot(p - a, ab) / (len * len)
                let f = s.truncatingRemainder(dividingBy: 2)
                let w = f < 0 ? -f : (f > 1 ? 2 - f : f)
                p = a + ab * w + (p - (a + ab * s))
            }
        }
        return p + SIMD3(0.004 * sin(t * 1.3 + tremor.x), 0.003 * sin(t * 1.7 + tremor.y), 0.004 * sin(t * 1.1 + tremor.z))
    }

    func cameraToWorld(_ t: Double) -> simd_double4x4 {
        let p = position(t)
        var aim = target
        if kind == .sideWalk { aim += (p - start) * 0.5 }
        let v = aim - p
        let yaw0 = atan2(v.z, v.x)
        let pitch0 = fixedPitch ?? atan2(-v.y, simd_length(SIMD2(v.x, v.z)))
        let yaw = yaw0 + panAmp * sin(2 * .pi * t / panPeriod + panPhase) + 0.004 * sin(t * 5.1 + tremor.w)
        let pitch = pitch0 + 0.025 * sin(2 * .pi * t / (panPeriod * 0.7) + tremor.x) + 0.003 * sin(t * 6.3 + tremor.y)
        let f = SIMD3(cos(pitch) * cos(yaw), -sin(pitch), cos(pitch) * sin(yaw))
        let back = -f
        var right = simd_normalize(simd_cross(SIMD3(0, 1, 0), back))
        var up = simd_cross(back, right)
        let r = roll + 0.02 * sin(t * 0.9 + tremor.z)
        (right, up) = (right * cos(r) + up * sin(r), -right * sin(r) + up * cos(r))
        if portrait { (right, up) = (up, -right) }
        return simd_double4x4(columns: (SIMD4(right, 0), SIMD4(up, 0), SIMD4(back, 0), SIMD4(p, 1)))
    }
}

/// ARKit horizontal plane anchors: appear a while after a surface is in view, start small around where the user
/// first looked, grow toward the true extent, carry a per-session height bias of 1–3 cm, and some get classified `.table`.
struct VTPlaneSim: Sendable {
    struct Truth: Sendable {
        var surface: VTSurface
        var center: SIMD3<Double>
        var extent: SIMD2<Double>
        var tableProb: Double
    }
    struct Track: Sendable {
        var seenAt: Double
        var seenPoint: SIMD3<Double>
        var detectAt: Double
        var growTime: Double
        var bias: Double
        var classifyAt: Double?
    }
    var truths: [Truth]
    var tracks: [VTSurface: Track] = [:]
    var lastUpdate = -Double.infinity
    var rng: VTRandom
    var trackingReady: Double
    let biasSigma: Double

    init(truths: [Truth], seed: UInt64, trackingReady: Double) {
        self.truths = truths
        rng = VTRandom(seed: seed)
        self.trackingReady = trackingReady
        var br = VTRandom(seed: seed ^ 0xabc)
        biasSigma = br.uniform(0.01, 0.03)
    }

    /// `t` = seconds since session start.
    mutating func update(t: Double, renderer: VTRenderer) {
        guard t >= trackingReady, t - lastUpdate >= 0.1 else { return }
        lastUpdate = t
        let k = renderer.camera.intrinsics
        for gy in 0..<7 {
            for gx in 0..<7 {
                let sx = (Double(gx) + 0.5) / 7 * k.width, sy = (Double(gy) + 0.5) / 7 * k.height
                let (s, p) = renderer.surface(atSourceX: sx, sourceY: sy)
                guard s != .none, tracks[s] == nil, truths.contains(where: { $0.surface == s }) else { continue }
                let truth = truths.first { $0.surface == s }!
                let delay = s == .floor ? rng.uniform(0.8, 2.0) : rng.uniform(0.35, 1.2)
                let detect = t + delay
                tracks[s] = Track(seenAt: t, seenPoint: p, detectAt: detect, growTime: rng.uniform(1.5, 3.0),
                                  bias: rng.gauss() * biasSigma,
                                  classifyAt: rng.chance(truth.tableProb) ? detect + rng.uniform(0.6, 2.0) : nil)
            }
        }
    }

    func anyDetected(_ t: Double) -> Bool { tracks.values.contains { $0.detectAt <= t } }

    func planes(t: Double, jitter: inout VTRandom) -> [LocatorPlane] {
        var out: [LocatorPlane] = []
        for truth in truths {
            guard let tr = tracks[truth.surface], tr.detectAt <= t else { continue }
            let g = min(1, (t - tr.detectAt) / tr.growTime)
            let ext = SIMD2(0.35, 0.35) + (truth.extent - SIMD2(0.35, 0.35)) * g
            var c = tr.seenPoint + (truth.center - tr.seenPoint) * g
            c.y = truth.center.y + tr.bias + jitter.gauss() * 0.002
            let isTable = tr.classifyAt.map { $0 <= t } ?? false
            out.append(LocatorPlane(center: c, extent: SIMD2(max(0.35, ext.x), max(0.35, ext.y)), isTable: isTable))
        }
        return out
    }
}

/// Everything for one simulated session.
struct VTSetup: Sendable {
    var condition: VTCondition
    var seed: UInt64
    var scene: VTScene
    var truth: VTTableTruth
    var trajectory: VTTrajectory
    var planeTruths: [VTPlaneSim.Truth]
    var fps: Int
    var timestampBase: Double
    var trackingReady: Double
    var intrinsics: CameraIntrinsics

    func camera(_ t: Double) -> CameraModel { CameraModel(intrinsics: intrinsics, cameraToWorld: trajectory.cameraToWorld(t)) }

    var elevationDeg: Double {
        let m = trajectory.cameraToWorld(0)
        let f = -SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z)
        return asin(-f.y) * 180 / .pi
    }

    // swiftlint:disable:next function_body_length
    static func make(_ cond: VTCondition, seed: UInt64) -> VTSetup {
        var rng = VTRandom(seed: seed &* 7919 &+ 17)
        let size = rng.pick([TableSize.sevenFoot, .eightFoot, .nineFoot])
        let spec = TableSpec(size: size)
        let clothH = rng.uniform(0.74, 0.80)
        let yaw = rng.uniform(-.pi, .pi)
        let cushion = 0.05, railWood = rng.uniform(0.10, 0.15)
        func truthAt(_ center: SIMD3<Double>) -> VTTableTruth {
            let ex = SIMD3(cos(yaw), 0, sin(yaw)), ez = SIMD3<Double>(0, 1, 0), ey = simd_cross(ez, ex)
            let o = center - ex * (spec.length / 2) - ey * (spec.width / 2)
            return VTTableTruth(size: size, spec: spec,
                                tableToWorld: simd_double4x4(columns: (SIMD4(ex, 0), SIMD4(ey, 0), SIMD4(ez, 0), SIMD4(o, 1))),
                                cushion: cushion, railWood: railWood, railTop: 0.045)
        }
        let truth = truthAt(SIMD3(0, clothH, 0))
        var felt = cond.felt.color * rng.uniform(0.93, 1.07)
        felt = simd_clamp(felt, VTColor(repeating: 0), VTColor(repeating: 1))
        let rail = rng.pick([VTColor(0.26, 0.15, 0.08), VTColor(0.70, 0.53, 0.33), VTColor(0.09, 0.08, 0.08), VTColor(0.42, 0.24, 0.12)])

        var scene = VTScene(lighting: lighting(cond.light, truth: truth, rng: &rng))
        let floorStyle = rng.pick([VTTexture.floorPlanks, .carpet, .concrete])
        scene.floorTexture = floorStyle
        switch floorStyle {
        case .floorPlanks: scene.floorAlbedo = rng.pick([VTColor(0.42, 0.30, 0.20), VTColor(0.25, 0.18, 0.12)])
        case .carpet: scene.floorAlbedo = rng.pick([VTColor(0.18, 0.18, 0.24), VTColor(0.35, 0.12, 0.12), VTColor(0.22, 0.22, 0.2)])
        default: scene.floorAlbedo = VTColor(0.45, 0.45, 0.44)
        }
        scene.wallAlbedo = rng.pick([VTColor(0.55, 0.5, 0.42), VTColor(0.35, 0.12, 0.10), VTColor(0.15, 0.18, 0.28), VTColor(0.3, 0.3, 0.3)])
        scene.tables = [truth]
        scene.boxes = VTBuild.table(truth, index: 0, felt: felt, rail: rail)
        scene.spheres = VTBuild.balls(truth, count: Int(rng.next() % 17), racked: rng.chance(0.4), rng: &rng)

        // Camera path.
        let path = rng.pick(cond.paths)
        let L = spec.length, W = spec.width, oh = truth.outerHalf
        let ex = truth.xAxis, ey = truth.yAxis, c = truth.center
        let d = rng.uniform(cond.distance)
        var h = rng.uniform(1.35, 1.75) - clothH    // phone height above the cloth
        let portraitDraw = rng.chance(0.6)
        let portrait = cond.portrait ?? portraitDraw
        let tremor = SIMD4(rng.uniform(0, 6), rng.uniform(0, 6), rng.uniform(0, 6), rng.uniform(0, 6))
        let panAmp = rng.uniform(5, 12) * .pi / 180, panPeriod = rng.uniform(3, 5), panPhase = rng.uniform(0, 2 * .pi)
        let endSign = rng.chance(0.5) ? 1.0 : -1.0, sideSign = rng.chance(0.5) ? 1.0 : -1.0
        var traj: VTTrajectory
        func up(_ v: SIMD3<Double>, _ hh: Double) -> SIMD3<Double> { SIMD3(v.x, clothH + hh, v.z) }
        switch path {
        case .endPan, .partial:
            let dd = path == .partial ? rng.uniform(0.25, 0.6) : d
            let lat = rng.uniform(-0.3, 0.3)
            let start = up(c - ex * (endSign * (oh.x + dd)) + ey * lat, h)
            let tgt = path == .partial ? c - ex * (endSign * L * 0.22) : c + ey * rng.uniform(-0.1, 0.1)
            traj = VTTrajectory(kind: path, start: start, target: tgt, panAmp: panAmp, panPeriod: panPeriod,
                                panPhase: panPhase, portrait: portrait, roll: rng.gauss() * 0.04, tremor: tremor)
        case .sideWalk:
            let x0 = rng.uniform(-L * 0.35, L * 0.35)
            let start = up(c + ey * (sideSign * (oh.y + d)) + ex * x0, h)
            let v = ex * (rng.chance(0.5) ? 0.3 : -0.3)
            let a = up(c + ey * (sideSign * (oh.y + d)) - ex * (L * 0.4), h), b = up(c + ey * (sideSign * (oh.y + d)) + ex * (L * 0.4), h)
            traj = VTTrajectory(kind: path, start: start, velocity: v, target: c, panAmp: panAmp * 0.5,
                                panPeriod: panPeriod, panPhase: panPhase, portrait: portrait, roll: rng.gauss() * 0.04,
                                tremor: tremor, walkLimit: (a, b))
        case .sideStatic:
            let elev = rng.uniform(cond.elevation ?? 30...40) * .pi / 180
            var D = h / tan(elev)
            let minD = oh.y + 0.15
            if D < minD { D = minD; h = min(1.35, D * tan(elev)) }
            let start = up(c + ey * (sideSign * D) + ex * rng.uniform(-0.2, 0.2), h)
            traj = VTTrajectory(kind: path, start: start, target: c, fixedPitch: elev, panAmp: panAmp, panPeriod: panPeriod,
                                panPhase: panPhase, portrait: portrait, roll: rng.gauss() * 0.04, tremor: tremor)
        }

        // Plane truths: the cloth (ARKit plane = bed, local extent along the table), the floor.
        var planes: [VTPlaneSim.Truth] = [
            .init(surface: .cloth(0), center: c, extent: SIMD2(L, W), tableProb: 0.6),
            .init(surface: .floor, center: SIMD3(traj.start.x, 0, traj.start.z), extent: SIMD2(4, 4), tableProb: 0),
        ]

        // Clutter.
        for k in cond.clutter {
            switch k {
            case .none: break
            case .secondTable:
                var side = rng.chance(0.5) ? 1.0 : -1.0
                if path == .sideWalk || path == .sideStatic { side = -sideSign }
                let gap = rng.uniform(1.3, 1.7)
                let t2 = truthAt(c + ey * (side * (2 * oh.y + gap)))
                let sameFelt = rng.chance(0.75)
                let felt2 = sameFelt ? felt : rng.pick(VTFelt.allCases.filter { $0 != cond.felt }).color
                scene.tables.append(t2)
                scene.boxes += VTBuild.table(t2, index: 1, felt: felt2, rail: rail)
                scene.spheres += VTBuild.balls(t2, count: Int(rng.next() % 12), racked: rng.chance(0.5), rng: &rng)
                planes.append(.init(surface: .cloth(1), center: t2.center, extent: SIMD2(L, W), tableProb: 0.6))
            case .coffeeTable:
                let cam = traj.start
                var p = cam + (c - cam) * 0.3
                p.y = 0
                // Keep it off the pool table footprint.
                let rel = p - c
                let lx = simd_dot(rel, ex), ly = simd_dot(rel, ey)
                if abs(lx) < oh.x + 0.5 && abs(ly) < oh.y + 0.5 {
                    p = cam + simd_normalize(SIMD3(cam.x - c.x, 0, cam.z - c.z)) * (-0.6)
                    p.y = 0
                    p = SIMD3(p.x, 0, p.z)
                }
                let rot = VTBuild.yawRot(rng.uniform(-.pi, .pi))
                let wood = rng.pick([VTColor(0.30, 0.20, 0.12), VTColor(0.12, 0.10, 0.09)])
                let top = 0.45
                scene.boxes.append(VTBox(center: SIMD3(p.x, top - 0.02, p.z), rot: rot, half: SIMD3(0.45, 0.25, 0.02),
                                         albedo: wood, texture: .wood, surface: .coffee))
                for (sx, sz) in [(-0.4, -0.2), (0.4, -0.2), (0.4, 0.2), (-0.4, 0.2)] {
                    scene.boxes.append(VTBox(center: SIMD3(p.x, 0, p.z) + rot * SIMD3(sx, sz, 0) + SIMD3(0, (top - 0.04) / 2, 0),
                                             rot: rot, half: SIMD3(0.025, 0.025, (top - 0.04) / 2), albedo: wood))
                }
                scene.boxes.append(VTBox(center: SIMD3(p.x + 0.1, top + 0.11, p.z), rot: rot, half: SIMD3(0.035, 0.035, 0.11),
                                         albedo: VTColor(0.12, 0.32, 0.14), lidarHole: true))   // green bottle
                planes.append(.init(surface: .coffee, center: SIMD3(p.x, top, p.z), extent: SIMD2(0.9, 0.5), tableProb: 0.5))
            case .people:
                let m0 = traj.cameraToWorld(0)
                let fw = -SIMD3(m0.columns.2.x, 0, m0.columns.2.z)
                let f = simd_normalize(fw), right = simd_normalize(simd_cross(f, SIMD3(0, 1, 0)))
                let dist = rng.uniform(0.9, 1.3), lat = (rng.chance(0.5) ? 1 : -1) * rng.uniform(0.15, 0.35)
                let base = SIMD3(traj.start.x, 0, traj.start.z) + f * dist + right * lat
                let rot = simd_double3x3(columns: (right, SIMD3(0, 1, 0), f))
                let shirt = rng.pick([VTColor(0.08, 0.09, 0.14), VTColor(0.05, 0.05, 0.05), VTColor(0.8, 0.8, 0.78),
                                      VTColor(0.12, 0.40, 0.22), VTColor(0.6, 0.12, 0.1)])
                let skin = rng.pick([VTColor(0.85, 0.65, 0.52), VTColor(0.55, 0.38, 0.27), VTColor(0.33, 0.22, 0.16)])
                let pants = VTColor(0.12, 0.13, 0.18)
                let first = scene.boxes.count
                scene.boxes.append(VTBox(center: base + SIMD3(0, 1.17, 0), rot: rot, half: SIMD3(0.22, 0.32, 0.13), albedo: shirt))
                scene.boxes.append(VTBox(center: base + SIMD3(0, 0.43, 0), rot: rot, half: SIMD3(0.18, 0.43, 0.12), albedo: pants))
                scene.boxes.append(VTBox(center: base + SIMD3(0, 1.62, 0), rot: rot, half: SIMD3(0.09, 0.12, 0.1), albedo: skin))
                // Arm reaching toward the table at rail height.
                let toT = simd_normalize(SIMD3(c.x - base.x, 0, c.z - base.z))
                let armRot = simd_double3x3(columns: (simd_normalize(simd_cross(toT, SIMD3(0, 1, 0))), SIMD3(0, 1, 0), toT))
                scene.boxes.append(VTBox(center: base + SIMD3(0, clothH + 0.2, 0) + toT * 0.45 + right * 0.15, rot: armRot,
                                         half: SIMD3(0.05, 0.05, 0.38), albedo: skin))
                for i in first..<scene.boxes.count {
                    scene.swaying.append((index: i, axis: right, amplitude: rng.uniform(0.08, 0.16), period: rng.uniform(2.5, 4)))
                }
            case .railObjects:
                let chalk = VTColor(0.12, 0.35, 0.75)
                let o = cushion + railWood / 2
                let spots: [(Double, Double)] = [(rng.uniform(0.1, L * 0.45), -o), (rng.uniform(L * 0.55, L - 0.1), W + o),
                                                 (-o, rng.uniform(0.15, W - 0.15)), (rng.uniform(0.2, L - 0.2), -o),
                                                 (L + o, rng.uniform(0.15, W - 0.15))]
                let top = truth.railTop
                let s0 = spots[0], s1 = spots[1], s2 = spots[2], s3 = spots[3], s4 = spots[4]
                scene.boxes.append(VTBuild.tableBox(truth, SIMD3(s0.0 - 0.011, s0.1 - 0.011, top), SIMD3(s0.0 + 0.011, s0.1 + 0.011, top + 0.022), chalk))
                scene.boxes.append(VTBuild.tableBox(truth, SIMD3(s2.0 - 0.011, s2.1 - 0.011, top), SIMD3(s2.0 + 0.011, s2.1 + 0.011, top + 0.022), chalk))
                // Phone overhanging the cushion.
                scene.boxes.append(VTBuild.tableBox(truth, SIMD3(s1.0 - 0.075, W - 0.01, top), SIMD3(s1.0 + 0.075, W + 0.065, top + 0.008),
                                                    VTColor(0.04, 0.04, 0.05), hole: true))
                // Beer glass and a second phone.
                scene.boxes.append(VTBuild.tableBox(truth, SIMD3(s3.0 - 0.035, s3.1 - 0.035, top), SIMD3(s3.0 + 0.035, s3.1 + 0.035, top + 0.14),
                                                    VTColor(0.62, 0.45, 0.18), hole: true))
                scene.boxes.append(VTBuild.tableBox(truth, SIMD3(s4.0 - 0.037, s4.1 - 0.075, top), SIMD3(s4.0 + 0.037, s4.1 + 0.075, top + 0.008),
                                                    VTColor(0.85, 0.85, 0.88)))
            }
        }
        if cond.light == .cueShadow {
            // Shooter at the near end: cue over the cloth, forearm and torso under the lamps → hard shadows.
            // Camera end: endSign > 0 puts the camera beyond x = 0 (head), else beyond x = L.
            let atHead = endSign > 0
            let xNear = atHead ? L * 0.15 : L * 0.85
            let a = rng.uniform(-0.25, 0.25)
            var cue = VTBuild.tableBox(truth, SIMD3(xNear - 0.72, W / 2 - 0.012, 0.07), SIMD3(xNear + 0.72, W / 2 + 0.012, 0.095),
                                       VTColor(0.55, 0.40, 0.22), extraYaw: a)
            cue.castsShadow = true
            scene.boxes.append(cue)
            // Torso leaning over the head rail.
            let xb = atHead ? 0.0 : L
            var torso = VTBuild.tableBox(truth, SIMD3(xb - 0.22, W / 2 - 0.25, 0.30), SIMD3(xb + 0.22, W / 2 + 0.25, 0.70),
                                         VTColor(0.08, 0.08, 0.1))
            torso.castsShadow = true
            scene.boxes.append(torso)
            var arm = VTBuild.tableBox(truth, SIMD3(min(xb, xNear), W / 2 + 0.05, 0.2), SIMD3(max(xb, xNear), W / 2 + 0.13, 0.27),
                                       VTColor(0.8, 0.62, 0.5))
            arm.castsShadow = true
            scene.boxes.append(arm)
        }

        let fps = rng.pick(cond.fps)
        // iPhone wide camera, ARKit 1920×1440 (fx ≈ 1450 px ≈ 67° across the long side).
        let k = CameraIntrinsics(fx: rng.uniform(1440, 1470), fy: 0, cx: 960 + rng.uniform(-6, 6), cy: 720 + rng.uniform(-6, 6),
                                 width: 1920, height: 1440)
        var kk = k; kk.fy = kk.fx
        return VTSetup(condition: cond, seed: seed, scene: scene, truth: truth, trajectory: traj, planeTruths: planes,
                       fps: fps, timestampBase: 1000 + rng.uniform(0, 5000), trackingReady: rng.uniform(0.5, 1.0),
                       intrinsics: kk)
    }

    static func lighting(_ l: VTLight, truth: VTTableTruth, rng: inout VTRandom) -> VTLighting {
        let even = VTLighting(ambient: VTColor(repeating: 0.55), sunDir: simd_normalize(SIMD3(0.2, -1, 0.1)),
                              sunColor: VTColor(repeating: 0.5))
        func lamps(_ color: VTColor = VTColor(1, 0.95, 0.85)) -> [VTLamp] {
            let L = truth.spec.length, W = truth.spec.width
            return [0.25, 0.5, 0.75].map { f in
                VTLamp(position: truth.world(L * f, W / 2, 0.95), color: color, power: rng.uniform(0.75, 1.0), coneCos: 0.72)
            }
        }
        switch l {
        case .even: return even
        case .lamp:
            return VTLighting(ambient: VTColor(repeating: 0.10), sunDir: SIMD3(0, -1, 0), sunColor: VTColor(repeating: 0.04),
                              lamps: lamps(), noiseSigma: 4)
        case .dim:
            var d = even
            d.ambient *= 0.3; d.sunColor *= 0.3; d.noiseSigma = 9
            return d
        case .neon:
            let tint = rng.pick([VTColor(1, 0.35, 0.9), VTColor(0.4, 0.55, 1.0), VTColor(1, 0.45, 0.3)])
            var n = even
            n.ambient = tint * 0.55; n.sunColor = tint * 0.45; n.noiseSigma = 4
            return n
        case .cueShadow:
            return VTLighting(ambient: VTColor(repeating: 0.12), sunDir: SIMD3(0, -1, 0), sunColor: VTColor(repeating: 0.04),
                              lamps: lamps(), noiseSigma: 4, shadows: true)
        }
    }
}


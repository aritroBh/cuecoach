import CoreGraphics
import CoreText
import CoreVideo
import Foundation
import Geometry
import ImageIO
import simd
import UniformTypeIdentifiers
@testable import CueCoach

/// FrameTap's locating-mode gate (ARLiveView.swift `session(_:didUpdate:)`), as a value type:
/// skip while busy, run at most every `interval × 0.9`, only after a horizontal plane was added.
/// `lastRun` is updated before the tracking check, exactly like FrameTap.
struct VTFrameTapGate: Sendable {
    var interval = 0.2
    var lastRun = -Double.infinity
    var busyUntil = -Double.infinity

    mutating func offer(timestamp now: Double, planeFound: Bool) -> Bool {
        guard now >= busyUntil, now - lastRun >= interval * 0.9 else { return false }
        guard planeFound else { return false }
        lastRun = now
        return true
    }
}

@inline(__always) func vtThreadCPU() -> Double { Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1e9 }

/// `.app` = what the app ships: `AutoTableLocating` (TableLocating adapter) behind the production `LocatingGate`
/// (~15 Hz + busy, no plane requirement), fed LiDAR depth and ARKit planes. `.feltQuad`/`.auto` are references.
enum VTLocatorKind: String, Sendable, CaseIterable {
    case app = "AppLocator", feltQuad = "FeltQuadLocator", auto = "ClassicalAutoTableLocator"

    /// VQA_LOCATORS=app,feltQuad,auto (default: all).
    static var selected: [VTLocatorKind] {
        guard let v = ProcessInfo.processInfo.environment["VQA_LOCATORS"], !v.isEmpty else { return allCases }
        let names = v.split(separator: ",").map(String.init)
        return allCases.filter { k in names.contains { $0 == "\(k)" || $0 == k.rawValue } }
    }
}

struct VTRunResult: Sendable {
    var locator: VTLocatorKind
    var condition: String
    var axis: String
    var seed: UInt64
    var path: String
    var fps: Int
    var size: TableSize
    var elevationDeg: Double
    var portrait: Bool
    var locked = false
    var ttlStart: Double?
    var ttlPlane: Double?
    var firstPlane: Double?
    var cornerErr: Double?
    var yawErrDeg: Double?
    var sizeOK: Bool?
    var falseLock = false
    var falseKind: String?
    var reason: String?          // what the locator itself reported (nil = nothing)
    var simDiagnosis: String?    // what the harness found on the last frame (not visible to the app)
    var samples = 0              // frames the locator actually ran on
    var newSamples = 0           // frames that produced a new measurement (FeltQuad: passed its own 0.2 s throttle)
    var meanCPUms = 0.0
    var lastConfidence = 0.0
    var tableFullyInView = false

    var accurate: Bool { locked && !falseLock && (cornerErr ?? 1) <= 0.05 }
}

struct VTThumb: Sendable {
    var condition: String
    var rgb: [UInt8]   // 320×240
    var truth: [Vec2]  // thumb px
    var felt: [Vec2]?
    var auto: [Vec2]?
    var note: String
}

/// One frame as the app would hand it to a locator.
struct VTFrame: Sendable {
    var pixel: PixelImage
    var depth: AutoDepthMap
    var planes: [LocatorPlane]
    var camera: CameraModel
    var convertCPU: Double
}

enum VTHarness {
    static let window = Double(ProcessInfo.processInfo.environment["VQA_WINDOW"] ?? "") ?? 10

    /// Ground-truth max corner error (m) under the best one-to-one corner assignment.
    static func cornerError(_ est: [SIMD3<Double>], _ truth: [SIMD3<Double>]) -> Double {
        guard est.count == 4 else { return .infinity }
        var best = Double.infinity
        func perms(_ a: [Int]) -> [[Int]] {
            if a.count <= 1 { return [a] }
            return a.indices.flatMap { i -> [[Int]] in
                var r = a; let x = r.remove(at: i)
                return perms(r).map { [x] + $0 }
            }
        }
        for p in perms([0, 1, 2, 3]) {
            best = min(best, (0..<4).map { simd_distance(est[p[$0]], truth[$0]) }.max()!)
        }
        return best
    }

    static func yawError(_ axis: SIMD3<Double>, _ truth: SIMD3<Double>) -> Double {
        let a = atan2(axis.z, axis.x), b = atan2(truth.z, truth.x)
        var d = abs(a - b).truncatingRemainder(dividingBy: .pi)
        if d > .pi / 2 { d = .pi - d }
        return d * 180 / .pi
    }

    static func render(_ s: VTSetup, t: Double, index: Int, planes: [LocatorPlane]) -> VTFrame {
        let cam = s.camera(t)
        let r = VTRenderer(scene: s.scene.at(time: t), camera: cam)
        let rgb = r.renderRGB(seed: s.seed &* 100_003 &+ UInt64(index))
        let depth = r.renderDepth(seed: s.seed &* 7 &+ UInt64(index))
        let c0 = vtThreadCPU()
        var buf: [UInt8] = []
        let pb = VTImageIO.pixelBuffer(rgb: rgb, width: r.width, height: r.height)!
        let conv = PixelImage.convert(pb, maxWidth: 960, into: &buf)!
        // FrameTap point-samples the 1920×1440 capture at stride 2: working (x, y) = source (2x, 2y).
        let img = PixelImage(width: conv.width, height: conv.height, rgb: conv.rgb, scale: 2, sourceWidth: 1920, sourceHeight: 1440)
        return VTFrame(pixel: img, depth: depth, planes: planes, camera: cam, convertCPU: vtThreadCPU() - c0)
    }

    static func tableInView(_ s: VTSetup, t: Double) -> Bool {
        let cam = s.camera(t)
        return s.truth.corners.allSatisfy { p in
            guard let q = cam.project(p) else { return false }
            return q.x >= 0 && q.x < 1920 && q.y >= 0 && q.y < 1440
        }
    }

    /// Runs one locator over the session exactly like FrameTap + ARLiveController (lock → confirm → stop).
    static func run(_ s: VTSetup, kind: VTLocatorKind, cache: inout [Int: VTFrame], thumbAt: Double? = nil,
                    thumb: inout VTFrame?) async -> (VTRunResult, [SIMD3<Double>]?) {
        let traj = s.trajectory
        var res = VTRunResult(locator: kind, condition: s.condition.name, axis: s.condition.axis, seed: s.seed,
                              path: traj.kind.rawValue, fps: s.fps, size: s.truth.size, elevationDeg: s.elevationDeg,
                              portrait: traj.portrait)
        res.tableFullyInView = tableInView(s, t: 1.5)
        var planes = VTPlaneSim(truths: s.planeTruths, seed: s.seed ^ 0x51, trackingReady: s.trackingReady)
        var jitter = VTRandom(seed: s.seed ^ 0x77)
        var tsJitter = VTRandom(seed: s.seed ^ 0x99)
        var gate = VTFrameTapGate()
        let felt = FeltQuadLocator()
        let auto = ClassicalAutoTableLocator()
        let app = AutoTableLocating()
        var appGate = LocatingGate()
        var busyUntil = -Double.infinity
        var cpu = 0.0
        var lockedCorners: [SIMD3<Double>]?
        var lastFrame: VTFrame?
        var reasons: [String: Int] = [:]
        var lastEst: TableEstimate?
        var lastFeltCorners: [SIMD3<Double>]?
        let n = Int(window * Double(s.fps))
        for i in 0..<n {
            let t = Double(i) / Double(s.fps) + tsJitter.gauss() * 0.0004
            let ts = s.timestampBase + t
            if t >= s.trackingReady && t - planes.lastUpdate >= 0.1 {
                planes.update(t: t, renderer: VTRenderer(scene: s.scene.at(time: t), camera: s.camera(t)))
            }
            if kind == .app {
                guard appGate.offer(timestamp: ts, busy: ts < busyUntil) else { continue }
            } else {
                guard gate.offer(timestamp: ts, planeFound: planes.anyDetected(t)) else { continue }
            }
            guard t >= s.trackingReady else { continue }   // ARKit still initialising: FrameTap drops the frame
            if res.firstPlane == nil { res.firstPlane = t }
            let frame: VTFrame
            if let f = cache[i] { frame = f } else {
                frame = render(s, t: t, index: i, planes: planes.planes(t: t, jitter: &jitter))
                cache[i] = frame
            }
            lastFrame = frame
            if let ta = thumbAt, thumb == nil, t >= ta { thumb = frame }
            res.samples += 1
            let c0 = vtThreadCPU()
            var isLocked = false
            switch kind {
            case .feltQuad:
                let lf = LocatorFrame(image: frame.pixel, camera: frame.camera, planes: frame.planes, timestamp: ts)
                let before = lastFeltCorners
                let e = await felt.ingest(lf)
                lastEst = e
                if let e { res.lastConfidence = e.confidence }
                if e?.corners != before { res.newSamples += 1 }
                lastFeltCorners = e?.corners
                if let e, e.locked {
                    isLocked = true
                    lockedCorners = e.corners
                    res.sizeOK = e.size == s.truth.size
                    if let fit = TableFitter.fit(corners: e.corners) {
                        res.yawErrDeg = yawError(fit.frame.tableToWorld.columns.0.xyz, s.truth.xAxis)
                    }
                }
            case .app:
                let d = frame.depth
                let lf = LocatorFrame(image: frame.pixel, camera: frame.camera, planes: frame.planes, timestamp: ts,
                                      depth: DepthMap(width: d.width, height: d.height, depth: d.depth, confidence: d.confidence))
                let e = await app.ingest(lf)
                res.newSamples += 1
                if ProcessInfo.processInfo.environment["VQA_TRACE"] == "\(s.condition.name):\(s.seed)", let a = app.lastAutoEstimate {
                    let d = a.frame
                    let err = a.pose.map { cornerError($0.corners, s.truth.corners) * 100 }
                    print(String(format: "[trace] t %.2f %@/%@ path %@ L %.3f W %.3f snap %@ kp %d vis %@ rej %@ | fused %@ err %@ cm",
                                 t, "\(a.state)", e.map { $0.locked ? "LOCK" : ($0.failure?.rawValue ?? "conv") } ?? "nil", "\(d.path)",
                                 d.measuredLength ?? 0, d.measuredWidth ?? 0, "\(d.snappedSize.map { "\($0)" } ?? "-")",
                                 d.keypointsUsed, d.visibleLengthFraction.map { String(format: "%.2f", $0) } ?? "-", d.rejection ?? "-",
                                 a.pose.map { "\($0.snappedSize.map { "\($0)" } ?? "m") \(String(format: "%.3f", $0.spec.length))" } ?? "-",
                                 err.map { String(format: "%.1f", $0) } ?? "-"))
                }
                if let e {
                    res.lastConfidence = e.confidence
                    if let f = e.failure { reasons[f.rawValue, default: 0] += 1; res.reason = f.rawValue } else { res.reason = "converging" }
                    if e.locked {
                        isLocked = true
                        lockedCorners = e.corners
                        res.sizeOK = e.size == s.truth.size
                        if let fr = e.frame { res.yawErrDeg = yawError(fr.tableToWorld.columns.0.xyz, s.truth.xAxis) }
                    }
                }
            case .auto:
                let k = frame.camera.intrinsics
                let ai = AutoIntrinsics(fx: k.fx / 2, fy: k.fy / 2, cx: k.cx / 2, cy: k.cy / 2, width: 960, height: 720)
                let hint = LocatorMath.plane(for: Vec2(k.cx, k.cy), camera: frame.camera, planes: frame.planes)
                let af = AutoTableFrame(image: AutoRGBImage(width: frame.pixel.width, height: frame.pixel.height, rgb: frame.pixel.rgb),
                                        intrinsics: ai, cameraToWorld: frame.camera.cameraToWorld, depth: frame.depth,
                                        plane: hint.map { AutoPlaneHint(point: $0.point, normal: $0.normal) }, timestamp: ts)
                let e = auto.process(af)
                res.newSamples += 1
                res.lastConfidence = e.confidence
                if let r = e.frame.rejection { reasons[r, default: 0] += 1; res.reason = r } else if e.pose == nil {
                    res.reason = "searching"
                } else {
                    res.reason = e.cornerSpread.isFinite ? "converging spread \(Int((e.cornerSpread * 1000).rounded())) mm" : "converging"
                }
                if e.state == .locked, let p = e.pose {
                    isLocked = true
                    lockedCorners = p.corners
                    res.sizeOK = p.snappedSize == s.truth.size
                    res.yawErrDeg = yawError(p.xAxis, s.truth.xAxis)
                }
            }
            let used = vtThreadCPU() - c0 + frame.convertCPU
            cpu += used
            gate.busyUntil = ts + used
            busyUntil = ts + used
            if isLocked {
                res.locked = true
                res.ttlStart = t
                res.ttlPlane = t - (res.firstPlane ?? t)
                break
            }
        }
        res.meanCPUms = res.samples > 0 ? cpu / Double(res.samples) * 1000 : 0
        if let lc = lockedCorners {
            let err = cornerError(lc, s.truth.corners)
            res.cornerErr = err
            if err > 0.20 {
                res.falseLock = true
                let cen = lc.reduce(SIMD3<Double>(), +) / 4
                if s.scene.tables.count > 1, simd_distance(cen, s.scene.tables[1].center) < 0.6 {
                    res.falseKind = "second table"
                } else if abs(cen.y - s.truth.clothHeight) > 0.15 {
                    res.falseKind = "other surface (y \(String(format: "%.2f", cen.y)))"
                } else { res.falseKind = "wrong pose on this table" }
            }
            if kind == .feltQuad { res.reason = lastEst?.failure?.rawValue }
        } else {
            switch kind {
            case .feltQuad:
                // The app's real reason (TableEstimate.failure → glyph + dev HUD), plus the harness diagnosis.
                res.reason = lastEst?.failure?.rawValue
                res.simDiagnosis = diagnoseFelt(lastFrame, est: lastEst, setup: s)
            case .auto, .app:
                if let top = reasons.max(by: { $0.value < $1.value }) { res.simDiagnosis = "top rejection: \(top.key) ×\(top.value)" }
            }
        }
        return (res, lockedCorners)
    }

    /// Why FeltQuadLocator didn't lock on the last frame (harness-side; the app never learns this).
    static func diagnoseFelt(_ f: VTFrame?, est: TableEstimate?, setup s: VTSetup) -> String {
        guard let f else { return "no frame reached the locator (no plane / tracking)" }
        guard let quad = FeltQuadProposer.propose(f.pixel) else { return "proposer: no felt quad" }
        let centre = quad.reduce(Vec2.zero, +) / 4
        guard let plane = LocatorMath.plane(for: centre, camera: f.camera, planes: f.planes) else {
            return "no ARKit plane under quad centre (\(f.planes.count) planes)"
        }
        let outer = quad.compactMap { f.camera.intersect(pixel: $0, with: plane) }
        guard outer.count == 4 else { return "quad corner above horizon" }
        let inner = TableFitter.insetQuad(outer, by: SyntheticTableScene.cushionWidth)
        let err = cornerError(inner, s.truth.corners)
        switch CornerValidator.check(inner, viewer: f.camera.position) {
        case .ok(let fit)?:
            if !fit.sizing.confident { return "size not confident (err \(Int(fit.sizing.relativeError * 100))%, quad err \(Int(err * 100)) cm)" }
            if fit.residual >= 0.05 { return "residual \(Int(fit.residual * 100)) cm" }
            return "unstable: agreeing run too short (conf \(String(format: "%.2f", est?.confidence ?? 0)), quad err \(Int(err * 100)) cm)"
        case .outlier?, nil:
            let fit = TableFitter.fit(corners: inner)
            return "validator rejects shape (L \(String(format: "%.2f", fit?.measuredLength ?? 0)) m, W \(String(format: "%.2f", fit?.measuredWidth ?? 0)) m, quad err \(Int(err * 100)) cm)"
        }
    }

    // MARK: - Matrix

    static func runMatrix(conditions: [VTCondition], seeds: Int, outDir: URL) async -> [VTRunResult] {
        struct Job: Sendable { var cond: VTCondition; var seed: UInt64 }
        let jobs = conditions.flatMap { c in (0..<seeds).map { Job(cond: c, seed: UInt64($0)) } }
        let limit = max(2, ProcessInfo.processInfo.activeProcessorCount)
        var results: [VTRunResult] = []
        var thumbs: [VTThumb] = []
        await withTaskGroup(of: ([VTRunResult], VTThumb?).self) { g in
            var it = jobs.makeIterator()
            func addNext() -> Bool {
                guard let j = it.next() else { return false }
                g.addTask {
                    let s = VTSetup.make(j.cond, seed: j.seed)
                    var cache: [Int: VTFrame] = [:]
                    var th: VTFrame?
                    var none: VTFrame?
                    var out: [VTRunResult] = []
                    var fc: [SIMD3<Double>]?, ac: [SIMD3<Double>]?
                    for k in VTLocatorKind.selected {
                        let (r, c) = k == VTLocatorKind.selected.first
                            ? await run(s, kind: k, cache: &cache, thumbAt: j.seed == 0 ? 1.5 : nil, thumb: &th)
                            : await run(s, kind: k, cache: &cache, thumb: &none)
                        out.append(r)
                        if k == .feltQuad { fc = c } else if k == .app || (k == .auto && ac == nil) { ac = c }
                    }
                    var thumb: VTThumb?
                    if let f = th { thumb = makeThumb(s, frame: f, felt: fc, auto: ac, results: out) }
                    return (out, thumb)
                }
                return true
            }
            for _ in 0..<limit { if !addNext() { break } }
            var done = 0
            while let (r, t) = await g.next() {
                results += r
                if let t { thumbs.append(t) }
                done += 1
                if done % 25 == 0 { print("[virtual-qa] \(done)/\(jobs.count) sessions") }
                _ = addNext()
            }
        }
        let order = Dictionary(uniqueKeysWithValues: conditions.enumerated().map { ($1.name, $0) })
        thumbs.sort { (order[$0.condition] ?? 0) < (order[$1.condition] ?? 0) }
        writeReports(results, conditions: conditions, outDir: outDir)
        writeContactSheet(thumbs, to: outDir.appendingPathComponent("frames/contact-sheet.png"))
        return results
    }

    static func makeThumb(_ s: VTSetup, frame: VTFrame, felt: [SIMD3<Double>]?, auto: [SIMD3<Double>]?, results: [VTRunResult]) -> VTThumb {
        let tw = 320, th = 240
        var small = [UInt8](repeating: 0, count: tw * th * 3)
        for y in 0..<th { for x in 0..<tw {
            for c in 0..<3 {
                var acc = 0
                for dy in 0..<3 { for dx in 0..<3 { acc += Int(frame.pixel.rgb[((y * 3 + dy) * 960 + x * 3 + dx) * 3 + c]) } }
                small[(y * tw + x) * 3 + c] = UInt8(acc / 9)
            }
        } }
        func proj(_ pts: [SIMD3<Double>]?) -> [Vec2]? {
            guard let pts else { return nil }
            let q = pts.compactMap { frame.camera.project($0) }.map { Vec2($0.x / 6, $0.y / 6) }
            return q.count == 4 ? q : nil
        }
        let note = results.map { r in
            let tag = r.locator == .feltQuad ? "FQ" : "AT"
            return r.locked ? "\(tag) \(String(format: "%.1fs %.0fcm", r.ttlStart ?? 0, (r.cornerErr ?? 0) * 100))" : "\(tag) –"
        }.joined(separator: "  ")
        return VTThumb(condition: s.condition.name, rgb: small, truth: proj(s.truth.corners) ?? [], felt: proj(felt), auto: proj(auto),
                       note: note)
    }

    // MARK: - Reports

    struct Row {
        var condition: String, axis: String, locator: VTLocatorKind
        var n = 0, locked = 0, accurate = 0, falseLocks = 0, reasonReported = 0, failures = 0, sizeOK = 0
        var ttl: [Double] = [], ttlPlane: [Double] = [], err: [Double] = [], yaw: [Double] = [], cpu: [Double] = []
        var reasons: [String: Int] = [:], diags: [String: Int] = [:], falseKinds: [String: Int] = [:]
        var inView = 0
    }

    static func pct(_ a: Int, _ n: Int) -> Double { n > 0 ? Double(a) / Double(n) * 100 : 0 }
    static func median(_ v: [Double]) -> Double? { v.isEmpty ? nil : v.sorted()[v.count / 2] }
    static func p90(_ v: [Double]) -> Double? { v.isEmpty ? nil : v.sorted()[min(v.count - 1, Int(Double(v.count) * 0.9))] }
    static func f(_ v: Double?, _ fmt: String = "%.2f") -> String { v.map { String(format: fmt, $0) } ?? "–" }

    static func rows(_ results: [VTRunResult], conditions: [VTCondition]) -> [Row] {
        var out: [Row] = []
        for c in conditions {
            for k in VTLocatorKind.allCases {
                var r = Row(condition: c.name, axis: c.axis, locator: k)
                for x in results where x.condition == c.name && x.locator == k {
                    r.n += 1
                    if x.tableFullyInView { r.inView += 1 }
                    if x.locked { r.locked += 1; r.cpu.append(x.meanCPUms) } else { r.cpu.append(x.meanCPUms) }
                    if x.accurate {
                        r.accurate += 1
                        if let t = x.ttlStart { r.ttl.append(t) }
                        if let t = x.ttlPlane { r.ttlPlane.append(t) }
                    }
                    if x.locked, !x.falseLock { if let e = x.cornerErr { r.err.append(e * 100) }; if let y = x.yawErrDeg { r.yaw.append(y) } }
                    if x.locked, x.sizeOK == true { r.sizeOK += 1 }
                    if x.falseLock { r.falseLocks += 1; r.falseKinds[x.falseKind ?? "?", default: 0] += 1 }
                    if !x.accurate {
                        r.failures += 1
                        if !x.locked {
                            if let reason = x.reason { r.reasonReported += 1; r.reasons[reason.hasPrefix("converging") ? "converging (spread > lock)" : reason, default: 0] += 1 }
                            if let d = x.simDiagnosis { r.diags[String(d.prefix(40)), default: 0] += 1 }
                        }
                    }
                }
                out.append(r)
            }
        }
        return out
    }

    static func writeReports(_ results: [VTRunResult], conditions: [VTCondition], outDir: URL) {
        try? FileManager.default.createDirectory(at: outDir.appendingPathComponent("frames"), withIntermediateDirectories: true)
        let rs = rows(results, conditions: conditions)
        var csv = "condition,axis,locator,n,lock_pct,accurate_lock_pct,false_lock_pct,ttl_median_s,ttl_p90_s,ttl_from_plane_median_s,corner_err_median_cm,corner_err_p90_cm,yaw_err_median_deg,size_ok_pct_of_locks,failure_reason_reported_pct,top_failure,mean_cpu_ms,table_fully_in_view_pct\n"
        var md = "# Virtual table lock matrix\n\n"
        md += "Generated \(ISO8601DateFormatter().string(from: Date())) by `CueCoachTests/VirtualTable` (branch wt/virtual-qa). "
        md += "\(results.count / 2) simulated sessions × 2 locators, \(Int(window)) s window each, fed through a replica of FrameTap's locating gate "
        md += "(0.2 s × 0.9 interval, busy flag = measured thread-CPU of convert + ingest, plane-found + tracking gating) at 30/60 fps ARKit timestamps.\n\n"
        md += "- **accurate** = locked with max corner error ≤ 5 cm. **false** = locked with max corner error > 20 cm (wrong surface / wrong pose).\n"
        md += "- **TTL** = seconds from session start (camera on) to lock, accurate locks only; *from plane* = from the first frame FrameTap handed to the locator.\n"
        md += "- **reason** = % of non-locking sessions where the locator's own output carried a failure reason (FeltQuad's `TableEstimate` has no field for one).\n"
        md += "- **in view** = % of sessions whose 4 cloth corners were all inside the frame at t = 1.5 s.\n\n"
        md += "| condition | locator | n | lock % | accurate % | false % | TTL med (s) | TTL p90 | from plane | err med (cm) | yaw med (°) | size ok | reason % | top failure | cpu ms | in view |\n"
        md += "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|\n"
        for r in rs {
            let top = (r.locator == .feltQuad ? r.diags : r.reasons).max { $0.value < $1.value }.map { "\($0.key) ×\($0.value)" } ?? ""
            let fk = r.falseKinds.map { "\($0.key) ×\($0.value)" }.joined(separator: "; ")
            let topAll = [top, fk.isEmpty ? "" : "FALSE: " + fk].filter { !$0.isEmpty }.joined(separator: " / ")
            let lp = pct(r.locked, r.n), ap = pct(r.accurate, r.n), fp = pct(r.falseLocks, r.n)
            let rp = r.failures > 0 ? pct(r.reasonReported, r.failures) : 100
            let sz = r.locked > 0 ? pct(r.sizeOK, r.locked) : 0
            md += "| \(r.condition) | \(r.locator == .feltQuad ? "FeltQuad" : "Auto") | \(r.n) | \(Int(lp)) | \(Int(ap)) | \(Int(fp)) | \(f(median(r.ttl))) | \(f(p90(r.ttl))) | \(f(median(r.ttlPlane))) | \(f(median(r.err), "%.1f")) | \(f(median(r.yaw), "%.1f")) | \(Int(sz))% | \(Int(rp)) | \(topAll) | \(f(median(r.cpu), "%.0f")) | \(Int(pct(r.inView, r.n))) |\n"
            csv += [r.condition, r.axis, r.locator.rawValue, "\(r.n)", f(lp, "%.1f"), f(ap, "%.1f"), f(fp, "%.1f"), f(median(r.ttl)), f(p90(r.ttl)),
                    f(median(r.ttlPlane)), f(median(r.err), "%.1f"), f(p90(r.err), "%.1f"), f(median(r.yaw), "%.2f"), f(sz, "%.0f"), f(rp, "%.0f"),
                    "\"\(topAll.replacingOccurrences(of: "\"", with: "'"))\"", f(median(r.cpu), "%.1f"), f(pct(r.inView, r.n), "%.0f")].joined(separator: ",") + "\n"
        }
        var runs = "locator,condition,seed,path,fps,size,elevation_deg,portrait,locked,accurate,false_lock,false_kind,ttl_s,ttl_from_plane_s,first_plane_s,corner_err_cm,yaw_err_deg,size_ok,samples,new_samples,mean_cpu_ms,last_conf,reason,sim_diagnosis,table_in_view\n"
        for x in results {
            runs += [x.locator.rawValue, x.condition, "\(x.seed)", x.path, "\(x.fps)", "\(x.size)", f(x.elevationDeg, "%.1f"), "\(x.portrait)",
                     "\(x.locked)", "\(x.accurate)", "\(x.falseLock)", x.falseKind ?? "", f(x.ttlStart), f(x.ttlPlane), f(x.firstPlane),
                     f(x.cornerErr.map { $0 * 100 }, "%.1f"), f(x.yawErrDeg), x.sizeOK.map { "\($0)" } ?? "", "\(x.samples)", "\(x.newSamples)",
                     f(x.meanCPUms, "%.1f"), f(x.lastConfidence), "\"\(x.reason ?? "")\"", "\"\(x.simDiagnosis ?? "")\"", "\(x.tableFullyInView)"]
                .joined(separator: ",") + "\n"
        }
        try? md.write(to: outDir.appendingPathComponent("lock-matrix.md"), atomically: true, encoding: .utf8)
        try? csv.write(to: outDir.appendingPathComponent("lock-matrix.csv"), atomically: true, encoding: .utf8)
        try? runs.write(to: outDir.appendingPathComponent("lock-runs.csv"), atomically: true, encoding: .utf8)
    }

    static func writeContactSheet(_ thumbs: [VTThumb], to url: URL) {
        guard !thumbs.isEmpty else { return }
        let tw = 320, th = 240, label = 34, cols = 5
        let rowsN = (thumbs.count + cols - 1) / cols
        let W = cols * tw, H = rowsN * (th + label)
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.setFillColor(CGColor(red: 0.08, green: 0.08, blue: 0.09, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        for (i, t) in thumbs.enumerated() {
            let ox = (i % cols) * tw, oyTop = (i / cols) * (th + label)
            guard let img = VTImageIO.cgImage(rgb: t.rgb, width: tw, height: th) else { continue }
            // CG origin is bottom-left.
            let rect = CGRect(x: ox, y: H - oyTop - th, width: tw, height: th)
            ctx.draw(img, in: rect)
            func poly(_ q: [Vec2]?, _ c: CGColor, _ w: CGFloat) {
                guard let q, q.count == 4 else { return }
                ctx.setStrokeColor(c); ctx.setLineWidth(w)
                ctx.beginPath()
                for (j, p) in q.enumerated() {
                    let pt = CGPoint(x: Double(ox) + p.x, y: Double(H - oyTop) - p.y)
                    if j == 0 { ctx.move(to: pt) } else { ctx.addLine(to: pt) }
                }
                ctx.closePath(); ctx.strokePath()
            }
            ctx.saveGState(); ctx.clip(to: rect)
            poly(t.truth, CGColor(red: 0, green: 1, blue: 1, alpha: 0.9), 1)
            poly(t.felt, CGColor(red: 1, green: 0.85, blue: 0, alpha: 1), 2)
            poly(t.auto, CGColor(red: 1, green: 0.2, blue: 0.9, alpha: 1), 2)
            ctx.restoreGState()
            func text(_ s: String, _ y: Int, _ size: CGFloat) {
                let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
                let attr = NSAttributedString(string: s, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font,
                                                                       NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 1, green: 1, blue: 1, alpha: 1)])
                let line = CTLineCreateWithAttributedString(attr)
                ctx.textPosition = CGPoint(x: ox + 4, y: H - oyTop - th - y)
                CTLineDraw(line, ctx)
            }
            text(t.condition, 14, 12)
            text(t.note, 29, 10)
        }
        guard let out = ctx.makeImage() else { return }
        writePNG(out, to: url)
    }

    static func writePNG(_ img: CGImage, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(d, img, nil)
        CGImageDestinationFinalize(d)
    }
}

extension SIMD4 where Scalar == Double {
    var xyz: SIMD3<Double> { SIMD3(x, y, z) }
}

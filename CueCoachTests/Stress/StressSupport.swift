import CoreGraphics
import Foundation
import Geometry
import Physics
import simd
import Testing
@testable import CueCoach

/// Shared helpers for the adversarial stress suite. Everything here is test-only.
enum Stress {
    static let spec = TableSpec(size: .sevenFoot)
    static let R = TableSpec.ballRadius
    static let dt = 1.0 / 30

    static func det(_ p: Vec2, _ k: BallKind = .solid, _ n: Int? = nil, conf: Double = 1) -> BallDetection {
        BallDetection(imagePoint: .zero, tablePoint: p, radiusPx: 10, confidence: conf, kind: k, tentativeNumber: n)
    }

    /// Grep-able measurement line in the xcodebuild log.
    static func metric(_ name: String, _ value: Any) {
        let line = "STRESS-METRIC \(name)=\(value)"
        print(line)
        // Also append to a host-side log when STRESS_LOG is set (survives a crashed test process).
        if let path = ProcessInfo.processInfo.environment["SIMCTL_CHILD_STRESS_LOG"] ?? ProcessInfo.processInfo.environment["STRESS_LOG"],
           let data = (line + "\n").data(using: .utf8) {
            if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
            if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(data); try? h.close() }
        }
    }

    /// Element counts of every collection-valued stored property (one level, plus one level inside optionals).
    static func collectionSizes(_ v: Any) -> [String: Int] {
        var out: [String: Int] = [:]
        func isColl(_ m: Mirror) -> Bool { m.displayStyle == .collection || m.displayStyle == .dictionary || m.displayStyle == .set }
        for c in Mirror(reflecting: v).children {
            guard let label = c.label else { continue }
            let m = Mirror(reflecting: c.value)
            if isColl(m) { out[label] = m.children.count }
            if m.displayStyle == .optional, let inner = m.children.first {
                for cc in Mirror(reflecting: inner.value).children {
                    guard let l = cc.label else { continue }
                    let mm = Mirror(reflecting: cc.value)
                    if isColl(mm) { out["\(label).\(l)"] = mm.children.count }
                }
            }
        }
        return out
    }

    /// 15-ball triangle, apex on the foot spot, rows growing toward the foot rail (+x).
    static func rack(spec: TableSpec = spec, gap: Double = 0.0003) -> [Vec2] {
        let apex = spec.footSpot
        let d = 2 * R + gap
        var out: [Vec2] = []
        for row in 0..<5 {
            for k in 0...row {
                out.append(apex + Vec2(Double(row) * d * 3.0.squareRoot() / 2, (Double(k) - Double(row) / 2) * d))
            }
        }
        return out
    }

    /// Standard rack numbering: 1 at the apex, 8 in the middle of row 3.
    static let rackNumbers = [1, 9, 2, 10, 8, 3, 11, 4, 12, 5, 13, 6, 14, 7, 15]

    static func kind(for n: Int) -> BallKind { n == 0 ? .cue : n == 8 ? .eight : n < 8 ? .solid : .stripe }

    // MARK: Ground-truth physics

    struct Frame { var t: Double; var balls: [BallID: Vec2] }

    /// Simulate a stroke and sample it at `fps`, starting `phase` seconds after the stroke; `tail` s after the trace ends.
    static func simulate(_ balls: [BallID: Vec2], stroke: Stroke, fps: Double = 30, phase: Double = 0.013,
                         tail: Double = 1.0) -> (trace: ShotTrace, frames: [Frame]) {
        let state = TableState(spec: spec, balls: balls.mapValues { BallState(position: $0) })
        let tr = Simulator().simulate(state, stroke: stroke)
        var frames: [Frame] = []
        var t = phase
        while t < tr.duration + tail {
            let s = tr.state(at: t)
            let onTable = s.balls.filter { $0.value.motion != .pocketed }.mapValues(\.position)
            frames.append(Frame(t: t, balls: onTable))
            t += 1 / fps
        }
        return (tr, frames)
    }

    /// What a detector would emit for the true positions: gaussian noise, nothing inside 6 cm of a pocket
    /// (ClassicalBallDetector drops those), optional drop-out region.
    static func detections(_ balls: [BallID: Vec2], noise: Double, rng: inout SplitMix,
                           hidden: (Vec2) -> Bool = { _ in false }) -> [BallDetection] {
        balls.keys.sorted().compactMap { id in
            let p = balls[id]!
            if spec.pockets.contains(where: { p.distance(to: spec.pocketCenter($0)) < 0.06 }) { return nil }
            if hidden(p) { return nil }
            let q = p + Vec2(rng.gauss() * noise, rng.gauss() * noise)
            return det(q, kind(for: id.number), id.number)
        }
    }

    /// Identity bookkeeping: for each truth ball, which track sits on it each frame.
    struct IDLedger {
        var seen: [BallID: [Int]] = [:]        // distinct track ids per truth ball, in order
        var owner: [Int: BallID] = [:]          // first truth ball a track id was seen on
        var swaps = 0                           // a track id moved from one truth ball to another
        var changes = 0                         // a truth ball's track id changed
        var ballFrames = 0
        var lostFrames = 0                      // truth ball visible but no confirmed track within 4 cm

        mutating func observe(truth: [BallID: Vec2], tracks: [TrackedBall]) {
            let confirmed = tracks.filter(\.confirmed)
            for (id, p) in truth {
                ballFrames += 1
                guard let tr = confirmed.min(by: { $0.position.distance(to: p) < $1.position.distance(to: p) }),
                      tr.position.distance(to: p) < 0.04 else { lostFrames += 1; continue }
                if let o = owner[tr.id], o != id { swaps += 1 }
                if owner[tr.id] == nil { owner[tr.id] = id }
                if let last = seen[id]?.last, last != tr.id { changes += 1 }
                if seen[id]?.last != tr.id { seen[id, default: []].append(tr.id) }
            }
        }
    }

    // MARK: Images

    static func image(_ scene: SyntheticTableScene, maxWidth: Int = 960) throws -> PixelImage {
        let cg = try #require(scene.render())
        return try #require(PixelImage(cgImage: cg, maxWidth: maxWidth))
    }

    /// Per-pixel colour transform (lighting changes).
    static func mapPixels(_ img: PixelImage, _ f: (Double, Double, Double) -> (Double, Double, Double)) -> PixelImage {
        var out = img.rgb
        for i in 0..<(img.width * img.height) {
            let (r, g, b) = f(Double(out[i * 3]), Double(out[i * 3 + 1]), Double(out[i * 3 + 2]))
            out[i * 3] = UInt8(max(0, min(255, r.rounded())))
            out[i * 3 + 1] = UInt8(max(0, min(255, g.rounded())))
            out[i * 3 + 2] = UInt8(max(0, min(255, b.rounded())))
        }
        return PixelImage(width: img.width, height: img.height, rgb: out, scale: img.scale,
                          sourceWidth: img.sourceWidth, sourceHeight: img.sourceHeight)
    }

    struct Paint { var poly: [Vec2]; var height: Double; var color: (UInt8, UInt8, UInt8); var alpha: Double = 1 }

    /// Render the scene, then paint extra table-space polygons over it (shadows, chalk, phones, glasses).
    static func render(_ scene: SyntheticTableScene, paints: [Paint]) throws -> CGImage {
        let base = try #require(scene.render())
        let W = base.width, H = base.height
        let ctx = try #require(CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: W, height: H))
        ctx.translateBy(x: 0, y: CGFloat(H)); ctx.scaleBy(x: 1, y: -1)
        for p in paints {
            let img = p.poly.compactMap { scene.camera.project(scene.frame.world($0, height: p.height)) }
            guard img.count == p.poly.count else { continue }
            let path = CGMutablePath()
            path.addLines(between: img.map { CGPoint(x: $0.x, y: $0.y) }); path.closeSubpath()
            ctx.addPath(path)
            ctx.setFillColor(CGColor(srgbRed: CGFloat(p.color.0) / 255, green: CGFloat(p.color.1) / 255,
                                     blue: CGFloat(p.color.2) / 255, alpha: CGFloat(p.alpha)))
            ctx.fillPath()
        }
        return try #require(ctx.makeImage())
    }

    static func disc(_ c: Vec2, _ r: Double, n: Int = 24) -> [Vec2] {
        (0..<n).map { c + Vec2(cos(Double($0) * 2 * .pi / Double(n)), sin(Double($0) * 2 * .pi / Double(n))) * r }
    }

    static func rect(_ c: Vec2, along u: Vec2, length: Double, width: Double) -> [Vec2] {
        let d = u.normalized, n = d.perpendicular
        return [c - d * (length / 2) - n * (width / 2), c + d * (length / 2) - n * (width / 2),
                c + d * (length / 2) + n * (width / 2), c - d * (length / 2) + n * (width / 2)]
    }

    /// Uniform felt-coloured working image matching the demo camera (cue-stick detector sees nothing).
    static func blankImage(source: CameraIntrinsics = SyntheticTableScene.demo().camera.intrinsics) -> PixelImage {
        let w = Int(source.width) / 10, h = Int(source.height) / 10
        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        for i in 0..<(w * h) { rgb[i * 3] = 24; rgb[i * 3 + 1] = 112; rgb[i * 3 + 2] = 74 }
        return PixelImage(width: w, height: h, rgb: rgb, scale: 10, sourceWidth: Int(source.width), sourceHeight: Int(source.height))
    }

    /// Resident memory footprint (bytes) of this process.
    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : 0
    }

    static func median(_ xs: [Double]) -> Double { let s = xs.sorted(); return s.isEmpty ? .nan : s[s.count / 2] }
    static func percentile(_ xs: [Double], _ p: Double) -> Double {
        let s = xs.sorted(); return s.isEmpty ? .nan : s[min(s.count - 1, Int(Double(s.count) * p))]
    }
}

/// A detector that replays scripted detections (pipeline harness without image cost).
final class ScriptedDetector: BallDetector, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [[BallDetection]] = []
    private var generator: (() -> [BallDetection])?

    init(_ frames: [[BallDetection]] = []) { queue = frames }

    func push(_ d: [BallDetection]) { lock.lock(); queue.append(d); lock.unlock() }
    func setGenerator(_ g: @escaping () -> [BallDetection]) { lock.lock(); generator = g; lock.unlock() }

    func detect(in image: PixelImage, geometry: FrameGeometry) -> [BallDetection] {
        lock.lock(); defer { lock.unlock() }
        if !queue.isEmpty { return queue.removeFirst() }
        return generator?() ?? []
    }
}

import CoreGraphics
import Foundation
import Geometry
import ImageIO
import simd
import Testing
@testable import CueCoach

/// D32 virtual-sim detector benchmark (opt-in). Runs the app's real detectors on the held-out 3D renders from
/// `tools/detector/bench_scenes.py` and dumps raw per-frame detections, timings and per-clip tracker output;
/// `tools/detector/bench_score.py` scores them against the ground truth.
///
///     TEST_RUNNER_CUECOACH_BENCH=v1 xcodebuild test … -only-testing:CueCoachTests/DetectorBenchTests
///
/// Frames go through the replay code path: JPEG → CGImage → `PixelImage(cgImage:)` (960 wide, point-sampled, as
/// the AR path samples `capturedImage`) → `detect(in:geometry:feltReference:timestamp:)`, then the pipeline's own
/// no-LiDAR shading filter when the detector asks for it. Clips also run through `PerceptionPipeline`.
@Suite(.serialized, .enabled(if: DetectorBench.benchName != nil))
struct DetectorBenchTests {
    @Test(arguments: DetectorBench.candidates)
    func run(_ candidate: String) async throws {
        let bench = try DetectorBench.load()
        var frames: [[String: Any]] = []
        let detector = DetectorBench.make(candidate)
        for f in bench.frames {
            let px = try DetectorBench.image(bench.dir.appendingPathComponent(f.file))
            let geo = FrameGeometry(frame: f.table, camera: f.camera)
            let t0 = DispatchTime.now().uptimeNanoseconds
            var dets = detector.detect(in: px, geometry: geo, feltReference: nil, timestamp: Double(f.index) / 30)
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
            let shading = detector.needsShadingCheck
            if shading { dets = DetectorBench.shadingFilter(dets, px) }
            frames.append(["file": f.file, "ms": ms, "classicalFrame": shading,
                           "detections": dets.map(DetectorBench.json)])
        }
        // Tracker level: each clip looped to 0.4 s at 30 Hz (3 hits confirm) through the app pipeline (fresh detector per clip).
        var clips: [[String: Any]] = []
        for (clip, list) in Dictionary(grouping: bench.frames, by: \.clip).sorted(by: { $0.key < $1.key }) {
            let p = PerceptionPipeline(detector: DetectorBench.make(candidate))
            await p.setTable(list[0].table)
            let images = try list.map { try DetectorBench.image(bench.dir.appendingPathComponent($0.file)) }
            var last: PerceptionResult?
            for i in 0..<12 {
                let k = i % list.count
                last = await p.process(PerceptionFrame(image: images[k], camera: list[k].camera, timestamp: Double(i) / 30))
            }
            let confirmed = last?.confirmed ?? []
            clips.append(["clip": clip, "lastFile": list[11 % list.count].file,
                          "tracks": confirmed.map { ["x": $0.position.x, "y": $0.position.y, "kind": $0.kind.rawValue,
                                                     "number": $0.tentativeNumber ?? -1] }])
        }
        let out: [String: Any] = ["candidate": candidate, "frames": frames, "clips": clips,
                                  "platform": DetectorBench.platform]
        let dir = bench.dir.appendingPathComponent("results")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: out).write(to: dir.appendingPathComponent("\(candidate).json"))
        let mean = frames.compactMap { $0["ms"] as? Double }.reduce(0, +) / Double(max(frames.count, 1))
        print("[bench] \(candidate): \(frames.count) frames, \(clips.count) clips, mean \(String(format: "%.1f", mean)) ms")
        #expect(frames.count == bench.frames.count)
    }
}

enum DetectorBench {
    /// `DetectorChoice` cases: classical, model (every frame), hybrid (≤ 30 Hz, classical between runs).
    static let candidates = DetectorChoice.allCases.map(\.rawValue)

    static var benchName: String? { ProcessInfo.processInfo.environment["CUECOACH_BENCH"] }

    static var platform: String {
        #if targetEnvironment(simulator)
        "simulator"
        #else
        "device"
        #endif
    }

    /// The app's own factory (`DetectorChoice.make`), so the benchmark scores exactly what the app would build.
    static func make(_ name: String) -> any BallDetector { (DetectorChoice(rawValue: name) ?? .hybrid).make() }

    /// The pipeline's no-LiDAR rule (PerceptionPipeline.process): white/unknown blobs need sphere shading.
    static func shadingFilter(_ dets: [BallDetection], _ img: PixelImage) -> [BallDetection] {
        dets.filter { d in
            d.kind != .cue && d.kind != .unknown
                || ClassicalBallDetector.hasBallShading(img, sourcePoint: d.imagePoint, radiusPx: d.radiusPx)
        }
    }

    static func json(_ d: BallDetection) -> [String: Any] {
        ["x": d.tablePoint.x, "y": d.tablePoint.y, "u": d.imagePoint.x, "v": d.imagePoint.y, "r": d.radiusPx,
         "conf": d.confidence, "kind": d.kind.rawValue, "number": d.tentativeNumber ?? -1]
    }

    struct Frame {
        var file: String
        var clip: Int
        var index: Int
        var table: TableFrame
        var camera: CameraModel
    }

    struct Bench {
        var dir: URL
        var frames: [Frame]
    }

    static func load() throws -> Bench {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dir = root.appendingPathComponent("tools/detector/data/bench/\(benchName ?? "v1")")
        let data = try Data(contentsOf: dir.appendingPathComponent("manifest.json"))
        let m = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rows = try #require(m["frames"] as? [[String: Any]])
        let frames = try rows.map { r -> Frame in
            let c = try #require(r["camera"] as? [String: Any])
            let cm = try #require(c["cameraToWorld"] as? [Double])
            func v(_ key: String) -> Double { (c[key] as? NSNumber)?.doubleValue ?? .nan }
            let k = CameraIntrinsics(fx: v("fx"), fy: v("fy"), cx: v("cx"), cy: v("cy"), width: v("width"), height: v("height"))
            let col = { (i: Int) in SIMD4(cm[i * 4], cm[i * 4 + 1], cm[i * 4 + 2], cm[i * 4 + 3]) }
            let cam = CameraModel(intrinsics: k, cameraToWorld: simd_double4x4(columns: (col(0), col(1), col(2), col(3))))
            let size = try #require(TableSize(rawValue: r["table"] as? String ?? ""))
            let table = TableFrame(tableToWorld: matrix_identity_double4x4, spec: TableSpec(size: size))
            return Frame(file: r["file"] as! String, clip: r["clip"] as! Int, index: r["frame"] as! Int, table: table, camera: cam)
        }
        return Bench(dir: dir, frames: frames)
    }

    static func image(_ url: URL) throws -> PixelImage {
        let src = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let cg = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
        return try #require(PixelImage(cgImage: cg))
    }
}

import CoreML
import CoreVideo
import Foundation
import Geometry
import Synchronization

/// Pure decoding of the trained ball detector's outputs (`BallDetector.mlpackage`, YOLO26n with embedded NMS,
/// wt/detector 1cbeaf1). `coordinates` is `[N, 4]` centre-x, centre-y, width, height relative to the 640×640
/// letterboxed input; `confidence` is `[N, 80]` (the Ultralytics NMS export pads the class axis to 80): only the
/// first 16 columns are classes (`BallDetector.json`: cue, 1…15).
enum BallDetectorOutput {
    static let classCount = 16
    static let inputSize = 640.0

    /// One detection in working-image pixels.
    struct Raw: Sendable, Equatable {
        var center: Vec2
        var radius: Double
        var cls: Int
        var score: Double
    }

    /// - confidence: row-major `count × columns`; coordinates: row-major `count × 4`.
    static func decode(confidence: [Float], columns: Int, coordinates: [Float], count: Int,
                       letterbox lb: AutoTableKeypointModel.Letterbox, minConfidence: Double) -> [Raw] {
        guard columns >= classCount, confidence.count >= count * columns, coordinates.count >= count * 4 else { return [] }
        var out: [Raw] = []
        for i in 0..<count {
            var best = -1
            var score: Float = 0
            for c in 0..<classCount where confidence[i * columns + c] > score { score = confidence[i * columns + c]; best = c }
            guard best >= 0, Double(score) >= minConfidence else { continue }
            let x = Double(coordinates[i * 4]) * inputSize, y = Double(coordinates[i * 4 + 1]) * inputSize
            let w = Double(coordinates[i * 4 + 2]) * inputSize, h = Double(coordinates[i * 4 + 3]) * inputSize
            let p = lb.toImage(SIMD2(x, y))
            out.append(Raw(center: Vec2(p.x, p.y), radius: (w + h) / 4 / lb.scale, cls: best, score: Double(score)))
        }
        return out
    }

    /// Class index → the tracker's coarse kind and the ball number (the model names the number outright).
    static func kind(forClass c: Int) -> (kind: BallKind, number: Int?) {
        switch c {
        case 0: (.cue, nil)
        case 8: (.eight, 8)
        case 1...7: (.solid, c)
        case 9...15: (.stripe, c)
        default: (.unknown, nil)
        }
    }

    /// Working-pixel detections → table detections: on the cloth, not in a pocket mouth, one per ball, ≤ 24.
    static func detections(_ raws: [Raw], image img: PixelImage, geometry geo: FrameGeometry) -> [BallDetection] {
        let spec = geo.spec, R = TableSpec.ballRadius
        let inv = geo.ballInverse
        var out: [BallDetection] = []
        for r in raws.sorted(by: { $0.score > $1.score }) {
            let (sx, sy) = img.toSource(r.center.x, r.center.y)
            guard let t = inv.apply(Vec2(sx, sy)),
                  t.x >= 0.6 * R, t.x <= spec.length - 0.6 * R, t.y >= 0.6 * R, t.y <= spec.width - 0.6 * R else { continue }
            let (kind, number) = kind(forClass: r.cls)
            // Same pocket rules as the classical detector: nothing in a mouth, no dark "ball" near one.
            let pocketDist = spec.pockets.map { t.distance(to: spec.pocketCenter($0)) - ($0.isSide ? 0.01 : 0) }.min() ?? 1
            if pocketDist < 0.06 { continue }
            if (kind == .eight || kind == .unknown) && pocketDist < 0.11 { continue }
            // Class-agnostic: two boxes on one ball keep the stronger.
            if out.contains(where: { $0.tablePoint.distance(to: t) < R }) { continue }
            out.append(BallDetection(imagePoint: Vec2(sx, sy), tablePoint: t, radiusPx: r.radius * img.scale,
                                     confidence: r.score, kind: kind, tentativeNumber: number))
            if out.count >= 24 { break }
        }
        return out
    }
}

/// A learned detector run: nil when it didn't run (not loaded, or failed).
protocol BallInference: Sendable {
    func infer(_ image: PixelImage) -> [BallDetectorOutput.Raw]?
}

/// The bundled YOLO26n ball detector on the Neural Engine (computeUnits .all). Called on the perception actor,
/// never the main actor. Trained on synthetic renders only: real-table accuracy is unmeasured.
final class CoreMLBallInference: BallInference, @unchecked Sendable {
    private let model: MLModel
    private let state = Mutex(0.0)
    var minConfidence = 0.35
    var iouThreshold = 0.6

    /// Loaded once; nil if the model is missing (the classical detector then runs alone).
    static let shared: CoreMLBallInference? = try? CoreMLBallInference()

    init(bundle: Bundle = .main) throws {
        guard let url = bundle.url(forResource: "BallDetector", withExtension: "mlmodelc") else { throw CocoaError(.fileNoSuchFile) }
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .all
        model = try MLModel(contentsOf: url, configuration: cfg)
    }

    /// Last inference time (ms) for the dev HUD.
    var lastInferenceMs: Double { state.withLock { $0 } }

    func infer(_ image: PixelImage) -> [BallDetectorOutput.Raw]? {
        guard image.width >= 8, image.height >= 8, image.rgb.count == image.width * image.height * 3 else { return nil }
        let lb = AutoTableKeypointModel.Letterbox(imageWidth: Double(image.width), imageHeight: Double(image.height),
                                                  inputSize: BallDetectorOutput.inputSize)
        guard let pb = CoreMLTableKeypointProvider.letterboxed(AutoRGBImage(width: image.width, height: image.height,
                                                                             rgb: image.rgb), lb) else { return nil }
        let t0 = CFAbsoluteTimeGetCurrent()
        guard let input = try? MLDictionaryFeatureProvider(dictionary: [
                  "image": MLFeatureValue(pixelBuffer: pb),
                  "iouThreshold": MLFeatureValue(double: iouThreshold),
                  "confidenceThreshold": MLFeatureValue(double: minConfidence)]),
              let out = try? model.prediction(from: input),
              let conf = out.featureValue(for: "confidence")?.multiArrayValue,
              let coords = out.featureValue(for: "coordinates")?.multiArrayValue else { return nil }
        state.withLock { $0 = (CFAbsoluteTimeGetCurrent() - t0) * 1000 }
        let n = conf.shape.first?.intValue ?? 0
        guard let (c, b) = Self.copyRows(confidence: conf, coordinates: coords) else { return nil }
        return BallDetectorOutput.decode(confidence: c, columns: BallDetectorOutput.classCount, coordinates: b, count: n, letterbox: lb,
                                         minConfidence: minConfidence)
    }

    /// The 16 real class columns (the rest is export padding) and the 4 box values per NMS row, read by stride
    /// (device outputs are padded). Nil when the shapes don't match the NMS pipeline.
    static func copyRows(confidence conf: MLMultiArray, coordinates coords: MLMultiArray) -> (conf: [Float], boxes: [Float])? {
        guard conf.shape.count == 2, coords.shape.count == 2 else { return nil }
        let n = conf.shape[0].intValue, k = BallDetectorOutput.classCount
        guard coords.shape[0].intValue == n, coords.shape[1].intValue >= 4, conf.shape[1].intValue >= k else { return nil }
        if n == 0 { return ([], []) }
        guard let c = StridedMultiArray.with(conf, { m in (0..<n * k).map { Float(m[$0 / k, $0 % k]) } }),
              let b = StridedMultiArray.with(coords, { m in (0..<n * 4).map { Float(m[$0 / 4, $0 % 4]) } }) else { return nil }
        return (c, b)
    }
}

/// The shipped detector: the trained model when it is due (≤ `minInterval` of frame time, like the table-keypoint
/// model's cadence) and runs; the classical v0 detector otherwise (model missing, failed, or between runs), so a
/// frame is never empty. The classical path's white balance and shading check stay as they were.
final class HybridBallDetector: BallDetector, @unchecked Sendable {
    let model: (any BallInference)?
    let classical: ClassicalBallDetector
    let minInterval: Double
    private let last = Mutex<Double?>(nil)

    init(model: (any BallInference)? = CoreMLBallInference.shared, classical: ClassicalBallDetector = ClassicalBallDetector(),
         minInterval: Double = 1.0 / 30) {
        self.model = model; self.classical = classical; self.minInterval = minInterval
    }

    /// Whether the last frame came from the classical detector (true until the model has produced a frame).
    private let lastClassical = Mutex(true)

    /// Only classical frames need the no-LiDAR shading check; a learned detector vouches for its own output
    /// (`BallDetector` contract). Read right after `detect` by the one pipeline that owns this detector.
    var needsShadingCheck: Bool { lastClassical.withLock { $0 } }

    func feltColor(in image: PixelImage, geometry: FrameGeometry) -> (UInt8, UInt8, UInt8)? {
        classical.feltColor(in: image, geometry: geometry)
    }

    func detect(in image: PixelImage, geometry: FrameGeometry) -> [BallDetection] {
        detect(in: image, geometry: geometry, feltReference: nil, timestamp: .nan)
    }

    func detect(in image: PixelImage, geometry: FrameGeometry, feltReference: (UInt8, UInt8, UInt8)?) -> [BallDetection] {
        detect(in: image, geometry: geometry, feltReference: feltReference, timestamp: .nan)
    }

    /// - timestamp: frame time; NaN = always due.
    func detect(in image: PixelImage, geometry: FrameGeometry, feltReference: (UInt8, UInt8, UInt8)?,
                timestamp t: Double) -> [BallDetection] {
        if let model, isDue(t), let raws = model.infer(image) {
            lastClassical.withLock { $0 = false }
            return BallDetectorOutput.detections(raws, image: image, geometry: geometry)
        }
        lastClassical.withLock { $0 = true }
        return classical.detect(in: image, geometry: geometry, feltReference: feltReference)
    }

    private func isDue(_ t: Double) -> Bool {
        guard t.isFinite else { return true }
        return last.withLock { l in
            // A timestamp going backwards is a new session or replay loop: run.
            if let p = l, t >= p, t - p < minInterval * 0.9 { return false }
            l = t
            return true
        }
    }
}

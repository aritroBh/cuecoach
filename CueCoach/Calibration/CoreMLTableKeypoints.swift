import CoreML
import CoreVideo
import Foundation
import Synchronization

/// tablekp YOLO26n-pose (`TableKeypoints.mlpackage`) as Auto's `TableKeypointProvider`.
/// Runs on the Neural Engine (computeUnits .all) on the locator's thread (never the main actor), throttled to
/// `minInterval`; frames in between get no keypoints and the classical path carries them.
/// Output `[1, 300, 36]`: per detection x1 y1 x2 y2 conf cls + 10 × (x, y, conf), in 640×640 model pixels.
final class CoreMLTableKeypointProvider: TableKeypointProvider, @unchecked Sendable {
    private let model: MLModel
    private let inputName: String
    private let outputName: String
    private let state = Mutex((last: -Double.infinity, inferenceMs: 0.0))
    /// Wall-clock backstop; the live cadence (≤ 10 Hz of frame time) is `MouthCountingProvider`'s.
    var minInterval = 0.0
    var minDetectionConfidence = 0.35

    /// The bundled model, loaded once (nil if missing — the locator then runs classical-only).
    static let shared: CoreMLTableKeypointProvider? = try? CoreMLTableKeypointProvider()

    init(bundle: Bundle = .main) throws {
        guard let url = bundle.url(forResource: "TableKeypoints", withExtension: "mlmodelc") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .all
        model = try MLModel(contentsOf: url, configuration: cfg)
        guard let i = model.modelDescription.inputDescriptionsByName.first(where: { $0.value.type == .image })?.key,
              let o = model.modelDescription.outputDescriptionsByName.first(where: { $0.value.type == .multiArray })?.key
        else { throw CocoaError(.coderInvalidValue) }
        inputName = i; outputName = o
    }

    /// Last inference time (ms) for the dev HUD.
    var lastInferenceMs: Double { state.withLock { $0.inferenceMs } }

    func keypoints(in image: AutoRGBImage, intrinsics: AutoIntrinsics) -> [AutoTableKeypoint] {
        let now = CFAbsoluteTimeGetCurrent()
        let due = state.withLock { s -> Bool in
            guard now - s.last >= minInterval else { return false }
            s.last = now
            return true
        }
        guard due else { return [] }
        let lb = AutoTableKeypointModel.Letterbox(imageWidth: Double(image.width), imageHeight: Double(image.height))
        guard let pb = Self.letterboxed(image, lb) else { return [] }
        let t0 = CFAbsoluteTimeGetCurrent()
        guard let input = try? MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(pixelBuffer: pb)]),
              let out = try? model.prediction(from: input),
              let arr = out.featureValue(for: outputName)?.multiArrayValue else { return [] }
        state.withLock { $0.inferenceMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000 }
        guard let rows = Self.bestRows(arr, minConfidence: minDetectionConfidence) else { return [] }
        return AutoTableKeypointModel.keypoints(rows: rows, letterbox: lb)
    }

    /// The highest-confidence detection's 10 keypoint rows (NMS-free head), or nil.
    static func bestRows(_ a: MLMultiArray, minConfidence: Double) -> [SIMD3<Double>]? {
        StridedMultiArray.with(a) { m -> [SIMD3<Double>]? in
            guard m.shape.count == 3, m.shape[0] >= 1, m.shape[2] >= 36 else { return nil }
            var best = -1, bestConf = minConfidence
            for i in 0..<m.shape[1] {
                let c = m[0, i, 4]
                if c > bestConf { bestConf = c; best = i }
            }
            guard best >= 0 else { return nil }
            return (0..<10).map { k in SIMD3(m[0, best, 6 + 3 * k], m[0, best, 7 + 3 * k], m[0, best, 8 + 3 * k]) }
        } ?? nil
    }

    /// Ultralytics letterbox into a 640×640 BGRA buffer (grey 114 padding), nearest-neighbour.
    static func letterboxed(_ img: AutoRGBImage, _ lb: AutoTableKeypointModel.Letterbox) -> CVPixelBuffer? {
        let size = Int(AutoTableKeypointModel.inputSize)
        var pb: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        guard CVPixelBufferCreate(nil, size, size, kCVPixelFormatType_32BGRA, attrs, &pb) == kCVReturnSuccess, let buf = pb
        else { return nil }
        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        guard let base = CVPixelBufferGetBaseAddress(buf) else { return nil }
        let rb = CVPixelBufferGetBytesPerRow(buf)
        let dst = base.assumingMemoryBound(to: UInt8.self)
        img.rgb.withUnsafeBufferPointer { src in
            for y in 0..<size {
                let row = dst + y * rb
                let sy = Int(((Double(y) - lb.padY + 0.5) / lb.scale - 0.5).rounded())
                for x in 0..<size {
                    let sx = Int(((Double(x) - lb.padX + 0.5) / lb.scale - 0.5).rounded())
                    let p = row + x * 4
                    if sx >= 0, sy >= 0, sx < img.width, sy < img.height {
                        let i = (sy * img.width + sx) * 3
                        p[0] = src[i + 2]; p[1] = src[i + 1]; p[2] = src[i]
                    } else {
                        p[0] = 114; p[1] = 114; p[2] = 114
                    }
                    p[3] = 255
                }
            }
        }
        return buf
    }
}

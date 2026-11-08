import Foundation
import CoreGraphics
import CoreML
import CoreVideo
import Vision

// D25: AuraFace-v1 face embedding (Apache-2.0 recognition graph only; see THIRD_PARTY_NOTICES.md).
// The model is fetched + converted on the developer's Mac by tools/faceid/fetch_auraface.sh into
// CueCoach/Resources/Models/FaceEmbedding.mlpackage (gitignored). Without it the app builds and runs with face off.

/// Core ML AuraFace on an *already aligned* 112×112 crop. Runs off the main actor, prefers the Neural Engine,
/// returns an L2-normalised 512-D vector.
struct FaceEmbeddingExtractor: EmbeddingExtracting {
    static let modelID = "fal.auraface.v1.fp16"
    static let resourceName = "FaceEmbedding"
    var modelID: String { Self.modelID }
    var isIdentityTrained: Bool { true }

    /// MLModel is thread-safe for predictions but not `Sendable`-annotated.
    final class Box: @unchecked Sendable {
        let model: MLModel
        let computeUnits: MLComputeUnits
        init(_ m: MLModel, _ u: MLComputeUnits) { model = m; computeUnits = u }
    }
    let box: Box

    /// The compiled model in the app bundle, or nil when it was never fetched.
    static func bundled(_ bundle: Bundle = .main, computeUnits: MLComputeUnits = .cpuAndNeuralEngine) -> FaceEmbeddingExtractor? {
        guard let url = bundle.url(forResource: resourceName, withExtension: "mlmodelc") else { return nil }
        return load(from: url, computeUnits: computeUnits)
    }

    static func load(from url: URL, computeUnits: MLComputeUnits = .cpuAndNeuralEngine) -> FaceEmbeddingExtractor? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let config = MLModelConfiguration()
        config.computeUnits = computeUnits
        guard let m = try? MLModel(contentsOf: url, configuration: config) else { return nil }
        return FaceEmbeddingExtractor(box: Box(m, computeUnits))
    }

    var computeUnitsDescription: String {
        switch box.computeUnits {
        case .cpuOnly: "cpu"
        case .cpuAndGPU: "cpu+gpu"
        case .cpuAndNeuralEngine: "cpu+ane"
        case .all: "all"
        @unknown default: "other"
        }
    }

    enum Failure: Error { case badInput, badOutput }

    func embedding(of image: CGImage) async throws -> Embedding {
        let input = try MLFeatureValue(cgImage: image, pixelsWide: FaceAlignment.size, pixelsHigh: FaceAlignment.size,
                                       pixelFormatType: kCVPixelFormatType_32BGRA, options: nil)
        let provider = try MLDictionaryFeatureProvider(dictionary: ["face": input])
        let out = try await box.model.prediction(from: provider)
        guard let arr = out.featureValue(for: "embedding")?.multiArrayValue else { throw Failure.badOutput }
        let v = Self.floats(arr)
        guard v.count == 512, let e = Embedding(modelID: modelID, vector: v).normalised else { throw Failure.badOutput }
        return e
    }

    static func floats(_ a: MLMultiArray) -> [Float] {
        (0..<a.count).map { a[$0].floatValue }
    }
}

/// One detected, gated and aligned face.
struct AlignedFace: @unchecked Sendable {
    var image: CGImage
    /// Vision normalised face box (origin lower-left).
    var box: CGRect
    var quality: Double
    var interOcularPixels: Double
}

/// Detect → 5-point landmarks → quality gate → similarity warp. Seam for tests.
protocol FaceCropping: Sendable {
    func faces(in image: CGImage) async -> [AlignedFace]
}

struct VisionFaceCropper: FaceCropping {
    var gate = FaceQualityGate.standard

    func faces(in image: CGImage) async -> [AlignedFace] {
        guard let found = try? await DetectFaceLandmarksRequest().perform(on: image), !found.isEmpty else { return [] }
        var q = DetectFaceCaptureQualityRequest()
        q.inputFaceObservations = found
        let scored = (try? await q.perform(on: image)) ?? []
        let size = CGSize(width: image.width, height: image.height)
        var out: [AlignedFace] = []
        for (i, f) in found.enumerated() {
            guard let lm = f.landmarks else { continue }
            func px(_ r: FaceObservation.Landmarks2D.Region) -> [CGPoint] { r.pointsInImageCoordinates(size, origin: .upperLeft) }
            guard let five = FaceLandmarks5(eyeA: px(lm.leftEye), eyeB: px(lm.rightEye), nose: px(lm.nose),
                                            outerLips: px(lm.outerLips)) else { continue }
            let quality = (i < scored.count ? scored[i] : f).captureQuality.map { Double($0.score) }
            guard gate.admits(interOcularPixels: five.interOcular, yawDegrees: f.yaw.converted(to: .degrees).value,
                              rollDegrees: f.roll.converted(to: .degrees).value, quality: quality),
                  let m = FaceAlignment.similarity(from: five.points, to: FaceAlignment.arcface112),
                  let crop = FaceAlignment.warp(image, transform: m) else { continue }
            out.append(AlignedFace(image: crop, box: f.boundingBox.cgRect, quality: quality ?? 0,
                                   interOcularPixels: five.interOcular))
        }
        return out
    }
}

/// Registration-side extractor: a whole selfie frame → its single gated face → aligned → AuraFace.
/// A frame with no admissible face, or with more than one (someone else in shot), throws and is skipped, so another
/// person's face is never enrolled as the owner's (r3 BLOCKER).
struct AlignedFaceExtractor: EmbeddingExtracting {
    var cropper: any FaceCropping = VisionFaceCropper()
    var embedder: FaceEmbeddingExtractor
    var modelID: String { embedder.modelID }
    var isIdentityTrained: Bool { true }

    enum Failure: Error, Equatable { case notExactlyOneFace }

    func embedding(of image: CGImage) async throws -> Embedding {
        let faces = await cropper.faces(in: image)
        guard faces.count == 1, let face = faces.first else { throw Failure.notExactlyOneFace }
        return try await embedder.embedding(of: face.image)
    }
}

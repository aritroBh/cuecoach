import Foundation
import simd

/// Adapter for the tablekp YOLO-pose model (tools/tablekp, `TableKeypoints.mlpackage`): turns its ten
/// (x, y, confidence) rows, in the 640×640 model-input pixels, into `AutoTableKeypoint`s in the frame image.
///
/// Index order (generate_dataset.py `KEYPOINT_NAMES`, export_coreml.py metadata `keypoint_order`):
/// 0–3 `corner_mouth_*` clockwise from the visually topmost corner, 4–5 `side_mouth_*` top to bottom,
/// 6–9 `nose_corner_*` in the same clockwise order. The groups carry no head/foot; the locator matches
/// each keypoint to the nearest model point of its kind.
enum AutoTableKeypointModel {
    static let keypointNames = [
        "corner_mouth_0", "corner_mouth_1", "corner_mouth_2", "corner_mouth_3",
        "side_mouth_0", "side_mouth_1",
        "nose_corner_0", "nose_corner_1", "nose_corner_2", "nose_corner_3",
    ]
    static let inputSize = 640.0

    /// Kind for a metadata keypoint name (`corner_mouth_2` → `.cornerMouth`); nil for an unknown name.
    static func kind(forName name: String) -> AutoKeypointKind? {
        if name.hasPrefix("corner_mouth_") { return .cornerMouth }
        if name.hasPrefix("side_mouth_") { return .sideMouth }
        if name.hasPrefix("nose_corner_") { return .noseCorner }
        return nil
    }

    /// Kinds by output index, from the exported metadata's names (nil if any name is unknown).
    static func kinds(names: [String] = keypointNames) -> [AutoKeypointKind]? {
        let k = names.compactMap(kind(forName:))
        return k.count == names.count ? k : nil
    }

    /// Ultralytics letterbox of an image into the square model input: uniform scale, centred padding.
    struct Letterbox: Sendable, Equatable {
        var scale: Double
        var padX: Double
        var padY: Double

        init(imageWidth: Double, imageHeight: Double, inputSize: Double = AutoTableKeypointModel.inputSize) {
            scale = min(inputSize / imageWidth, inputSize / imageHeight)
            padX = (inputSize - imageWidth * scale) / 2
            padY = (inputSize - imageHeight * scale) / 2
        }

        /// Model-input pixel → image pixel (both integer-centre convention).
        func toImage(_ p: SIMD2<Double>) -> SIMD2<Double> {
            SIMD2((p.x - padX + 0.5) / scale - 0.5, (p.y - padY + 0.5) / scale - 0.5)
        }

        /// Image pixel → model-input pixel.
        func toModel(_ p: SIMD2<Double>) -> SIMD2<Double> {
            SIMD2((p.x + 0.5) * scale + padX - 0.5, (p.y + 0.5) * scale + padY - 0.5)
        }
    }

    /// Converts one detection's rows (x, y, confidence in model-input pixels) into frame keypoints,
    /// dropping rows under `minConfidence`. Returns [] unless there is exactly one row per model keypoint.
    static func keypoints(rows: [SIMD3<Double>], letterbox: Letterbox, kinds: [AutoKeypointKind]? = kinds(),
                          minConfidence: Double = 0.3) -> [AutoTableKeypoint] {
        guard let kinds, rows.count == kinds.count else { return [] }
        return zip(rows, kinds).compactMap { r, k in
            guard r.z >= minConfidence else { return nil }
            return AutoTableKeypoint(kind: k, pixel: letterbox.toImage(SIMD2(r.x, r.y)), confidence: min(1, r.z))
        }
    }
}

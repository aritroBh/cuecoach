import Foundation
import CoreGraphics
import Vision

// Vision-backed implementations of the identity protocols. On-device only.

/// `GenerateImageFeaturePrintRequest` embedding. Generic (not identity-trained): fine for clothing,
/// a weak stand-in for faces until a licensed face model clears `LIC-ID` (research §6).
struct VisionFeaturePrintExtractor: EmbeddingExtracting {
    /// "face" or "body"; part of the model ID so face and body templates never cross.
    var kind: String
    var modelID: String { "apple.vision.featureprint.\(kind).r1" }

    func embedding(of image: CGImage) async throws -> Embedding {
        let obs = try await GenerateImageFeaturePrintRequest().perform(on: image)
        return Embedding(modelID: modelID, vector: Self.floats(obs.data, type: obs.elementType, count: obs.elementCount))
    }

    static func floats(_ data: Data, type: ElementType, count: Int) -> [Float] {
        data.withUnsafeBytes { raw in
            switch type {
            case .double: return raw.bindMemory(to: Double.self).prefix(count).map { Float($0) }
            default: return Array(raw.bindMemory(to: Float.self).prefix(count))
            }
        }
    }
}

/// People in a frame: 2D pose, a box from the joints, and (only when allowed) upper-body / face embeddings.
struct VisionPersonAnalyzer: PersonAnalyzing {
    var body = VisionFeaturePrintExtractor(kind: "body")
    var face = VisionFeaturePrintExtractor(kind: "face")
    var maxPeople = 4

    func people(in image: CGImage, wants: AnalysisWants) async throws -> [ObservedPerson] {
        let poses = try await DetectHumanBodyPoseRequest().perform(on: image)
        var out: [ObservedPerson] = []
        for pose in poses.prefix(maxPeople) {
            let joints = Self.joints(pose)
            guard let box = Self.box(joints) else { continue }
            var p = ObservedPerson(box: box, joints: joints)
            if wants.appearance, let crop = Self.crop(image, Self.upperBody(joints) ?? box) {
                p.appearance = try? await body.embedding(of: crop)
            }
            out.append(p)
        }
        // Only in a consented face check-in window (Q10); stroke-time identification never asks for faces.
        if wants.face, !out.isEmpty {
            let faces = ((try? await DetectFaceRectanglesRequest().perform(on: image)) ?? []).map { $0.boundingBox.cgRect }
            for (fi, pi) in Self.assignFaces(faces, to: out) {
                guard let crop = Self.crop(image, faces[fi]) else { continue }
                out[pi].face = try? await face.embedding(of: crop)
            }
        }
        return out
    }

    /// Face index → person index, one-to-one. A face is a candidate for every person whose (inflated) box holds
    /// its centre; pairs are taken nearest-head-first, so overlapping players never swap or lose faces.
    static func assignFaces(_ faces: [CGRect], to people: [ObservedPerson]) -> [Int: Int] {
        var pairs: [(face: Int, person: Int, d: Double)] = []
        for (fi, r) in faces.enumerated() {
            let c = CGPoint(x: r.midX, y: r.midY)
            for (pi, p) in people.enumerated() where p.box.insetBy(dx: -0.05, dy: -0.05).contains(c) {
                let head = p.joints.points[.neck] ?? CGPoint(x: p.box.midX, y: p.box.maxY)
                pairs.append((fi, pi, ShootingPose.distance(c, head)))
            }
        }
        pairs.sort { $0.d != $1.d ? $0.d < $1.d : ($0.face, $0.person) < ($1.face, $1.person) }
        var out: [Int: Int] = [:], taken = Set<Int>()
        for p in pairs where out[p.face] == nil && !taken.contains(p.person) {
            out[p.face] = p.person; taken.insert(p.person)
        }
        return out
    }

    static let names: [HumanBodyPoseObservation.JointName: BodyJoints.Name] = [
        .neck: .neck, .root: .root, .leftWrist: .leftWrist, .rightWrist: .rightWrist, .leftElbow: .leftElbow,
        .rightElbow: .rightElbow, .leftShoulder: .leftShoulder, .rightShoulder: .rightShoulder,
    ]

    static func joints(_ pose: HumanBodyPoseObservation, minConfidence: Float = 0.3) -> BodyJoints {
        var pts: [BodyJoints.Name: CGPoint] = [:]
        for (vn, mine) in names {
            if let j = pose.joint(for: vn), j.confidence >= minConfidence { pts[mine] = j.location.cgPoint }
        }
        return BodyJoints(points: pts)
    }

    static func box(_ j: BodyJoints) -> CGRect? {
        let pts = Array(j.points.values)
        guard pts.count >= 2 else { return nil }
        let xs = pts.map(\.x), ys = pts.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            .insetBy(dx: -0.03, dy: -0.03)
    }

    /// Shoulders → hips region (the shirt).
    static func upperBody(_ j: BodyJoints) -> CGRect? {
        let pts = [j.points[.leftShoulder], j.points[.rightShoulder], j.points[.neck], j.points[.root]].compactMap { $0 }
        guard pts.count >= 3 else { return nil }
        let xs = pts.map(\.x), ys = pts.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            .insetBy(dx: -0.02, dy: -0.02)
    }

    /// Normalised lower-left rect → pixel crop (CGImage is top-left).
    static func crop(_ image: CGImage, _ r: CGRect) -> CGImage? {
        let clipped = r.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return nil }
        let px = NormalizedRect(normalizedRect: clipped)
            .toImageCoordinates(CGSize(width: image.width, height: image.height), origin: .upperLeft).integral
        guard px.width >= 8, px.height >= 8 else { return nil }
        return image.cropping(to: px)
    }
}

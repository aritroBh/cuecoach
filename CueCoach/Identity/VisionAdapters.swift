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

/// Face crop handed to the face embedder. Box-only today; a 5-point aligner (ArcFace-style 112×112 template) for an
/// identity-trained model drops in here without touching attribution (face-embedding.md F4).
protocol FaceAligning: Sendable {
    func aligned(_ image: CGImage, face: CGRect) -> CGImage?
}

/// Square crop around the face box with a margin. Generic feature prints were enrolled the same way.
struct BoxFaceAligner: FaceAligning {
    var margin: CGFloat = 0.15
    func aligned(_ image: CGImage, face r: CGRect) -> CGImage? {
        let side = max(r.width, r.height) * (1 + 2 * margin)
        let aspect = CGFloat(image.width) / CGFloat(max(image.height, 1))
        let sq = CGRect(x: r.midX - side / 2, y: r.midY - side * aspect / 2, width: side, height: side * aspect)
        return VisionPersonAnalyzer.crop(image, sq)
    }
}

/// Face capture quality in [0, 1] for one face box; nil when Vision can't say. Seam for tests.
protocol FaceQualityScoring: Sendable {
    func quality(of face: CGRect, in image: CGImage) async -> Double?
}

struct VisionFaceQuality: FaceQualityScoring {
    func quality(of face: CGRect, in image: CGImage) async -> Double? {
        var req = DetectFaceCaptureQualityRequest()
        req.inputFaceObservations = [FaceObservation(boundingBox: NormalizedRect(normalizedRect: face))]
        return ((try? await req.perform(on: image)) ?? []).first?.captureQuality.map { Double($0.score) }
    }
}

/// People in a frame: 2D pose, a box from the joints, and (only when allowed, and only for people the shooter gate
/// admits) upper-body / face embeddings. Bystanders get a pose and a box, nothing else.
struct VisionPersonAnalyzer: PersonAnalyzing {
    var body: any EmbeddingExtracting = VisionFeaturePrintExtractor(kind: "body")
    /// Swap for a licence-clean identity-trained model (its own modelID + calibration entry); never a model whose
    /// weights or training data licence is unclear (face-embedding.md F2/F3).
    var face: any EmbeddingExtracting = VisionFeaturePrintExtractor(kind: "face")
    var aligner: any FaceAligning = BoxFaceAligner()
    var faceQuality: any FaceQualityScoring = VisionFaceQuality()
    var minFaceQuality = 0.5
    /// SPEC §3: up to eight players, so up to eight people nearest the cue ball are kept.
    var maxPeople = 8

    func people(in image: CGImage, wants: AnalysisWants) async throws -> [ObservedPerson] {
        let poses = try await DetectHumanBodyPoseRequest().perform(on: image)
        let found = poses.compactMap { pose -> ObservedPerson? in
            let joints = Self.joints(pose)
            return Self.box(joints).map { ObservedPerson(box: $0, joints: joints) }
        }
        var out = Self.nearestFirst(found, cueBall: wants.cueBall, limit: maxPeople)
        for i in out.indices where wants.appearance && wants.admits(out[i].joints, box: out[i].box) {
            if let crop = Self.crop(image, Self.upperBody(out[i].joints) ?? out[i].box) {
                out[i].appearance = try? await body.embedding(of: crop)
            }
        }
        if wants.face, out.contains(where: { wants.admits($0.joints, box: $0.box) }) {
            let faces = ((try? await DetectFaceRectanglesRequest().perform(on: image)) ?? []).map { $0.boundingBox.cgRect }
            for (fi, pi) in Self.assignFaces(faces, to: out) where wants.admits(out[pi].joints, box: out[pi].box) {
                guard let q = await faceQuality.quality(of: faces[fi], in: image), q >= minFaceQuality,
                      let crop = aligner.aligned(image, face: faces[fi]) else { continue }
                out[pi].faceQuality = q
                out[pi].face = try? await face.embedding(of: crop)
            }
        }
        return out
    }

    /// Rank by reach distance to the cue ball before capping, so the shooter is never the one dropped.
    static func nearestFirst(_ people: [ObservedPerson], cueBall: CGPoint, limit: Int) -> [ObservedPerson] {
        let d = people.map { ShootingPose.reachDistance($0.joints, box: $0.box, cueBall: cueBall) }
        return people.indices.sorted { d[$0] != d[$1] ? d[$0] < d[$1] : $0 < $1 }.prefix(limit).map { people[$0] }
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

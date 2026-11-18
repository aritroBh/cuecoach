import Foundation
import CoreGraphics

// 5-point face alignment to the ArcFace 112×112 template, plus the face quality gate (face-embedding.md F4).
// Pure geometry + one CoreGraphics warp; no Vision here. All points are pixels, top-left origin.

/// The five alignment points, ordered like the ArcFace template: image-left eye, image-right eye, nose,
/// image-left mouth corner, image-right mouth corner.
struct FaceLandmarks5: Hashable, Sendable {
    var points: [CGPoint]

    /// From Vision landmark regions (already in top-left pixels). Eyes and mouth corners are ordered by image x, so
    /// it doesn't matter which side Vision calls "left". Nose = centroid of the nose region (close to the tip on a
    /// frontal face; its offset from the RetinaFace definition is measured by the §6 benchmark, not assumed away).
    init?(eyeA: [CGPoint], eyeB: [CGPoint], nose: [CGPoint], outerLips: [CGPoint]) {
        guard let a = Self.centroid(eyeA), let b = Self.centroid(eyeB), let n = Self.centroid(nose), outerLips.count >= 2,
              let ml = outerLips.min(by: { $0.x < $1.x }), let mr = outerLips.max(by: { $0.x < $1.x }), ml != mr
        else { return nil }
        let (l, r) = a.x <= b.x ? (a, b) : (b, a)
        points = [l, r, n, ml, mr]
    }

    var interOcular: Double { ShootingPose.distance(points[0], points[1]) }

    static func centroid(_ p: [CGPoint]) -> CGPoint? {
        guard !p.isEmpty else { return nil }
        return CGPoint(x: p.reduce(0) { $0 + $1.x } / CGFloat(p.count), y: p.reduce(0) { $0 + $1.y } / CGFloat(p.count))
    }
}

enum FaceAlignment {
    static let size = 112
    /// InsightFace `arcface_dst` (112×112).
    static let arcface112: [CGPoint] = [
        CGPoint(x: 38.2946, y: 51.6963), CGPoint(x: 73.5318, y: 51.5014), CGPoint(x: 56.0252, y: 71.7366),
        CGPoint(x: 41.5493, y: 92.3655), CGPoint(x: 70.7299, y: 92.2041),
    ]

    /// Least-squares similarity (rotation + uniform scale + translation, no reflection) mapping `src` onto `dst`.
    /// nil for mismatched / too few / degenerate (all-coincident) points.
    static func similarity(from src: [CGPoint], to dst: [CGPoint]) -> CGAffineTransform? {
        guard src.count == dst.count, src.count >= 2 else { return nil }
        let n = Double(src.count)
        let sx = src.reduce(0.0) { $0 + Double($1.x) } / n, sy = src.reduce(0.0) { $0 + Double($1.y) } / n
        let dx = dst.reduce(0.0) { $0 + Double($1.x) } / n, dy = dst.reduce(0.0) { $0 + Double($1.y) } / n
        var num1 = 0.0, num2 = 0.0, den = 0.0
        for (s, d) in zip(src, dst) {
            let x = Double(s.x) - sx, y = Double(s.y) - sy, u = Double(d.x) - dx, v = Double(d.y) - dy
            num1 += x * u + y * v
            num2 += x * v - y * u
            den += x * x + y * y
        }
        guard den > 1e-9, den.isFinite else { return nil }
        let a = num1 / den, b = num2 / den
        guard a * a + b * b > 1e-12 else { return nil }
        // x' = a x − b y + tx ; y' = b x + a y + ty
        let tx = dx - (a * sx - b * sy), ty = dy - (b * sx + a * sy)
        return CGAffineTransform(a: a, b: b, c: -b, d: a, tx: tx, ty: ty)
    }

    /// Renders the 112×112 aligned crop: output pixel p (top-left) samples source pixel m⁻¹(p).
    static func warp(_ image: CGImage, transform m: CGAffineTransform) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        ctx.interpolationQuality = .high
        // CG draws image pixel (u, v_top) at (u, H − v_top). Want it at F112(m(u, v_top)): CTM = F_H · m · F_112.
        let h = CGFloat(image.height)
        let flipSrc = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)
        let flipDst = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(size))
        ctx.concatenate(flipSrc.concatenating(m).concatenating(flipDst))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()
    }
}

/// Size, pose and capture-quality gate for any face that may be embedded (enrolment and stroke time).
/// Floors are assumptions to tune with the §6 benchmark (face-embedding.md).
struct FaceQualityGate: Hashable, Sendable {
    var minInterOcularPixels = 24.0
    var maxYawDegrees = 35.0
    var maxRollDegrees = 25.0
    /// `DetectFaceCaptureQualityRequest` score floor; Apple's score is treated as relative, so this is only a floor.
    var minQuality = 0.5
    static let standard = FaceQualityGate()

    func admits(interOcularPixels: Double, yawDegrees: Double, rollDegrees: Double, quality: Double?) -> Bool {
        guard let quality else { return false }
        return interOcularPixels >= minInterOcularPixels && abs(yawDegrees) <= maxYawDegrees
            && abs(rollDegrees) <= maxRollDegrees && quality >= minQuality
    }
}

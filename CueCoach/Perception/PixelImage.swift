import CoreGraphics
import CoreVideo
import Foundation

/// Downsampled RGB working image (3 bytes/pixel, R,G,B). Pure value type, safe to hand across actors.
/// `scale` maps working pixels to source pixels: source = (working + 0.5) · scale − 0.5.
struct PixelImage: Sendable {
    var width: Int
    var height: Int
    var rgb: [UInt8]
    var scale: Double
    /// Source image size (pixels) the calibration lives in.
    var sourceWidth: Int
    var sourceHeight: Int

    init(width: Int, height: Int, rgb: [UInt8], scale: Double = 1, sourceWidth: Int? = nil, sourceHeight: Int? = nil) {
        precondition(rgb.count == width * height * 3)
        self.width = width; self.height = height; self.rgb = rgb; self.scale = scale
        self.sourceWidth = sourceWidth ?? width; self.sourceHeight = sourceHeight ?? height
    }

    @inline(__always) func pixel(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
        let i = (y * width + x) * 3
        return (rgb[i], rgb[i + 1], rgb[i + 2])
    }

    func toSource(_ x: Double, _ y: Double) -> (Double, Double) { ((x + 0.5) * scale - 0.5, (y + 0.5) * scale - 0.5) }
    func toWorking(_ x: Double, _ y: Double) -> (Double, Double) { ((x + 0.5) / scale - 0.5, (y + 0.5) / scale - 0.5) }

    /// Integer stride so the working width is ≤ `maxWidth`.
    static func stride(forWidth w: Int, maxWidth: Int) -> Int { max(1, Int((Double(w) / Double(maxWidth)).rounded(.up))) }

    /// From a BGRA or 420 YCbCr (ARKit `capturedImage`) pixel buffer, point-sampled at an integer stride.
    init?(pixelBuffer pb: CVPixelBuffer, maxWidth: Int = 960) {
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let s = PixelImage.stride(forWidth: w, maxWidth: maxWidth)
        let ow = w / s, oh = h / s
        var out = [UInt8](repeating: 0, count: ow * oh * 3)
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let fmt = CVPixelBufferGetPixelFormatType(pb)
        switch fmt {
        case kCVPixelFormatType_32BGRA:
            guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
            let rb = CVPixelBufferGetBytesPerRow(pb)
            let src = base.assumingMemoryBound(to: UInt8.self)
            out.withUnsafeMutableBufferPointer { o in
                for y in 0..<oh {
                    let row = src + (y * s) * rb
                    for x in 0..<ow {
                        let p = row + (x * s) * 4, i = (y * ow + x) * 3
                        o[i] = p[2]; o[i + 1] = p[1]; o[i + 2] = p[0]
                    }
                }
            }
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            guard CVPixelBufferGetPlaneCount(pb) >= 2,
                  let yb = CVPixelBufferGetBaseAddressOfPlane(pb, 0),
                  let cb = CVPixelBufferGetBaseAddressOfPlane(pb, 1) else { return nil }
            let yrb = CVPixelBufferGetBytesPerRowOfPlane(pb, 0), crb = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
            let yp = yb.assumingMemoryBound(to: UInt8.self), cp = cb.assumingMemoryBound(to: UInt8.self)
            let video = fmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            out.withUnsafeMutableBufferPointer { o in
                for y in 0..<oh {
                    let sy = y * s
                    let yrow = yp + sy * yrb, crow = cp + (sy / 2) * crb
                    for x in 0..<ow {
                        let sx = x * s
                        let c = crow + (sx / 2) * 2
                        let rgb = YCbCr.toRGB(yrow[sx], c[0], c[1], videoRange: video)
                        let i = (y * ow + x) * 3
                        o[i] = rgb.0; o[i + 1] = rgb.1; o[i + 2] = rgb.2
                    }
                }
            }
        default:
            return nil
        }
        self.init(width: ow, height: oh, rgb: out, scale: Double(s), sourceWidth: w, sourceHeight: h)
    }

    /// From a CGImage (replay, tests), downsampled to ≤ maxWidth.
    init?(cgImage: CGImage, maxWidth: Int = 960) {
        let w = cgImage.width, h = cgImage.height
        let s = PixelImage.stride(forWidth: w, maxWidth: maxWidth)
        let ow = w / s, oh = h / s
        var rgba = [UInt8](repeating: 0, count: ow * oh * 4)
        let ok = rgba.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: ow, height: oh, bitsPerComponent: 8,
                                      bytesPerRow: ow * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: ow, height: oh))
            return true
        }
        guard ok else { return nil }
        var rgb = [UInt8](repeating: 0, count: ow * oh * 3)
        for i in 0..<(ow * oh) { rgb[i * 3] = rgba[i * 4]; rgb[i * 3 + 1] = rgba[i * 4 + 1]; rgb[i * 3 + 2] = rgba[i * 4 + 2] }
        self.init(width: ow, height: oh, rgb: rgb, scale: Double(s), sourceWidth: w, sourceHeight: h)
    }

    /// Every `k`-th pixel (cheaper image for segmentation).
    func decimated(by k: Int) -> PixelImage {
        guard k > 1 else { return self }
        let ow = width / k, oh = height / k
        var out = [UInt8](repeating: 0, count: ow * oh * 3)
        for y in 0..<oh {
            for x in 0..<ow {
                let s = ((y * k) * width + x * k) * 3, d = (y * ow + x) * 3
                out[d] = rgb[s]; out[d + 1] = rgb[s + 1]; out[d + 2] = rgb[s + 2]
            }
        }
        return PixelImage(width: ow, height: oh, rgb: out, scale: scale * Double(k),
                          sourceWidth: sourceWidth, sourceHeight: sourceHeight)
    }
}

enum YCbCr {
    /// BT.601 (ARKit's documented capturedImage conversion), full or video range.
    @inline(__always) static func toRGB(_ y: UInt8, _ cb: UInt8, _ cr: UInt8, videoRange: Bool = false) -> (UInt8, UInt8, UInt8) {
        var yy = Double(y)
        var u = Double(cb) - 128, v = Double(cr) - 128
        if videoRange { yy = (yy - 16) * 255 / 219; u *= 255 / 224; v *= 255 / 224 }
        func c(_ d: Double) -> UInt8 { UInt8(max(0, min(255, d.rounded()))) }
        return (c(yy + 1.402 * v), c(yy - 0.344136 * u - 0.714136 * v), c(yy + 1.772 * u))
    }

    static func fromRGB(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> (UInt8, UInt8, UInt8) {
        let r = Double(r), g = Double(g), b = Double(b)
        let y = 0.299 * r + 0.587 * g + 0.114 * b
        func c(_ d: Double) -> UInt8 { UInt8(max(0, min(255, d.rounded()))) }
        return (c(y), c(128 + (b - y) / 1.772), c(128 + (r - y) / 1.402))
    }
}

/// HSV helpers on 8-bit RGB. Hue degrees [0, 360), s and v in [0, 1].
enum ColorMath {
    @inline(__always) static func hsv(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> (h: Double, s: Double, v: Double) {
        let rf = Double(r) / 255, gf = Double(g) / 255, bf = Double(b) / 255
        let mx = max(rf, gf, bf), mn = min(rf, gf, bf), d = mx - mn
        var h = 0.0
        if d > 1e-9 {
            if mx == rf { h = 60 * ((gf - bf) / d).truncatingRemainder(dividingBy: 6) }
            else if mx == gf { h = 60 * ((bf - rf) / d + 2) }
            else { h = 60 * ((rf - gf) / d + 4) }
        }
        if h < 0 { h += 360 }
        return (h, mx > 0 ? d / mx : 0, mx)
    }

    static func hueDistance(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 360)
        return min(d, 360 - d)
    }
}

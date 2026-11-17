import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import Geometry

/// Rolling camera frame ring buffer + local `.mp4` writer with burned-in ball trajectories (SPEC §9, D3, D55).
/// Clips live strictly on-device under `Application Support/Clips/` (excluded from backup; deleted with their game).
enum ShotClipStore {
    static var defaultBaseDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    }

    static func clipsDirectory(in base: URL = defaultBaseDirectory) throws -> URL {
        var dir = base.appending(path: "Clips", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var rv = URLResourceValues()
        rv.isExcludedFromBackup = true
        try? dir.setResourceValues(rv)
        return dir
    }

    static func relativePath(for shotID: UUID) -> String {
        "Clips/\(shotID.uuidString).mp4"
    }

    static func resolveURL(relativePath: String, baseDirectory: URL = defaultBaseDirectory) -> URL? {
        guard !relativePath.isEmpty,
              !relativePath.contains(".."),
              relativePath.hasPrefix("Clips/") else { return nil }
        let url = baseDirectory.appending(path: relativePath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    @discardableResult
    static func saveReceivedClip(shotID: UUID, data: Data, baseDirectory: URL = defaultBaseDirectory) throws -> String {
        let dir = try clipsDirectory(in: baseDirectory)
        let rel = relativePath(for: shotID)
        var fileURL = dir.appending(path: "\(shotID.uuidString).mp4")
        try data.write(to: fileURL, options: .atomic)
        var rv = URLResourceValues()
        rv.isExcludedFromBackup = true
        try? fileURL.setResourceValues(rv)
        return rel
    }

    static func deleteClips(relativePaths: [String], baseDirectory: URL = defaultBaseDirectory) {
        for rel in relativePaths where !rel.isEmpty && !rel.contains("..") && rel.hasPrefix("Clips/") {
            let url = baseDirectory.appending(path: rel)
            try? FileManager.default.removeItem(at: url)
        }
    }
}

struct BufferedClipFrame: @unchecked Sendable {
    var timestamp: Double
    var image: CGImage
}

/// Bounded ~5 s rolling ring buffer (~3 s pre-stroke + ~2 s post-settle).
struct RollingFrameBuffer: Sendable {
    let maxDuration: Double
    let maxFrames: Int
    private(set) var frames: [BufferedClipFrame] = []

    init(maxDuration: Double = 5.5, maxFrames: Int = 75) {
        self.maxDuration = maxDuration
        self.maxFrames = maxFrames
    }

    mutating func append(_ frame: BufferedClipFrame) {
        frames.append(frame)
        let cutoff = frame.timestamp - maxDuration
        frames.removeAll { $0.timestamp < cutoff }
        if frames.count > maxFrames {
            frames.removeFirst(frames.count - maxFrames)
        }
    }

    func window(aroundStroke strokeAt: Double, preSeconds: Double = 3.0, postSeconds: Double = 2.0) -> [BufferedClipFrame] {
        let lo = strokeAt - preSeconds
        let hi = strokeAt + postSeconds
        return frames.filter { $0.timestamp >= lo && $0.timestamp <= hi }
    }
}

actor ShotClipRecorder {
    let baseDirectory: URL
    private var buffer = RollingFrameBuffer()

    init(baseDirectory: URL = ShotClipStore.defaultBaseDirectory) {
        self.baseDirectory = baseDirectory
    }

    func pushFrame(_ image: CGImage, timestamp: Double) {
        buffer.append(BufferedClipFrame(timestamp: timestamp, image: image))
    }

    /// Exports a short `.mp4` clip with burned-in actual ball paths (`before` → `after` / pocket).
    /// When no live camera frames are buffered (e.g. Simulator replay), renders a clean animated trajectory clip.
    func exportClip(shotID: UUID, strokeAt: Double? = nil, tableSize: TableSize = .sevenFoot,
                    before: [BallID: Vec2], after: [BallID: Vec2],
                    pocketed: [BallID: Pocket]) async throws -> (relativePath: String, url: URL) {
        let dir = try ShotClipStore.clipsDirectory(in: baseDirectory)
        var fileURL = dir.appending(path: "\(shotID.uuidString).mp4")
        try? FileManager.default.removeItem(at: fileURL)

        let width = 480
        let height = 270
        let spec = TableSpec(size: tableSize)
        let paths = Self.computePaths(spec: spec, before: before, after: after, pocketed: pocketed)

        let captured: [CGImage]
        if let strokeAt {
            captured = buffer.window(aroundStroke: strokeAt).map(\.image)
        } else {
            captured = buffer.frames.suffix(24).map(\.image)
        }
        let totalFrames = max(18, min(45, captured.isEmpty ? 24 : captured.count))

        let writer = try AVAssetWriter(outputURL: fileURL, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attrs)
        guard writer.canAdd(input) else { throw CocoaError(.fileWriteUnknown) }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)

        let fps: Int32 = 15
        for frameIdx in 0..<totalFrames {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
            }
            let progress = Double(frameIdx) / Double(max(1, totalFrames - 1))
            let bg = captured.isEmpty ? nil : captured[min(captured.count - 1, frameIdx)]
            if let pb = Self.renderFrame(width: width, height: height, background: bg,
                                         spec: spec, paths: paths, before: before, progress: progress) {
                let pts = CMTime(value: CMTimeValue(frameIdx), timescale: fps)
                adaptor.append(pb, withPresentationTime: pts)
            }
        }

        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }
        var rv = URLResourceValues()
        rv.isExcludedFromBackup = true
        try? fileURL.setResourceValues(rv)
        return (ShotClipStore.relativePath(for: shotID), fileURL)
    }

    private static func computePaths(spec: TableSpec, before: [BallID: Vec2],
                                     after: [BallID: Vec2], pocketed: [BallID: Pocket]) -> [BallID: (Vec2, Vec2)] {
        var out: [BallID: (Vec2, Vec2)] = [:]
        for (id, start) in before {
            if let pk = pocketed[id] {
                out[id] = (start, spec.pocketCenter(pk))
            } else if let end = after[id] {
                out[id] = (start, end)
            } else {
                out[id] = (start, start)
            }
        }
        return out
    }

    private static func renderFrame(width: Int, height: Int, background: CGImage?,
                                    spec: TableSpec, paths: [BallID: (Vec2, Vec2)],
                                    before: [BallID: Vec2], progress: Double) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
        guard status == kCVReturnSuccess, let pb = pixelBuffer else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pb)
        let cs = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let ctx = CGContext(data: base, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: bytesPerRow, space: cs, bitmapInfo: bitmapInfo) else { return nil }

        let fullRect = CGRect(x: 0, y: 0, width: width, height: height)
        if let background {
            ctx.draw(background, in: fullRect)
        } else {
            ctx.setFillColor(red: 0.06, green: 0.08, blue: 0.11, alpha: 1.0)
            ctx.fill(fullRect)
        }

        let padX = Double(width) * 0.10
        let padY = Double(height) * 0.12
        let tableW = Double(width) - 2 * padX
        let tableH = Double(height) - 2 * padY
        let tableRect = CGRect(x: padX, y: padY, width: tableW, height: tableH)

        if background == nil {
            ctx.setFillColor(red: 0.08, green: 0.34, blue: 0.25, alpha: 1.0)
            ctx.fill(tableRect)
            ctx.setStrokeColor(red: 0.22, green: 0.62, blue: 0.45, alpha: 0.9)
            ctx.setLineWidth(3)
            ctx.stroke(tableRect)
        }

        func mapPoint(_ p: Vec2) -> CGPoint {
            let nx = max(0, min(1, p.x / max(0.01, spec.length)))
            let ny = max(0, min(1, p.y / max(0.01, spec.width)))
            return CGPoint(x: padX + nx * tableW, y: padY + ny * tableH)
        }

        // Burn-in actual ball trajectory lines + animated ball discs.
        for (ball, seg) in paths {
            let p0 = mapPoint(seg.0)
            let curVec = seg.0 + (seg.1 - seg.0) * progress
            let pCur = mapPoint(curVec)
            if p0.x != pCur.x || p0.y != pCur.y {
                if ball.isCue {
                    ctx.setStrokeColor(red: 0.95, green: 0.96, blue: 0.98, alpha: 0.85)
                } else {
                    ctx.setStrokeColor(red: 0.20, green: 0.85, blue: 0.60, alpha: 0.90)
                }
                ctx.setLineWidth(2.5)
                ctx.move(to: p0)
                ctx.addLine(to: pCur)
                ctx.strokePath()
            }
            let r: CGFloat = 6.0
            if ball.isCue {
                ctx.setFillColor(red: 0.98, green: 0.98, blue: 0.99, alpha: 1.0)
            } else {
                ctx.setFillColor(red: 0.96, green: 0.72, blue: 0.18, alpha: 1.0)
            }
            ctx.fillEllipse(in: CGRect(x: pCur.x - r, y: pCur.y - r, width: r * 2, height: r * 2))
        }
        return pb
    }
}

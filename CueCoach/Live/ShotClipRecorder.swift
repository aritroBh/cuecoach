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

    /// Strict canonical single-file validation (`Clips/<UUID>.mp4`) so untrusted backup strings like `"Clips/"` or `"Clips/."`
    /// can never escape `Clips/` or delete the directory itself.
    static func isValidRelativeClipPath(_ relativePath: String) -> Bool {
        guard !relativePath.contains(".."), !relativePath.contains("\\") else { return false }
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == "Clips" else { return false }
        let filename = String(parts[1])
        guard filename.hasSuffix(".mp4") else { return false }
        let stem = String(filename.dropLast(4))
        return UUID(uuidString: stem) != nil
    }

    static func resolveURL(relativePath: String, baseDirectory: URL = defaultBaseDirectory) -> URL? {
        guard isValidRelativeClipPath(relativePath) else { return nil }
        let url = baseDirectory.appending(path: relativePath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    @discardableResult
    static func saveReceivedClip(shotID: UUID, data: Data, baseDirectory: URL = defaultBaseDirectory) throws -> String {
        let dir = try clipsDirectory(in: baseDirectory)
        let rel = relativePath(for: shotID)
        var fileURL = dir.appending(path: "\(shotID.uuidString).mp4")
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var rv = URLResourceValues()
        rv.isExcludedFromBackup = true
        try? fileURL.setResourceValues(rv)
        return rel
    }

    static func deleteClips(relativePaths: [String], baseDirectory: URL = defaultBaseDirectory) {
        for rel in Set(relativePaths) where isValidRelativeClipPath(rel) {
            let url = baseDirectory.appending(path: rel)
            try? FileManager.default.removeItem(at: url)
        }
    }
}

struct BufferedClipFrame: @unchecked Sendable {
    var timestamp: Double
    var image: CGImage
}

/// Bounded rolling ring buffer (~14 s) so slow rolls still retain `stroke - 1 s` through `settle + 2 s`.
struct RollingFrameBuffer: Sendable {
    let maxDuration: Double
    let maxFrames: Int
    private(set) var frames: [BufferedClipFrame] = []

    init(maxDuration: Double = 14.0, maxFrames: Int = 180) {
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

    func window(aroundStroke strokeAt: Double, settledAt: Double? = nil,
                preSeconds: Double = 1.0, postSeconds: Double = 2.0) -> [BufferedClipFrame] {
        let lo = strokeAt - preSeconds
        let hi = max(settledAt ?? strokeAt, strokeAt) + postSeconds
        return frames.filter { $0.timestamp >= lo && $0.timestamp <= hi }
    }
}

actor ShotClipRecorder {
    private struct ActivePostSettleWindow {
        var shotID: UUID
        var lo: Double
        var hi: Double
    }

    private struct PendingIndexWindow {
        var index: Int
        var lo: Double
        var hi: Double
        var frames: [BufferedClipFrame]
    }

    private struct PendingTokenWindow {
        var token: UUID
        var lo: Double
        var hi: Double
        var frames: [BufferedClipFrame]
    }

    static let maxRetainedShots = 24
    static let maxFramesPerShot = 150

    let baseDirectory: URL
    private var buffer = RollingFrameBuffer()
    private var capturedShots: [UUID: [BufferedClipFrame]] = [:]
    private var shotOrder: [UUID] = []
    private var activeWindows: [ActivePostSettleWindow] = []
    private var pendingByIndex: [Int: PendingIndexWindow] = [:]
    private var pendingByToken: [UUID: PendingTokenWindow] = [:]
    private var tokenOrder: [UUID] = []
    private var waitingShotIDByIndex: [Int: UUID] = [:]
    private var boundShotIDByIndex: [Int: UUID] = [:]
    private var lastPushedTimestamp: Double?
    private var lastPushUptime: Double?

    init(baseDirectory: URL = ShotClipStore.defaultBaseDirectory) {
        self.baseDirectory = baseDirectory
    }

    func pushFrame(_ image: CGImage, timestamp: Double) {
        let frame = BufferedClipFrame(timestamp: timestamp, image: image)
        buffer.append(frame)
        lastPushedTimestamp = timestamp
        lastPushUptime = ProcessInfo.processInfo.systemUptime
        activeWindows.removeAll { timestamp > $0.hi }
        for win in activeWindows where timestamp >= win.lo && timestamp <= win.hi {
            var arr = capturedShots[win.shotID] ?? []
            if arr.count < Self.maxFramesPerShot {
                arr.append(frame)
                capturedShots[win.shotID] = arr
            }
        }
        for (idx, var pending) in pendingByIndex where timestamp >= pending.lo && timestamp <= pending.hi {
            if pending.frames.count < Self.maxFramesPerShot {
                pending.frames.append(frame)
                pendingByIndex[idx] = pending
            }
        }
        for (tok, var pending) in pendingByToken where timestamp >= pending.lo && timestamp <= pending.hi {
            if pending.frames.count < Self.maxFramesPerShot {
                pending.frames.append(frame)
                pendingByToken[tok] = pending
            }
        }
    }

    /// Snapshots `[strokeAt - 1.0, settledAt + 2.0]` for `shotID` and keeps appending incoming reaction frames up to `settledAt + 2.0`
    /// so an early-rack highlight never ages out before rack end (SPEC §7).
    func sealShot(shotID: UUID, strokeAt: Double, settledAt: Double, boundIndex: Int? = nil) {
        let lo = strokeAt - 1.0
        let hi = max(settledAt, strokeAt) + 2.0
        let initial = Array(buffer.frames.filter { $0.timestamp >= lo && $0.timestamp <= hi }.prefix(Self.maxFramesPerShot))
        if let boundIndex { boundShotIDByIndex[boundIndex] = shotID }
        registerCaptured(shotID: shotID, frames: initial, lo: lo, hi: hi)
    }

    /// Seals `[strokeAt - 1.0, settledAt + 2.0]` under an exact per-shot `token` (`LiveModel.enqueue`), bound 1-to-1 to `shotID`
    /// when `shotSettled` closes that FIFO entry.
    func sealToken(_ token: UUID, strokeAt: Double, settledAt: Double) {
        let lo = strokeAt - 1.0
        let hi = max(settledAt, strokeAt) + 2.0
        let initial = Array(buffer.frames.filter { $0.timestamp >= lo && $0.timestamp <= hi }.prefix(Self.maxFramesPerShot))
        if pendingByToken[token] == nil {
            tokenOrder.append(token)
            while tokenOrder.count > Self.maxRetainedShots {
                let oldest = tokenOrder.removeFirst()
                pendingByToken.removeValue(forKey: oldest)
            }
        }
        pendingByToken[token] = PendingTokenWindow(token: token, lo: lo, hi: hi, frames: initial)
    }

    @discardableResult
    func bindToken(_ token: UUID, to shotID: UUID, boundIndex: Int? = nil) -> Bool {
        guard let pending = pendingByToken.removeValue(forKey: token) else { return false }
        tokenOrder.removeAll { $0 == token }
        if let boundIndex { boundShotIDByIndex[boundIndex] = shotID }
        registerCaptured(shotID: shotID, frames: pending.frames, lo: pending.lo, hi: pending.hi)
        return true
    }

    /// Seals `[strokeAt - 1.0, settledAt + 2.0]` immediately on local physical shot-end (before any pocket-confirm FIFO).
    /// Bidirectional with `bindPendingLocalIndexIfPresent`: works whether local settlement or mesh commit arrives first.
    @discardableResult
    func sealPendingLocalIndex(_ index: Int, strokeAt: Double, settledAt: Double) -> UUID? {
        let lo = strokeAt - 1.0
        let hi = max(settledAt, strokeAt) + 2.0
        let initial = Array(buffer.frames.filter { $0.timestamp >= lo && $0.timestamp <= hi }.prefix(Self.maxFramesPerShot))
        if let waitingID = waitingShotIDByIndex.removeValue(forKey: index) {
            boundShotIDByIndex[index] = waitingID
            registerCaptured(shotID: waitingID, frames: initial, lo: lo, hi: hi)
            return waitingID
        }
        pendingByIndex[index] = PendingIndexWindow(index: index, lo: lo, hi: hi, frames: initial)
        if pendingByIndex.count > Self.maxRetainedShots, let minKey = pendingByIndex.keys.min() {
            pendingByIndex.removeValue(forKey: minKey)
        }
        return nil
    }

    @discardableResult
    func bindPendingLocalIndexIfPresent(_ index: Int, to shotID: UUID) -> Bool {
        if capturedShots[shotID] != nil {
            waitingShotIDByIndex.removeValue(forKey: index)
            boundShotIDByIndex[index] = shotID
            return false
        }
        if let pending = pendingByIndex.removeValue(forKey: index) {
            waitingShotIDByIndex.removeValue(forKey: index)
            boundShotIDByIndex[index] = shotID
            registerCaptured(shotID: shotID, frames: pending.frames, lo: pending.lo, hi: pending.hi)
            return true
        }
        if let prevID = boundShotIDByIndex[index], prevID != shotID,
           let existing = capturedShots.removeValue(forKey: prevID) {
            boundShotIDByIndex[index] = shotID
            if let orderIdx = shotOrder.firstIndex(of: prevID) {
                shotOrder[orderIdx] = shotID
            } else {
                shotOrder.append(shotID)
            }
            capturedShots[shotID] = existing
            for i in activeWindows.indices where activeWindows[i].shotID == prevID {
                activeWindows[i].shotID = shotID
            }
            return true
        }
        waitingShotIDByIndex[index] = shotID
        if waitingShotIDByIndex.count > Self.maxRetainedShots, let minKey = waitingShotIDByIndex.keys.min() {
            waitingShotIDByIndex.removeValue(forKey: minKey)
        }
        return false
    }

    private func registerCaptured(shotID: UUID, frames: [BufferedClipFrame], lo: Double, hi: Double) {
        if capturedShots[shotID] == nil {
            shotOrder.append(shotID)
            while shotOrder.count > Self.maxRetainedShots {
                let oldest = shotOrder.removeFirst()
                capturedShots.removeValue(forKey: oldest)
                activeWindows.removeAll { $0.shotID == oldest }
            }
        }
        capturedShots[shotID] = frames
        activeWindows.removeAll { $0.shotID == shotID }
        if (lastPushedTimestamp ?? lo) <= hi {
            activeWindows.append(ActivePostSettleWindow(shotID: shotID, lo: lo, hi: hi))
        }
    }

    /// When live camera frames are actively streaming on the final winning shot, waits up to the remaining `settle + 2 s`
    /// window (cancellable immediately) before exporting the `.mp4`.
    func waitForPostSettleIfStreaming(shotID: UUID) async {
        for _ in 0..<20 {
            guard !Task.isCancelled,
                  let win = activeWindows.first(where: { $0.shotID == shotID }),
                  !(capturedShots[shotID]?.isEmpty ?? true),
                  let lastTS = lastPushedTimestamp,
                  let lastWall = lastPushUptime,
                  ProcessInfo.processInfo.systemUptime - lastWall < 0.35,
                  lastTS < win.hi else { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    func capturedFrameCount(for shotID: UUID) -> Int {
        capturedShots[shotID]?.count ?? 0
    }

    /// Exports a short `.mp4` clip with burned-in actual ball paths (`before` → `after` / pocket).
    /// When no live camera frames are buffered (e.g. Simulator replay), renders a clean animated trajectory clip.
    func exportClip(shotID: UUID, strokeAt: Double? = nil, settledAt: Double? = nil,
                    tableSize: TableSize = .sevenFoot,
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
        if let sealed = capturedShots[shotID], !sealed.isEmpty {
            captured = sealed.map(\.image)
        } else if let strokeAt {
            captured = buffer.window(aroundStroke: strokeAt, settledAt: settledAt).map(\.image)
        } else {
            captured = buffer.frames.suffix(24).map(\.image)
        }
        let totalFrames = captured.isEmpty ? 24 : max(18, min(Self.maxFramesPerShot, captured.count))

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
            let bg: CGImage? = if captured.isEmpty {
                nil
            } else {
                captured[min(captured.count - 1, Int((progress * Double(captured.count - 1)).rounded()))]
            }
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

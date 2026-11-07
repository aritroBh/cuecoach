#if !targetEnvironment(simulator)
import ARKit
import Geometry
import RealityKit
import simd
import SwiftUI
import Synchronization
import UIKit

/// Full-screen ARKit camera with the table overlay anchored in 3D.
struct ARLiveView: UIViewRepresentable {
    let model: LiveModel

    func makeCoordinator() -> ARLiveController { ARLiveController(model: model) }

    func makeUIView(context: Context) -> ARView {
        let c = context.coordinator
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        view.renderOptions.insert(.disableMotionBlur)
        view.renderOptions.insert(.disableDepthOfField)
        c.attach(view)
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {}

    static func dismantleUIView(_ uiView: ARView, coordinator: ARLiveController) {
        coordinator.stop()
    }
}

@MainActor
final class ARLiveController: NSObject {
    let model: LiveModel
    private weak var view: ARView?
    private let pipeline = PerceptionPipeline()
    private var tap: FrameTap?
    private var cornerWorld: [SIMD3<Double>] = []
    private var cornerAnchors: [AnchorEntity] = []
    private var overlay: TableOverlay?
    private let haptic = UIImpactFeedbackGenerator(style: .light)
    private var thermalObserver: NSObjectProtocol?

    init(model: LiveModel) {
        self.model = model
        super.init()
        model.undo = { [weak self] in self?.undoCorner() }
        model.recalibrate = { [weak self] in self?.resetCalibration() }
    }

    func attach(_ v: ARView) {
        view = v
        let tap = FrameTap(pipeline: pipeline) { [weak self] result, status in
            self?.handle(result, status)
        }
        self.tap = tap
        v.session.delegate = tap
        v.session.delegateQueue = tap.queue
        let config = Self.configuration()
        model.formatLabel = "\(Int(config.videoFormat.imageResolution.width))x\(Int(config.videoFormat.imageResolution.height))@\(config.videoFormat.framesPerSecond)"
        v.session.run(config)
        v.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.thermal = ProcessInfo.processInfo.thermalState }
        }
        UIApplication.shared.isIdleTimerDisabled = true
    }

    func stop() {
        view?.session.pause()
        UIApplication.shared.isIdleTimerDisabled = false
        if let o = thermalObserver { NotificationCenter.default.removeObserver(o) }
    }

    /// Highest-fps, then highest-resolution format; LiDAR depth + person occlusion when supported.
    static func configuration() -> ARWorldTrackingConfiguration {
        let c = ARWorldTrackingConfiguration()
        c.planeDetection = [.horizontal]
        c.environmentTexturing = .none
        let formats = ARWorldTrackingConfiguration.supportedVideoFormats
        if let best = formats.max(by: { a, b in
            if a.framesPerSecond != b.framesPerSecond { return a.framesPerSecond < b.framesPerSecond }
            return a.imageResolution.width * a.imageResolution.height < b.imageResolution.width * b.imageResolution.height
        }) { c.videoFormat = best }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) { c.frameSemantics.insert(.sceneDepth) }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentationWithDepth) {
            c.frameSemantics.insert(.personSegmentationWithDepth)
        }
        return c
    }

    // MARK: Calibration taps

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        guard let v = view, !model.calibrated, cornerWorld.count < 4 else { return }
        let p = g.location(in: v)
        let hit = v.raycast(from: p, allowing: .existingPlaneGeometry, alignment: .horizontal).first
            ?? v.raycast(from: p, allowing: .estimatedPlane, alignment: .horizontal).first
        guard let hit else { return }
        let t = hit.worldTransform.columns.3
        let w = SIMD3<Double>(Double(t.x), Double(t.y), Double(t.z))
        cornerWorld.append(w)
        let a = AnchorEntity(world: SIMD3<Float>(t.x, t.y, t.z))
        a.addChild(ModelEntity(mesh: .generateSphere(radius: 0.012), materials: [UnlitMaterial(color: .white)]))
        v.scene.addAnchor(a)
        cornerAnchors.append(a)
        haptic.impactOccurred()
        model.cornersPlaced = cornerWorld.count
        if cornerWorld.count == 4 { finishCalibration() }
    }

    private func undoCorner() {
        guard !cornerWorld.isEmpty, !model.calibrated else { return }
        cornerWorld.removeLast()
        if let a = cornerAnchors.popLast() { view?.scene.removeAnchor(a) }
        model.cornersPlaced = cornerWorld.count
    }

    private func finishCalibration() {
        guard let v = view else { return }
        let camT = v.cameraTransform.translation
        let viewer = SIMD3<Double>(Double(camT.x), Double(camT.y), Double(camT.z))
        // All corners onto one plane at their mean height (ARKit world is gravity-aligned).
        let meanY = cornerWorld.map(\.y).reduce(0, +) / 4
        let flat = cornerWorld.map { SIMD3($0.x, meanY, $0.z) }
        guard let fit = TableFitter.fit(corners: flat, viewer: viewer) else {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            resetCalibration()
            return
        }
        for a in cornerAnchors { v.scene.removeAnchor(a) }
        cornerAnchors = []
        let o = TableOverlay(frame: fit.frame)
        v.scene.addAnchor(o.anchor)
        overlay = o
        model.tableSize = fit.frame.spec.size
        model.calibrated = true
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        let pipeline = pipeline, frame = fit.frame
        Task { await pipeline.setTable(frame) }
        tap?.setActive(true)
    }

    private func resetCalibration() {
        tap?.setActive(false)
        let pipeline = pipeline
        Task { await pipeline.setTable(nil) }
        if let o = overlay { view?.scene.removeAnchor(o.anchor) }
        overlay = nil
        for a in cornerAnchors { view?.scene.removeAnchor(a) }
        cornerAnchors = []
        cornerWorld = []
        model.cornersPlaced = 0
        model.calibrated = false
        model.noteResult(nil)
    }

    private var wasAtRest = true

    private func handle(_ r: PerceptionResult?, _ s: FrameTap.Status) {
        model.planeFound = model.planeFound || s.planeFound
        model.trackingOK = s.trackingOK
        model.depthConfidence = s.depthConfidence
        guard model.calibrated else { return }
        model.noteResult(r)
        overlay?.update(r)
        if let r {
            if wasAtRest && !r.atRest && r.tracks.contains(where: { $0.confirmed && $0.speed > 0.3 }) {
                UIImpactFeedbackGenerator(style: .soft).impactOccurred()  // shot started (haptic only)
            }
            wasAtRest = r.atRest
        }
    }
}

/// ARSession delegate on its own queue: turns ARFrames into small Sendable frames, drops frames while busy.
final class FrameTap: NSObject, ARSessionDelegate, @unchecked Sendable {
    struct Status: Sendable { var planeFound: Bool; var trackingOK: Bool; var depthConfidence: Double? }

    let queue = DispatchQueue(label: "cuecoach.arframes", qos: .userInteractive)
    private let pipeline: PerceptionPipeline
    private let onResult: @MainActor (PerceptionResult?, Status) -> Void
    private let state = Mutex((busy: false, active: false, planeFound: false, lastStatus: 0.0))

    init(pipeline: PerceptionPipeline, onResult: @escaping @MainActor (PerceptionResult?, Status) -> Void) {
        self.pipeline = pipeline
        self.onResult = onResult
    }

    func setActive(_ a: Bool) { state.withLock { $0.active = a } }

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        if anchors.contains(where: { ($0 as? ARPlaneAnchor)?.alignment == .horizontal }) {
            state.withLock { $0.planeFound = true }
        }
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let (go, sendStatus, plane): (Bool, Bool, Bool) = state.withLock { s in
            let now = frame.timestamp
            let status = now - s.lastStatus > 0.25
            if status { s.lastStatus = now }
            guard s.active, !s.busy else { return (false, status, s.planeFound) }
            s.busy = true
            return (true, status, s.planeFound)
        }
        let tracking: Bool = { if case .normal = frame.camera.trackingState { return true } else { return false } }()
        let status = Status(planeFound: plane, trackingOK: tracking,
                            depthConfidence: sendStatus ? Self.depthConfidence(frame) : nil)
        let onResult = onResult
        guard go else {
            if sendStatus { Task { @MainActor in onResult(nil, status) } }
            return
        }
        guard let img = PixelImage(pixelBuffer: frame.capturedImage, maxWidth: 960) else {
            state.withLock { $0.busy = false }
            return
        }
        let k = frame.camera.intrinsics, res = frame.camera.imageResolution
        let intr = CameraIntrinsics(fx: Double(k[0][0]), fy: Double(k[1][1]), cx: Double(k[2][0]), cy: Double(k[2][1]),
                                    width: Double(res.width), height: Double(res.height))
        let cam = CameraModel(intrinsics: intr, cameraToWorld: frame.camera.transform.toDouble)
        let pf = PerceptionFrame(image: img, camera: cam, timestamp: frame.timestamp)
        let pipeline = pipeline
        Task.detached(priority: .userInitiated) { [weak self] in
            let r = await pipeline.process(pf)
            self?.state.withLock { $0.busy = false }
            await MainActor.run { onResult(r, status) }
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        // Fall back to a plain configuration (e.g. a semantics combination the device refuses).
        let c = ARWorldTrackingConfiguration()
        c.planeDetection = [.horizontal]
        session.run(c)
    }

    private static func depthConfidence(_ frame: ARFrame) -> Double? {
        guard let map = frame.sceneDepth?.confidenceMap else { return nil }
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(map) else { return nil }
        let w = CVPixelBufferGetWidth(map), h = CVPixelBufferGetHeight(map), rb = CVPixelBufferGetBytesPerRow(map)
        let p = base.assumingMemoryBound(to: UInt8.self)
        var high = 0, n = 0
        for y in stride(from: 0, to: h, by: 4) {
            for x in stride(from: 0, to: w, by: 4) {
                if p[y * rb + x] == UInt8(ARConfidenceLevel.high.rawValue) { high += 1 }
                n += 1
            }
        }
        return n > 0 ? Double(high) / Double(n) : nil
    }
}

/// RealityKit entities in table coordinates (x length, y width, z up).
@MainActor
final class TableOverlay {
    let anchor: AnchorEntity
    private let spec: TableSpec
    private var ballRings: [ModelEntity] = []
    private let cueLine: ModelEntity
    private let objectLine: ModelEntity
    private let ghost: ModelEntity
    private let R = Float(TableSpec.ballRadius)

    init(frame: TableFrame) {
        spec = frame.spec
        anchor = AnchorEntity(world: frame.tableToWorld.toFloat)
        let L = Float(spec.length), W = Float(spec.width)
        let outline = OverlayMesh.material(.white, 0.55)
        let edges: [(SIMD2<Float>, SIMD2<Float>)] = [([0, 0], [L, 0]), ([L, 0], [L, W]), ([L, W], [0, W]), ([0, W], [0, 0])]
        for (a, b) in edges { anchor.addChild(OverlayMesh.segment(from: a, to: b, z: 0.002, width: 0.006, material: outline)) }
        let pocketMat = OverlayMesh.material(.white, 0.7)
        for p in spec.pockets {
            let c = spec.pocketCenter(p)
            let r = Float((p.isSide ? spec.sideMouth : spec.cornerMouth) / 2)
            let e = ModelEntity(mesh: OverlayMesh.ring(inner: r - 0.006, outer: r), materials: [pocketMat])
            e.position = [Float(c.x), Float(c.y), 0.003]
            anchor.addChild(e)
        }
        let ringMesh = OverlayMesh.ring(inner: R * 1.12, outer: R * 1.32)
        for _ in 0..<16 {
            let e = ModelEntity(mesh: ringMesh, materials: [OverlayMesh.material(.white, 0.45)])
            e.isEnabled = false
            anchor.addChild(e)
            ballRings.append(e)
        }
        cueLine = OverlayMesh.segment(from: [0, 0], to: [1, 0], z: R, width: 0.005, material: OverlayMesh.material(.white, 0.9))
        objectLine = OverlayMesh.segment(from: [0, 0], to: [1, 0], z: R, width: 0.004, material: OverlayMesh.material(.white, 0.5))
        ghost = ModelEntity(mesh: OverlayMesh.ring(inner: R * 0.92, outer: R), materials: [OverlayMesh.material(.white, 0.9)])
        for e in [cueLine, objectLine, ghost] { e.isEnabled = false; anchor.addChild(e) }
    }

    func update(_ r: PerceptionResult?) {
        let tracks = (r?.tracks ?? []).filter(\.confirmed)
        for (i, ring) in ballRings.enumerated() {
            guard i < tracks.count else { ring.isEnabled = false; continue }
            let t = tracks[i]
            ring.isEnabled = true
            ring.position = [Float(t.position.x), Float(t.position.y), 0.004]
            let cue = t.kind == .cue
            ring.model?.materials = [OverlayMesh.material(cue ? .white : .white, cue ? 0.95 : 0.4)]
            ring.scale = cue ? [1.1, 1.1, 1] : [1, 1, 1]
        }
        guard let aim = r?.aim else {
            for e in [cueLine, objectLine, ghost] { e.isEnabled = false }
            return
        }
        let color: UIColor = aim.ease > 0.35 ? UIColor(red: 0.29, green: 0.87, blue: 0.5, alpha: 1)
            : aim.ease > 0.15 ? UIColor(red: 0.98, green: 0.8, blue: 0.08, alpha: 1)
            : UIColor(red: 0.97, green: 0.44, blue: 0.44, alpha: 1)
        OverlayMesh.place(cueLine, from: aim.cue.f, to: aim.ghost.f, z: R)
        OverlayMesh.place(objectLine, from: aim.object.f, to: aim.pocketPoint.f, z: R)
        objectLine.model?.materials = [OverlayMesh.material(color, 0.75)]
        ghost.position = [Float(aim.ghost.x), Float(aim.ghost.y), R]
        for e in [cueLine, objectLine, ghost] { e.isEnabled = true }
    }
}

private extension Vec2 { var f: SIMD2<Float> { [Float(x), Float(y)] } }

@MainActor
enum OverlayMesh {
    static func material(_ c: UIColor, _ alpha: Double) -> UnlitMaterial {
        var m = UnlitMaterial(color: c)
        m.blending = .transparent(opacity: .init(floatLiteral: Float(alpha)))
        return m
    }

    /// Flat annulus in the local xy-plane, both faces.
    static func ring(inner: Float, outer: Float, segments: Int = 48) -> MeshResource {
        var pos: [SIMD3<Float>] = []
        var idx: [UInt32] = []
        for i in 0..<segments {
            let a = Float(i) / Float(segments) * 2 * .pi
            pos.append([inner * cos(a), inner * sin(a), 0])
            pos.append([outer * cos(a), outer * sin(a), 0])
        }
        for i in 0..<segments {
            let a = UInt32(2 * i), b = a + 1, c = UInt32(2 * ((i + 1) % segments)), d = c + 1
            idx += [a, b, d, a, d, c]   // up
            idx += [a, d, b, a, c, d]   // down
        }
        var desc = MeshDescriptor(name: "ring")
        desc.positions = MeshBuffers.Positions(pos)
        desc.primitives = .triangles(idx)
        return (try? MeshResource.generate(from: [desc])) ?? .generateSphere(radius: outer)
    }

    static func segment(from a: SIMD2<Float>, to b: SIMD2<Float>, z: Float, width: Float, material: UnlitMaterial) -> ModelEntity {
        let e = ModelEntity(mesh: .generateBox(size: [1, width, width * 0.5]), materials: [material])
        place(e, from: a, to: b, z: z)
        return e
    }

    static func place(_ e: Entity, from a: SIMD2<Float>, to b: SIMD2<Float>, z: Float) {
        let d = b - a
        let len = max(0.001, simd_length(d))
        e.position = [(a.x + b.x) / 2, (a.y + b.y) / 2, z]
        e.orientation = simd_quatf(angle: atan2(d.y, d.x), axis: [0, 0, 1])
        e.scale = [len, 1, 1]
    }
}
#endif

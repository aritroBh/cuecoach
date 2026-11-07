#if !targetEnvironment(simulator)
import ARKit
import Combine
import CoreMotion
import Geometry
import RealityKit
import simd
import SwiftUI
import Synchronization
import UIKit
import Vision

/// Full-screen ARKit camera with the table overlay anchored in 3D.
struct ARLiveView: UIViewRepresentable {
    let model: LiveModel
    var locator: any TableLocating = FeltQuadLocator()

    func makeCoordinator() -> ARLiveController { ARLiveController(model: model, locator: locator) }

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        view.renderOptions.insert(.disableMotionBlur)
        view.renderOptions.insert(.disableDepthOfField)
        context.coordinator.attach(view)
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {}

    static func dismantleUIView(_ uiView: ARView, coordinator: ARLiveController) { coordinator.stop() }
}

@MainActor
final class ARLiveController: NSObject {
    let model: LiveModel
    private let locator: any TableLocating
    private weak var view: ARView?
    private let pipeline = PerceptionPipeline()
    private var tap: FrameTap?
    private var markers: CornerMarkers?
    private var overlay: TableOverlay?
    private var thermalObserver: NSObjectProtocol?
    private var sceneUpdate: Cancellable?
    private var markerKey = ""
    private var tier: CapturePolicy.Tier = .max
    private let motion = CMMotionManager()
    private var bump = BumpDetector()
    private var lastStatus: LiveStatus = .searching
    private var planeFoundAt: Date?
    private var tableFrame: TableFrame?
    private var limitedSince: Date?
    private var revalidating = false
    private var wasMerged = false

    init(model: LiveModel, locator: any TableLocating) {
        self.model = model
        self.locator = locator
        super.init()
        model.undo = { [weak self] in self?.undo() }
        model.recalibrate = { [weak self] in self?.recalibrate() }
        model.confirm = { [weak self] in self?.confirm() }
        model.dragHandle = { [weak self] i, p in self?.drag(i, to: p) }
        model.startTapMode = { [weak self] in self?.startTapMode() }
    }

    func attach(_ v: ARView) {
        view = v
        let tap = FrameTap(pipeline: pipeline, locator: locator,
                           onResult: { [weak self] r, s in self?.handle(r, s) },
                           onEstimate: { [weak self] e in self?.handleEstimate(e) })
        self.tap = tap
        v.session.delegate = tap
        v.session.delegateQueue = tap.queue
        tier = CapturePolicy.Tier(ProcessInfo.processInfo.thermalState)
        runSession(v)
        v.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
        let hud = UILongPressGestureRecognizer(target: self, action: #selector(hudGesture(_:)))
        hud.numberOfTouchesRequired = 3
        hud.minimumPressDuration = 0.8
        v.addGestureRecognizer(hud)
        let m = CornerMarkers()
        v.scene.addAnchor(m.anchor)
        markers = m
        sceneUpdate = v.scene.subscribe(to: SceneEvents.Update.self) { [weak self] _ in
            MainActor.assumeIsolated { self?.everyFrame() }
        }
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.thermalChanged() }
        }
        startMotion()
        tap.setMode(.locating)
        UIApplication.shared.isIdleTimerDisabled = true
    }

    func stop() {
        view?.session.pause()
        motion.stopDeviceMotionUpdates()
        sceneUpdate?.cancel()
        UIApplication.shared.isIdleTimerDisabled = false
        if let o = thermalObserver { NotificationCenter.default.removeObserver(o) }
    }

    @objc private func hudGesture(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began else { return }
        let d = UserDefaults.standard
        d.set(!d.bool(forKey: "dev.hud"), forKey: "dev.hud")
        UISelectionFeedbackGenerator().selectionChanged()
    }

    // MARK: Session / formats / thermal

    private func runSession(_ v: ARView) {
        let config = Self.configuration(tier: tier)
        let f = config.videoFormat
        model.formatLabel = "\(Int(f.imageResolution.width))x\(Int(f.imageResolution.height))@\(f.framesPerSecond)"
        tap?.setTier(tier)
        v.session.run(config)  // no reset: the table anchor survives a format change
    }

    private func thermalChanged() {
        let state = ProcessInfo.processInfo.thermalState
        model.thermal = state
        let newTier = CapturePolicy.Tier(state)
        guard newTier != tier, let v = view else { return }
        tier = newTier
        runSession(v)
    }

    static func configuration(tier: CapturePolicy.Tier) -> ARWorldTrackingConfiguration {
        let c = ARWorldTrackingConfiguration()
        c.planeDetection = [.horizontal]
        c.environmentTexturing = .none
        let formats = ARWorldTrackingConfiguration.supportedVideoFormats.filter { $0.captureDeviceType == .builtInWideAngleCamera }
        func pf(_ f: ARConfiguration.VideoFormat) -> CapturePolicy.Format {
            .init(width: Int(f.imageResolution.width), height: Int(f.imageResolution.height), fps: f.framesPerSecond)
        }
        let fourK = ARWorldTrackingConfiguration.recommendedVideoFormatFor4KResolution
        if let pick = CapturePolicy.choose(formats.map(pf), tier: tier, fourK: fourK.map(pf)) {
            if let k = fourK, pf(k) == pick { c.videoFormat = k }
            else if let f = formats.first(where: { pf($0) == pick }) { c.videoFormat = f }
        }
        let extras = CapturePolicy.extras(tier)
        if extras.mesh, ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            c.sceneReconstruction = .meshWithClassification
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) { c.frameSemantics.insert(.sceneDepth) }
        if extras.smoothedDepth, ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            c.frameSemantics.insert(.smoothedSceneDepth)
        }
        if extras.personOcclusion, ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentationWithDepth) {
            c.frameSemantics.insert(.personSegmentationWithDepth)
        }
        return c
    }

    private func startMotion() {
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 20
        motion.startDeviceMotionUpdates(to: .main) { [weak self] dm, _ in
            guard let dm else { return }
            MainActor.assumeIsolated {
                guard let self, self.model.calibrated else { return }
                let a = dm.userAcceleration, r = dm.rotationRate
                let bumped = self.bump.update(userAcceleration: (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot(),
                                              rotationRate: (r.x * r.x + r.y * r.y + r.z * r.z).squareRoot(),
                                              at: dm.timestamp)
                if self.model.bumped != bumped { self.model.bumped = bumped }
            }
        }
    }

    // MARK: Per render frame: handle positions + markers + state transitions

    private func everyFrame() {
        guard let v = view else { return }
        let editor = model.editor
        let alpha = model.manualCorrection || model.tapMode ? 1 : 0.25 + 0.75 * model.ghostConfidence
        let key = "\(editor.revision)-\(Int(alpha * 10))-\(model.calibrated)"
        if key != markerKey {
            markerKey = key
            markers?.rebuild(corners: editor.corners, perimeter: editor.perimeter, outlier: editor.outlier,
                             alpha: alpha, hidden: model.calibrated)
        }
        if model.calibrated {
            if !model.handles.isEmpty { model.handles = [] }
        } else {
            model.handles = editor.corners.map { w in v.project(w.f).map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) } }
        }
        let st = model.status
        if st != lastStatus {
            if st == .trackingLost || st == .phoneMoved { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
            overlay?.setDimmed(st.showsRecalibratePulse)
            lastStatus = st
        }
        // Tap-4 only as a last resort: after 12 s with a plane but no confident ghost.
        if !model.calibrated, !model.showTapFallback, let t = planeFoundAt, Date().timeIntervalSince(t) > 12,
           model.ghostConfidence < 0.5 {
            model.showTapFallback = true
        }
    }

    // MARK: Locator

    private func handleEstimate(_ e: TableEstimate?) {
        if revalidating, let e, e.locked, let current = tableFrame {
            // After relocalization: keep the lock if the table is where we left it, else re-anchor.
            let now = current.corners.map { current.world($0) }
            let moved = e.corners.map { c in now.map { simd_distance($0, c) }.min() ?? 0 }.max() ?? 0
            revalidating = false
            if moved > 0.06, let fit = TableFitter.fit(corners: e.corners, viewer: viewerPosition(), size: current.spec.size) {
                install(fit.frame)
            }
            tap?.setMode(.detecting)
            return
        }
        guard let e, !model.calibrated, !model.manualCorrection, !model.tapMode else { return }
        model.editor.setProposal(e.corners)
        model.ghostConfidence = e.confidence
        if e.locked { confirm() }
    }

    // MARK: Corners (correction drag, tap-4 fallback)

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        guard let v = view, !model.calibrated else { return }
        guard model.planeFound else {
            model.notReadyTick += 1
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }
        guard model.tapMode || model.editor.outlier != nil else { return }
        guard let w = worldPoint(at: g.location(in: v), in: v) else {
            model.notReadyTick += 1
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }
        if model.editor.add(w) { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    }

    private func startTapMode() {
        model.tapMode = true
        model.manualCorrection = true
        model.editor.reset()
    }

    /// Screen → table-plane point: the corners' plane once known, else ARKit planes.
    private func worldPoint(at p: CGPoint, in v: ARView) -> SIMD3<Double>? {
        if let plane = model.editor.plane, let ray = v.ray(through: p) {
            return plane.intersect(origin: ray.origin.d, direction: simd_normalize(ray.direction.d))
        }
        let hit = v.raycast(from: p, allowing: .existingPlaneGeometry, alignment: .horizontal).first
            ?? v.raycast(from: p, allowing: .estimatedPlane, alignment: .horizontal).first
        guard let t = hit?.worldTransform.columns.3 else { return nil }
        return SIMD3(Double(t.x), Double(t.y), Double(t.z))
    }

    private func drag(_ i: Int, to p: CGPoint) {
        guard let v = view, !model.calibrated, let w = worldPoint(at: p, in: v) else { return }
        if !model.manualCorrection { model.manualCorrection = true }
        model.editor.move(i, to: w)
    }

    private func undo() {
        guard !model.calibrated else { return }
        model.editor.undo()
    }

    private func confirm() {
        guard let v = view, !model.calibrated else { return }
        let t = v.cameraTransform.translation
        guard let fit = model.editor.confirm(viewer: SIMD3(Double(t.x), Double(t.y), Double(t.z))) else {
            if model.manualCorrection || model.tapMode { UINotificationFeedbackGenerator().notificationOccurred(.error) }
            return
        }
        install(fit.frame)
        model.tableSize = fit.frame.spec.size
        model.calibrated = true
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        tap?.setMode(.detecting)
    }

    private func install(_ frame: TableFrame) {
        guard let v = view else { return }
        if let o = overlay { v.scene.removeAnchor(o.anchor) }
        let o = TableOverlay(frame: frame)
        v.scene.addAnchor(o.anchor)
        overlay = o
        tableFrame = frame
        let pipeline = pipeline
        Task { await pipeline.setTable(frame) }
    }

    private func viewerPosition() -> SIMD3<Double>? {
        guard let t = view?.cameraTransform.translation else { return nil }
        return SIMD3(Double(t.x), Double(t.y), Double(t.z))
    }

    private func recalibrate() {
        tap?.setMode(.idle)
        let pipeline = pipeline, locator = locator
        if let o = overlay { view?.scene.removeAnchor(o.anchor) }
        overlay = nil
        tableFrame = nil
        revalidating = false
        model.clearCalibration()
        planeFoundAt = model.planeFound ? Date() : nil
        Task {
            await pipeline.setTable(nil)
            await locator.reset()
            await MainActor.run { [weak self] in self?.tap?.setMode(.locating) }
        }
    }

    /// Re-run the locator once after relocalization; perception resumes when it answers.
    private func revalidate() {
        revalidating = true
        tap?.setMode(.idle)
        let locator = locator
        Task {
            await locator.reset()
            await MainActor.run { [weak self] in self?.tap?.setMode(.locating) }
        }
        // Don't stall forever: resume detecting after 4 s even without a fresh lock.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, self.revalidating else { return }
            self.revalidating = false
            self.tap?.setMode(.detecting)
        }
    }

    // MARK: Results

    private func handle(_ r: PerceptionResult?, _ s: FrameTap.Status) {
        if s.planeFound && !model.planeFound {
            model.planeFound = true
            planeFoundAt = Date()
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
        if model.trackingOK != s.trackingOK {
            model.trackingOK = s.trackingOK
            if !s.trackingOK {
                limitedSince = Date()
            } else if let since = limitedSince, model.calibrated, Date().timeIntervalSince(since) > 1 {
                limitedSince = nil
                revalidate()
            } else {
                limitedSince = nil
            }
        }
        if let d = s.depthConfidence { model.depthConfidence = d }
        guard model.calibrated, s.isResult else { return }
        model.noteResult(r)
        overlay?.update(r)
        if let r {
            // Shot events are haptic only (no audio, no text while aiming).
            if r.shotStarted { UIImpactFeedbackGenerator(style: .soft).impactOccurred() }
            if r.shot != nil { UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.6) }
            let merged = r.convergence > 0.8
            if merged && !wasMerged { UISelectionFeedbackGenerator().selectionChanged() }  // aim locked onto the line
            wasMerged = merged
        }
    }
}

/// ARSession delegate on its own queue: turns ARFrames into small Sendable frames, drops frames while busy.
/// Locating mode feeds the table locator; detecting mode feeds ball perception.
final class FrameTap: NSObject, ARSessionDelegate, @unchecked Sendable {
    struct Status: Sendable { var planeFound: Bool; var trackingOK: Bool; var depthConfidence: Double?; var isResult = false }
    enum Mode: Sendable { case idle, locating, detecting }

    let queue = DispatchQueue(label: "cuecoach.arframes", qos: .userInteractive)
    private let pipeline: PerceptionPipeline
    private let locator: any TableLocating
    private let onResult: @MainActor (PerceptionResult?, Status) -> Void
    private let onEstimate: @MainActor (TableEstimate?) -> Void
    private let state = Mutex((busy: false, mode: Mode.idle, planeFound: false, lastStatus: 0.0, lastRun: 0.0,
                               interval: 1.0 / 30, width: 960, lastPose: 0.0, wrists: [Vec2]()))
    /// Used only on `queue`.
    private let poseRequest = VNDetectHumanBodyPoseRequest()

    init(pipeline: PerceptionPipeline, locator: any TableLocating,
         onResult: @escaping @MainActor (PerceptionResult?, Status) -> Void,
         onEstimate: @escaping @MainActor (TableEstimate?) -> Void) {
        self.pipeline = pipeline
        self.locator = locator
        self.onResult = onResult
        self.onEstimate = onEstimate
    }

    func setMode(_ m: Mode) { state.withLock { $0.mode = m } }

    func setTier(_ t: CapturePolicy.Tier) {
        state.withLock {
            $0.interval = CapturePolicy.detectInterval(t)
            $0.width = CapturePolicy.detectWidth(source: t == .max ? 3840 : 1920, tier: t)
        }
    }

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        if anchors.contains(where: { ($0 as? ARPlaneAnchor)?.alignment == .horizontal }) {
            state.withLock { $0.planeFound = true }
        }
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let (mode, sendStatus, plane, width): (Mode, Bool, Bool, Int) = state.withLock { s in
            let now = frame.timestamp
            let status = now - s.lastStatus > 0.25
            if status { s.lastStatus = now }
            let interval = s.mode == .locating ? 0.2 : s.interval
            guard s.mode != .idle, !s.busy, now - s.lastRun >= interval * 0.9 else { return (.idle, status, s.planeFound, 0) }
            if s.mode == .locating && !s.planeFound { return (.idle, status, s.planeFound, 0) }
            s.busy = true
            s.lastRun = now
            return (s.mode, status, s.planeFound, s.width)
        }
        let tracking: Bool = { if case .normal = frame.camera.trackingState { return true } else { return false } }()
        let status = Status(planeFound: plane, trackingOK: tracking,
                            depthConfidence: sendStatus ? Self.depthConfidence(frame) : nil)
        let onResult = onResult, onEstimate = onEstimate
        // World-anchored work is meaningless while ARKit is relocalizing: pause it.
        guard mode != .idle, tracking else {
            if mode != .idle { state.withLock { $0.busy = false } }
            if sendStatus { Task { @MainActor in onResult(nil, status) } }
            return
        }
        guard let img = PixelImage(pixelBuffer: frame.capturedImage, maxWidth: mode == .locating ? 960 : width) else {
            state.withLock { $0.busy = false }
            return
        }
        let cam = CameraModel(arCamera: frame.camera)
        if mode == .locating {
            let planes = frame.anchors.compactMap { a -> LocatorPlane? in
                guard let p = a as? ARPlaneAnchor, p.alignment == .horizontal else { return nil }
                let c = p.transform * SIMD4<Float>(p.center, 1)
                let ext = p.planeExtent
                return LocatorPlane(center: SIMD3(Double(c.x), Double(c.y), Double(c.z)),
                                    extent: SIMD2(Double(ext.width), Double(ext.height)),
                                    isTable: p.classification == .table)
            }
            let lf = LocatorFrame(image: img, camera: cam, planes: planes, timestamp: frame.timestamp)
            let locator = locator
            Task.detached(priority: .userInitiated) { [weak self] in
                let e = await locator.ingest(lf)
                self?.state.withLock { $0.busy = false }
                await MainActor.run { onEstimate(e); onResult(nil, status) }
            }
            return
        }
        let wrists = bodyPoseWrists(frame)
        let pf = PerceptionFrame(image: img, camera: cam, timestamp: frame.timestamp, depth: Self.depthMap(frame),
                                 wrists: wrists)
        let pipeline = pipeline
        var rs = status
        rs.isResult = true
        let resultStatus = rs
        Task.detached(priority: .userInitiated) { [weak self] in
            let r = await pipeline.process(pf)
            self?.state.withLock { $0.busy = false }
            await MainActor.run { onResult(r, resultStatus) }
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        // Drop the heavy extras, keep LiDAR depth.
        let c = ARWorldTrackingConfiguration()
        c.planeDetection = [.horizontal]
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) { c.frameSemantics = [.sceneDepth] }
        session.run(c)
    }

    /// Shooter wrists (source pixels) from Vision body pose, refreshed at ~6 Hz on the ANE.
    private func bodyPoseWrists(_ frame: ARFrame) -> [Vec2] {
        let now = frame.timestamp
        let due = state.withLock { s -> Bool in
            guard now - s.lastPose > 0.16 else { return false }
            s.lastPose = now
            return true
        }
        guard due else { return state.withLock { $0.wrists } }
        let w = Double(CVPixelBufferGetWidth(frame.capturedImage)), h = Double(CVPixelBufferGetHeight(frame.capturedImage))
        let handler = VNImageRequestHandler(cvPixelBuffer: frame.capturedImage, orientation: .up)
        var found: [Vec2] = []
        if (try? handler.perform([poseRequest])) != nil {
            for obs in poseRequest.results ?? [] {
                for joint in [VNHumanBodyPoseObservation.JointName.leftWrist, .rightWrist] {
                    if let p = try? obs.recognizedPoint(joint), p.confidence > 0.3 {
                        found.append(Vec2(Double(p.location.x) * w, (1 - Double(p.location.y)) * h))
                    }
                }
            }
        }
        state.withLock { $0.wrists = found }
        return found
    }

    /// LiDAR depth (smoothed when available), copied out so the ARFrame isn't retained.
    private static func depthMap(_ frame: ARFrame) -> DepthMap? {
        guard let sd = frame.smoothedSceneDepth ?? frame.sceneDepth else { return nil }
        let map = sd.depthMap
        guard CVPixelBufferGetPixelFormatType(map) == kCVPixelFormatType_DepthFloat32 else { return nil }
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(map) else { return nil }
        let w = CVPixelBufferGetWidth(map), h = CVPixelBufferGetHeight(map), rb = CVPixelBufferGetBytesPerRow(map)
        var depth = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            let row = (base + y * rb).assumingMemoryBound(to: Float.self)
            for x in 0..<w { depth[y * w + x] = row[x] }
        }
        var conf: [UInt8]?
        if let cm = sd.confidenceMap {
            CVPixelBufferLockBaseAddress(cm, .readOnly)
            if let cb = CVPixelBufferGetBaseAddress(cm) {
                let crb = CVPixelBufferGetBytesPerRow(cm)
                var c = [UInt8](repeating: 0, count: w * h)
                for y in 0..<h { let row = (cb + y * crb).assumingMemoryBound(to: UInt8.self); for x in 0..<w { c[y * w + x] = row[x] } }
                conf = c
            }
            CVPixelBufferUnlockBaseAddress(cm, .readOnly)
        }
        return DepthMap(width: w, height: h, depth: depth, confidence: conf)
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

/// Glowing corner markers on the cloth + the ghost outline between them while locating/correcting.
@MainActor
final class CornerMarkers {
    let anchor = AnchorEntity(world: SIMD3<Float>(0, 0, 0))

    func rebuild(corners: [SIMD3<Double>], perimeter: [SIMD3<Double>], outlier: Int?, alpha: Double, hidden: Bool) {
        for c in anchor.children.map({ $0 }) { c.removeFromParent() }
        guard !hidden else { return }
        for (i, w) in corners.enumerated() {
            let color = i == outlier ? TableOverlay.red : TableOverlay.green
            let a = i == outlier ? 1 : alpha
            let dot = ModelEntity(mesh: .generateSphere(radius: 0.018), materials: [OverlayMesh.material(color, a)])
            dot.position = w.f + [0, 0.02, 0]
            anchor.addChild(dot)
            let halo = ModelEntity(mesh: OverlayMesh.ring(inner: 0.035, outer: 0.05), materials: [OverlayMesh.material(color, a * 0.8)])
            halo.position = w.f + [0, 0.003, 0]
            halo.orientation = simd_quatf(angle: -.pi / 2, axis: [1, 0, 0])
            anchor.addChild(halo)
        }
        let ring = perimeter
        let closed = ring.count == 4
        let n = closed ? 4 : max(0, ring.count - 1)
        for i in 0..<n {
            let a = ring[i], b = ring[(i + 1) % ring.count]
            anchor.addChild(OverlayMesh.segment3D(from: a.f + [0, 0.004, 0], to: b.f + [0, 0.004, 0], width: 0.008,
                                                  material: OverlayMesh.material(.white, alpha * 0.85)))
        }
    }
}

/// RealityKit entities in table coordinates (x length, y width, z up).
@MainActor
final class TableOverlay {
    let anchor: AnchorEntity
    private let spec: TableSpec
    private var outline: [ModelEntity] = []
    private var ballRings: [ModelEntity] = []
    private let cueLine: ModelEntity
    private let objectLine: ModelEntity
    private let ghost: ModelEntity
    private var dashes: [ModelEntity] = []
    private let liveLine: ModelEntity
    private let liveObject: ModelEntity
    private let liveGhost: ModelEntity
    private let R = Float(TableSpec.ballRadius)
    private var dimmed = false

    static let green = UIColor(red: 0.29, green: 0.87, blue: 0.5, alpha: 1)    // #4ADE80
    static let yellow = UIColor(red: 0.98, green: 0.8, blue: 0.08, alpha: 1)   // #FACC15
    static let red = UIColor(red: 0.97, green: 0.44, blue: 0.44, alpha: 1)     // #F87171

    init(frame: TableFrame) {
        spec = frame.spec
        anchor = AnchorEntity(world: frame.tableToWorld.toFloat)
        let L = Float(spec.length), W = Float(spec.width)
        let edges: [(SIMD2<Float>, SIMD2<Float>)] = [([0, 0], [L, 0]), ([L, 0], [L, W]), ([L, W], [0, W]), ([0, W], [0, 0])]
        for (a, b) in edges {
            let e = OverlayMesh.segment(from: a, to: b, z: 0.002, width: 0.006, material: OverlayMesh.material(.white, 0.55))
            outline.append(e); anchor.addChild(e)
        }
        for p in spec.pockets {
            let c = spec.pocketCenter(p)
            let r = Float((p.isSide ? spec.sideMouth : spec.cornerMouth) / 2)
            let e = ModelEntity(mesh: OverlayMesh.ring(inner: r - 0.006, outer: r), materials: [OverlayMesh.material(.white, 0.7)])
            e.position = [Float(c.x), Float(c.y), 0.003]
            outline.append(e); anchor.addChild(e)
        }
        let ringMesh = OverlayMesh.ring(inner: R * 1.12, outer: R * 1.34)
        for _ in 0..<16 {
            let e = ModelEntity(mesh: ringMesh, materials: [OverlayMesh.material(.white, 0.45)])
            e.isEnabled = false
            anchor.addChild(e); ballRings.append(e)
        }
        cueLine = OverlayMesh.segment(from: [0, 0], to: [1, 0], z: R, width: 0.005, material: OverlayMesh.material(.white, 0.9))
        objectLine = OverlayMesh.segment(from: [0, 0], to: [1, 0], z: R, width: 0.005, material: OverlayMesh.material(.white, 0.7))
        ghost = ModelEntity(mesh: OverlayMesh.ring(inner: R * 0.9, outer: R), materials: [OverlayMesh.material(.white, 0.9)])
        for e in [cueLine, objectLine, ghost] { e.isEnabled = false; anchor.addChild(e) }
        liveLine = OverlayMesh.segment(from: [0, 0], to: [1, 0], z: R, width: 0.006, material: OverlayMesh.material(.white, 1))
        liveObject = OverlayMesh.segment(from: [0, 0], to: [1, 0], z: R, width: 0.004, material: OverlayMesh.material(.white, 0.7))
        liveGhost = ModelEntity(mesh: OverlayMesh.ring(inner: R * 0.88, outer: R), materials: [OverlayMesh.material(.white, 1)])
        for e in [liveLine, liveObject, liveGhost] { e.isEnabled = false; anchor.addChild(e) }
        for _ in 0..<14 {
            let d = OverlayMesh.segment(from: [0, 0], to: [1, 0], z: R, width: 0.004, material: OverlayMesh.material(.white, 0.45))
            d.isEnabled = false
            anchor.addChild(d); dashes.append(d)
        }
    }

    func setDimmed(_ d: Bool) {
        dimmed = d
        for e in outline { e.model?.materials = [OverlayMesh.material(.white, d ? 0.2 : 0.6)] }
        if d { for e in ballRings + dashes + [cueLine, objectLine, ghost, liveLine, liveObject, liveGhost] { e.isEnabled = false } }
    }

    func update(_ r: PerceptionResult?) {
        guard !dimmed else { return }
        let tracks = r?.confirmed ?? []
        for (i, ring) in ballRings.enumerated() {
            guard i < tracks.count else { ring.isEnabled = false; continue }
            let t = tracks[i]
            ring.isEnabled = true
            ring.position = [Float(t.position.x), Float(t.position.y), 0.004]
            let (color, alpha): (UIColor, Double) = switch r?.marks[t.id] ?? .unknown {
            case .cue: (.white, 0.95)
            case .legal: (Self.green, 0.85)
            case .illegal: (Self.red, 0.8)
            case .unknown: (.white, 0.35)
            }
            ring.model?.materials = [OverlayMesh.material(color, alpha)]
            ring.scale = r?.marks[t.id] == .cue ? [1.1, 1.1, 1] : [1, 1, 1]
        }
        // Live aim from the cue stick: bright, turns green as it merges with the suggestion.
        let live = r?.liveAim
        if let live {
            let merged = (r?.convergence ?? 0) > 0.8
            let c: UIColor = merged ? Self.green : .white
            OverlayMesh.place(liveLine, from: live.cue.f, to: live.end.f, z: R)
            liveLine.model?.materials = [OverlayMesh.material(c, 0.95)]
            liveLine.isEnabled = true
            if let g = live.ghost, let od = live.objectDirection, let i = live.hitIndex, i >= 0 {
                liveGhost.position = [Float(g.x), Float(g.y), R]
                liveGhost.model?.materials = [OverlayMesh.material(c, 0.95)]
                let start = g + od * (2 * TableSpec.ballRadius)
                let end = AimPlanner.clipToTable(from: start, dir: od, maxLength: 0.6, spec: spec)
                OverlayMesh.place(liveObject, from: start.f, to: end.f, z: R)
                liveObject.model?.materials = [OverlayMesh.material(c, 0.7)]
                liveGhost.isEnabled = true; liveObject.isEnabled = true
            } else { liveGhost.isEnabled = false; liveObject.isEnabled = false }
        } else {
            for e in [liveLine, liveObject, liveGhost] { e.isEnabled = false }
        }
        guard let aim = r?.aim else {
            for e in dashes + [cueLine, objectLine, ghost] { e.isEnabled = false }
            return
        }
        // With a live cue the suggestion becomes a faint guide.
        let guide = live == nil ? 1.0 : 0.3
        let color = aim.ease > 0.35 ? Self.green : aim.ease > 0.15 ? Self.yellow : Self.red
        OverlayMesh.place(cueLine, from: aim.cue.f, to: aim.ghost.f, z: R)                 // Line 1
        cueLine.model?.materials = [OverlayMesh.material(.white, 0.9 * guide)]
        ghost.model?.materials = [OverlayMesh.material(.white, 0.9 * guide)]
        OverlayMesh.place(objectLine, from: aim.object.f, to: aim.pocketPoint.f, z: R)     // Line 2 (throw-compensated)
        objectLine.model?.materials = [OverlayMesh.material(color, 0.85 * guide)]
        ghost.position = [Float(aim.ghost.x), Float(aim.ghost.y), R]
        for e in [cueLine, objectLine, ghost] { e.isEnabled = true }
        // Line 3: dashed cue path after contact.
        var segs: [(SIMD2<Float>, SIMD2<Float>)] = []
        if aim.cuePath.count >= 2 {
            let a = aim.cuePath[0].f, b = aim.cuePath[aim.cuePath.count - 1].f
            let len = simd_length(b - a), dash: Float = 0.04, gap: Float = 0.03
            if len > 0.01 {
                let u = (b - a) / len
                var s = Float(TableSpec.ballRadius)
                while s < len && segs.count < dashes.count {
                    segs.append((a + u * s, a + u * min(len, s + dash)))
                    s += dash + gap
                }
            }
        }
        for (i, d) in dashes.enumerated() {
            if i < segs.count { OverlayMesh.place(d, from: segs[i].0, to: segs[i].1, z: R); d.isEnabled = true }
            else { d.isEnabled = false }
        }
    }
}

private extension Vec2 { var f: SIMD2<Float> { [Float(x), Float(y)] } }
private extension SIMD3<Double> { var f: SIMD3<Float> { SIMD3<Float>(Float(x), Float(y), Float(z)) } }
private extension SIMD3<Float> { var d: SIMD3<Double> { SIMD3<Double>(Double(x), Double(y), Double(z)) } }

extension CameraModel {
    init(arCamera c: ARCamera) {
        let k = c.intrinsics, res = c.imageResolution
        self.init(intrinsics: CameraIntrinsics(fx: Double(k[0][0]), fy: Double(k[1][1]), cx: Double(k[2][0]),
                                               cy: Double(k[2][1]), width: Double(res.width), height: Double(res.height)),
                  cameraToWorld: c.transform.toDouble)
    }
}

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
            idx += [a, b, d, a, d, c]
            idx += [a, d, b, a, c, d]
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

    static func segment3D(from a: SIMD3<Float>, to b: SIMD3<Float>, width: Float, material: UnlitMaterial) -> ModelEntity {
        let e = ModelEntity(mesh: .generateBox(size: [1, width * 0.5, width]), materials: [material])
        let d = b - a, len = max(0.001, simd_length(d))
        e.position = (a + b) / 2
        e.orientation = simd_quatf(from: [1, 0, 0], to: d / len)
        e.scale = [len, 1, 1]
        return e
    }
}
#endif

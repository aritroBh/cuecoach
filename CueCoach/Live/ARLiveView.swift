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
    /// Lock source = AutoTableLocator (lock plan step 1); FeltQuad only seeds the ghost inside the adapter.
    var locator: any TableLocating = AutoTableLocating()

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
    private let pipeline = PerceptionPipeline(detector: PerceptionPipeline.defaultDetector())
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
    private var locatingSince = Date()
    private var failureTimer = FailureTimer()
    private var tableFrame: TableFrame?
    private var limitedSince: Date?
    private var revalidating = false
    private var convergenceLatch = ConvergenceLatch()
    private var illegalAimLatch = EntryLatch()
    private var resultOrder = FrameOrdering()
    private var lastStatusSeq = -1
    private var estimateOrder = FrameOrdering()

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
        let pipeline = pipeline
        model.legalChanged = { legal in Task { await pipeline.setLegal(legal) } }
        let seed = model.initialLegalTargets()   // the shell's active game, before any shot
        Task { await pipeline.setLegal(seed) }
        let tap = FrameTap(pipeline: pipeline, locator: locator,
                           onResult: { [weak self] r, s in self?.handle(r, s) },
                           onEstimate: { [weak self] e, s in self?.handleEstimate(e, s) })
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
        // Corner fallback: after ~4 s unlocked, or the same failure for 2.5 s (plane or not).
        let now = Date().timeIntervalSinceReferenceDate
        if !model.calibrated, !model.showTapFallback, !model.tapMode, !model.manualCorrection,
           FallbackPolicy.offer(unlockedFor: Date().timeIntervalSince(locatingSince),
                                sameFailureFor: failureTimer.sameFor(at: now)) {
            model.showTapFallback = true
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }
    }

    // MARK: Locator

    private func handleEstimate(_ e: TableEstimate?, _ s: FrameTap.Status) {
        guard let tap, estimateOrder.accept(seq: s.seq, epoch: s.epoch, currentEpoch: tap.epoch) else { return }
        if !model.calibrated {
            model.lockFailure = e?.failure
            failureTimer.note(e?.failure, at: Date().timeIntervalSinceReferenceDate)
            // Candidate corners the user's drags snap to (the locator's current best guess).
            if let e, e.corners.count == 4, e.confidence >= 0.25 { model.snapTargets = e.corners }
        }
        if revalidating, let e, e.locked, let current = tableFrame {
            // After relocalization: keep the lock if the table is where we left it, else re-anchor.
            let now = current.corners.map { current.world($0) }
            let moved = e.corners.map { c in now.map { simd_distance($0, c) }.min() ?? 0 }.max() ?? 0
            var frame = current
            if moved > 0.06 {
                guard let fit = TableFitter.fit(corners: e.corners, viewer: viewerPosition(), size: current.spec.size) else {
                    // Moved but can't fit: stay relocking (dimmed, no perception) and keep searching.
                    Task { await locator.reset() }
                    return
                }
                frame = fit.frame
            }
            revalidating = false
            installThenDetect(frame) { [weak self] in
                self?.model.relocking = false
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
            return
        }
        if revalidating { return }   // still relocking: keep the old table hidden, don't treat as a new table
        guard let e, !model.calibrated, !model.manualCorrection, !model.tapMode else { return }
        if e.corners.count == 4 { model.editor.setProposal(e.corners) }
        model.ghostConfidence = e.confidence
        if e.locked {
            if let frame = e.frame { lockAuto(frame) } else { confirm() }
        }
    }

    // MARK: Corners (correction drag, tap-4 fallback)

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        guard let v = view, !model.calibrated else { return }
        guard model.tapMode || model.editor.outlier != nil else { return }
        guard let w = worldPoint(at: g.location(in: v), in: v) else {
            model.notReadyTick += 1
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }
        if model.tapMode {
            // Two-tap fallback: the two corner pockets nearest the user, any order; plane + preset fill the rest.
            guard model.editor.add(w) else { return }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            if model.editor.corners.count == 2, let viewer = viewerPosition(),
               let four = TwoTapTable.corners(model.editor.corners[0], model.editor.corners[1], viewer: viewer,
                                              size: TableHealth.measuredSize()) {
                model.editor.setProposal(four)
                model.tapMode = false          // now drag any corner (loupe + snap), then ✓
                model.manualCorrection = true
            }
            return
        }
        if model.editor.add(w) { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    }

    /// Manual fallback keeps the best ghost: with 4 corners it opens straight into drag-to-correct;
    /// otherwise the user taps the corners (taps work before ARKit finds a plane via estimatedPlane).
    private func startTapMode() {
        model.manualCorrection = true
        model.showTapFallback = false
        if model.editor.isComplete {
            model.tapMode = false
        } else {
            model.tapMode = true
            model.editor.reset()
        }
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
        guard let v = view, !model.calibrated else { return }
        // Snap to the locator's candidate corners (rail/pocket evidence) when close.
        let targets = model.snapTargets.compactMap { v.project($0.f).map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) } }
        let snapped = DragSnap.snap(p, to: targets, radius: 30)
        if snapped != nil && model.snappedHandle != i { UISelectionFeedbackGenerator().selectionChanged() }
        model.snappedHandle = snapped == nil ? nil : i
        guard let w = worldPoint(at: snapped ?? p, in: v) else { return }
        if !model.manualCorrection { model.manualCorrection = true }
        model.editor.move(i, to: w)
        updateLoupe(at: snapped ?? p)
    }

    /// Loupe: a magnified snapshot around the handle being dragged (≈10 Hz).
    private var lastLoupe = Date.distantPast
    private func updateLoupe(at p: CGPoint) {
        guard let v = view, Date().timeIntervalSince(lastLoupe) > 0.1 else { model.loupeCenter = p; return }
        lastLoupe = Date()
        model.loupeCenter = p
        v.snapshot(saveToHDR: false) { [weak self] img in
            Task { @MainActor in self?.model.loupeImage = img }
        }
    }

    private func undo() {
        guard !model.calibrated else { return }
        model.editor.undo()
    }

    /// Auto locked: install its exact pose (no re-fit of the corners).
    private func lockAuto(_ frame: TableFrame) {
        guard !model.calibrated else { return }
        TableHealth.rememberMeasured(frame.spec.size)
        model.showAimHint = true
        model.tableSize = frame.spec.size
        model.calibrated = true
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        installThenDetect(frame) {}
    }

    private func confirm() {
        guard let v = view, !model.calibrated else { return }
        let t = v.cameraTransform.translation
        guard let fit = model.editor.confirm(viewer: SIMD3(Double(t.x), Double(t.y), Double(t.z))) else {
            if model.manualCorrection || model.tapMode { UINotificationFeedbackGenerator().notificationOccurred(.error) }
            return
        }
        TableHealth.rememberMeasured(fit.frame.spec.size)   // manual confirm too (Codex r6)
        model.tableSize = fit.frame.spec.size
        model.calibrated = true
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        installThenDetect(fit.frame) {}
    }

    /// Shows the table overlay (with the lock-in settle animation) and only starts detecting once the
    /// perception pipeline has the new table — never against a stale frame.
    private func installThenDetect(_ frame: TableFrame, then done: @escaping @MainActor () -> Void) {
        guard let v = view else { return }
        if let o = overlay { v.scene.removeAnchor(o.anchor) }
        let o = TableOverlay(frame: frame, visibility: model.visibility)
        v.scene.addAnchor(o.anchor)
        o.playLockIn()
        overlay = o
        tableFrame = frame
        tap?.setMode(.idle)
        model.perceptionReset()   // the segmenter starts over: close any open aim/shot for the shell
        let pipeline = pipeline
        Task { @MainActor [weak self] in
            await pipeline.setTable(frame)
            guard let self, self.tableFrame == nil || self.overlay === o else { return }
            self.tap?.setMode(.detecting)
            done()
        }
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
        model.perceptionReset()
        model.clearCalibration()
        planeFoundAt = model.planeFound ? Date() : nil
        locatingSince = Date()
        failureTimer = FailureTimer()
        Task {
            await pipeline.setTable(nil)
            await locator.reset()
            await MainActor.run { [weak self] in self?.tap?.setMode(.locating) }
        }
    }

    /// After relocalization the old table frame can't be trusted: dim, stop perception, and relock.
    /// Perception resumes only on a fresh lock (no timeout back onto the stale frame); the pulsing
    /// recalibrate button restarts from scratch if the user prefers.
    private func revalidate() {
        revalidating = true
        model.relocking = true
        model.perceptionReset()   // no shot can settle while perception is stopped
        model.noteResult(nil)
        tap?.setMode(.idle)
        let locator = locator
        Task {
            await locator.reset()
            await MainActor.run { [weak self] in self?.tap?.setMode(.locating) }
        }
    }

    // MARK: Results

    private func handle(_ r: PerceptionResult?, _ s: FrameTap.Status) {
        if s.planeFound && !model.planeFound {
            model.planeFound = true
            planeFoundAt = Date()
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
        // Status ticks are ordered too: an older "tracking normal" must not overwrite a newer "limited".
        let fresh = s.seq > lastStatusSeq
        if fresh { lastStatusSeq = s.seq }
        // A limited spell seen on any frame since the last tick (even one shorter than the tick): re-validate.
        if s.limitedSeen, s.trackingOK, model.calibrated, limitedSince == nil, !revalidating { revalidate() }
        if fresh, model.trackingOK != s.trackingOK {
            model.trackingOK = s.trackingOK
            if !s.trackingOK {
                limitedSince = Date()
            } else if limitedSince != nil, model.calibrated {
                // Any limited/relocalizing spell invalidates the table frame (stress B3: a stale frame produced
                // 24 phantom balls) — re-validate however short it was.
                limitedSince = nil
                revalidate()
            } else {
                limitedSince = nil
            }
        }
        if let d = s.depthConfidence { model.depthConfidence = d }
        if let c = s.convertMs { model.convertMs = model.convertMs * 0.8 + c * 0.2 }
        guard model.calibrated, s.isResult, model.status.trustsTable, let tap,
              resultOrder.accept(seq: s.seq, epoch: s.epoch, currentEpoch: tap.epoch) else { return }
        // Balls whose image size doesn't match 57.15 mm at the table's pose: the frame is stale — drop and relock.
        if let r, TableHealth.isStale(ballScale: r.ballScale, detections: r.detections.count) {
            revalidate()
            return
        }
        model.noteResult(r)
        defer { overlay?.update(r) }   // after the live style below is decided (no one-frame lag)
        if let r {
            // Shot events are haptic only (no audio, no text while aiming).
            if r.shotStarted { UIImpactFeedbackGenerator(style: .soft).impactOccurred() }
            if r.shot != nil { UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.6) }
            let now = CACurrentMediaTime()
            // Game mode never hints at the suggested shot, not even by haptic.
            let showsSuggestion = model.visibility.line1
            if convergenceLatch.update(r.liveAim == nil || !showsSuggestion ? 0 : r.convergence, at: now) {
                UISelectionFeedbackGenerator().selectionChanged()   // aim locked onto the suggested line
            }
            let style = LiveAimStyle.of(hitTrackID: r.liveAim == nil ? nil : r.liveTargetID, marks: r.marks,
                                        merged: convergenceLatch.merged)
            if illegalAimLatch.update(style == .illegal, at: now) {
                UINotificationFeedbackGenerator().notificationOccurred(.warning)   // once per entry
            }
            overlay?.liveStyle = style
        }
    }
}

/// ARSession delegate on its own queue: turns ARFrames into small Sendable frames, drops frames while busy.
/// Locating mode feeds the table locator; detecting mode feeds ball perception.
final class FrameTap: NSObject, ARSessionDelegate, @unchecked Sendable {
    struct Status: Sendable {
        var planeFound: Bool; var trackingOK: Bool; var depthConfidence: Double?; var isResult = false
        var seq = 0; var epoch = 0
        var convertMs: Double?
        /// Some frame since the last delivered status had non-normal tracking (latched per frame).
        var limitedSeen = false
    }
    enum Mode: Sendable { case idle, locating, detecting }

    let queue = DispatchQueue(label: "cuecoach.arframes", qos: .userInteractive)
    private let pipeline: PerceptionPipeline
    private let locator: any TableLocating
    private let onResult: @MainActor (PerceptionResult?, Status) -> Void
    private let onEstimate: @MainActor (TableEstimate?, Status) -> Void
    private let state = Mutex((busy: false, mode: Mode.idle, planeFound: false, lastStatus: 0.0, lastRun: 0.0,
                               locateGate: LocatingGate(),
                               interval: 1.0 / 30, width: 960, lastPose: 0.0, wrists: [[Vec2]](),
                               seq: 0, epoch: 0, lastTracking: true, limited: LimitedLatch()))

    /// Current epoch: results stamped with an older one are stale.
    var epoch: Int { state.withLock { $0.epoch } }
    /// Used only on `queue`.
    private let poseRequest = VNDetectHumanBodyPoseRequest()
    /// Reused working-image storage (only touched on `queue`, and only while no job holds it).
    nonisolated(unsafe) private var workBuffer: [UInt8] = []

    init(pipeline: PerceptionPipeline, locator: any TableLocating,
         onResult: @escaping @MainActor (PerceptionResult?, Status) -> Void,
         onEstimate: @escaping @MainActor (TableEstimate?, Status) -> Void) {
        self.pipeline = pipeline
        self.locator = locator
        self.onResult = onResult
        self.onEstimate = onEstimate
    }

    func setMode(_ m: Mode) { state.withLock { $0.mode = m; $0.epoch += 1 } }

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
        let trackingNow: Bool = { if case .normal = frame.camera.trackingState { return true } else { return false } }()
        let (mode, sendStatus, plane, width, seq, epoch): (Mode, Bool, Bool, Int, Int, Int) = state.withLock { s in
            let now = frame.timestamp
            if trackingNow != s.lastTracking { s.lastTracking = trackingNow; s.epoch += 1 }
            s.limited.note(trackingNormal: trackingNow)
            s.seq += 1
            let seq = s.seq, epoch = s.epoch
            let status = now - s.lastStatus > 0.25
            if status { s.lastStatus = now }
            // Locating: the shared LocatingGate (~15 Hz + busy), no plane requirement (provisional LiDAR plane).
            if s.mode == .locating {
                guard s.locateGate.offer(timestamp: now, busy: s.busy) else { return (.idle, status, s.planeFound, 0, seq, epoch) }
            } else {
                guard s.mode != .idle, !s.busy, now - s.lastRun >= s.interval * 0.9 else {
                    return (.idle, status, s.planeFound, 0, seq, epoch)
                }
            }
            s.busy = true
            s.lastRun = now
            return (s.mode, status, s.planeFound, s.width, seq, epoch)
        }
        let tracking = trackingNow
        var status = Status(planeFound: plane, trackingOK: tracking,
                            depthConfidence: sendStatus ? Self.depthConfidence(frame) : nil, seq: seq, epoch: epoch)
        // Hand the latch to whatever this frame delivers (a status tick or a result).
        if FrameDelivery.delivers(statusTick: sendStatus, active: mode != .idle, trackingNormal: tracking) {
            status.limitedSeen = state.withLock { $0.limited.take() }
        }
        let onResult = onResult, onEstimate = onEstimate
        // World-anchored work is meaningless while ARKit is relocalizing: pause it.
        guard mode != .idle, tracking else {
            if mode != .idle { state.withLock { $0.busy = false } }
            if sendStatus { Task { @MainActor in onResult(nil, status) } }
            return
        }
        let c0 = CACurrentMediaTime()
        guard let img = PixelImage.convert(frame.capturedImage, maxWidth: mode == .locating ? 960 : width,
                                           into: &workBuffer) else {
            state.withLock { $0.busy = false }
            return
        }
        let convertMs = (CACurrentMediaTime() - c0) * 1000
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
            let lf = LocatorFrame(image: img, camera: cam, planes: planes, timestamp: frame.timestamp,
                                  depth: Self.depthMap(frame), trackingNormal: tracking)
            let locator = locator
            Task.detached(priority: .userInitiated) { [weak self] in
                let e = await locator.ingest(lf)
                self?.state.withLock { $0.busy = false }
                await MainActor.run { onEstimate(e, status); onResult(nil, status) }
            }
            return
        }
        let people = bodyPoseWrists(frame)
        let pf = PerceptionFrame(image: img, camera: cam, timestamp: frame.timestamp, depth: Self.depthMap(frame),
                                 wristsByPerson: people)
        let pipeline = pipeline
        var rs = status
        rs.isResult = true
        rs.convertMs = convertMs
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

    /// Wrists per person (source pixels) from Vision body pose, refreshed at ~6 Hz on the ANE.
    /// The pipeline picks the shooter (person nearest the cue ball).
    private func bodyPoseWrists(_ frame: ARFrame) -> [[Vec2]] {
        let now = frame.timestamp
        let due = state.withLock { s -> Bool in
            guard now - s.lastPose > 0.16 else { return false }
            s.lastPose = now
            return true
        }
        guard due else { return state.withLock { $0.wrists } }
        let w = Double(CVPixelBufferGetWidth(frame.capturedImage)), h = Double(CVPixelBufferGetHeight(frame.capturedImage))
        let handler = VNImageRequestHandler(cvPixelBuffer: frame.capturedImage, orientation: .up)
        var found: [[Vec2]] = []
        if (try? handler.perform([poseRequest])) != nil {
            for obs in poseRequest.results ?? [] {
                var person: [Vec2] = []
                for joint in [VNHumanBodyPoseObservation.JointName.leftWrist, .rightWrist] {
                    if let p = try? obs.recognizedPoint(joint), p.confidence > 0.3 {
                        person.append(Vec2(Double(p.location.x) * w, (1 - Double(p.location.y)) * h))
                    }
                }
                if !person.isEmpty { found.append(person) }
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
    /// Everything hangs off this so the lock-in can animate as one.
    private let root = Entity()
    private let spec: TableSpec
    private var outline: [ModelEntity] = []
    private var ballRings: [ModelEntity] = []
    private let cueLine: ModelEntity
    private let objectLine: ModelEntity
    private let ghost: ModelEntity
    private var dashes: [ModelEntity] = []
    private var objectSegs: [ModelEntity] = []
    private let liveLine: ModelEntity
    private let liveObject: ModelEntity
    private let liveGhost: ModelEntity
    private let R = Float(TableSpec.ballRadius)
    private var dimmed = false
    private let solidRing: MeshResource
    private let dashedRing: MeshResource
    private var ringShape: [RingStyle.Shape] = []
    private var turnStart = CACurrentMediaTime()
    private var wasAtRest = false
    /// Set by the controller from the convergence latch + legality.
    var liveStyle: LiveAimStyle = .neutral

    static let green = UIColor(red: 0.29, green: 0.87, blue: 0.5, alpha: 1)    // #4ADE80
    static let yellow = UIColor(red: 0.98, green: 0.8, blue: 0.08, alpha: 1)   // #FACC15
    static let red = UIColor(red: 0.97, green: 0.44, blue: 0.44, alpha: 1)     // #F87171

    private let vis: OverlayVisibility

    init(frame: TableFrame, visibility: OverlayVisibility = .of(.training(level: 3))) {
        vis = visibility
        spec = frame.spec
        anchor = AnchorEntity(world: frame.tableToWorld.toFloat)
        anchor.addChild(root)
        let L = Float(spec.length), W = Float(spec.width)
        let edges: [(SIMD2<Float>, SIMD2<Float>)] = [([0, 0], [L, 0]), ([L, 0], [L, W]), ([L, W], [0, W]), ([0, W], [0, 0])]
        for (a, b) in edges {
            let e = OverlayMesh.segment(from: a, to: b, z: 0.002, width: 0.006, material: OverlayMesh.material(.white, 0.55))
            outline.append(e); root.addChild(e)
        }
        for p in spec.pockets {
            let c = spec.pocketCenter(p)
            let r = Float((p.isSide ? spec.sideMouth : spec.cornerMouth) / 2)
            let e = ModelEntity(mesh: OverlayMesh.ring(inner: r - 0.008, outer: r), materials: [OverlayMesh.material(.white, 0.9)])
            e.position = [Float(c.x), Float(c.y), 0.003]
            outline.append(e); root.addChild(e)
            // Soft glow in the pocket mouth.
            let glow = ModelEntity(mesh: OverlayMesh.ring(inner: r, outer: r + 0.018), materials: [OverlayMesh.material(Self.green, 0.35)])
            glow.position = [Float(c.x), Float(c.y), 0.002]
            root.addChild(glow)
        }
        let solid = OverlayMesh.ring(inner: R * 1.12, outer: R * 1.34)
        solidRing = solid
        dashedRing = OverlayMesh.dashedRing(inner: R * 1.12, outer: R * 1.42, dashes: 10)
        for _ in 0..<16 {
            let e = ModelEntity(mesh: solid, materials: [OverlayMesh.material(.white, 0.45)])
            e.isEnabled = false
            root.addChild(e); ballRings.append(e); ringShape.append(.solid)
        }
        cueLine = OverlayMesh.segment(from: [0, 0], to: [1, 0], z: R, width: 0.005, material: OverlayMesh.material(.white, 0.9))
        objectLine = OverlayMesh.segment(from: [0, 0], to: [1, 0], z: R, width: 0.005, material: OverlayMesh.material(.white, 0.7))
        ghost = ModelEntity(mesh: OverlayMesh.ring(inner: R * 0.9, outer: R), materials: [OverlayMesh.material(.white, 0.9)])
        for e in [cueLine, objectLine, ghost] { e.isEnabled = false; root.addChild(e) }
        liveLine = OverlayMesh.segment(from: [0, 0], to: [1, 0], z: R, width: 0.006, material: OverlayMesh.material(.white, 1))
        liveObject = OverlayMesh.segment(from: [0, 0], to: [1, 0], z: R, width: 0.004, material: OverlayMesh.material(.white, 0.7))
        liveGhost = ModelEntity(mesh: OverlayMesh.ring(inner: R * 0.88, outer: R), materials: [OverlayMesh.material(.white, 1)])
        for e in [liveLine, liveObject, liveGhost] { e.isEnabled = false; root.addChild(e) }
        for _ in 0..<16 {
            let e = OverlayMesh.segment(from: [0, 0], to: [1, 0], z: R, width: 0.005, material: OverlayMesh.material(.white, 0.7))
            e.isEnabled = false
            root.addChild(e); objectSegs.append(e)
        }
        for _ in 0..<14 {
            let d = OverlayMesh.segment(from: [0, 0], to: [1, 0], z: R, width: 0.004, material: OverlayMesh.material(.white, 0.45))
            d.isEnabled = false
            root.addChild(d); dashes.append(d)
        }
    }

    /// "Table found": the whole overlay settles onto the cloth (from slightly raised and enlarged).
    func playLockIn() {
        var start = Transform.identity
        start.scale = [1.05, 1.05, 1]
        start.translation = [Float(spec.length) * -0.025, Float(spec.width) * -0.025, 0.04]
        root.transform = start
        root.move(to: Transform.identity, relativeTo: anchor, duration: 0.6, timingFunction: .easeOut)
    }

    func setDimmed(_ d: Bool) {
        dimmed = d
        for e in outline { e.model?.materials = [OverlayMesh.material(.white, d ? 0.2 : 0.6)] }
        if d { for e in ballRings + dashes + objectSegs + [cueLine, objectLine, ghost, liveLine, liveObject, liveGhost] { e.isEnabled = false } }
    }

    func update(_ r: PerceptionResult?) {
        guard !dimmed else { return }
        let tracks = r?.confirmed ?? []
        let now = CACurrentMediaTime()
        let atRest = r?.atRest ?? false
        if atRest && !wasAtRest { turnStart = now }   // a new turn: legal rings pulse once
        wasAtRest = atRest
        let targeted = r?.liveAim == nil ? nil : r?.liveTargetID
        for (i, ring) in ballRings.enumerated() {
            guard i < tracks.count else { ring.isEnabled = false; continue }
            let t = tracks[i]
            let mark = r?.marks[t.id] ?? .unknown
            let st = RingStyle.of(mark, turnAge: now - turnStart, time: now, targeted: targeted == t.id)
            if ringShape[i] != st.shape {
                ring.model?.mesh = st.shape == .dashed ? dashedRing : solidRing
                ringShape[i] = st.shape
            }
            ring.isEnabled = true
            ring.position = [Float(t.position.x), Float(t.position.y), 0.004]
            let color: UIColor = switch mark { case .cue, .unknown: .white; case .legal: Self.green; case .illegal: Self.red }
            ring.model?.materials = [OverlayMesh.material(color, st.alpha)]
            ring.scale = [Float(st.scale), Float(st.scale), 1]
        }
        // Live aim from the cue stick: bright, turns green as it merges with the suggestion.
        let live = vis.liveCueLine ? r?.liveAim : nil
        if let live {
            let c: UIColor = switch liveStyle { case .illegal: Self.red; case .merged: Self.green; case .neutral: .white }
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
        guard let aim = r?.aim, vis.line1 || vis.line2 || vis.line3 else {
            for e in dashes + objectSegs + [cueLine, objectLine, ghost] { e.isEnabled = false }
            return
        }
        // With a live cue the suggestion becomes a faint guide.
        let guide = live == nil ? 1.0 : 0.3
        let color = aim.ease > 0.35 ? Self.green : aim.ease > 0.15 ? Self.yellow : Self.red
        OverlayMesh.place(cueLine, from: aim.cue.f, to: aim.ghost.f, z: R)                 // Line 1
        cueLine.model?.materials = [OverlayMesh.material(.white, 0.9 * guide)]
        ghost.model?.materials = [OverlayMesh.material(.white, 0.9 * guide)]
        // Line 2: object-ball path (simulated with throw when Physics previewed it).
        objectLine.isEnabled = false
        let line2 = OverlayPath.segments(aim.objectPath.count >= 2 ? aim.objectPath : [aim.object, aim.pocketPoint],
                                         max: objectSegs.count)
        for (i, e) in objectSegs.enumerated() {
            if i < line2.count {
                OverlayMesh.place(e, from: line2[i].0.f, to: line2[i].1.f, z: R)
                e.model?.materials = [OverlayMesh.material(color, 0.85 * guide)]
                e.isEnabled = true
            } else { e.isEnabled = false }
        }
        ghost.position = [Float(aim.ghost.x), Float(aim.ghost.y), R]
        cueLine.isEnabled = vis.line1
        ghost.isEnabled = vis.suggestedGhost
        if !vis.line2 { for e in objectSegs { e.isEnabled = false } }
        // Line 3: dashed cue path after contact (follows cushions when simulated).
        let segs = !vis.line3 ? [] : OverlayPath.dashes(aim.cuePath, dash: 0.04, gap: 0.03, skip: TableSpec.ballRadius, max: dashes.count)
            .map { ($0.0.f, $0.1.f) }
        let dashMat = OverlayMesh.material(.white, 0.45 * guide)
        for (i, d) in dashes.enumerated() {
            if i < segs.count {
                OverlayMesh.place(d, from: segs[i].0, to: segs[i].1, z: R)
                d.model?.materials = [dashMat]
                d.isEnabled = true
            } else { d.isEnabled = false }
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

    /// Segmented annulus (colour-blind-safe shape for illegal targets).
    static func dashedRing(inner: Float, outer: Float, dashes: Int, fill: Float = 0.55) -> MeshResource {
        var pos: [SIMD3<Float>] = []
        var idx: [UInt32] = []
        let per = 6
        for d in 0..<dashes {
            let a0 = Float(d) / Float(dashes) * 2 * .pi
            let span = 2 * .pi / Float(dashes) * fill
            let base = UInt32(pos.count)
            for k in 0...per {
                let a = a0 + span * Float(k) / Float(per)
                pos.append([inner * cos(a), inner * sin(a), 0])
                pos.append([outer * cos(a), outer * sin(a), 0])
            }
            for k in 0..<per {
                let a = base + UInt32(2 * k), b = a + 1, c = a + 2, dd = a + 3
                idx += [a, b, dd, a, dd, c, a, dd, b, a, c, dd]
            }
        }
        var desc = MeshDescriptor(name: "dashedRing")
        desc.positions = MeshBuffers.Positions(pos)
        desc.primitives = .triangles(idx)
        return (try? MeshResource.generate(from: [desc])) ?? ring(inner: inner, outer: outer)
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

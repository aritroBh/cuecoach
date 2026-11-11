import Geometry
import SwiftUI
import Training

/// Live camera screen. Device: ARKit + RealityKit. Simulator / `-cuecoach.replay`: synthetic replay.
/// No text anywhere except the dev HUD (D9, 3-finger long-press).
struct LiveScreen: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: LiveModel
    @AppStorage("dev.hud") private var showHUD = false

    private let drill: DrillID?
    private let onClose: (() -> Void)?

    /// App-shell contract: `.game` (rules helpers + rating) or `.training(level:)` (aim lines, D24); the drill being
    /// trained (nil in a game); lifecycle hooks into LiveSession; `onClose` replaces the default dismiss.
    /// `tablePrior`: the table size chosen in game setup or Settings (D36), the locator's size prior.
    init(mode: LiveMode = .training(level: AssistLevel.full.rawValue), drill: DrillID? = nil, hooks: LiveHooks = LiveHooks(),
         tablePrior: TableSize? = nil, onClose: (() -> Void)? = nil) {
        let m = LiveModel(mode: mode)
        m.drill = drill
        m.tablePrior = tablePrior
        m.hooks = hooks
        _model = State(initialValue: m)
        self.drill = drill
        self.onClose = onClose
    }

    /// Replay exists only in simulator builds (D20): device builds always run the AR pipeline.
    static var useReplay: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    var body: some View {
        ZStack {
            AXLive.stage.ignoresSafeArea()
            content.ignoresSafeArea().accessibilityIdentifier("live.view")
            HandlesLayer(model: model).ignoresSafeArea()
            LoupeView(model: model).ignoresSafeArea().allowsHitTesting(false)
            controls
            PocketConfirmView(model: model).ignoresSafeArea()
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("-cuecoach.hud") { showHUD = true }
            UIApplication.shared.isIdleTimerDisabled = true      // no auto-lock while Live is up
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    @ViewBuilder private var content: some View {
        #if targetEnvironment(simulator)
        ReplayLiveView(model: model)
        #else
        ARLiveView(model: model, locator: AutoTableLocating(prior: model.tablePrior))
        #endif
    }

    private var controls: some View {
        let st = model.status
        return VStack(spacing: 12) {
            HStack(alignment: .top) {
                CircleButton(symbol: "xmark", id: "live.close") { if let onClose { onClose() } else { dismiss() } }
                Spacer()
                if model.calibrated && model.showAimHint && model.status == .calibrated {
                    AimHintGlyph().accessibilityIdentifier("live.aimHint")
                }
                if !model.calibrated {
                    CoachingGlyph(status: st, confidence: model.ghostConfidence, placed: model.editor.corners.count,
                                  tapMode: model.tapMode, shake: model.notReadyTick, failure: model.lockFailure)
                        .accessibilityIdentifier("live.coach")
                        .accessibilityValue("\(st)")
                }
                Spacer()
                Color.clear.frame(width: 56, height: 56)
            }
            if showHUD { DebugHUD(model: model).frame(maxWidth: .infinity, alignment: .trailing) }
            Spacer()
            if st.showsRecalibratePulse {
                PulsingButton(symbol: "scope", tint: AXLive.caution, id: "live.recalibratePulse") {
                    model.recalibrate()
                }
                Spacer()
            }
            HStack(alignment: .bottom, spacing: 16) {
                if model.calibrated {
                    CircleButton(symbol: "scope", id: "live.recalibrate") { model.recalibrate() }
                } else if model.tapMode && !model.editor.corners.isEmpty {
                    CircleButton(symbol: "arrow.uturn.backward", id: "live.undo") { model.undo() }
                } else if model.showTapFallback && !model.tapMode {
                    PulsingButton(symbol: "hand.tap", tint: AXLive.aim, id: "live.tapMode", size: 64) { model.startTapMode() }
                } else if !model.tapMode && !model.manualCorrection {
                    // Always-available manual path (small, calm) before the automatic offer.
                    SmallButton(symbol: "hand.tap", id: "live.manual") { model.startTapMode() }
                }
                Spacer()
                if !model.calibrated && model.editor.isComplete && (model.manualCorrection || model.tapMode) {
                    ConfirmButton { model.confirm() }
                }
                if model.calibrated, model.status == .calibrated, model.visibility.shotDock, let aim = model.aim {
                    ShotDock(spin: aim.spin, power: aim.power)
                }
            }
        }
        .padding(16)
        .overlay {
            if let b = model.badge { PostShotRatingBadge(rating: b.rating).transition(.scale(scale: 0.9).combined(with: .opacity)) }
        }
        .animation(.smooth(duration: 0.25), value: model.badge)
        .overlay(alignment: .bottomTrailing) {
            Color.clear.frame(width: 1, height: 1)
                .accessibilityElement()
                .accessibilityIdentifier("live.overlay")
                .accessibilityValue("calibrated:\(model.calibrated) balls:\(model.ballCount) aim:\(model.aim != nil && model.visibility.line1) mode:\(model.mode == .game ? "game" : "training")")
        }
    }
}

/// Top-centre coaching: sweep animation while searching; a ghost table filling as the locator converges;
/// corner dots (order-free) in tap mode. Shakes when a tap can't be used yet.
struct CoachingGlyph: View {
    var status: LiveStatus
    var confidence: Double
    var placed: Int
    var tapMode: Bool
    var shake: Int
    var failure: LockFailure? = nil
    @State private var sweep = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.shellForceReduceMotion) private var forcedReduceMotion
    @State private var shakeOffset: CGFloat = 0

    private let green = AXLive.legal

    var body: some View {
        let w: CGFloat = 112, h: CGFloat = 56
        ZStack {
            RoundedRectangle(cornerRadius: AX.radius.inner)
                .stroke(status == .searching ? AXLive.aim.opacity(0.4) : green.opacity(0.4 + 0.6 * confidence), lineWidth: 2)
                .frame(width: w, height: h)
            if status == .searching {
                Image(systemName: "iphone.gen3")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(AXLive.aim)
                    .rotationEffect(.degrees(-20))
                    .offset(x: sweep ? 40 : -40)
            } else if tapMode {
                // Two-tap fallback: the two near corner pockets (bottom of the glyph = nearest the user).
                ForEach(0..<2, id: \.self) { i in
                    let pos = [CGPoint(x: 0, y: h), CGPoint(x: w, y: h)][i]
                    Circle().fill(i < placed ? green : AXLive.aim.opacity(0.2))
                        .frame(width: 16, height: 16)
                        .position(x: pos.x + 8, y: pos.y + 8)
                }
            } else {
                // Ghost table converging: felt fills with confidence.
                RoundedRectangle(cornerRadius: AX.radius.inner).fill(green.opacity(0.35 * confidence)).frame(width: w, height: h)
                // What's missing, as a glyph: step back, move closer, hold steady, point at the cloth…
                // Never a check before the lock: the glyph only says what's missing (or that it's converging).
                let symbol = CoachingSymbol.of(failure: failure, locked: false)
                Image(systemName: symbol)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(failure == nil ? green : AXLive.aim)
                    .symbolEffect(.pulse, isActive: confidence < 1)
                    .accessibilityIdentifier("live.lockHint")
                    .accessibilityValue(failure?.rawValue ?? "converging")
            }
        }
        .frame(width: w + 16, height: h + 16)
        .padding(10)
        .background(AXLive.chip.opacity(0.72), in: RoundedRectangle(cornerRadius: AX.radius.container, style: .continuous))
        .offset(x: shakeOffset)
        .onAppear { if !(reduceMotion || forcedReduceMotion) { withAnimation(.easeInOut(duration: 1.1).repeatForever()) { sweep = true } } }
        .onChange(of: shake) {
            withAnimation(.spring(response: 0.12, dampingFraction: 0.2)) { shakeOffset = 14 }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.4).delay(0.12)) { shakeOffset = 0 }
        }
    }
}

/// Draggable corner handles (correction only). The finger drags from where it lands, so it never hides the centre.
struct HandlesLayer: View {
    let model: LiveModel
    @State private var dragStart: [Int: CGPoint] = [:]
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.shellForceReduceMotion) private var forcedReduceMotion

    var body: some View {
        ZStack {
            ForEach(Array(model.handles.enumerated()), id: \.offset) { i, p in
                if let p, !model.calibrated {
                    let bad = model.editor.outlier == i
                    let color = bad ? AXLive.danger : AXLive.legal
                    ZStack {
                        Circle().stroke(color, lineWidth: 3).frame(width: 44, height: 44)
                        Circle().fill(color).frame(width: 6, height: 6)
                    }
                    .frame(width: 64, height: 64)
                    .contentShape(Circle())
                    .scaleEffect(bad && pulse ? 1.25 : 1)
                    .opacity(model.manualCorrection || model.tapMode || bad ? 1 : 0.35 + 0.65 * model.ghostConfidence)
                    .position(p)
                    .gesture(DragGesture(minimumDistance: 2)
                        .onChanged { g in
                            let start = dragStart[i] ?? p
                            if dragStart[i] == nil { dragStart[i] = p }
                            model.dragHandle(i, CGPoint(x: start.x + g.translation.width, y: start.y + g.translation.height))
                        }
                        .onEnded { _ in
                            dragStart[i] = nil
                            model.loupeCenter = nil
                            model.loupeImage = nil
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        })
                    .accessibilityIdentifier("calib.handle.\(i)")
                }
            }
        }
        .onAppear { if !(reduceMotion || forcedReduceMotion) { withAnimation(.easeInOut(duration: 0.5).repeatForever()) { pulse = true } } }
    }
}

/// Suggested spin (cue-ball face with a strike dot) and power (5-step meter). Suggestions only; no numbers.
struct ShotDock: View {
    var spin: SpinSuggestion
    var power: Int

    var body: some View {
        HStack(alignment: .bottom, spacing: 12) {
            ZStack {
                Circle().fill(AXLive.aim.opacity(0.92))
                Circle().stroke(AXLive.stage.opacity(0.15), lineWidth: 1)
                Circle().fill(AXLive.danger)
                    .frame(width: 12, height: 12)
                    .offset(x: CGFloat(spin.tip.x) * 52, y: CGFloat(-spin.tip.y) * 52)
            }
            .frame(width: 64, height: 64)
            VStack(spacing: 4) {
                ForEach((1...5).reversed(), id: \.self) { step in
                    RoundedRectangle(cornerRadius: AX.radius.inner)
                        .fill(step <= power ? AXLive.aim : AXLive.aim.opacity(0.2))
                        .frame(width: 20, height: 9)
                }
            }
        }
        .padding(10)
        .background(AXLive.chip.opacity(0.72), in: RoundedRectangle(cornerRadius: AX.radius.container, style: .continuous))
        .accessibilityIdentifier("live.shotDock")
    }
}

/// Magnifier above the finger while a corner is dragged (a crop of the live view, 2.5×).
struct LoupeView: View {
    let model: LiveModel
    var body: some View {
        GeometryReader { geo in
            if let c = model.loupeCenter, let img = model.loupeImage {
                let d: CGFloat = 120, zoom: CGFloat = 2.5
                let sx = img.size.width / max(1, geo.size.width), sy = img.size.height / max(1, geo.size.height)
                let crop = CGRect(x: (c.x - d / zoom / 2) * sx, y: (c.y - d / zoom / 2) * sy, width: d / zoom * sx, height: d / zoom * sy)
                if let cg = img.cgImage?.cropping(to: CGRect(x: crop.minX * img.scale, y: crop.minY * img.scale,
                                                             width: crop.width * img.scale, height: crop.height * img.scale)) {
                    ZStack {
                        Image(decorative: cg, scale: 1).resizable().interpolation(.none)
                        Image(systemName: "plus").font(.system(size: 18, weight: .bold)).foregroundStyle(AXLive.aim)
                    }
                    .frame(width: d, height: d)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(AXLive.aim, lineWidth: 2))
                    .position(x: c.x, y: max(d / 2 + 8, c.y - d))
                    .accessibilityIdentifier("live.loupe")
                }
            }
        }
    }
}

/// After the lock: a pulsing cue ball says "now aim" (no text). Hidden at the first aim.
struct AimHintGlyph: View {
    @State private var on = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.shellForceReduceMotion) private var forcedReduceMotion
    var body: some View {
        Circle().fill(AXLive.aim)
            .frame(width: 30, height: 30)
            .overlay(Circle().stroke(AXLive.aim.opacity(0.6), lineWidth: 2).scaleEffect(on ? 1.9 : 1).opacity(on ? 0 : 1))
            .frame(width: 64, height: 64)
            .background(AXLive.chip.opacity(0.72), in: Circle())
            .onAppear { if !(reduceMotion || forcedReduceMotion) { withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) { on = true } } }
    }
}

struct SmallButton: View {
    var symbol: String
    var id: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(AXLive.aim.opacity(0.7))
                .frame(width: 44, height: 44)
                .background(AXLive.chip.opacity(0.72), in: Circle())
        }
        .accessibilityIdentifier(id)
    }
}

struct ConfirmButton: View {
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "checkmark")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(AXLive.stage)
                .frame(width: 72, height: 72)
                .background(Circle().fill(AXLive.legal))
        }
        .accessibilityIdentifier("calib.confirm")
    }
}

struct PulsingButton: View {
    var symbol: String
    var tint: Color
    var id: String
    var size: CGFloat = 96
    var action: () -> Void
    @State private var on = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.shellForceReduceMotion) private var forcedReduceMotion
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.35, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .background(AXLive.chip.opacity(0.72), in: Circle())
                .overlay(Circle().stroke(tint, lineWidth: 3).scaleEffect(on ? 1.3 : 1).opacity(on ? 0 : 0.9))
        }
        .accessibilityIdentifier(id)
        .onAppear { if !(reduceMotion || forcedReduceMotion) { withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) { on = true } } }
    }
}

struct CircleButton: View {
    var symbol: String
    var id: String
    var tint: Color = AXLive.aim
    var dim = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(tint.opacity(dim ? 0.55 : 1))
                .frame(width: 60, height: 60)
                .background(AXLive.chip.opacity(0.72), in: Circle())
        }
        .accessibilityIdentifier(id)
    }
}

/// Dev-only (D9).
struct DebugHUD: View {
    let model: LiveModel
    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text("\(Int(model.fps)) fps · conv \(String(format: "%.1f", model.convertMs)) · det \(String(format: "%.1f", model.detectMs)) · all \(String(format: "%.1f", model.totalMs)) ms")
            Text("lidar balls \(model.depthBalls)")
            Text("balls \(model.ballCount) · rest \(model.atRest ? "y" : "n") · aim \(model.aim != nil ? "y" : "n")")
            Text("plane \(model.planeFound ? "y" : "n") · track \(model.trackingOK ? "ok" : "lim") · \(model.formatLabel)")
            Text("lock \(model.lockFailure?.rawValue ?? (model.calibrated ? "locked" : "converging"))")
            Text("ghost \(Int(model.ghostConfidence * 100))% · depth \(model.depthConfidence.map { String(format: "%.0f%%", $0 * 100) } ?? "–")")
            Text("ball scale \(model.ballScale.map { String(format: "%.2f", $0) } ?? "–") · thermal \(model.thermal.rawValue) · \(model.tableSize?.rawValue ?? "–") · \(String(describing: model.status))")
        }
        .font(.system(size: 13, weight: .semibold, design: .monospaced))
        .foregroundStyle(AXLive.ink)
        .padding(AX.space.s2)
        .background(AXLive.chip.opacity(0.85), in: RoundedRectangle(cornerRadius: AX.radius.element, style: .continuous))
        .accessibilityIdentifier("live.hud")
    }
}

#if targetEnvironment(simulator)
/// Simulator / replay: synthetic table image through the same locator → lock → detection path.
struct ReplayLiveView: View {
    let model: LiveModel
    @State private var scene = SyntheticTableScene.demo()
    @State private var image: CGImage?
    @State private var pixels: PixelImage?
    @State private var table: TableFrame?
    @State private var result: PerceptionResult?
    @State private var pipeline = PerceptionPipeline(detector: PerceptionPipeline.defaultDetector())
    @State private var locator: AutoTableLocating

    init(model: LiveModel) {
        self.model = model
        _locator = State(initialValue: AutoTableLocating(prior: model.tablePrior))
    }
    @State private var loop: Task<Void, Never>?
    @State private var viewSize: CGSize = .zero

    private var map: AspectFill {
        AspectFill(image: CGSize(width: scene.camera.intrinsics.width, height: scene.camera.intrinsics.height), view: viewSize)
    }

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, _ in
                if let image { ctx.draw(Image(decorative: image, scale: 1), in: map.imageRect) }
                draw(&ctx, map)
            }
            .contentShape(Rectangle())
            .onTapGesture { p in tap(map.toImage(p)) }
            .onAppear { viewSize = geo.size }
            .onChange(of: geo.size) { viewSize = geo.size; refreshHandles() }
        }
        .onAppear(perform: start)
        .onDisappear { loop?.cancel() }
        .onChange(of: model.editor.revision) { refreshHandles() }
        .task {
            let pl = pipeline
            model.bindLegal { legal in Task { await pl.setLegal(legal) } }
            let seed = model.initialLegalTargets()
            Task { await pl.setLegal(seed) }
            model.undo = { model.editor.undo() }
            model.recalibrate = { reset() }
            model.confirm = { confirm() }
            model.startTapMode = {
                model.manualCorrection = true
                model.showTapFallback = false
                if !model.editor.isComplete { model.tapMode = true; model.editor.reset() }
            }
            model.dragHandle = { i, p in
                guard table == nil, let w = scene.camera.intersect(pixel: map.toImage(p), with: scene.plane) else { return }
                model.manualCorrection = true
                model.editor.move(i, to: w)
            }
        }
    }

    private var planes: [LocatorPlane] {
        let s = scene.frame.spec
        return [LocatorPlane(center: scene.frame.world(Vec2(s.length / 2, s.width / 2)), extent: SIMD2(1.2, 0.8), isTable: true)]
    }

    private func start() {
        model.planeFound = true
        image = scene.render()
        pixels = image.flatMap { PixelImage(cgImage: $0) }
        let pipeline = pipeline, locator = locator, cam = scene.camera, planes = planes
        let depth = scene.renderDepth(width: 256, height: 144)
        guard let px = pixels else { return }
        loop = Task {
            var t = 0.0
            while !Task.isCancelled {
                t += 1.0 / 15
                if table == nil {
                    if !model.manualCorrection && !model.tapMode {
                        let e = await locator.ingest(LocatorFrame(image: px, camera: cam, planes: planes, timestamp: t,
                                                                  depth: depth))
                        if let e, table == nil, !model.manualCorrection {
                            model.lockFailure = e.failure
                            if e.corners.count == 4 { model.editor.setProposal(e.corners) }
                            model.ghostConfidence = e.confidence
                            if e.locked { if let f = e.frame { lock(f) } else { confirm() } }
                        }
                    }
                } else {
                    let r = await pipeline.process(PerceptionFrame(image: px, camera: cam, timestamp: t))
                    result = r
                    model.noteResult(r)
                    if let pk = model.pocketConfirm?.pocket, let tf = table,
                       let p = FrameGeometry(frame: tf, camera: cam).cloth.apply(tf.spec.pocketCenter(pk)) {
                        model.pocketConfirmPoint = map.toView(p)
                    }
                }
                try? await Task.sleep(for: .milliseconds(66))
            }
        }
    }

    private func refreshHandles() {
        model.handles = table == nil ? model.editor.corners.map { w in scene.camera.project(w).map { map.toView($0) } } : []
    }

    private func tap(_ px: Vec2) {
        guard table == nil, model.tapMode || model.editor.outlier != nil,
              let w = scene.camera.intersect(pixel: px, with: scene.plane) else { return }
        model.editor.add(w)
        if model.tapMode, model.editor.corners.count == 2,
           let four = TwoTapTable.corners(model.editor.corners[0], model.editor.corners[1], viewer: scene.camera.position,
                                          size: TableHealth.measuredSize()) {
            model.editor.setProposal(four)
            model.tapMode = false
            model.manualCorrection = true
        }
    }

    private func lock(_ f: TableFrame) {
        guard table == nil else { return }
        TableHealth.rememberMeasured(f.spec.size)
        model.showAimHint = true
        table = f
        model.tableSize = f.spec.size
        model.calibrated = true
        refreshHandles()
        let pipeline = pipeline
        model.perceptionReset()
        Task { await pipeline.setTable(f) }
    }

    private func confirm() {
        guard table == nil, let fit = model.editor.confirm(viewer: scene.camera.position) else { return }
        TableHealth.rememberMeasured(fit.frame.spec.size)
        table = fit.frame
        model.tableSize = fit.frame.spec.size
        model.calibrated = true
        refreshHandles()
        let pipeline = pipeline, frame = fit.frame
        model.perceptionReset()
        Task { await pipeline.setTable(frame) }
    }

    private func reset() {
        table = nil; result = nil
        model.clearCalibration()
        model.planeFound = true
        let pipeline = pipeline, locator = locator
        model.perceptionReset()
        Task { await pipeline.setTable(nil); await locator.reset() }
    }

    private func draw(_ ctx: inout GraphicsContext, _ map: AspectFill) {
        let green = AXLive.legal, red = AXLive.danger
        guard let table else {
            // Ghost outline growing between placed / estimated corners.
            let pts = model.editor.perimeter.compactMap { scene.camera.project($0).map { map.toView($0) } }
            if pts.count >= 2 {
                var p = Path(); p.addLines(pts); if pts.count == 4 { p.closeSubpath() }
                let a = model.manualCorrection || model.tapMode ? 0.9 : 0.25 + 0.65 * model.ghostConfidence
                ctx.stroke(p, with: .color(AXLive.aim.opacity(a)), lineWidth: 2)
            }
            return
        }
        let geo = FrameGeometry(frame: table, camera: scene.camera)
        func v(_ p: Vec2, ball: Bool = false) -> CGPoint? { (ball ? geo.ball : geo.cloth).apply(p).map { map.toView($0) } }
        var outline = Path()
        let pts = table.corners.compactMap { v($0) }
        if pts.count == 4 { outline.addLines(pts); outline.closeSubpath() }
        ctx.stroke(outline, with: .color(AXLive.aim.opacity(0.55)), lineWidth: 2)
        for p in table.spec.pockets {
            let r = (p.isSide ? table.spec.sideMouth : table.spec.cornerMouth) / 2
            ctx.stroke(circle(table.spec.pocketCenter(p), r, geo.cloth, map), with: .color(AXLive.aim.opacity(0.7)), lineWidth: 2)
        }
        for t in result?.confirmed ?? [] {
            let mark = result?.marks[t.id] ?? .unknown
            let c: Color = switch mark { case .cue: AXLive.aim; case .legal: green; case .illegal: red; case .unknown: AXLive.aim.opacity(0.4) }
            let st = RingStyle.of(mark, turnAge: 5, time: Date().timeIntervalSinceReferenceDate)
            ctx.stroke(circle(t.position, TableSpec.ballRadius * 1.25, geo.cloth, map), with: .color(c.opacity(st.alpha)),
                       style: StrokeStyle(lineWidth: mark == .cue ? 3 : 2, dash: st.shape == .dashed ? [5, 4] : []))
        }
        let vis = model.visibility
        if vis.line1, let aim = result?.aim, let a = v(aim.cue, ball: true), let g = v(aim.ghost, ball: true),
           let o = v(aim.object, ball: true), let pk = v(aim.pocketPoint, ball: true) {
            var l1 = Path(); l1.move(to: a); l1.addLine(to: g)
            ctx.stroke(l1, with: .color(AXLive.aim.opacity(0.9)), lineWidth: 2)
            ctx.stroke(circle(aim.ghost, TableSpec.ballRadius, geo.ball, map), with: .color(AXLive.aim.opacity(0.9)), lineWidth: 2)
            var l2 = Path(); l2.move(to: o); l2.addLine(to: pk)
            if aim.objectPath.count >= 2 { l2 = Path(); l2.addLines(aim.objectPath.compactMap { v($0, ball: true) }) }
            let c: Color = aim.ease > 0.35 ? green : aim.ease > 0.15 ? AXLive.caution : red
            ctx.stroke(l2, with: .color(c.opacity(0.85)), lineWidth: 2)
            if vis.line3, aim.cuePath.count >= 2 {
                var l3 = Path(); l3.addLines(aim.cuePath.compactMap { v($0, ball: true) })
                ctx.stroke(l3, with: .color(AXLive.aim.opacity(0.5)), style: StrokeStyle(lineWidth: 2, dash: [6, 6]))
            }
        }
    }

    private func circle(_ c: Vec2, _ r: Double, _ h: Homography, _ map: AspectFill) -> Path {
        var p = Path()
        let pts = (0...32).compactMap { i -> CGPoint? in
            let a = Double(i) / 32 * 2 * .pi
            return h.apply(c + Vec2(cos(a), sin(a)) * r).map { map.toView($0) }
        }
        if pts.count > 2 { p.addLines(pts) }
        return p
    }
}

#endif

/// Aspect-fill mapping between image pixels and view points.
struct AspectFill {
    var image: CGSize
    var view: CGSize
    var scale: CGFloat { max(view.width / max(1, image.width), view.height / max(1, image.height)) }
    var offset: CGPoint { CGPoint(x: (view.width - image.width * scale) / 2, y: (view.height - image.height * scale) / 2) }
    var imageRect: CGRect { CGRect(origin: offset, size: CGSize(width: image.width * scale, height: image.height * scale)) }
    func toView(_ p: Vec2) -> CGPoint { CGPoint(x: offset.x + p.x * scale, y: offset.y + p.y * scale) }
    func toImage(_ p: CGPoint) -> Vec2 { Vec2((p.x - offset.x) / scale, (p.y - offset.y) / scale) }
}

import Geometry
import SwiftUI

/// Live camera screen. Device: ARKit + RealityKit. Simulator / `-cuecoach.replay`: synthetic replay.
struct LiveScreen: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model = LiveModel()
    @AppStorage("dev.hud") private var showHUD = false

    static var useReplay: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        ProcessInfo.processInfo.arguments.contains("-cuecoach.replay")
        #endif
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            content.ignoresSafeArea()
            controls
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .accessibilityIdentifier("live.view")
    }

    @ViewBuilder private var content: some View {
        #if targetEnvironment(simulator)
        ReplayLiveView(model: model)
        #else
        if Self.useReplay { ReplayLiveView(model: model) } else { ARLiveView(model: model) }
        #endif
    }

    private var controls: some View {
        VStack {
            HStack(alignment: .top) {
                CircleButton(symbol: "xmark", id: "live.close") { dismiss() }
                Spacer()
                if !model.calibrated {
                    CornerGlyph(placed: model.cornersPlaced, searching: !model.planeFound && !Self.useReplay)
                        .accessibilityIdentifier("live.cornerGlyph")
                        .accessibilityValue("\(model.cornersPlaced)")
                }
                Spacer()
                CircleButton(symbol: "ladybug", id: "live.devHUD", dim: !showHUD) { showHUD.toggle() }
            }
            if showHUD { DebugHUD(model: model).frame(maxWidth: .infinity, alignment: .trailing) }
            Spacer()
            HStack {
                if model.calibrated {
                    CircleButton(symbol: "scope", id: "live.recalibrate", tint: model.trackingOK ? .white : .yellow) {
                        model.recalibrate()
                    }
                } else if model.cornersPlaced > 0 {
                    CircleButton(symbol: "arrow.uturn.backward", id: "live.undo") { model.undo() }
                }
                Spacer()
            }
        }
        .padding(16)
        .overlay(alignment: .bottomTrailing) {
            // Machine-readable state for UI tests (not visible).
            Color.clear.frame(width: 1, height: 1)
                .accessibilityElement()
                .accessibilityIdentifier("live.overlay")
                .accessibilityValue("calibrated:\(model.calibrated) balls:\(model.ballCount) aim:\(model.hasAim)")
        }
    }
}

/// Table glyph: 2:1 outline with 4 corner dots; placed corners fill, the next one pulses. No text.
struct CornerGlyph: View {
    var placed: Int
    var searching: Bool
    @State private var pulse = false

    var body: some View {
        let w: CGFloat = 112, h: CGFloat = 56
        ZStack {
            RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(searching ? 0.35 : 0.8), lineWidth: 2)
                .frame(width: w, height: h)
            ForEach(0..<4, id: \.self) { i in
                let pos = [CGPoint(x: 0, y: 0), CGPoint(x: w, y: 0), CGPoint(x: w, y: h), CGPoint(x: 0, y: h)][i]
                Circle()
                    .fill(i < placed ? Color.white : Color.white.opacity(0.15))
                    .overlay(Circle().stroke(.white, lineWidth: i == placed ? 2 : 0))
                    .frame(width: 16, height: 16)
                    .scaleEffect(i == placed && pulse ? 1.35 : 1)
                    .position(x: pos.x + 8, y: pos.y + 8)
            }
            if searching {
                Image(systemName: "viewfinder").font(.system(size: 22, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
            }
        }
        .frame(width: w + 16, height: h + 16)
        .padding(10)
        .background(.ultraThinMaterial.opacity(0.6), in: RoundedRectangle(cornerRadius: 20))
        .onAppear { withAnimation(.easeInOut(duration: 0.8).repeatForever()) { pulse = true } }
    }
}

struct CircleButton: View {
    var symbol: String
    var id: String
    var tint: Color = .white
    var dim = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(tint.opacity(dim ? 0.45 : 1))
                .frame(width: 56, height: 56)
                .background(.ultraThinMaterial.opacity(0.7), in: Circle())
        }
        .accessibilityIdentifier(id)
    }
}

/// Dev-only (D9).
struct DebugHUD: View {
    let model: LiveModel
    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text("\(Int(model.fps)) fps · det \(String(format: "%.1f", model.detectMs)) ms")
            Text("balls \(model.ballCount) · rest \(model.atRest ? "y" : "n") · aim \(model.hasAim ? "y" : "n")")
            Text("plane \(model.planeFound ? "y" : "n") · track \(model.trackingOK ? "ok" : "lim") · \(model.formatLabel)")
            Text("depth \(model.depthConfidence.map { String(format: "%.0f%%", $0 * 100) } ?? "–") · thermal \(model.thermal.rawValue) · \(model.tableSize?.rawValue ?? "–")")
        }
        .font(.system(size: 13, weight: .semibold, design: .monospaced))
        .foregroundStyle(.white)
        .padding(8)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier("live.hud")
    }
}

/// Simulator / replay: synthetic table image, same tap-corners → plane → table frame → detection path.
struct ReplayLiveView: View {
    let model: LiveModel
    @State private var scene = SyntheticTableScene.demo()
    @State private var image: CGImage?
    @State private var pixels: PixelImage?
    @State private var corners: [SIMD3<Double>] = []
    @State private var table: TableFrame?
    @State private var result: PerceptionResult?
    @State private var pipeline = PerceptionPipeline()
    @State private var loop: Task<Void, Never>?

    var body: some View {
        GeometryReader { geo in
            let map = AspectFill(image: CGSize(width: scene.camera.intrinsics.width, height: scene.camera.intrinsics.height),
                                 view: geo.size)
            Canvas { ctx, _ in
                if let image { ctx.draw(Image(decorative: image, scale: 1), in: map.imageRect) }
                draw(&ctx, map)
            }
            .contentShape(Rectangle())
            .onTapGesture { p in tap(map.toImage(p)) }
        }
        .onAppear(perform: start)
        .onDisappear { loop?.cancel() }
        .task { model.undo = { undo() }; model.recalibrate = { reset() } }
    }

    private func start() {
        model.planeFound = true
        image = scene.render()
        pixels = image.flatMap { PixelImage(cgImage: $0) }
        let pipeline = pipeline, cam = scene.camera
        guard let px = pixels else { return }
        loop = Task {
            var t = 0.0
            while !Task.isCancelled {
                let r = await pipeline.process(PerceptionFrame(image: px, camera: cam, timestamp: t))
                t += 1.0 / 15
                if table != nil { result = r; model.noteResult(r) }
                try? await Task.sleep(for: .milliseconds(66))
            }
        }
    }

    private func tap(_ px: Vec2) {
        guard table == nil, corners.count < 4, let w = scene.camera.intersect(pixel: px, with: scene.plane) else { return }
        corners.append(w)
        model.cornersPlaced = corners.count
        guard corners.count == 4 else { return }
        guard let fit = TableFitter.fit(corners: corners, viewer: scene.camera.position) else { reset(); return }
        table = fit.frame
        model.tableSize = fit.frame.spec.size
        model.calibrated = true
        let pipeline = pipeline, frame = fit.frame
        Task { await pipeline.setTable(frame) }
    }

    private func undo() {
        guard table == nil, !corners.isEmpty else { return }
        corners.removeLast(); model.cornersPlaced = corners.count
    }

    private func reset() {
        corners = []; table = nil; result = nil
        model.cornersPlaced = 0; model.calibrated = false; model.noteResult(nil)
        let pipeline = pipeline
        Task { await pipeline.setTable(nil) }
    }

    private func draw(_ ctx: inout GraphicsContext, _ map: AspectFill) {
        for w in corners where table == nil {
            if let p = scene.camera.project(w) {
                let v = map.toView(p)
                ctx.fill(Path(ellipseIn: CGRect(x: v.x - 6, y: v.y - 6, width: 12, height: 12)), with: .color(.white))
            }
        }
        guard let table else { return }
        let geo = FrameGeometry(frame: table, camera: scene.camera)
        func v(_ p: Vec2, ball: Bool = false) -> CGPoint? {
            (ball ? geo.ball : geo.cloth).apply(p).map { map.toView($0) }
        }
        var outline = Path()
        let pts = table.corners.compactMap { v($0) }
        if pts.count == 4 { outline.addLines(pts); outline.closeSubpath() }
        ctx.stroke(outline, with: .color(.white.opacity(0.55)), lineWidth: 2)
        for p in table.spec.pockets {
            let r = (p.isSide ? table.spec.sideMouth : table.spec.cornerMouth) / 2
            ctx.stroke(circle(table.spec.pocketCenter(p), r, geo.cloth, map), with: .color(.white.opacity(0.7)), lineWidth: 2)
        }
        for t in (result?.tracks ?? []).filter(\.confirmed) {
            ctx.stroke(circle(t.position, TableSpec.ballRadius * 1.25, geo.cloth, map),
                       with: .color(.white.opacity(t.kind == .cue ? 0.95 : 0.45)), lineWidth: t.kind == .cue ? 3 : 2)
        }
        if let aim = result?.aim, let a = v(aim.cue, ball: true), let g = v(aim.ghost, ball: true),
           let o = v(aim.object, ball: true), let pk = v(aim.pocketPoint, ball: true) {
            var l1 = Path(); l1.move(to: a); l1.addLine(to: g)
            ctx.stroke(l1, with: .color(.white.opacity(0.9)), lineWidth: 2)
            ctx.stroke(circle(aim.ghost, TableSpec.ballRadius, geo.ball, map), with: .color(.white.opacity(0.9)), lineWidth: 2)
            var l2 = Path(); l2.move(to: o); l2.addLine(to: pk)
            let c: Color = aim.ease > 0.35 ? Color(red: 0.29, green: 0.87, blue: 0.5)
                : aim.ease > 0.15 ? Color(red: 0.98, green: 0.8, blue: 0.08) : Color(red: 0.97, green: 0.44, blue: 0.44)
            ctx.stroke(l2, with: .color(c.opacity(0.85)), style: StrokeStyle(lineWidth: 2, dash: [6, 6]))
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

/// Aspect-fill mapping between image pixels and view points.
struct AspectFill {
    var image: CGSize
    var view: CGSize
    var scale: CGFloat { max(view.width / image.width, view.height / image.height) }
    var offset: CGPoint { CGPoint(x: (view.width - image.width * scale) / 2, y: (view.height - image.height * scale) / 2) }
    var imageRect: CGRect { CGRect(origin: offset, size: CGSize(width: image.width * scale, height: image.height * scale)) }
    func toView(_ p: Vec2) -> CGPoint { CGPoint(x: offset.x + p.x * scale, y: offset.y + p.y * scale) }
    func toImage(_ p: CGPoint) -> Vec2 { Vec2((p.x - offset.x) / scale, (p.y - offset.y) / scale) }
}

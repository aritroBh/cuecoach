import SwiftUI
import Training

/// Training: drill grid + assist level (1–4) + Start.
struct TrainingPickerView: View {
    @State var model: TrainingPickerModel
    @Environment(\.dynamicTypeSize) private var typeSize

    private var columns: [GridItem] {
        typeSize.isAccessibilitySize ? [GridItem(.flexible())] : [GridItem(.flexible(), spacing: 12), GridItem(.flexible())]
    }

    var body: some View {
        ZStack {
            ShellBackground()
            ScrollView {
                VStack(spacing: 28) {
                    ShellSection(title: "Drill") {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(model.drills, id: \.self) { d in
                                ChoiceTile(selected: model.drill == d, id: "training.drill.\(d.rawValue)",
                                           label: TrainingPickerModel.name(d)) {
                                    model.drill = d
                                } content: {
                                    Image(systemName: TrainingPickerModel.symbol(d)).font(.system(size: 28, weight: .semibold))
                                    Text(TrainingPickerModel.name(d)).axFont(.headline)
                                }
                            }
                        }
                    }
                    ShellSection(title: "Help") {
                        LazyVGrid(columns: typeSize.isAccessibilitySize ? [GridItem(.flexible())]
                                  : Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                            ForEach(AssistLevel.allCases, id: \.self) { l in
                                ChoiceTile(selected: model.level == l, id: "training.level.\(l.rawValue)",
                                           label: "Level \(l.rawValue), \(TrainingPickerModel.levelName(l))") {
                                    model.level = l
                                } content: {
                                    LevelSketch(elements: model.sketch(for: l)).frame(width: 56, height: 40)
                                    Text("\(l.rawValue)").axFont(.subtitle, weight: .bold).monospacedDigit()
                                }
                            }
                        }
                        Text(TrainingPickerModel.levelName(model.level))
                            .axFont(.headline).foregroundStyle(AX.ink)
                            .accessibilityIdentifier("training.levelName")
                    }
                }
                .padding(16)
            }
        }
        .safeAreaInset(edge: .bottom) {
            ShellStartButton(enabled: true, id: "training.start") { model.start() }
                .padding(.horizontal, 16).padding(.bottom, 8)
                .background(AX.page.opacity(0.9))
        }
        .navigationTitle("Training")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Tiny drawing of what a level shows while aiming: cue ball, object ball, pocket, and only the allowed lines.
struct LevelSketch: View {
    let elements: Set<OverlayElement>
    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let cue = CGPoint(x: w * 0.15, y: h * 0.8), obj = CGPoint(x: w * 0.6, y: h * 0.45)
            let pocket = CGPoint(x: w * 0.92, y: h * 0.12)
            let ghost = CGPoint(x: obj.x - 6, y: obj.y + 4)
            if elements.contains(.cueToGhostLine) {
                var p = Path(); p.move(to: cue); p.addLine(to: ghost)
                ctx.stroke(p, with: .color(AX.onDark.opacity(0.9)), lineWidth: 2)
            }
            if elements.contains(.objectToPocketLine) {
                var p = Path(); p.move(to: obj); p.addLine(to: pocket)
                ctx.stroke(p, with: .color(AX.onDark.opacity(0.6)), style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
            }
            if elements.contains(.ghostBall) {
                ctx.stroke(Path(ellipseIn: CGRect(x: ghost.x - 5, y: ghost.y - 5, width: 10, height: 10)),
                           with: .color(AX.onDark.opacity(0.9)), lineWidth: 1.5)
            }
            if elements.contains(.positionZone) {
                let zone = CGRect(x: w * 0.22, y: h * 0.12, width: w * 0.26, height: h * 0.3)
                ctx.fill(Path(ellipseIn: zone), with: .color(AX.legal.opacity(0.35)))
                ctx.stroke(Path(ellipseIn: zone), with: .color(AX.legal), lineWidth: 1)
            }
            if elements.contains(.cueAfterContactLine) {
                var p = Path(); p.move(to: ghost); p.addLine(to: CGPoint(x: w * 0.35, y: h * 0.27))
                ctx.stroke(p, with: .color(AX.onDark.opacity(0.45)), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
            }
            ctx.fill(Path(ellipseIn: CGRect(x: pocket.x - 4, y: pocket.y - 4, width: 8, height: 8)), with: .color(AX.pocket))
            ctx.fill(Path(ellipseIn: CGRect(x: obj.x - 5, y: obj.y - 5, width: 10, height: 10)), with: .color(AX.caution))
            ctx.fill(Path(ellipseIn: CGRect(x: cue.x - 5, y: cue.y - 5, width: 10, height: 10)), with: .color(AX.ballWhite))
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(AX.felt))
        .accessibilityHidden(true)
    }
}

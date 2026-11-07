import SwiftUI

/// Archetype radar. Swift Charts has no radar, so it is a Canvas: 3 grid rings, 1 dataset, optional dashed
/// overlay (previous snapshot on long-press, or the pro's shape in the comparison sheet).
struct ArchetypeRadar: View {
    let axes: [RadarAxis]
    var overlay: [RadarAxis]?
    var accent: Color
    var draft = false
    var showsLabels = true
    @State private var drawn: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.saForceReduceMotion) private var forceReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || forceReduceMotion }

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let radius = side / 2 - (showsLabels ? 36 : 6)
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            ZStack {
                Canvas { ctx, _ in
                    let n = max(axes.count, 3)
                    for ring in 1...3 {
                        ctx.stroke(polygon(Array(repeating: Double(ring) / 3, count: n), center, radius),
                                   with: .color(SA.inkMuted.opacity(0.2)), lineWidth: 1)
                    }
                    for i in 0..<n {
                        var p = Path(); p.move(to: center); p.addLine(to: point(i, n, 1, center, radius))
                        ctx.stroke(p, with: .color(SA.inkMuted.opacity(0.15)), lineWidth: 1)
                    }
                    if let overlay, overlay.count == axes.count {
                        ctx.stroke(polygon(overlay.map(\.value), center, radius),
                                   with: .color(.white.opacity(0.45)),
                                   style: StrokeStyle(lineWidth: 2, dash: [6, 6]))
                    }
                }
                if !axes.isEmpty {
                    let shape = SARadarShape(values: axes.map(\.value), center: center, radius: radius)
                    shape.fill(accent.opacity(draft ? 0.08 : 0.2))
                        .opacity(reduceMotion ? 1 : Double(drawn))
                    shape.trim(from: 0, to: reduceMotion ? 1 : drawn)
                        .stroke(accent.opacity(draft ? 0.5 : 1),
                                style: StrokeStyle(lineWidth: 2, lineJoin: .round, dash: draft ? [6, 6] : []))
                }
                if showsLabels {
                    ForEach(Array(axes.enumerated()), id: \.element.id) { i, a in
                        Text(a.name)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(SA.inkMuted)
                            .fixedSize()
                            .position(point(i, axes.count, 1, center, radius + 22))
                    }
                }
            }
        }
        .onAppear {
            if reduceMotion { drawn = 1 } else { withAnimation(.easeOut(duration: 0.35)) { drawn = 1 } }
        }
    }

    private func point(_ i: Int, _ n: Int, _ v: Double, _ c: CGPoint, _ r: CGFloat) -> CGPoint {
        let angle = -Double.pi / 2 + 2 * Double.pi * Double(i) / Double(n)
        return CGPoint(x: c.x + CGFloat(cos(angle) * v) * r, y: c.y + CGFloat(sin(angle) * v) * r)
    }

    private func polygon(_ values: [Double], _ c: CGPoint, _ r: CGFloat) -> Path {
        SARadarShape(values: values, center: c, radius: r).path(in: .zero)
    }
}

struct SARadarShape: Shape {
    var values: [Double]
    var center: CGPoint
    var radius: CGFloat
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let n = values.count
        guard n >= 3 else { return p }
        for (i, v) in values.enumerated() {
            let angle = -Double.pi / 2 + 2 * Double.pi * Double(i) / Double(n)
            let pt = CGPoint(x: center.x + CGFloat(cos(angle) * v) * radius,
                             y: center.y + CGFloat(sin(angle) * v) * radius)
            i == 0 ? p.move(to: pt) : p.addLine(to: pt)
        }
        p.closeSubpath()
        return p
    }
}

/// Make % heat: rows = distance, columns = cut bucket. No numbers in cells; long-press shows the value.
struct MakeHeatGrid: View {
    let cells: [HeatCellView]
    @State private var pressed: String?
    @Environment(\.dynamicTypeSize) private var typeSize

    private var cell: CGFloat { typeSize.isAccessibilitySize ? 44 : 52 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Color.clear.frame(width: rowLabelWidth, height: 1)
                ForEach(CutBucket.allCases, id: \.self) { c in
                    Text(HeatCellView.cutAxisLabel(c))
                        .font(.footnote.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(SA.inkMuted)
                        .frame(width: cell)
                        .accessibilityHidden(true)
                }
            }
            ForEach(DistanceBucket.allCases, id: \.self) { d in
                HStack(spacing: 4) {
                    Text(HeatCellView.distanceName(d))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(SA.inkMuted)
                        .frame(width: rowLabelWidth, alignment: .leading)
                        .accessibilityHidden(true)
                    ForEach(cells.filter { $0.distance == d }) { c in heatCell(c) }
                }
            }
            Text(pressedCaption ?? " ")
                .font(.footnote.weight(.semibold)).monospacedDigit()
                .foregroundStyle(SA.ink)
                .frame(maxWidth: .infinity, alignment: .center)
                .opacity(pressedCaption == nil ? 0 : 1)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Make percent by cut and distance")
    }

    private var rowLabelWidth: CGFloat { typeSize.isAccessibilitySize ? 72 : 48 }

    private var pressedCaption: String? {
        cells.first { $0.id == pressed && $0.hasData }?.valueCaption
    }

    private func heatCell(_ c: HeatCellView) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(c.hasData ? SA.legal.opacity(c.fillOpacity) : SA.bg.opacity(0.5))
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(pressed == c.id ? SA.ink : SA.inkMuted.opacity(0.15), lineWidth: pressed == c.id ? 2 : 1)
            if let g = c.glyph {
                Image(systemName: g).font(.callout.weight(.semibold))
                    .foregroundStyle(c.make >= 0.5 ? SA.bg : SA.ink)
            } else {
                Circle().fill(SA.inkMuted).frame(width: 5, height: 5)
            }
        }
        .frame(width: cell, height: cell)
        .onLongPressGesture(minimumDuration: 0.3) {} onPressingChanged: { pressing in
            pressed = pressing ? c.id : nil
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(c.accessibilityLabel)
        .accessibilityIdentifier("profile.heat.\(c.id)")
    }
}

/// Circular progress/similarity ring.
struct SARing: View {
    let progress: Double
    let color: Color
    var lineWidth: CGFloat = 8
    var body: some View {
        ZStack {
            Circle().stroke(SA.inkMuted.opacity(0.2), lineWidth: lineWidth)
            Circle().trim(from: 0, to: max(0, min(1, progress)))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

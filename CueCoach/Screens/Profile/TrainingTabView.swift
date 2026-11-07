import SwiftUI

/// Training tab. Reads only `TrainingContent` (built from `TrainingProfileSource`, the Training store);
/// it never shows make %, WPA, win rate, archetypes or pro comps (SPEC §2, §10).
struct TrainingTabView: View {
    let content: TrainingContent?

    var body: some View {
        VStack(spacing: SA.section) {
            Rectangle().fill(SA.brilliant.opacity(0.15)).frame(height: 4)
                .clipShape(Capsule())
                .accessibilityHidden(true)
            if let content, !content.drills.isEmpty || content.bias != nil {
                if !content.drills.isEmpty {
                    VStack(spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: "graduationcap").foregroundStyle(SA.brilliant)
                            Text("Training only").font(.title2.weight(.semibold)).foregroundStyle(SA.ink)
                            Spacer()
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(.isHeader)
                        SACard(padding: 0) {
                            VStack(spacing: 0) {
                                ForEach(Array(content.drills.enumerated()), id: \.element.id) { i, d in
                                    if i > 0 { Divider().overlay(SA.inkMuted.opacity(0.3)).padding(.leading, 16) }
                                    DrillRow(drill: d)
                                }
                            }
                        }
                    }
                }
                if let bias = content.bias {
                    VStack(spacing: 8) {
                        SA.sectionHeader("Tendency")
                        TendencyCard(bias: bias)
                    }
                }
            } else {
                ContentUnavailableView("No drills yet", systemImage: "graduationcap")
                    .foregroundStyle(SA.inkMuted)
                    .frame(minHeight: 280)
                    .accessibilityIdentifier("profile.training.empty")
            }
        }
        .accessibilityIdentifier("profile.training")
    }
}

private struct DrillRow: View {
    let drill: DrillLevel
    var body: some View {
        HStack(spacing: 12) {
            Text(drill.name).font(.body).foregroundStyle(SA.ink)
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                ForEach(1...4, id: \.self) { i in
                    if i <= drill.clampedLevel {
                        Circle().fill(SA.ink).frame(width: 12, height: 12)
                    } else {
                        Circle().stroke(SA.inkMuted, lineWidth: 1.5).frame(width: 12, height: 12)
                    }
                }
            }
            Text("Lv \(drill.clampedLevel)").font(.footnote.weight(.semibold)).monospacedDigit()
                .foregroundStyle(SA.inkMuted)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 56)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(drill.name), level \(drill.clampedLevel) of 4")
    }
}

/// Correct line (solid) vs habitual line (dashed) with a correction arrow. One correction at a time.
private struct TendencyCard: View {
    let bias: BiasHint
    var body: some View {
        SACard {
            VStack(alignment: .leading, spacing: 12) {
                Canvas { ctx, size in
                    let start = CGPoint(x: size.width * 0.2, y: size.height * 0.85)
                    let correct = CGPoint(x: size.width * 0.6, y: size.height * 0.12)
                    let off = CGFloat(bias.sign >= 0 ? 1 : -1) * size.width * 0.16
                    let habit = CGPoint(x: correct.x + off, y: correct.y + 6)
                    var a = Path(); a.move(to: start); a.addLine(to: correct)
                    ctx.stroke(a, with: .color(.white.opacity(0.9)), lineWidth: 2)
                    var b = Path(); b.move(to: start); b.addLine(to: habit)
                    ctx.stroke(b, with: .color(.white.opacity(0.45)), style: StrokeStyle(lineWidth: 2, dash: [6, 6]))
                    var arrow = Path()
                    let from = CGPoint(x: habit.x, y: habit.y + 18), to = CGPoint(x: correct.x, y: correct.y + 18)
                    arrow.move(to: from); arrow.addLine(to: to)
                    let dir: CGFloat = to.x > from.x ? -1 : 1
                    arrow.move(to: to); arrow.addLine(to: CGPoint(x: to.x + dir * 8, y: to.y - 6))
                    arrow.move(to: to); arrow.addLine(to: CGPoint(x: to.x + dir * 8, y: to.y + 6))
                    ctx.stroke(arrow, with: .color(SA.caution), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    for p in [correct] {
                        ctx.stroke(Path(ellipseIn: CGRect(x: p.x - 10, y: p.y - 10, width: 20, height: 20)),
                                   with: .color(.white.opacity(0.9)), lineWidth: 2)
                    }
                    ctx.fill(Path(ellipseIn: CGRect(x: start.x - 10, y: start.y - 10, width: 20, height: 20)),
                             with: .color(.white))
                }
                .frame(height: 140)
                .accessibilityHidden(true)
                Label(bias.word, systemImage: bias.symbol)
                    .font(.body.weight(.semibold)).foregroundStyle(SA.caution)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Tendency: \(bias.word)")
        .accessibilityIdentifier("profile.training.tendency")
    }
}

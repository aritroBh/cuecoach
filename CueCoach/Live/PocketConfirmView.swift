import SwiftUI

/// D30 post-shot one-tap confirm, icon only: the ball glyph at the pocket it may have dropped into, with ✓ (it
/// dropped) and ✗ (it didn't). Shown only after the balls settle and never while anyone aims (LiveModel gates it);
/// Rules, the badge and the turn wait on the answer.
struct PocketConfirmView: View {
    let model: LiveModel

    var body: some View {
        GeometryReader { geo in
            if model.showsPocketConfirm {
                let at = model.pocketConfirmPoint ?? CGPoint(x: geo.size.width / 2, y: geo.size.height - 140)
                HStack(spacing: 14) {
                    answer(symbol: "xmark", tint: AXLive.danger, id: "live.pocket.no", dropped: false)
                    Image(systemName: "circle.fill")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(AXLive.aim)
                        .frame(width: 56, height: 56)
                        .background(Circle().fill(AXLive.chip.opacity(0.8)))
                        .overlay(Circle().stroke(AXLive.aim.opacity(0.7), style: StrokeStyle(lineWidth: 2, dash: [5, 4])))
                        .accessibilityHidden(true)
                    answer(symbol: "checkmark", tint: AXLive.legal, id: "live.pocket.yes", dropped: true)
                }
                .position(x: min(max(at.x, 110), geo.size.width - 110), y: min(max(at.y, 60), geo.size.height - 60))
                .transition(.opacity)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("live.pocketConfirm")
            }
        }
    }

    private func answer(symbol: String, tint: Color, id: String, dropped: Bool) -> some View {
        Button { model.answerPocket(dropped: dropped) } label: {
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(tint)
                .frame(minWidth: 56, minHeight: 56)
                .background(Circle().fill(AXLive.chip.opacity(0.8)))
                .overlay(Circle().stroke(tint, lineWidth: 3))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }
}

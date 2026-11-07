import SwiftUI
import Engine

/// Post-shot badge overlay. Place over the live camera; it lays itself out at 38% height (portrait)
/// or the centre of the top half (landscape) and is transparent to touches when empty.
public struct PostShotBadgeView: View {
    @State private var model: PostShotBadgeModel
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.sbForceReduceMotion) private var forcedReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || forcedReduceMotion }
    @Environment(\.dynamicTypeSize) private var typeSize

    public init(model: PostShotBadgeModel) { _model = State(initialValue: model) }

    public var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            let y = landscape ? geo.size.height * 0.25 : geo.size.height * 0.38
            ZStack {
                if let rating = model.current, let style = model.style {
                    badge(rating, style)
                        .position(x: geo.size.width / 2, y: y)
                        .transition(transition)
                }
            }
            .animation(model.current == nil ? .easeOut(duration: 0.15)
                       : (reduceMotion ? .easeInOut(duration: 0.2) : .snappy(duration: 0.25)),
                       value: model.generation)
            .animation(.easeOut(duration: 0.15), value: model.current == nil)
        }
        .allowsHitTesting(model.current != nil)
        .task { await model.run() }
        .task(id: model.generation) {
            let g = model.generation
            try? await Task.sleep(for: .seconds(PostShotBadgeModel.holdSeconds + 0.25))
            model.holdElapsed(generation: g)
        }
        .onChange(of: model.announcement) { _, text in
            if let text { AccessibilityNotification.Announcement(text).post() }
        }
        .sensoryFeedback(.success, trigger: model.generation) { _, _ in model.wantsSuccessHaptic }
    }

    private var transition: AnyTransition {
        reduceMotion ? .opacity : .asymmetric(insertion: .scale(scale: 0.9).combined(with: .opacity), removal: .opacity)
    }

    private func badge(_ rating: PostShotRating, _ style: RatingBadgeStyle) -> some View {
        VStack(spacing: 8) {
            ZStack {
                RatingBadgeCircle(style: style, diameter: 72, symbolSize: 32)
                TeamArc()
                    .stroke(SBColor.team(rating.team), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .frame(width: 84, height: 84)
            }
            Text(style.words)
                .font(.system(size: 13, weight: .semibold))
                .dynamicTypeSize(...DynamicTypeSize.xxLarge)   // 13 → ~17 pt max
                .foregroundStyle(SBColor.ink)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 8).fill(SBColor.bg.opacity(0.8)))
        }
        .overlay(alignment: .topTrailing) {
            if model.isPinned {
                Image(systemName: "pin.fill").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SBColor.inkMuted).offset(x: 6, y: -2)
            }
        }
        .frame(minWidth: 110, minHeight: 110)
        .contentShape(Rectangle())
        .onTapGesture { model.tap() }
        .gesture(DragGesture(minimumDistance: 16).onEnded { v in
            if v.translation.height < -24 { model.swipeUp() }
        })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(style.words) shot by \(rating.shooterName)")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(model.isPinned ? "Double tap to dismiss" : "Double tap to keep")
        .accessibilityIdentifier("postshot.badge.\(rating.rating.rawValue)")
    }
}

#Preview("Badge") {
    ZStack {
        SBColor.feltCenter.ignoresSafeArea()
        PostShotBadgeView(model: {
            let m = PostShotBadgeModel()
            m.receive(.rated(PostShotRating(shotID: UUID(), rating: .brilliant, shooterName: "Sam", team: 0)))
            m.tap()
            return m
        }())
    }
}

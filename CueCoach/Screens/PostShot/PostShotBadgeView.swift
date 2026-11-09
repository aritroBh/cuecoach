import SwiftUI
import UIKit
import Engine

/// Post-shot badge overlay. Place over the live camera; it lays itself out at 38% height (portrait)
/// or the centre of the top half (landscape) and is transparent to touches when empty.
public struct PostShotBadgeView: View {
    let model: PostShotBadgeModel
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.sbForceReduceMotion) private var forcedReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || forcedReduceMotion }
    @Environment(\.dynamicTypeSize) private var typeSize

    public init(model: PostShotBadgeModel) { self.model = model }

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
        // Announce only once the badge has been up ~0.3 s and nobody has started aiming since.
        .task(id: model.announcement) {
            guard let text = model.announcement else { return }
            try? await Task.sleep(for: .seconds(0.3))
            guard !Task.isCancelled, model.announcement == text else { return }
            AccessibilityNotification.Announcement(text).post()
        }
        // Aim started: interrupt anything VoiceOver is still saying (no audio while aiming).
        .onChange(of: model.speechInterrupts) { _, _ in
            UIAccessibility.post(notification: .announcement,
                                 argument: NSAttributedString(string: " ", attributes: [.accessibilitySpeechQueueAnnouncement: false]))
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
                // Points at the shooting team's avatar corner (A top-left, B top-right); B dashed.
                TeamArc.pointing(team: rating.team)
                    .stroke(AX.team(rating.team), style: AX.teamStroke(rating.team))
                    .frame(width: 84, height: 84)
            }
            // Footnote scales with Dynamic Type, clamped at xxLarge (13 → 17 pt). A soft dark halo gives contrast
            // over the camera without a chip shape.
            Text(style.words)
                .axFont(.label, weight: .semibold)
                .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                .foregroundStyle(AXLive.aim)
                .lineLimit(1)
                .fixedSize()
                .shadow(color: AXLive.stage.opacity(0.85), radius: 3)
                .shadow(color: AXLive.stage.opacity(0.85), radius: 6)
        }
        .overlay(alignment: .topTrailing) {
            if model.isPinned {
                Image(systemName: "pin.fill").font(AXGlyph.font(13, .semibold))
                    .foregroundStyle(AX.inkMuted).offset(x: 6, y: -2)
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
        AX.felt.ignoresSafeArea()
        PostShotBadgeView(model: {
            let m = PostShotBadgeModel()
            m.receive(.rated(PostShotRating(shotID: UUID(), rating: .brilliant, shooterName: "Sam", team: 0)))
            m.tap()
            return m
        }())
    }
}

import SwiftUI
import UIKit

/// Section title on a settings or profile page: the Astryx heading at level 2.
struct AXSectionHeader: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        AXHeading(text: text, level: 2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum Haptics {
    @MainActor static func notify(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        UINotificationFeedbackGenerator().notificationOccurred(type)
    }
    @MainActor static func selection() { UISelectionFeedbackGenerator().selectionChanged() }
}

/// `.snappy`/`.smooth`, or a crossfade when Reduce Motion is on.
struct SAMotion {
    let reduce: Bool
    var snappy: Animation { reduce ? .easeInOut(duration: 0.2) : .snappy }
    var smooth: Animation { reduce ? .easeInOut(duration: 0.25) : .smooth }
}

/// A Screens A card: the Astryx `Card` (card ground, border, container radius).
struct SACard<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content
    var body: some View {
        AXCard(padding: padding == 0 ? .v0 : padding >= 20 ? .v5 : padding <= 12 ? .v3 : .v4) { content }
    }
}

extension EnvironmentValues {
    /// Debug router / tests can force Reduce Motion behaviour (the system value is read-only).
    @Entry var saForceReduceMotion: Bool = false
}

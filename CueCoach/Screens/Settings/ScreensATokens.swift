import SwiftUI
import UIKit

/// MASTER.md color tokens, scoped to Screens A so they can't collide with other modules' theme files.
enum SA {
    static let bg = Color(saHex: "#0B0F0E")
    static let surface = Color(saHex: "#151B19")
    static let felt = Color(saHex: "#0E5A43")
    static let feltDeep = Color(saHex: "#0A4433")
    static let rail = Color(saHex: "#2A1D14")
    static let railHi = Color(saHex: "#3A2A1E")
    static let ink = Color(saHex: "#F2F5F3")
    static let inkMuted = Color(saHex: "#F2F5F3").opacity(0.6)
    static let legal = Color(saHex: "#4ADE80")
    static let caution = Color(saHex: "#FACC15")
    static let danger = Color(saHex: "#F87171")
    static let brilliant = Color(saHex: "#22D3EE")
    static let teamA = Color(saHex: "#60A5FA")

    static let gutter: CGFloat = 16
    static let section: CGFloat = 24
    static let cardRadius: CGFloat = 20
    static let buttonRadius: CGFloat = 14

    static func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.title2.weight(.semibold))
            .foregroundStyle(ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }

    @MainActor static func haptic(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        UINotificationFeedbackGenerator().notificationOccurred(type)
    }
    @MainActor static func selection() { UISelectionFeedbackGenerator().selectionChanged() }
}

extension Color {
    init(saHex hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        let v = UInt64(s, radix: 16) ?? 0x888888
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255)
    }
}

/// `.snappy`/`.smooth`, or a crossfade when Reduce Motion is on.
struct SAMotion {
    let reduce: Bool
    var snappy: Animation { reduce ? .easeInOut(duration: 0.2) : .snappy }
    var smooth: Animation { reduce ? .easeInOut(duration: 0.25) : .smooth }
}

struct SACard<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SA.surface, in: RoundedRectangle(cornerRadius: SA.cardRadius, style: .continuous))
    }
}

extension EnvironmentValues {
    /// Debug router / tests can force Reduce Motion behaviour (the system value is read-only).
    @Entry var saForceReduceMotion: Bool = false
}

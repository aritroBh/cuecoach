import Astryx
import SwiftUI
import UIKit

// D34: CueCoach paints every screen and overlay with Meta's Astryx design system (Default theme, light and dark,
// following the system). This file is the one place the app imports Astryx: it names the Astryx tokens by the
// roles CueCoach draws with, and wraps the Astryx views CueCoach uses, so screen files keep SwiftUI's own
// `Text`/`Button` and never need `SwiftUI.` prefixes.

// MARK: - Colour roles

/// App colour roles, each an Astryx Default-theme token that follows light and dark where it is drawn.
enum AX {
    /// A colour that resolves to `light` or `dark` by the trait collection it is drawn in.
    static func dynamic(_ light: Color, _ dark: Color) -> Color {
        let l = UIColor(light), d = UIColor(dark)
        return Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? d : l })
    }

    private static let l = Theme.default.light.color
    private static let d = Theme.default.dark.color
    private static func token(_ path: KeyPath<ColorTokens, Color>) -> Color { dynamic(l[keyPath: path], d[keyPath: path]) }

    // Grounds
    static let page = token(\.backgroundBody)
    static let surface = token(\.backgroundCard)
    static let raised = token(\.backgroundPopover)
    static let muted = token(\.backgroundMuted)
    static let scrim = token(\.overlay)
    // Ink
    static let ink = token(\.textPrimary)
    static let inkMuted = token(\.textSecondary)
    static let inkDisabled = token(\.textDisabled)
    static let border = token(\.border)
    static let borderStrong = token(\.borderEmphasized)
    static let neutral = token(\.neutral)
    // Brand
    static let accent = token(\.accent)
    static let accentMuted = token(\.accentMuted)
    static let accentText = token(\.textAccent)
    static let onAccent = token(\.onAccent)
    // Feedback. Every role clears WCAG on the page and on a card in both modes (AstryxThemeTests): words 4.5:1,
    // rings and glyphs 3:1. Where Astryx's semantic token misses (light `success` 4.3, `warning` 1.8, `error` 4.3,
    // `dataCategoricalOrange` 2.8; dark `error` 4.4 on a card, dark `success` 4.0), the role takes the nearest
    // Astryx ramp step that clears it. Large fills and the Live overlay (AXLive) keep the bright tokens.
    static let legal = dynamic(l.dataShamrock5, d.dataShamrock3)
    static let legalMuted = token(\.successMuted)
    static let caution = dynamic(l.textWarning, d.warning)
    static let onCaution = token(\.onWarning)
    /// Rings and glyphs only (3:1).
    static let warn = dynamic(l.dataOrange4, d.dataCategoricalOrange)
    static let danger = dynamic(l.dataRed4, d.dataRed3)
    static let dangerMuted = token(\.errorMuted)
    static let brilliant = dynamic(l.dataCategoricalCyan, d.iconCyan)
    // Teams: A = Astryx blue (solid ring), B = orange (dashed ring); never colour alone.
    static let teamA = dynamic(l.accent, d.textAccent)
    /// Team B rings and glyphs (3:1); `teamBText` for words (4.5:1).
    static let teamB = dynamic(l.dataOrange4, d.dataCategoricalOrange)
    static let teamBText = dynamic(l.dataOrange5, d.dataCategoricalOrange)
    static func team(_ i: Int) -> Color { i == 0 ? teamA : teamB }
    /// Team colour for words (4.5:1).
    static func teamText(_ i: Int) -> Color { i == 0 ? teamA : teamBText }
    /// Team A solid, Team B dashed: never colour alone.
    static func teamStroke(_ i: Int, width: CGFloat = 2) -> StrokeStyle {
        StrokeStyle(lineWidth: width, lineCap: .round, dash: i == 0 ? [] : [4, 3])
    }
    // The table as drawn in diagrams (Review replay, profile heatmaps): Astryx's shamrock and orange data ramps.
    static let felt = token(\.dataShamrock4)
    static let feltEdge = token(\.dataShamrock5)
    static let rail = token(\.dataOrange5)
    static let railHighlight = token(\.dataCategoricalBrown)
    /// Ink on the felt and on other always-dark grounds.
    static let onDark = token(\.onDark)

    /// Avatar swatches (8, per identity sheet spec). `PlayerProfile.avatarColor` stores the name.
    static let avatarNames = ["blue", "teal", "green", "yellow", "orange", "red", "pink", "purple"]
    static func avatar(_ name: String) -> Color {
        switch name {
        case "blue": token(\.dataCategoricalBlue)
        case "teal": token(\.dataCategoricalTeal)
        case "green": token(\.dataCategoricalGreen)
        case "yellow": token(\.dataYellow3)
        case "orange": token(\.dataCategoricalOrange)
        case "red": token(\.dataCategoricalRed)
        case "pink": token(\.dataCategoricalPink)
        case "purple": token(\.dataCategoricalPurple)
        default: avatarName(forHex: name).map(avatar) ?? token(\.dataNeutral)
        }
    }

    /// Profiles saved before D34 store a hex colour (`#RRGGBB`): the Astryx swatch nearest to it in hue.
    static func avatarName(forHex hex: String) -> String? {
        guard hex.hasPrefix("#"), hex.count == 7, let v = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        func hue(_ c: UIColor) -> CGFloat {
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            return h
        }
        let target = hue(UIColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                                 blue: CGFloat(v & 0xFF) / 255, alpha: 1))
        func distance(_ name: String) -> CGFloat {
            let d = abs(hue(UIColor(avatar(name)).resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))) - target)
            return min(d, 1 - d)
        }
        return avatarNames.min { distance($0) < distance($1) }
    }

    /// A pool ball's colour (1 yellow, 2 blue, 3 red, 4 purple, 5 orange, 6 green, 7 maroon, 8 black; stripes repeat
    /// 9-15), from Astryx's data ramps. The same in both modes: they depict real balls on the felt.
    static func ball(_ number: Int) -> Color {
        let c = Theme.default.light.color
        switch (number - 1) % 8 + 1 {
        case 1: return c.dataYellow3
        case 2: return c.dataBlue4
        case 3: return c.dataRed4
        case 4: return c.dataPurple4
        case 5: return c.dataOrange4
        case 6: return c.dataShamrock4
        case 7: return c.dataRed5
        default: return c.backgroundInverted
        }
    }

    /// The cue ball and a stripe's white band.
    static let ballWhite = Theme.default.light.color.onDark

    /// A pocket, and the 8 ball's ink.
    static let pocket = Theme.default.light.color.backgroundInverted

    // MARK: Space and shape (Astryx spacing ladder and radii; the same in both modes)
    static let space = Theme.default.light.space
    static let radius = Theme.default.light.radius
    /// Platform minimum touch target.
    static let minTarget: CGFloat = 44
}

/// The live overlays draw on the camera feed, which looks the same in light and dark, so they always take the
/// Astryx dark-mode values: bright lines and rings on a dark, busy ground.
enum AXLive {
    private static let d = Theme.default.dark.color
    static let aim = d.onDark
    static let legal = d.dataShamrock3
    static let caution = d.warning
    static let danger = d.error
    static let brilliant = d.iconCyan
    static let accent = d.textAccent
    /// Dim layer under a menu or a sheet over the camera.
    static let scrim = d.overlay
    /// Ground of a chip or a round control on the camera.
    static let chip = d.backgroundPopover
    static let ink = d.textPrimary
    /// The stage behind the camera before the first frame.
    static let stage = d.backgroundBody

    static let uiAim = UIColor(aim)
    static let uiLegal = UIColor(legal)
    static let uiCaution = UIColor(caution)
    static let uiDanger = UIColor(danger)
}

// MARK: - Type

/// CueCoach's type roles on the Astryx type tokens. Body is Astryx's `lg` size (17 pt), not its 14 pt web body:
/// the app is read at arm's length beside a table.
enum AXType: Sendable {
    case display, title, subtitle, headline, body, label, small

    func size(_ f: FontTokens) -> CGFloat {
        switch self {
        case .display: f.display2.size
        case .title: f.heading1.size
        case .subtitle: f.heading2.size
        case .headline: f.large.size
        case .body: f.size.lg
        case .label: f.label.size
        case .small: f.supporting.size
        }
    }

    func weight(_ f: FontTokens) -> Font.Weight {
        switch self {
        case .display, .title, .subtitle, .headline: .semibold
        case .label: .medium
        case .body, .small: .regular
        }
    }

    /// Dynamic Type growth for this role. Astryx grows every size by the body factor; iOS grows large styles
    /// less (Large Title ×1.8 at AX5 while Body ×3.1), so titles stay on screen at AX5. Body and smaller grow fully.
    func scale(_ textScale: CGFloat, _ f: FontTokens) -> CGFloat {
        let s = size(f)
        guard textScale > 1, s > f.size.lg else { return textScale }
        let damping = pow(f.size.lg / s, 1.5)
        return 1 + (textScale - 1) * damping
    }
}

private struct AXFontModifier: ViewModifier {
    let type: AXType
    let weight: Font.Weight?
    let monospacedDigits: Bool
    @Environment(\.astryx) private var astryx

    func body(content: Content) -> some View {
        let f = astryx.tokens.font
        let font = Font.system(size: type.size(f) * type.scale(astryx.textScale, f), weight: weight ?? type.weight(f))
        content.font(monospacedDigits ? font.monospacedDigit() : font)
    }
}

extension View {
    /// The Astryx type for a role, grown by Dynamic Type.
    func axFont(_ type: AXType, weight: Font.Weight? = nil, monospacedDigits: Bool = false) -> some View {
        modifier(AXFontModifier(type: type, weight: weight, monospacedDigits: monospacedDigits))
    }

    /// Paints the subtree with the Astryx Default theme (light and dark follow the system).
    func cueCoachTheme() -> some View { astryxTheme(.default) }

    /// An Astryx surface: the card ground, its border, the container radius, and an optional Astryx shadow.
    func axSurface(_ fill: Color = AX.surface, radius: CGFloat = AX.radius.container, elevated: Bool = false) -> some View {
        modifier(AXSurface(fill: fill, radius: radius, elevated: elevated))
    }
}

private struct AXSurface: ViewModifier {
    let fill: Color
    let radius: CGFloat
    let elevated: Bool
    @Environment(\.astryx) private var astryx

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let low = astryx.tokens.shadow.low
        content
            .background(shape.fill(fill))
            .overlay(shape.strokeBorder(astryx.tokens.color.border, lineWidth: astryx.tokens.size.borderWidth))
            .shadow(color: elevated ? (low.last?.color ?? .clear) : .clear, radius: (low.last?.blur ?? 0) / 2,
                    y: low.last?.y ?? 0)
    }
}

/// A symbol drawn inside a fixed-size shape (avatar, disc, 44-pt handle). It does not scale with Dynamic Type,
/// because the shape around it does not; the words beside it do.
enum AXGlyph {
    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight) }
}

// MARK: - Astryx views, under app names

/// Astryx `Heading`: a header trait and the theme's heading type.
struct AXHeading: View {
    var text: String
    var level: Int = 2
    var muted = false
    var body: some View {
        Astryx.Heading(text, level: HeadingLevel(rawValue: level) ?? .v2, color: muted ? .secondary : .primary)
    }
}

/// Astryx `Text` at a role size.
struct AXText: View {
    var text: String
    var size: TextSize = .lg
    var muted = false
    var weight: TextWeight? = nil
    var maxLines: Int? = nil
    init(_ text: String, size: TextSize = .lg, muted: Bool = false, weight: TextWeight? = nil, maxLines: Int? = nil) {
        self.text = text; self.size = size; self.muted = muted; self.weight = weight; self.maxLines = maxLines
    }
    var body: some View {
        Astryx.Text(text, size: size, color: muted ? .secondary : .primary, weight: weight, maxLines: maxLines.map(Double.init))
    }
}

/// Astryx `Card`.
struct AXCard<Content: View>: View {
    var padding: CardPadding = .v4
    var muted = false
    @ViewBuilder var content: Content
    var body: some View {
        Astryx.Card(padding: padding, variant: muted ? .muted : .default) { content }
    }
}

/// Astryx `Banner`: status icon + title + optional description on the status ground.
struct AXBanner: View {
    enum Status { case info, warning, error, success }
    var status: Status
    var title: String
    var description: String? = nil
    var body: some View {
        let s: AstryxBannerStatus = switch status {
        case .info: .info
        case .warning: .warning
        case .error: .error
        case .success: .success
        }
        Astryx.Banner(status: s, title: title, description: description)
    }
}

/// Astryx `Button` (words only). Its tap area is at least 44 × 44 pt.
struct AXButton: View {
    enum Variant { case primary, secondary, ghost, destructive }
    var title: String
    var variant: Variant = .secondary
    var fill = false
    var id: String? = nil
    var action: () -> Void
    var body: some View {
        let v: ButtonVariant = switch variant {
        case .primary: .primary
        case .secondary: .secondary
        case .ghost: .ghost
        case .destructive: .destructive
        }
        Astryx.Button(label: title, variant: v, size: .lg, width: fill ? .fill : nil,
                      base: AstryxBaseProps(id: id), onClick: action)
    }
}

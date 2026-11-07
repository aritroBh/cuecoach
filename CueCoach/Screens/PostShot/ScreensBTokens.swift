import SwiftUI
import Engine

/// MASTER.md colour tokens, local to Screens B (Lobby, PostShot, Review) until a shared theme module lands.
enum SBColor {
    static let bg = Color(hex: 0x0B0F0E)
    static let surface = Color(hex: 0x151B19).opacity(0.92)
    static let feltCenter = Color(hex: 0x0E5A43)
    static let feltEdge = Color(hex: 0x0A4433)
    static let rail = Color(hex: 0x2A1D14)
    static let railHighlight = Color(hex: 0x3A2A1E)
    static let ink = Color(hex: 0xF2F5F3)
    static let inkMuted = Color(hex: 0xF2F5F3).opacity(0.6)
    static let aim = Color.white.opacity(0.9)
    static let predict = Color.white.opacity(0.45)
    static let legal = Color(hex: 0x4ADE80)
    static let caution = Color(hex: 0xFACC15)
    /// Open question 1 in pages/screens-b.md: not in MASTER yet; local until the user decides.
    static let warn = Color(hex: 0xFB923C)
    static let danger = Color(hex: 0xF87171)
    static let brilliant = Color(hex: 0x22D3EE)
    static let teamA = Color(hex: 0x60A5FA)
    static let teamB = Color(hex: 0xF59E0B)

    static func team(_ i: Int) -> Color { i == 0 ? teamA : teamB }
    /// Team A solid, Team B dashed: never colour alone.
    static func teamStroke(_ i: Int, width: CGFloat = 2) -> StrokeStyle {
        StrokeStyle(lineWidth: width, lineCap: .round, dash: i == 0 ? [] : [4, 3])
    }

    /// Avatar swatches (8, per identity sheet spec). `PlayerProfile.avatarColor` stores the name.
    static let avatarNames = ["blue", "teal", "green", "yellow", "orange", "red", "pink", "purple"]
    static func avatar(_ name: String) -> Color {
        switch name {
        case "blue": Color(hex: 0x3B82F6)
        case "teal": Color(hex: 0x14B8A6)
        case "green": Color(hex: 0x22C55E)
        case "yellow": Color(hex: 0xEAB308)
        case "orange": Color(hex: 0xF97316)
        case "red": Color(hex: 0xEF4444)
        case "pink": Color(hex: 0xEC4899)
        case "purple": Color(hex: 0x8B5CF6)
        default:
            if name.hasPrefix("#"), let v = UInt32(name.dropFirst(), radix: 16) { Color(hex: v) } else { Color(hex: 0x64748B) }
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

/// Lets the debug router (and previews) force Reduce Motion; views OR it with the system setting.
extension EnvironmentValues {
    @Entry var sbForceReduceMotion: Bool = false
}

// MARK: - Rating badge style (RATING_CLASSES.md / pages/screens-b.md §2 table)

enum BadgeTone: Equatable, Sendable {
    case brilliant, legal, ink, inkMuted, caution, warn, danger
    var color: Color {
        switch self {
        case .brilliant: SBColor.brilliant
        case .legal: SBColor.legal
        case .ink: SBColor.ink
        case .inkMuted: SBColor.inkMuted
        case .caution: SBColor.caution
        case .warn: SBColor.warn
        case .danger: SBColor.danger
        }
    }
}

struct RatingBadgeStyle: Equatable, Sendable {
    var symbol: String
    var tone: BadgeTone
    var words: String
    /// The only glow on screen (Brilliant).
    var glows: Bool = false
    /// Win-chance chart dot (max four kinds, avoids badge soup).
    var marksChart: Bool = false
    /// Drawn at 60% in the timeline so the eye skips it.
    var recedes: Bool = false

    static func of(_ rating: DecisionRating?) -> RatingBadgeStyle {
        guard let rating else { return RatingBadgeStyle(symbol: "circle.dashed", tone: .inkMuted, words: "Unrated") }
        switch rating {
        case .brilliant: return .init(symbol: "sparkles", tone: .brilliant, words: "Brilliant", glows: true, marksChart: true)
        case .great: return .init(symbol: "star.fill", tone: .legal, words: "Great", marksChart: true)
        case .best: return .init(symbol: "checkmark.seal.fill", tone: .legal, words: "Best")
        case .good: return .init(symbol: "checkmark", tone: .ink, words: "Good")
        case .okay: return .init(symbol: "circle", tone: .inkMuted, words: "Okay", recedes: true)
        case .book: return .init(symbol: "book.closed.fill", tone: .inkMuted, words: "Book", recedes: true)
        case .inaccuracy: return .init(symbol: "exclamationmark", tone: .caution, words: "Inaccuracy")
        case .miss: return .init(symbol: "scope", tone: .warn, words: "Missed chance")
        case .mistake: return .init(symbol: "questionmark", tone: .warn, words: "Mistake", marksChart: true)
        case .blunder: return .init(symbol: "xmark", tone: .danger, words: "Blunder", marksChart: true)
        }
    }
}

/// Reusable round badge: symbol on a 22% tint of the rating colour with a 3-pt ring.
struct RatingBadgeCircle: View {
    var style: RatingBadgeStyle
    var diameter: CGFloat
    var symbolSize: CGFloat
    var selected = false
    var showGlow = true

    var body: some View {
        ZStack {
            Circle().fill(SBColor.bg)
            Circle().fill(style.tone.color.opacity(0.22))
            Circle().strokeBorder(style.tone.color, style: StrokeStyle(lineWidth: 3, dash: style.symbol == "circle.dashed" ? [4, 3] : []))
            Image(systemName: style.symbol)
                .font(SBFont.glyph(symbolSize))
                .foregroundStyle(style.tone.color)
        }
        .frame(width: diameter, height: diameter)
        .overlay {
            if selected { Circle().strokeBorder(SBColor.ink, lineWidth: 3).padding(-6) }
        }
        .shadow(color: (style.glows && showGlow) ? SBColor.brilliant.opacity(0.7) : .clear, radius: 14)
    }
}

/// 2-pt arc in the shooting team's colour. Default sits under a circle (timeline); `pointing(team:)` aims it
/// at that team's avatar corner (Team A top-left, Team B top-right). Stroke with `SBColor.teamStroke` so B is dashed.
struct TeamArc: Shape {
    var start: Angle = .degrees(45)
    var end: Angle = .degrees(135)

    /// y-down SwiftUI angles: 180–270° is the upper-left quadrant, 270–360° the upper-right.
    static func angles(team: Int) -> (start: Angle, end: Angle) {
        team == 0 ? (.degrees(200), .degrees(250)) : (.degrees(290), .degrees(340))
    }

    static func pointing(team: Int) -> TeamArc {
        let a = angles(team: team)
        return TeamArc(start: a.start, end: a.end)
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: rect.width / 2,
                 startAngle: start, endAngle: end, clockwise: false)
        return p
    }
}

/// Type scale (MASTER.md) on Dynamic Type text styles so every label scales.
enum SBFont {
    static let largeTitle = Font.largeTitle.bold()                       // 34 bold
    static let score = Font.system(.largeTitle, design: .rounded).bold() // 34 bold rounded
    static let title = Font.title2.weight(.semibold)                     // 22 semibold
    static let headline = Font.headline                                  // 17 semibold
    static let roundedHeadline = Font.system(.headline, design: .rounded)
    static let body = Font.body                                          // 17 regular
    static let caption = Font.footnote.weight(.semibold)                 // 13 semibold
    /// A symbol drawn inside a fixed-size shape (avatar, disc, 44-pt handle). It does not scale with
    /// Dynamic Type, because the shape around it does not; the words beside it do.
    static func glyph(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight) }
}

/// Circle avatar with optional team ring (A solid, B dashed: colour-blind safe).
struct SBAvatar: View {
    var symbol: String
    var colorName: String
    var size: CGFloat
    var team: Int? = nil
    var dimmed = false

    var body: some View {
        ZStack {
            Circle().fill(SBColor.avatar(colorName))
            Image(systemName: symbol)
                .font(SBFont.glyph(size * 0.45))
                .foregroundStyle(SBColor.ink)
        }
        .frame(width: size, height: size)
        .overlay {
            if let team {
                Circle()
                    .strokeBorder(SBColor.team(team), style: StrokeStyle(lineWidth: 3, dash: team == 0 ? [] : [4, 3]))
                    .padding(-5)
            }
        }
        .opacity(dimmed ? 0.4 : 1)
    }
}

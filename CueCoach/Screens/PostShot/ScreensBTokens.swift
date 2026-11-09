import SwiftUI
import Engine

/// Lets the debug router (and previews) force Reduce Motion; views OR it with the system setting.
extension EnvironmentValues {
    @Entry var sbForceReduceMotion: Bool = false
}

// MARK: - Rating badge style (RATING_CLASSES.md / pages/screens-b.md §2 table)

enum BadgeTone: Equatable, Sendable {
    case brilliant, legal, ink, inkMuted, caution, warn, danger
    var color: Color {
        switch self {
        case .brilliant: AX.brilliant
        case .legal: AX.legal
        case .ink: AX.ink
        case .inkMuted: AX.inkMuted
        case .caution: AX.caution
        case .warn: AX.warn
        case .danger: AX.danger
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
            Circle().fill(AX.page)
            Circle().fill(style.tone.color.opacity(0.22))
            Circle().strokeBorder(style.tone.color, style: StrokeStyle(lineWidth: 3, dash: style.symbol == "circle.dashed" ? [4, 3] : []))
            Image(systemName: style.symbol)
                .font(AXGlyph.font(symbolSize))
                .foregroundStyle(style.tone.color)
        }
        .frame(width: diameter, height: diameter)
        .overlay {
            if selected { Circle().strokeBorder(AX.ink, lineWidth: 3).padding(-6) }
        }
        .shadow(color: (style.glows && showGlow) ? AX.brilliant.opacity(0.7) : .clear, radius: 14)
    }
}

/// 2-pt arc in the shooting team's colour. Default sits under a circle (timeline); `pointing(team:)` aims it
/// at that team's avatar corner (Team A top-left, Team B top-right). Stroke with `AX.teamStroke` so B is dashed.
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

/// Circle avatar with optional team ring (A solid, B dashed: colour-blind safe).
struct SBAvatar: View {
    var symbol: String
    var colorName: String
    var size: CGFloat
    var team: Int? = nil
    var dimmed = false

    var body: some View {
        ZStack {
            Circle().fill(AX.avatar(colorName))
            Image(systemName: symbol)
                .font(AXGlyph.font(size * 0.45))
                .foregroundStyle(AX.ink)
        }
        .frame(width: size, height: size)
        .overlay {
            if let team {
                Circle()
                    .strokeBorder(AX.team(team), style: StrokeStyle(lineWidth: 3, dash: team == 0 ? [] : [4, 3]))
                    .padding(-5)
            }
        }
        .opacity(dimmed ? 0.4 : 1)
    }
}

/// The post-shot badge without the shell's team arc and tap/swipe (MASTER.md: 72-pt circle, symbol + colour +
/// ≤ 2 words). Standalone Live shows it after the balls settle; Live hides it the moment the next aim starts.
struct PostShotRatingBadge: View {
    var rating: DecisionRating

    var body: some View {
        let style = RatingBadgeStyle.of(rating)
        VStack(spacing: 8) {
            RatingBadgeCircle(style: style, diameter: 72, symbolSize: 32)
            Text(style.words)
                .axFont(.label, weight: .semibold)
                .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                .foregroundStyle(AX.ink)
                .lineLimit(1)
                .fixedSize()
                .shadow(color: AXLive.stage.opacity(0.85), radius: 3)
                .shadow(color: AXLive.stage.opacity(0.85), radius: 6)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("live.badge")
    }
}

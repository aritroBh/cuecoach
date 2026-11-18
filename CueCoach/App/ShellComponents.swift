import SwiftUI

/// Shell-wide flags (UI tests force Reduce Motion with `-appshell.reduceMotion`).
extension EnvironmentValues {
    @Entry var shellForceReduceMotion: Bool = false
    /// UI tests: no endless loops (sweeps, breathing), which keep XCUITest from ever seeing the app idle.
    @Entry var shellNoLoops: Bool = false
}

/// Big calm choice tile: one glyph cluster + one word, on an Astryx card.
struct ShellTile<Glyph: View>: View {
    let title: String
    let id: String
    var minHeight: CGFloat = 168
    let action: () -> Void
    @ViewBuilder let glyph: () -> Glyph

    var body: some View {
        Button(action: action) {
            VStack(spacing: AX.space.s4) {
                glyph()
                Text(title)
                    .axFont(.title)
                    .foregroundStyle(AX.ink)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: minHeight)
            .padding(.vertical, AX.space.s4)
            .axSurface(elevated: true)
            .contentShape(RoundedRectangle(cornerRadius: AX.radius.container, style: .continuous))
        }
        .buttonStyle(ShellPressStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(id)
    }
}

struct ShellPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Environment(\.shellForceReduceMotion) private var forced
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !(reduce || forced) ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)   // Astryx press opacity
            .animation(.snappy(duration: 0.2), value: configuration.isPressed)
    }
}

/// 44–56 pt circular icon control on the Astryx card ground.
struct ShellCircleButton: View {
    let symbol: String
    let label: String
    let id: String
    var size: CGFloat = 48
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(AXGlyph.font(size * 0.4, .semibold))
                .foregroundStyle(AX.ink)
                .frame(width: size, height: size)
                .background(Circle().fill(AX.surface))
                .overlay(Circle().strokeBorder(AX.border, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(ShellPressStyle())
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }
}

/// The one primary action per screen, in the Astryx primary look (accent fill, on-accent label), drawn tall
/// (64 pt) because it is pressed beside a table. Dim when blocked; a blocked tap still fires `action` so the
/// model can point at what's missing.
struct ShellStartButton: View {
    var title = "Start"
    var symbol = "play.fill"
    var enabled: Bool
    let id: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            // Blocked = Astryx neutral fill + lock glyph at full contrast; the screen points at what's missing.
            Label(title, systemImage: enabled ? symbol : "lock.fill")
                .axFont(.subtitle)
                .foregroundStyle(enabled ? AX.onAccent : AX.ink)
                .frame(maxWidth: .infinity, minHeight: 64)
                .background(RoundedRectangle(cornerRadius: AX.radius.container, style: .continuous)
                    .fill(enabled ? AX.accent : AX.neutral))
                .contentShape(RoundedRectangle(cornerRadius: AX.radius.container, style: .continuous))
        }
        .buttonStyle(ShellPressStyle())
        .accessibilityIdentifier(id)
        .accessibilityValue(enabled ? "ready" : "not ready")
    }
}

/// Section heading: the Astryx heading (level 3), in secondary ink.
struct ShellSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: AX.space.s3) {
            AXHeading(text: title, level: 3, muted: true)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ShellBackground: View {
    var body: some View { AX.page.ignoresSafeArea() }
}

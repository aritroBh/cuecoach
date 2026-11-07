import SwiftUI

/// Shell-wide flags (UI tests force Reduce Motion with `-appshell.reduceMotion`).
extension EnvironmentValues {
    @Entry var shellForceReduceMotion: Bool = false
}

/// Big calm choice tile: one glyph cluster + one word.
struct ShellTile<Glyph: View>: View {
    let title: String
    let id: String
    var minHeight: CGFloat = 168
    let action: () -> Void
    @ViewBuilder let glyph: () -> Glyph

    var body: some View {
        Button(action: action) {
            VStack(spacing: 16) {
                glyph()
                Text(title)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(SBColor.ink)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: minHeight)
            .padding(.vertical, 16)
            .background(RoundedRectangle(cornerRadius: 20).fill(SBColor.surface))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(SBColor.ink.opacity(0.08), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 20))
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
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.snappy(duration: 0.2), value: configuration.isPressed)
    }
}

/// 44–56 pt circular icon control.
struct ShellCircleButton: View {
    let symbol: String
    let label: String
    let id: String
    var size: CGFloat = 48
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(SBColor.ink)
                .frame(width: size, height: size)
                .background(Circle().fill(SBColor.surface))
                .overlay(Circle().stroke(SBColor.ink.opacity(0.1), lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(ShellPressStyle())
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }
}

/// The one green primary action per screen. Dim when blocked; a blocked tap still fires `action`
/// so the model can point at what's missing.
struct ShellStartButton: View {
    var title = "Start"
    var symbol = "play.fill"
    var enabled: Bool
    let id: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            // Blocked = surface + lock glyph at full contrast; the screen points at what's missing.
            Label(title, systemImage: enabled ? symbol : "lock.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(enabled ? Color.black : SBColor.ink)
                .frame(maxWidth: .infinity, minHeight: 64)
                .background(Capsule().fill(enabled ? SBColor.legal : SBColor.surface))
                .overlay(Capsule().strokeBorder(SBColor.ink.opacity(enabled ? 0 : 0.25), lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(ShellPressStyle())
        .accessibilityIdentifier(id)
        .accessibilityValue(enabled ? "ready" : "not ready")
    }
}

/// Small uppercase-free section heading (22 semibold per MASTER is for titles; sections use headline).
struct ShellSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline).foregroundStyle(SBColor.inkMuted).accessibilityAddTraits(.isHeader)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ShellBackground: View {
    var body: some View { SBColor.bg.ignoresSafeArea() }
}

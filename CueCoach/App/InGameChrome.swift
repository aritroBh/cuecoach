import SwiftUI

/// The one place that constructs LiveScreen. When the capture worker's `LiveScreen(mode:)` lands, replace the body
/// with `LiveScreen(mode: mode.liveMode)` (and uncomment `liveMode` below).
struct LiveScreenAdapter: View {
    let mode: ShellLiveMode
    var body: some View { LiveScreen() }
}

// extension ShellLiveMode {
//     var liveMode: LiveMode {
//         switch self { case .game: .game; case .training(let level): .training(level: level) }
//     }
// }

/// Live camera + the shell's minimal chrome.
struct LiveHost: View {
    let session: LiveSession
    let router: AppRouter

    var body: some View {
        ZStack {
            LiveScreenAdapter(mode: session.mode)
            InGameChrome(session: session, router: router)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(session.mode == .game ? "shell.live.game" : "shell.live.training")
    }
}

/// Top-right menu (LiveScreen keeps the top-left ✕), team discs (Game only), post-shot badge.
/// No text while aiming: discs are avatars + team colour + ring shape; the menu is icon-only until opened.
struct InGameChrome: View {
    let session: LiveSession
    let router: AppRouter
    @State private var menuOpen = false
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Environment(\.shellForceReduceMotion) private var forced

    var body: some View {
        ZStack {
            if let game = session.game {
                PostShotBadgeView(model: game.badge)
                    .environment(\.sbForceReduceMotion, forced)
            }
            VStack(spacing: 12) {
                HStack {
                    Spacer()
                    menuButton
                }
                if let game = session.game, game.hasLineup {
                    TurnDiscs(game: game, reduceMotion: reduce || forced)
                }
                Spacer()
            }
            .padding(16)
            if menuOpen { menu.transition(.opacity) }
        }
        .animation(reduce || forced ? nil : .smooth(duration: 0.3), value: menuOpen)
        #if DEBUG
        .task { await ShellLaunch.demoShotIfRequested(session.game) }
        #endif
    }

    private var menuButton: some View {
        Button { menuOpen = true } label: {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(Circle().fill(.black.opacity(0.45)))
                .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(ShellPressStyle())
        .accessibilityLabel("Menu")
        .accessibilityIdentifier("chrome.menu")
    }

    private var menu: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.5).ignoresSafeArea().onTapGesture { menuOpen = false }
                .accessibilityHidden(true)
            HStack(spacing: 16) {
                menuAction("Resume", symbol: "play.fill", tint: SBColor.ink, id: "chrome.resume") { menuOpen = false }
                if session.game != nil {
                    menuAction("End game", symbol: "flag.checkered", tint: SBColor.danger, id: "chrome.endGame") {
                        menuOpen = false
                        router.endGame()
                    }
                } else {
                    menuAction("Stop", symbol: "stop.fill", tint: SBColor.danger, id: "chrome.stop") {
                        menuOpen = false
                        router.stopTraining()
                    }
                }
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 20).fill(SBColor.surface))
            .padding(16)
        }
    }

    private func menuAction(_ title: String, symbol: String, tint: Color, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 26, weight: .semibold)).foregroundStyle(tint)
                Text(title).font(.body.weight(.semibold)).foregroundStyle(SBColor.ink)
            }
            .frame(maxWidth: .infinity, minHeight: 96)
            .background(RoundedRectangle(cornerRadius: 14).fill(SBColor.bg.opacity(0.6)))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(ShellPressStyle())
        .accessibilityIdentifier(id)
    }
}

/// One disc per team at the top edge: the shooter lit with their team ring, the waiting player dimmed.
/// Tapping the dim disc hands the turn over (SPEC §5.8 one-tap correction).
struct TurnDiscs: View {
    let game: GameSessionModel
    let reduceMotion: Bool

    var body: some View {
        HStack {
            disc(team: 0)
            Spacer()
            disc(team: 1)
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: game.turnIndex)
        .sensoryFeedback(.selection, trigger: game.turnIndex)
    }

    private func disc(team: Int) -> some View {
        let active = game.shootingTeam == team
        let p = active ? game.shooter : game.waitingShooter
        return Button { game.handTurn(toTeam: team) } label: {
            SBAvatar(symbol: p?.symbol ?? "person.fill", colorName: p?.colorName ?? "blue", size: active ? 56 : 44,
                     team: team, dimmed: !active)
                .frame(width: 64, height: 64)
                .contentShape(Circle())
        }
        .buttonStyle(ShellPressStyle())
        .accessibilityLabel("Team \(GameSetupModel.teamLetter(team)), \(p?.name ?? "")")
        .accessibilityValue(active ? "shooting" : "waiting")
        .accessibilityHint(active ? "" : "Double tap to give them the turn")
        .accessibilityIdentifier("chrome.team.\(team)")
    }
}

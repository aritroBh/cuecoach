import SwiftUI

/// Home: two big calm choices (D24) + small Profile / Settings entries.
struct HomeScreen: View {
    let router: AppRouter
    @Environment(\.verticalSizeClass) private var vSize

    var body: some View {
        ZStack {
            ShellBackground()
            VStack(spacing: 24) {
                HStack(spacing: 12) {
                    Spacer()
                    ShellCircleButton(symbol: "person.fill", label: "Profile", id: "home.profile") { router.sheet = .profile }
                    ShellCircleButton(symbol: "gearshape.fill", label: "Settings", id: "home.settings") { router.sheet = .settings }
                }
                Spacer(minLength: 0)
                let layout = vSize == .compact ? AnyLayout(HStackLayout(spacing: 16)) : AnyLayout(VStackLayout(spacing: 16))
                layout {
                    ShellTile(title: "Game", id: "home.game", action: router.openGame) {
                        HStack(spacing: -10) {
                            SBAvatar(symbol: "person.fill", colorName: "blue", size: 56, team: 0)
                            SBAvatar(symbol: "person.fill", colorName: "orange", size: 56, team: 1)
                        }
                        .accessibilityHidden(true)
                    }
                    ShellTile(title: "Training", id: "home.training", action: router.openTraining) {
                        Image(systemName: "scope")
                            .font(AXGlyph.font(48, .semibold))
                            .foregroundStyle(AX.accent)
                            .frame(height: 64)
                            .accessibilityHidden(true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(16)
        }
        .toolbar(.hidden, for: .navigationBar)
    }
}

/// Game: host a new game on this phone, or join one hosted nearby.
struct GameHubScreen: View {
    let router: AppRouter
    @Environment(\.verticalSizeClass) private var vSize

    var body: some View {
        ZStack {
            ShellBackground()
            ScrollView {
                let layout = vSize == .compact ? AnyLayout(HStackLayout(spacing: 16)) : AnyLayout(VStackLayout(spacing: 16))
                layout {
                    ShellTile(title: "New game", id: "game.new", action: router.openNewGame) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 48, weight: .semibold)).foregroundStyle(AX.accent)
                            .accessibilityHidden(true)
                    }
                    ShellTile(title: "Join nearby", id: "game.join", action: router.openJoinNearby) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(AXGlyph.font(44, .semibold)).foregroundStyle(AX.accent)
                            .accessibilityHidden(true)
                    }
                }
                .padding(16)
            }
        }
        .navigationTitle("Game")
        .navigationBarTitleDisplayMode(.inline)
    }
}

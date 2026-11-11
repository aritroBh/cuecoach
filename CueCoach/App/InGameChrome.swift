import SwiftUI
import Geometry

/// The one place that constructs LiveScreen: mode, drill and the hooks that drive `LiveSession` (aim → menu
/// closed + badge silenced; settled → rating recorded, badge, turn), with the shell's game injected for ratings
/// and ring legality. Live's own ✕ dismisses; the cover's `onDismiss` maps it (`AppRouter.liveClosed`).
struct LiveScreenAdapter: View {
    let session: LiveSession
    var body: some View {
        LiveScreen(mode: session.mode.liveMode, drill: session.drill, hooks: Self.hooks(for: session),
                   tablePrior: Self.tablePrior(for: session))
    }

    /// D36 (C): the locator's size prior is the game's setup size, or in Training the Settings manual size (if any).
    @MainActor static func tablePrior(for session: LiveSession, defaults: UserDefaults = .standard) -> TableSize? {
        session.game?.config.tableSize ?? SetupDefaults.fromSettings(defaults).manualTable
    }

    @MainActor static func hooks(for session: LiveSession) -> LiveHooks {
        var h = LiveHooks(aimStarted: { session.aimStarted() }, aimEnded: { session.aimEnded() },
                          aimCancelled: { session.aimCancelled() }, ballsSettled: { session.ballsSettled() },
                          settled: { _, _ in })
        h.settledShot = { session.settled($0) }
        let game = session.game
        h.currentGame = { game?.rules }
        h.gameAdvanced = { game?.rulesAdvanced($0) }
        h.legalSink = { sink in game?.legalChanged = sink }
        return h
    }
}

extension ShellLiveMode {
    var liveMode: LiveMode {
        switch self { case .game: .game; case .training(let level): .training(level: level) }
    }
}

/// Live camera + the shell's minimal chrome.
struct LiveHost: View {
    let session: LiveSession
    let router: AppRouter

    var body: some View {
        ZStack {
            LiveScreenAdapter(session: session)
            InGameChrome(session: session, router: router)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(session.mode == .game ? "shell.live.game" : "shell.live.training")
    }
}

/// Top-right menu (LiveScreen keeps the top-left ✕), team discs (Game only), post-shot badge.
/// No text while aiming: discs are avatars + team colour + ring shape; the menu is icon-only until opened.
struct InGameChrome: View {
    @Bindable var session: LiveSession
    let router: AppRouter
    private var menuOpen: Bool { session.isMenuOpen }
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
                    // Hidden while anyone aims: the menu has words (SPEC §2).
                    if session.menuAvailable { menuButton } else { Color.clear.frame(width: 56, height: 56) }
                }
                if let game = session.game, game.hasLineup {
                    TurnDiscs(game: game, reduceMotion: reduce || forced) { session.handTurn(toTeam: $0) }
                }
                Spacer()
            }
            .padding(16)
            if menuOpen { menu.transition(.opacity) }
        }
        .animation(reduce || forced ? nil : .smooth(duration: 0.3), value: menuOpen)
        .overlay(alignment: .bottomLeading) {
            Color.clear.frame(width: 1, height: 1)
                .accessibilityElement()
                .accessibilityIdentifier("chrome.mesh")
                .accessibilityValue("peers:\(session.game?.mesh?.peerCount ?? 1)")
        }
        #if DEBUG
        .task { await ShellLaunch.demoShotIfRequested(session.game) }
        #endif
    }

    private var menuButton: some View {
        Button { session.isMenuOpen = true } label: {
            Image(systemName: "line.3.horizontal")
                .font(AXGlyph.font(22, .semibold))
                .foregroundStyle(AXLive.aim)
                .frame(width: 56, height: 56)
                .background(Circle().fill(AXLive.chip.opacity(0.7)))
                .overlay(Circle().strokeBorder(AXLive.aim.opacity(0.25), lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(ShellPressStyle())
        .accessibilityLabel("Menu")
        .accessibilityIdentifier("chrome.menu")
    }

    private var menu: some View {
        ZStack(alignment: .bottom) {
            AXLive.scrim.ignoresSafeArea().onTapGesture { session.isMenuOpen = false }
                .accessibilityHidden(true)
            VStack(spacing: 16) {
                if let game = session.game, game.hasLineup { OrderEditor(game: game) }
                HStack(spacing: 16) {
                    menuAction("Resume", symbol: "play.fill", tint: AX.accent, id: "chrome.resume") { session.isMenuOpen = false }
                    if session.game != nil {
                        menuAction("End game", symbol: "flag.checkered", tint: AX.danger, id: "chrome.endGame") {
                            session.isMenuOpen = false
                            router.endGame()
                        }
                    } else {
                        menuAction("Stop", symbol: "stop.fill", tint: AX.danger, id: "chrome.stop") {
                            session.isMenuOpen = false
                            router.stopTraining()
                        }
                    }
                }
            }
            .padding(AX.space.s4)
            .axSurface(AX.raised, radius: AX.radius.page, elevated: true)
            .padding(AX.space.s4)
        }
    }

    private func menuAction(_ title: String, symbol: String, tint: Color, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: symbol).font(AXGlyph.font(26, .semibold)).foregroundStyle(tint)
                Text(title).axFont(.headline).foregroundStyle(AX.ink)
            }
            .frame(maxWidth: .infinity, minHeight: 96)
            .background(RoundedRectangle(cornerRadius: AX.radius.container, style: .continuous).fill(AX.neutral))
            .contentShape(RoundedRectangle(cornerRadius: AX.radius.container, style: .continuous))
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
    /// Routed through `LiveSession`, which ignores it while a shot is live.
    let handTurn: (Int) -> Void

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
        return Button { handTurn(team) } label: {
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

/// Mid-game shooting order (SPEC §4): tap one player, then another on the same team, to swap them.
/// Only inside the menu, which can't open while anyone aims.
struct OrderEditor: View {
    let game: GameSessionModel
    @State private var picked: (team: Int, slot: Int)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(0..<game.teams.count, id: \.self) { t in
                HStack(spacing: 20) {
                    TeamRing(team: t, size: 16)
                    ForEach(Array(game.teams[t].enumerated()), id: \.element.id) { i, p in
                        let isPicked = picked.map { $0.team == t && $0.slot == i } ?? false
                        Button {
                            if let pk = picked, pk.team == t {
                                game.swap(team: t, pk.slot, i)
                                picked = nil
                            } else {
                                picked = (t, i)
                            }
                        } label: {
                            SBAvatar(symbol: p.symbol, colorName: p.colorName, size: 44, team: t)
                                .overlay(Circle().stroke(AX.ink, lineWidth: isPicked ? 3 : 0).padding(-6))
                                .frame(width: 56, height: 56)
                                .contentShape(Circle())
                        }
                        .buttonStyle(ShellPressStyle())
                        .accessibilityLabel("\(p.name), team \(GameSetupModel.teamLetter(t)), position \(i + 1)")
                        .accessibilityHint("Tap another player on this team to swap")
                        .accessibilityIdentifier("chrome.order.\(t).\(i)")
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(AX.space.s3)
        .background(RoundedRectangle(cornerRadius: AX.radius.container, style: .continuous).fill(AX.neutral))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chrome.order")
    }
}

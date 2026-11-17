import SwiftUI

/// Root: the shell once the store opened, else the recovery screen (no profile or game creation without a store).
struct AppShellRoot: View {
    @State private var boot = ShellEnvironment.current()

    var body: some View {
        switch boot {
        case .ready(let env): ShellMain(env: env)
        case .storeUnavailable: StoreRecoveryView { boot = ShellEnvironment.current() }
        }
    }
}

/// The saved-games store didn't open. Nothing is deleted; Retry opens it again.
struct StoreRecoveryView: View {
    let retry: () -> Void

    var body: some View {
        ZStack {
            ShellBackground()
            VStack(spacing: 24) {
                Image(systemName: "externaldrive.badge.exclamationmark")
                    .font(AXGlyph.font(64, .semibold))
                    .foregroundStyle(AX.caution)
                    .accessibilityHidden(true)
                Text("Can't open your saved games.")
                    .axFont(.subtitle)
                    .foregroundStyle(AX.ink)
                    .multilineTextAlignment(.center)
                ShellStartButton(title: "Retry", symbol: "arrow.clockwise", enabled: true, id: "shell.storeRetry", action: retry)
            }
            .padding(16)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("shell.storeUnavailable")
    }
}

/// NavigationStack (Home → Game hub → New game | Join nearby; Home → Training) under one full-screen
/// cover for Live and Review. See docs/design/app-shell.md for the graph.
struct ShellMain: View {
    let env: ShellEnvironment
    @State private var router = AppRouter()
    /// The cover was dismissed by its content (LiveScreen's own ✕) and is animating away.
    @State private var coverDismissing = false

    var body: some View {
        NavigationStack(path: $router.path) {
            HomeScreen(router: router)
                .navigationDestination(for: ShellRoute.self) { route in destination(route) }
        }
        .tint(AX.accentText)   // Astryx text-accent: legible as words on bars in dark mode
        .fullScreenCover(isPresented: coverBinding, onDismiss: {
            coverDismissing = false
            router.liveClosed()   // game → review (re-presents); training → back to the picker
        }) {
            stage
        }
        .sheet(item: $router.sheet) { sheet in
            NavigationStack { sheetContent(sheet) }
                .environment(\.saForceReduceMotion, env.reduceMotion)
        }
        .environment(\.shellForceReduceMotion, env.reduceMotion)
        .environment(\.shellNoLoops, env.noLoops)
        .environment(\.sbForceReduceMotion, env.reduceMotion)
        .cueCoachTheme()
        .onAppear { router.meshFactory = env.meshFactory; router.recorder = env.recorder; router.stack = env.stack }
        #if DEBUG
        .task { await ShellAutopilot.run(env: env, router: router) }
        #endif
    }

    private var coverBinding: Binding<Bool> {
        Binding(get: { router.stage != nil && !coverDismissing },
                set: { presented in if !presented { coverDismissing = true } })
    }

    @ViewBuilder private func destination(_ route: ShellRoute) -> some View {
        switch route {
        case .gameHub: GameHubScreen(router: router)
        case .newGame:
            GameSetupView(model: {
                let m = env.setupModel()
                m.onStart = { [router] in router.startGame($0) }
                return m
            }())
        case .joinNearby:
            JoinNearbyView(model: {
                let m = JoinNearbyModel(mesh: env.mesh)
                m.onStart = { [router] in router.startGame($0) }
                return m
            }())
        case .training:
            TrainingPickerView(model: {
                let m = TrainingPickerModel(defaults: env.defaults)
                m.onStart = { [router] in router.startTraining(drill: $0, level: $1) }
                return m
            }())
        }
    }

    @ViewBuilder private var stage: some View {
        switch router.stage {
        case .live(let s)?:
            LiveHost(session: s, router: router)
                .environment(\.shellForceReduceMotion, env.reduceMotion)
                // The camera is the ground: Live always draws in Astryx dark (D34 design call). Scoped through the
                // environment, not `preferredColorScheme`, which would stick to the cover when it turns into Review.
                .environment(\.colorScheme, .dark)
        case .review(let model)?:
            GameReviewView(model: model)
            .environment(\.sbForceReduceMotion, env.reduceMotion)
        case nil:
            AXLive.stage
        }
    }

    @ViewBuilder private func sheetContent(_ sheet: ShellSheet) -> some View {
        switch sheet {
        case .settings:
            SettingsView(model: SettingsViewModel(store: env.settings, measurement: env.measurement, defaults: env.defaults))
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { router.sheet = nil }.accessibilityIdentifier("sheet.done") } }
        case .profile:
            ProfileSheet(model: ProfileEntryModel(store: env.owners), stack: env.stack)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { router.sheet = nil }.accessibilityIdentifier("sheet.done") } }
        }
    }
}

/// Reviewed game wrapper for `fullScreenCover(item:)` from Profile History.
private struct PresentedHistoryGame: Identifiable {
    let id: UUID
    let model: GameReviewModel
}

private struct OwnerProfileHost: View {
    let owner: ShellPlayer
    let ownerStore: any OwnerStore
    let stack: PersistenceStack?
    @State private var vm: PlayerProfileViewModel
    @State private var openedGame: PresentedHistoryGame?

    init(owner: ShellPlayer, ownerStore: any OwnerStore, stack: PersistenceStack?) {
        self.owner = owner
        self.ownerStore = ownerStore
        self.stack = stack
        if let stack {
            self._vm = State(initialValue: PlayerProfileViewModel(
                playerID: owner.id,
                stats: PersistenceProfileStatsSource(stack: stack),
                training: PersistenceTrainingSource(stack: stack)))
        } else {
            self._vm = State(initialValue: PlayerProfileViewModel(
                playerID: owner.id,
                stats: OwnerOnlyStats(owner: owner, store: ownerStore),
                training: SampleTrainingSource(drills: [], bias: nil)))
        }
    }

    var body: some View {
        PlayerProfileView(model: vm)
            .onAppear { wireOpenGame() }
            .fullScreenCover(item: $openedGame) { item in
                GameReviewView(model: item.model)
            }
    }

    private func wireOpenGame() {
        guard let stack else { return }
        vm.onOpenGame = { gameID in
            let reviewModel = PersistedGameReviewEditor.makeModel(
                stack: stack, gameID: gameID,
                onChanged: { Task { await vm.load() } },
                onDismiss: { openedGame = nil })
            openedGame = PresentedHistoryGame(id: gameID, model: reviewModel)
        }
    }
}

/// The owner's profile, or a one-field "your name" form when this phone has no owner yet.
struct ProfileSheet: View {
    @State var model: ProfileEntryModel
    var stack: PersistenceStack? = nil
    @State private var name = ""

    var body: some View {
        if let owner = model.owner {
            OwnerProfileHost(owner: owner, ownerStore: model.ownerStore, stack: stack)
                .id(owner.id)
        } else {
            ZStack {
                ShellBackground()
                VStack(spacing: 24) {
                    SBAvatar(symbol: ShellPalette.symbols[0], colorName: ShellPalette.names[1], size: 96)
                        .accessibilityHidden(true)
                    TextField("Your name", text: $name)
                        .axFont(.subtitle, weight: .regular)
                        .textInputAutocapitalization(.words)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 56)
                        .background(RoundedRectangle(cornerRadius: AX.radius.container).fill(AX.surface))
                        .accessibilityIdentifier("shell.profile.nameField")
                        .onSubmit(save)
                    ShellStartButton(title: "Save", symbol: "checkmark", enabled: !name.trimmingCharacters(in: .whitespaces).isEmpty,
                                     id: "shell.profile.save", action: save)
                }
                .padding(16)
            }
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func save() { try? model.create(name: name) }
}

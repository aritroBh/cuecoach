import SwiftUI

/// Root: NavigationStack (Home → Game hub → New game | Join nearby; Home → Training) under one full-screen
/// cover for Live and Review. See docs/design/app-shell.md for the graph.
struct AppShellRoot: View {
    @State private var env = ShellEnvironment.current()
    @State private var router = AppRouter()
    /// The cover was dismissed by its content (LiveScreen's own ✕) and is animating away.
    @State private var coverDismissing = false

    var body: some View {
        NavigationStack(path: $router.path) {
            HomeScreen(router: router)
                .navigationDestination(for: ShellRoute.self) { route in destination(route) }
        }
        .tint(AX.accent)
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
        .onAppear { router.meshFactory = env.meshFactory }
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
        case .review(let data)?:
            GameReviewView(model: {
                let m = GameReviewModel(data: data)
                m.onDone = { [router] in router.finishReview() }
                return m
            }())
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
            ProfileSheet(model: ProfileEntryModel(store: env.owners))
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { router.sheet = nil }.accessibilityIdentifier("sheet.done") } }
        }
    }
}

/// The owner's profile, or a one-field "your name" form when this phone has no owner yet.
struct ProfileSheet: View {
    @State var model: ProfileEntryModel
    @State private var name = ""

    var body: some View {
        if let owner = model.owner {
            PlayerProfileView(model: PlayerProfileViewModel(playerID: owner.id, stats: OwnerOnlyStats(owner: owner, store: model.ownerStore),
                                                            training: SampleTrainingSource(drills: [], bias: nil)))
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

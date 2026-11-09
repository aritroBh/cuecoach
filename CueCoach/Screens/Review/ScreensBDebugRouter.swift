#if DEBUG
import SwiftUI
import UIKit
import Engine

/// Debug-only router so XCUITests can open Screens B without touching App/HomeView.
/// Launch with `-screen=<name>`; optional `-sbReduceMotion` and `-sbDynamicType=xxl` (forces the largest size, AX5).
/// Installed by `ScreensBDebugBoot.c` (a C constructor) only when the name is one of ours.
enum ScreensBDebugRouter {
    static let screens: Set<String> = Set(
        ["lobby", "lobby-locked", "lobby-solo", "lobby-peer", "lobby-identity", "lobby-join", "lobby-meshdenied",
         "badge-live", "review", "review-loading", "review-empty", "review-locked", "review-error", "review-short",
         "review-failed"] + DecisionRating.allCases.map { "badge-\($0.rawValue)" })

    static func requestedScreen(_ args: [String] = ProcessInfo.processInfo.arguments) -> String? {
        args.first { $0.hasPrefix("-screen=") }.map { String($0.dropFirst("-screen=".count)) }
    }

    @MainActor static var installed = false

    @MainActor static func install() {
        guard !installed, let name = requestedScreen(), screens.contains(name) else { return }
        let args = ProcessInfo.processInfo.arguments
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            guard let window = scene.keyWindow ?? scene.windows.first else { continue }
            let root = ScreensBDebugScreen(name: name)
                .environment(\.sbForceReduceMotion, args.contains("-sbReduceMotion"))
                .modifier(SBDynamicType(xxl: args.contains("-sbDynamicType=xxl")))
            window.rootViewController = UIHostingController(rootView: root)
            installed = true
        }
    }
}

private struct SBDynamicType: ViewModifier {
    var xxl: Bool
    func body(content: Content) -> some View {
        if xxl { content.dynamicTypeSize(.accessibility5) } else { content }
    }
}

@_cdecl("cuecoach_screensb_debug_boot")
func cuecoachScreensBDebugBoot() {
    guard let name = ScreensBDebugRouter.requestedScreen(), ScreensBDebugRouter.screens.contains(name) else { return }
    NotificationCenter.default.addObserver(forName: UIScene.didActivateNotification, object: nil, queue: .main) { _ in
        MainActor.assumeIsolated { ScreensBDebugRouter.install() }
    }
}

struct ScreensBDebugScreen: View {
    let name: String

    var body: some View {
        switch name {
        case "lobby": Owned(LobbySamples.hostFull()) { LobbyView(model: $0) }
        case "lobby-locked": Owned(LobbySamples.hostLocked()) { LobbyView(model: $0) }
        case "lobby-solo": Owned(LobbySamples.solo()) { LobbyView(model: $0) }
        case "lobby-peer": Owned(LobbySamples.peerView()) { LobbyView(model: $0) }
        case "lobby-identity":
            Owned(LobbySamples.hostLocked()) { LobbyView(model: $0, initialSheet: .identity(SeatRef(team: 0, slot: 1))) }
        case "lobby-join": Owned(LobbySamples.joinable()) { LobbyView(model: $0, initialSheet: .join) }
        case "lobby-meshdenied": Owned(LobbySamples.meshDenied()) { LobbyView(model: $0) }
        case "review": Owned(GameReviewModel(source: InMemoryGameReviewSource(GameReviewSamples.finished()))) { GameReviewView(model: $0) }
        case "review-loading":
            Owned(GameReviewModel(source: InMemoryGameReviewSource(GameReviewSamples.finished(), delay: .seconds(600)))) { GameReviewView(model: $0) }
        case "review-empty": Owned(GameReviewModel(data: GameReviewSamples.empty())) { GameReviewView(model: $0) }
        case "review-locked": Owned(GameReviewModel(data: GameReviewSamples.inProgress())) { GameReviewView(model: $0) }
        case "review-error": Owned(GameReviewModel(data: GameReviewSamples.withBrokenShot())) { GameReviewView(model: $0) }
        case "review-short": Owned(GameReviewModel(data: GameReviewSamples.short())) { GameReviewView(model: $0) }
        case "review-failed": Owned(GameReviewModel(source: InMemoryGameReviewSource(nil))) { GameReviewView(model: $0) }
        case "badge-live": BadgeStage(rating: .great, pinned: false)
        default:
            if let r = DecisionRating(rawValue: name.replacingOccurrences(of: "badge-", with: "")) {
                BadgeStage(rating: r, pinned: true)
            } else {
                Text(name)
            }
        }
    }
}

/// The owner keeps one model instance for the screen's lifetime (views hold theirs as plain `let`).
private struct Owned<M: AnyObject, Content: View>: View {
    @State private var model: M
    let content: (M) -> Content
    init(_ model: @autoclosure () -> M, @ViewBuilder content: @escaping (M) -> Content) {
        _model = State(wrappedValue: model())
        self.content = content
    }
    var body: some View { content(model) }
}

/// Stand-in for the live camera: felt + turn avatars, with the badge overlay on top.
private struct BadgeStage: View {
    let rating: DecisionRating
    let pinned: Bool
    @State private var model = PostShotBadgeModel()
    @State private var aiming = false

    var body: some View {
        ZStack {
            RadialGradient(colors: [SBColor.feltCenter, SBColor.feltEdge, SBColor.bg], center: .center,
                           startRadius: 40, endRadius: 520).ignoresSafeArea()
            VStack {
                HStack {
                    SBAvatar(symbol: "hare.fill", colorName: "orange", size: 56, team: 0)
                    Spacer()
                    SBAvatar(symbol: "flame.fill", colorName: "red", size: 56, team: 1, dimmed: true)
                }
                .padding(24)
                Spacer()
                if !pinned {
                    HStack(spacing: 16) {
                        Button { aiming = false; model.receive(.aimEnded); fire() } label: {
                            Text("Rate").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                        }
                        .accessibilityIdentifier("debug.rate")
                        Button { aiming = true; model.receive(.aimStarted) } label: {
                            Text("Aim").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                        }
                        .accessibilityIdentifier("debug.aim")
                    }
                    .foregroundStyle(SBColor.inkMuted)
                    .padding(.bottom, 24)
                }
            }
            PostShotBadgeView(model: model)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            guard pinned else { return }   // live mode waits for the Rate button
            fire()
            model.tap()
        }
    }

    private func fire() {
        model.receive(.rated(PostShotRating(shotID: UUID(), rating: rating, shooterName: "Sam", team: 0)))
    }
}
#endif

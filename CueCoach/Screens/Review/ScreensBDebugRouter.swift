#if DEBUG
import SwiftUI
import UIKit
import Engine

/// Debug-only router so XCUITests can open Screens B without touching App/HomeView.
/// Launch with `-screen=<name>`; optional `-sbReduceMotion` and `-sbDynamicType=xxl`.
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
        if xxl { content.dynamicTypeSize(.accessibility3) } else { content }
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
        case "lobby": LobbyView(model: LobbySamples.hostFull())
        case "lobby-locked": LobbyView(model: LobbySamples.hostLocked())
        case "lobby-solo": LobbyView(model: LobbySamples.solo())
        case "lobby-peer": LobbyView(model: LobbySamples.peerView())
        case "lobby-identity": LobbyView(model: LobbySamples.hostLocked(), initialSheet: .identity(SeatRef(team: 0, slot: 1)))
        case "lobby-join": LobbyView(model: LobbySamples.joinable(), initialSheet: .join)
        case "lobby-meshdenied": LobbyView(model: LobbySamples.meshDenied())
        case "review": GameReviewView(model: GameReviewModel(source: InMemoryGameReviewSource(GameReviewSamples.finished())))
        case "review-loading": GameReviewView(model: GameReviewModel(source: InMemoryGameReviewSource(GameReviewSamples.finished(), delay: .seconds(600))))
        case "review-empty": GameReviewView(model: GameReviewModel(data: GameReviewSamples.empty()))
        case "review-locked": GameReviewView(model: GameReviewModel(data: GameReviewSamples.inProgress()))
        case "review-error": GameReviewView(model: GameReviewModel(data: GameReviewSamples.withBrokenShot()))
        case "review-short": GameReviewView(model: GameReviewModel(data: GameReviewSamples.short()))
        case "review-failed": GameReviewView(model: GameReviewModel(source: InMemoryGameReviewSource(nil)))
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
                        Button("Rate") { aiming = false; model.receive(.aimEnded); fire() }
                            .accessibilityIdentifier("debug.rate")
                        Button("Aim") { aiming = true; model.receive(.aimStarted) }
                            .accessibilityIdentifier("debug.aim")
                    }
                    .frame(minHeight: 44)
                    .foregroundStyle(SBColor.inkMuted)
                    .padding(.bottom, 24)
                }
            }
            PostShotBadgeView(model: model)
        }
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("screen.badge")
        .onAppear {
            fire()
            if pinned { model.tap() }
        }
    }

    private func fire() {
        model.receive(.rated(PostShotRating(shotID: UUID(), rating: rating, shooterName: "Sam", team: 0)))
    }
}
#endif

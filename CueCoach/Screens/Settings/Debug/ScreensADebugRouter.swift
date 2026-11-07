#if DEBUG
import Geometry
import SwiftUI
import UIKit

/// Debug-only router so XCUITests can open Screens A directly, without touching Home or CueCoach/App.
///
/// Launch arguments:
///   -screen=settings|profile
///   -fixture=<name>       settings: default|measured|empty|deleteFail   profile: veteran|newPlayer|preUnlock|error|guest
///   -tab=stats|history|training
///   -dynamicType=xxl      -reduceMotion
///
/// Installed by a C constructor (ScreensADebugBoot.m) that swaps the first active window's root view controller.
enum ScreensADebugRouter {
    struct Request: Equatable {
        var screen: String
        var fixture: String
        var tab: String?
        var xxl: Bool
        var reduceMotion: Bool
    }

    static func parse(_ args: [String]) -> Request? {
        func value(_ key: String) -> String? {
            args.first { $0.hasPrefix("-\(key)=") }.map { String($0.dropFirst(key.count + 2)) }
        }
        guard let screen = value("screen") else { return nil }
        return Request(screen: screen, fixture: value("fixture") ?? "default", tab: value("tab"),
                       xxl: value("dynamicType") == "xxl", reduceMotion: args.contains("-reduceMotion"))
    }

    nonisolated(unsafe) static var observer: NSObjectProtocol?

    static func installIfRequested() {
        guard let request = parse(ProcessInfo.processInfo.arguments) else { return }
        observer = NotificationCenter.default.addObserver(forName: UIScene.didActivateNotification, object: nil,
                                                          queue: .main) { note in
            nonisolated(unsafe) let note = note
            MainActor.assumeIsolated {
                guard let scene = note.object as? UIWindowScene,
                      let window = scene.windows.first(where: \.isKeyWindow) ?? scene.windows.first else { return }
                window.rootViewController = UIHostingController(rootView: ScreensADebugRoot(request: request))
                if let observer { NotificationCenter.default.removeObserver(observer) }
                observer = nil
            }
        }
    }
}

struct ScreensADebugRoot: View {
    let request: ScreensADebugRouter.Request

    var body: some View {
        NavigationStack { screen }
            .dynamicTypeSize(request.xxl ? .xxLarge : .large)
            .environment(\.saForceReduceMotion, request.reduceMotion)
            .preferredColorScheme(.dark)
    }

    @ViewBuilder private var screen: some View {
        switch request.screen {
        case "settings": SettingsView(model: settingsModel())
        case "profile": PlayerProfileView(model: profileModel())
        default: Text("Unknown screen").accessibilityIdentifier("debug.unknown")
        }
    }

    @MainActor private func settingsModel() -> SettingsViewModel {
        let suite = "cc.screensA.debug"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = InMemorySettingsStore(hasRecognitionData: request.fixture != "empty")
        store.failDelete = request.fixture == "deleteFail"
        struct Fixed: TableMeasurementSource { var measured: TableSize? }
        let model = SettingsViewModel(store: store,
                                      measurement: Fixed(measured: request.fixture == "measured" ? .eightFoot : nil),
                                      defaults: defaults)
        if request.fixture != "empty" { model.recognitionOptIn = true }
        return model
    }

    @MainActor private func profileModel() -> PlayerProfileViewModel {
        let guest = request.fixture == "guest"
        let f = SamplePlayerData.named(guest ? "veteran" : request.fixture) ?? .veteran
        let m = PlayerProfileViewModel(playerID: f.playerID, stats: f.stats, training: guest ? nil : f.training)
        if let t = request.tab.flatMap(ProfileTab.init(rawValue:)), m.tabs.contains(t) { m.tab = t }
        return m
    }
}

@_cdecl("cc_screensA_installDebugRouter")
func cc_screensA_installDebugRouter() {
    ScreensADebugRouter.installIfRequested()
}
#endif

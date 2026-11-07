import Testing
@testable import CueCoach

@MainActor @Test func appModuleLoads() {
    _ = AppShellRoot()
}

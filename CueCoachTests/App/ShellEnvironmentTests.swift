import Foundation
import Testing
@testable import CueCoach

/// Fix round (review finding 6): a store that fails to open is an error state, never a silent in-memory game.
@MainActor
@Suite struct ShellEnvironmentBootTests {
    struct Broken: Error {}

    @Test func storeThatFailsToOpenIsAnErrorStateNotAnEnvironment() {
        var calls = 0
        let boot = ShellEnvironment.production(makeStack: { calls += 1; throw Broken() })
        #expect(calls == 1)
        if case .ready = boot { Issue.record("a failed store must not yield a usable environment") }
        #expect(boot.environment == nil)
    }

    @Test func storeThatOpensGivesAnEnvironment() throws {
        let boot = ShellEnvironment.production(makeStack: { try PersistenceStack(inMemory: true) })
        #expect(boot.environment != nil)
    }
}

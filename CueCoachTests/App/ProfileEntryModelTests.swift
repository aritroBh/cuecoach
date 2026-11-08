import Foundation
import Testing
@testable import CueCoach

@MainActor
@Suite struct ProfileEntryModelTests {
    @Test func withoutAnOwnerAsksForAName() {
        let m = ProfileEntryModel(store: InMemoryOwnerStore(owner: nil))
        #expect(m.owner == nil)
    }

    @Test func createsTheOwnerOnce() throws {
        let store = InMemoryOwnerStore(owner: nil)
        let m = ProfileEntryModel(store: store)
        try m.create(name: " Ari ")
        #expect(m.owner?.name == "Ari")
        #expect(store.owner?.name == "Ari")
        #expect(m.owner?.isGuest == false)
    }

    @Test func blankNameIsRejected() {
        let m = ProfileEntryModel(store: InMemoryOwnerStore(owner: nil))
        #expect(throws: SetupError.blankName) { try m.create(name: "   ") }
        #expect(m.owner == nil)
    }

    @Test func existingOwnerIsShown() {
        let p = ShellPlayer(id: UUID(), name: "Ari", symbol: "hare.fill", colorName: "teal")
        #expect(ProfileEntryModel(store: InMemoryOwnerStore(owner: p)).owner == p)
    }
}

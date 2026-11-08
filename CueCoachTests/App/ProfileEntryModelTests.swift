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

    /// screens-a's rename writes the owner's PlayerProfile row (integration: OwnerOnlyStats lacked updateProfile).
    @Test func renamingFromTheProfileWritesTheOwnerRow() async throws {
        let stack = try PersistenceStack(inMemory: true)
        let store = PersistenceOwnerStore(stack: stack)
        let owner = try store.createOwner(name: "Ari", symbol: "hare.fill", colorName: "teal")
        let stats = OwnerOnlyStats(owner: owner, store: store)
        try await stats.updateProfile(owner.id, name: "Aritro", avatarSymbol: "tortoise.fill")
        #expect(store.owner?.name == "Aritro")
        #expect(store.owner?.symbol == "tortoise.fill")
        #expect(try await stats.profile(owner.id).name == "Aritro")
    }

    @Test func renamingSomeoneElseIsRefused() async throws {
        let store = InMemoryOwnerStore(owner: ShellPlayer(id: UUID(), name: "Ari", symbol: "hare.fill", colorName: "teal"))
        let stats = OwnerOnlyStats(owner: store.owner!, store: store)
        await #expect(throws: SetupError.self) { try await stats.updateProfile(UUID(), name: "X", avatarSymbol: "s") }
        await #expect(throws: SetupError.blankName) { try await stats.updateProfile(store.owner!.id, name: "  ", avatarSymbol: "s") }
        #expect(store.owner?.name == "Ari")
    }
}

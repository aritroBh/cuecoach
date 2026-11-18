import Foundation
import Observation
import SwiftData
import Synchronization

/// The phone owner's profile (`PlayerProfile.isLocalOwner`).
@MainActor protocol OwnerStore: AnyObject {
    var owner: ShellPlayer? { get }
    func createOwner(name: String, symbol: String, colorName: String) throws -> ShellPlayer
    /// Renames / re-glyphs the owner (the profile screen's edit). Throws `SetupError.notOwner` for anyone else.
    func updateOwner(_ id: UUID, name: String, symbol: String) throws
}

@MainActor final class InMemoryOwnerStore: OwnerStore {
    private(set) var owner: ShellPlayer?
    init(owner: ShellPlayer?) { self.owner = owner }
    func createOwner(name: String, symbol: String, colorName: String) throws -> ShellPlayer {
        let p = ShellPlayer(id: UUID(), name: name, symbol: symbol, colorName: colorName)
        owner = p
        return p
    }
    func updateOwner(_ id: UUID, name: String, symbol: String) throws {
        guard var o = owner, o.id == id else { throw SetupError.notOwner }
        o.name = name; o.symbol = symbol
        owner = o
    }
}

@MainActor final class PersistenceOwnerStore: OwnerStore {
    private let stack: PersistenceStack
    init(stack: PersistenceStack) { self.stack = stack }
    var owner: ShellPlayer? {
        let rows = (try? stack.competitiveContext.fetch(SAFetch.localOwners())) ?? []
        return rows.sorted { $0.createdAt < $1.createdAt }.first.map(PersistenceRoster.player)
    }
    func createOwner(name: String, symbol: String, colorName: String) throws -> ShellPlayer {
        let p = PlayerProfile(name: name, avatarSymbol: symbol, avatarColor: colorName, isLocalOwner: true)
        stack.competitiveContext.insert(p)
        try stack.competitiveContext.save()
        return PersistenceRoster.player(p)
    }
    func updateOwner(_ id: UUID, name: String, symbol: String) throws {
        let ctx = stack.competitiveContext
        guard let p = try ctx.fetch(SAFetch.localOwners()).first(where: { $0.id == id }) else { throw SetupError.notOwner }
        p.name = name; p.avatarSymbol = symbol; p.updatedAt = .now
        do { try ctx.save() } catch { ctx.rollback(); throw error }
    }
}

@MainActor @Observable
final class ProfileEntryModel {
    private(set) var owner: ShellPlayer?
    @ObservationIgnored private let store: any OwnerStore
    var ownerStore: any OwnerStore { store }
    init(store: any OwnerStore) { self.store = store; owner = store.owner }

    func create(name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SetupError.blankName }
        owner = try store.createOwner(name: trimmed, symbol: ShellPalette.symbols[0], colorName: ShellPalette.names[1])
    }
}

/// Profile summary for the owner until the Stats module provides a real `ProfileStatsSource`:
/// name and avatar from the row, no games yet (the profile screen's new-player state). Rename writes the row.
final class OwnerOnlyStats: ProfileStatsSource {
    private let current: Mutex<ShellPlayer>
    private let write: @MainActor @Sendable (UUID, String, String) throws -> Void

    init(owner: ShellPlayer, store: any OwnerStore) {
        current = Mutex(owner)
        nonisolated(unsafe) let store = store
        write = { id, name, symbol in try store.updateOwner(id, name: name, symbol: symbol) }
    }

    func profile(_ id: UUID) async throws -> ProfileSummary {
        let owner = current.withLock { $0 }
        return ProfileSummary(id: owner.id, name: owner.name, avatarSymbol: owner.symbol, avatarColor: owner.colorName,
                              games: 0, wins: 0, shots: 0, makes: 0)
    }
    func archetype(_ id: UUID) async throws -> ArchetypeView? { nil }
    func makeGrid(_ id: UUID) async throws -> [HeatCell] { [] }
    func badges(_ id: UUID) async throws -> [EarnedBadge] { [] }
    func proComp(_ id: UUID) async throws -> ProCompView? { nil }
    func history(_ id: UUID) async throws -> [SessionSummary] { [] }
    func updateProfile(_ id: UUID, name: String, avatarSymbol: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SetupError.blankName }
        guard current.withLock({ $0.id }) == id else { throw SetupError.notOwner }
        try await write(id, trimmed, avatarSymbol)
        current.withLock { $0.name = trimmed; $0.symbol = avatarSymbol }
    }
}

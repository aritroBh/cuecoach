import Foundation
import Observation
import SwiftData

/// The phone owner's profile (`PlayerProfile.isLocalOwner`).
@MainActor protocol OwnerStore: AnyObject {
    var owner: ShellPlayer? { get }
    func createOwner(name: String, symbol: String, colorName: String) throws -> ShellPlayer
}

@MainActor final class InMemoryOwnerStore: OwnerStore {
    private(set) var owner: ShellPlayer?
    init(owner: ShellPlayer?) { self.owner = owner }
    func createOwner(name: String, symbol: String, colorName: String) throws -> ShellPlayer {
        let p = ShellPlayer(id: UUID(), name: name, symbol: symbol, colorName: colorName)
        owner = p
        return p
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
}

@MainActor @Observable
final class ProfileEntryModel {
    private(set) var owner: ShellPlayer?
    @ObservationIgnored private let store: any OwnerStore
    init(store: any OwnerStore) { self.store = store; owner = store.owner }

    func create(name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SetupError.blankName }
        owner = try store.createOwner(name: trimmed, symbol: ShellPalette.symbols[0], colorName: ShellPalette.names[1])
    }
}

/// Profile summary for the owner until the Stats module provides a real `ProfileStatsSource`:
/// name and avatar from the row, no games yet (the profile screen's new-player state).
struct OwnerOnlyStats: ProfileStatsSource {
    var owner: ShellPlayer
    func profile(_ id: UUID) async throws -> ProfileSummary {
        ProfileSummary(id: owner.id, name: owner.name, avatarSymbol: owner.symbol, avatarColor: owner.colorName,
                       games: 0, wins: 0, shots: 0, makes: 0)
    }
    func archetype(_ id: UUID) async throws -> ArchetypeView? { nil }
    func makeGrid(_ id: UUID) async throws -> [HeatCell] { [] }
    func badges(_ id: UUID) async throws -> [EarnedBadge] { [] }
    func proComp(_ id: UUID) async throws -> ProCompView? { nil }
    func history(_ id: UUID) async throws -> [SessionSummary] { [] }
}

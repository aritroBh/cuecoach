import Foundation
import SwiftData
import Testing
@testable import CueCoach

@MainActor
@Suite struct RecognitionPrivacyTests {
    #if targetEnvironment(simulator)
    nonisolated static let dataProtection = false     // the simulator has no Data Protection; the attribute never reads back
    #else
    nonisolated static let dataProtection = true
    #endif

    @Test(.enabled(if: RecognitionPrivacyTests.dataProtection, "Data Protection exists only on a real device"))
    func storeDirectoryIsFileProtected() throws {
        // CX-5: templates on disk are protected by Data Protection, not just sandboxed.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("prot-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try PersistenceStack(directory: dir)
        let attrs = try FileManager.default.attributesOfItem(atPath: dir.path)
        #expect(attrs[.protectionKey] as? FileProtectionType == PersistenceStack.storeProtection)
    }

    @Test func deleteMyRecognitionDataRemovesOnlyEmbeddings() throws {
        let stack = try PersistenceStack(inMemory: true)
        let ctx = stack.competitiveContext
        _ = Fixture.populateCompetitive(ctx)
        try ctx.save()
        try stack.deleteMyRecognitionData()

        #expect(try Fixture.count(RecognitionData.self, ctx) == 0)
        let owner = try #require(ctx.fetch(FetchDescriptor<PlayerProfile>()).first)
        #expect(owner.recognition == nil)
        #expect(owner.name == "Ari")
        #expect(try Fixture.count(Session.self, ctx) == 1)
        #expect(try Fixture.count(Shot.self, ctx) == 2)
        #expect(try Fixture.count(ArchetypeSnapshot.self, ctx) == 1)
    }

    @Test func deleteMyRecognitionDataKeepsOtherProfilesEmbeddings() throws {
        let stack = try PersistenceStack(inMemory: true)
        let ctx = stack.competitiveContext
        _ = Fixture.populateCompetitive(ctx)
        let guest = PlayerProfile(id: Fixture.guestID, name: "Sam", avatarSymbol: "star", avatarColor: "red",
                                  isSessionGuest: true)
        guest.recognition = Fixture.recognition()
        ctx.insert(guest)
        try ctx.save()
        try stack.deleteMyRecognitionData()
        let remaining = try ctx.fetch(FetchDescriptor<RecognitionData>())
        #expect(remaining.count == 1)
        #expect(remaining.first?.profile?.id == Fixture.guestID)
    }

    @Test func deleteMyRecognitionDataIsSafeWhenNothingStored() throws {
        let stack = try PersistenceStack(inMemory: true)
        try stack.deleteMyRecognitionData()
        #expect(try Fixture.count(RecognitionData.self, stack.competitiveContext) == 0)
    }
}

@MainActor
@Suite struct SessionGuestTests {
    @Test func purgeSessionGuestsRemovesGuestsAndTheirEmbeddingsOnly() throws {
        let stack = try PersistenceStack(inMemory: true)
        let ctx = stack.competitiveContext
        _ = Fixture.populateCompetitive(ctx)
        let guest = PlayerProfile(id: Fixture.guestID, name: "Sam", avatarSymbol: "star", avatarColor: "red",
                                  isSessionGuest: true)
        guest.recognition = Fixture.recognition()
        ctx.insert(guest)
        try ctx.save()
        #expect(try Fixture.count(PlayerProfile.self, ctx) == 2)

        try stack.purgeSessionGuests()

        let left = try ctx.fetch(FetchDescriptor<PlayerProfile>())
        #expect(left.map(\.id) == [Fixture.ownerID])
        #expect(try Fixture.count(RecognitionData.self, ctx) == 1)   // owner's own stays
        #expect(try Fixture.count(Shot.self, ctx) == 2)              // guest's shots are game history
    }
}

@MainActor
@Suite struct StoreIsolationTests {
    @Test func containerSchemasShareNoTypes() throws {
        let stack = try PersistenceStack(inMemory: true)
        let comp = Set(stack.competitiveContainer.schema.entities.map(\.name))
        let train = Set(stack.trainingContainer.schema.entities.map(\.name))
        #expect(comp == ["PlayerProfile", "RecognitionData", "Session", "Game", "Shot", "ArchetypeSnapshot", "Highlight"])
        #expect(train == ["TrainingProfile", "DrillProgress", "TrainingAttempt", "BiasRecord"])
        #expect(comp.isDisjoint(with: train))
    }

    @Test func noRelationshipCrossesStores() throws {
        let stack = try PersistenceStack(inMemory: true)
        for (schema, own) in [(stack.competitiveContainer.schema, stack.competitiveContainer.schema),
                              (stack.trainingContainer.schema, stack.trainingContainer.schema)] {
            let names = Set(own.entities.map(\.name))
            for e in schema.entities {
                for r in e.relationships { #expect(names.contains(r.destination), "\(e.name).\(r.name)") }
            }
        }
    }

    @Test func writingTrainingDataLeavesCompetitiveCountsUnchanged() throws {
        let stack = try PersistenceStack(inMemory: true)
        _ = Fixture.populateCompetitive(stack.competitiveContext)
        try stack.competitiveContext.save()
        let before = try competitiveCounts(stack)
        _ = Fixture.populateTraining(stack.trainingContext)
        try stack.trainingContext.save()
        #expect(try competitiveCounts(stack) == before)
        #expect(try Fixture.count(TrainingAttempt.self, stack.trainingContext) == 3)
    }

    @Test func writingCompetitiveDataLeavesTrainingCountsUnchanged() throws {
        let stack = try PersistenceStack(inMemory: true)
        _ = Fixture.populateTraining(stack.trainingContext)
        try stack.trainingContext.save()
        let before = try trainingCounts(stack)
        _ = Fixture.populateCompetitive(stack.competitiveContext)
        try stack.competitiveContext.save()
        #expect(try trainingCounts(stack) == before)
    }

    @Test func eachSchemaLacksTheOtherStoresModels() throws {
        let stack = try PersistenceStack(inMemory: true)
        for t in PersistenceStack.trainingModels {
            #expect(stack.competitiveContainer.schema.entity(for: t) == nil)
        }
        for t in PersistenceStack.competitiveModels {
            #expect(stack.trainingContainer.schema.entity(for: t) == nil)
        }
    }

    private func competitiveCounts(_ s: PersistenceStack) throws -> [Int] {
        let c = s.competitiveContext
        return [try Fixture.count(PlayerProfile.self, c), try Fixture.count(RecognitionData.self, c),
                try Fixture.count(Session.self, c), try Fixture.count(Game.self, c),
                try Fixture.count(Shot.self, c), try Fixture.count(ArchetypeSnapshot.self, c),
                try Fixture.count(Highlight.self, c)]
    }

    private func trainingCounts(_ s: PersistenceStack) throws -> [Int] {
        let c = s.trainingContext
        return [try Fixture.count(TrainingProfile.self, c), try Fixture.count(DrillProgress.self, c),
                try Fixture.count(TrainingAttempt.self, c), try Fixture.count(BiasRecord.self, c)]
    }
}

import Foundation
import SwiftData
import Testing
@testable import CueCoach

@MainActor
@Suite struct RecognitionPrivacyTests {
    @Test func deleteMyRecognitionDataRemovesOnlyEmbeddings() throws {
        let stack = try PersistenceStack(inMemory: true)
        let ctx = stack.competitiveContext
        _ = Fixture.populateCompetitive(ctx)
        try ctx.save()
        try Fixture.addOwnerRecognition(stack)
        try stack.deleteMyRecognitionData()

        #expect(try Fixture.count(RecognitionData.self, stack.recognitionContext) == 0)
        #expect(try stack.recognition(for: Fixture.ownerID) == nil)
        let owner = try #require(ctx.fetch(FetchDescriptor<PlayerProfile>()).first)
        #expect(owner.name == "Ari")
        #expect(try Fixture.count(Session.self, ctx) == 1)
        #expect(try Fixture.count(Shot.self, ctx) == 2)
        #expect(try Fixture.count(ArchetypeSnapshot.self, ctx) == 1)
    }

    /// The one tap clears the whole store: cached peer templates go too (they come back over the mesh if the
    /// peer still consents).
    @Test func deleteMyRecognitionDataClearsEveryProfilesTemplates() throws {
        let stack = try PersistenceStack(inMemory: true)
        let ctx = stack.competitiveContext
        _ = Fixture.populateCompetitive(ctx)
        ctx.insert(PlayerProfile(id: Fixture.guestID, name: "Sam", avatarSymbol: "star", avatarColor: "red",
                                 isSessionGuest: true))
        try ctx.save()
        try Fixture.addOwnerRecognition(stack)
        try stack.storeRecognition(profileID: Fixture.guestID, faceEmbedding: Data([5]), appearanceEmbedding: nil,
                                   optedInAt: Fixture.t0, version: 1)
        try stack.deleteMyRecognitionData()
        #expect(try Fixture.count(RecognitionData.self, stack.recognitionContext) == 0)
    }

    @Test func deleteMyRecognitionDataIsSafeWhenNothingStored() throws {
        let stack = try PersistenceStack(inMemory: true)
        try stack.deleteMyRecognitionData()
        #expect(try Fixture.count(RecognitionData.self, stack.recognitionContext) == 0)
    }
}

@MainActor
@Suite struct SessionGuestTests {
    @Test func purgeSessionGuestsRemovesGuestsAndTheirEmbeddingsOnly() throws {
        let stack = try PersistenceStack(inMemory: true)
        let ctx = stack.competitiveContext
        _ = Fixture.populateCompetitive(ctx)
        ctx.insert(PlayerProfile(id: Fixture.guestID, name: "Sam", avatarSymbol: "star", avatarColor: "red",
                                 isSessionGuest: true))
        try ctx.save()
        try Fixture.addOwnerRecognition(stack)
        try stack.storeRecognition(profileID: Fixture.guestID, faceEmbedding: Data([5]), appearanceEmbedding: nil,
                                   optedInAt: Fixture.t0, version: 1)
        #expect(try Fixture.count(PlayerProfile.self, ctx) == 2)

        try stack.purgeSessionGuests()

        let left = try ctx.fetch(FetchDescriptor<PlayerProfile>())
        #expect(left.map(\.id) == [Fixture.ownerID])
        #expect(try stack.recognitionContext.fetch(FetchDescriptor<RecognitionData>()).map(\.profileID) == [Fixture.ownerID])
        #expect(try Fixture.count(Shot.self, ctx) == 2)              // guest's shots are game history
    }
}

@MainActor
@Suite struct StoreIsolationTests {
    @Test func containerSchemasShareNoTypes() throws {
        let stack = try PersistenceStack(inMemory: true)
        let comp = Set(stack.competitiveContainer.schema.entities.map(\.name))
        let train = Set(stack.trainingContainer.schema.entities.map(\.name))
        let rec = Set(stack.recognitionContainer.schema.entities.map(\.name))
        #expect(comp == ["PlayerProfile", "Session", "Game", "Shot", "ArchetypeSnapshot", "Highlight"])
        #expect(train == ["TrainingProfile", "DrillProgress", "TrainingAttempt", "BiasRecord"])
        #expect(rec == ["RecognitionData"])
        #expect(comp.isDisjoint(with: train) && comp.isDisjoint(with: rec) && train.isDisjoint(with: rec))
    }

    @Test func noRelationshipCrossesStores() throws {
        let stack = try PersistenceStack(inMemory: true)
        for (schema, own) in [(stack.competitiveContainer.schema, stack.competitiveContainer.schema),
                              (stack.trainingContainer.schema, stack.trainingContainer.schema),
                              (stack.recognitionContainer.schema, stack.recognitionContainer.schema)] {
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
        return [try Fixture.count(PlayerProfile.self, c), try Fixture.count(RecognitionData.self, s.recognitionContext),
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

import Foundation
import SwiftData

// Versioned schemas per store so model changes get an explicit migration plan.
// Unchanged models are shared between versions; a model whose shape changes gets a frozen copy in the old
// version (see CompetitiveSchemaV1.PlayerProfile).

/// V1: first shipped shape. RecognitionData lived here (and so in every iCloud/Finder device backup).
enum CompetitiveSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    static var models: [any PersistentModel.Type] {
        [PlayerProfile.self, RecognitionData.self, Session.self, Game.self, Shot.self,
         ArchetypeSnapshot.self, Highlight.self]
    }

    /// Frozen V1 shape. Only the migration reads it.
    @Model
    final class PlayerProfile {
        @Attribute(.unique) var id: UUID
        var nameValue: String
        var avatarSymbolValue: String
        var avatarColorValue: String
        var isLocalOwner: Bool
        var isSessionGuest: Bool
        var createdAtValue: Date
        var updatedAt: Date
        var skillModelData: Data
        @Relationship(deleteRule: .cascade, inverse: \RecognitionData.profileLink)
        var recognitionLink: RecognitionData?

        init(id: UUID, name: String, avatarSymbol: String = "person", avatarColor: String = "teal",
             isLocalOwner: Bool, isSessionGuest: Bool, createdAt: Date) {
            self.id = id
            nameValue = name
            avatarSymbolValue = avatarSymbol
            avatarColorValue = avatarColor
            self.isLocalOwner = isLocalOwner
            self.isSessionGuest = isSessionGuest
            createdAtValue = createdAt
            updatedAt = createdAt
            skillModelData = Blob.encode(StoredSkillModel.prior)
        }
    }

    /// Frozen V1 shape. Only the migration reads it.
    @Model
    final class RecognitionData {
        @Attribute(.unique) var id: UUID
        @Attribute(.externalStorage) var faceEmbeddingValue: Data?
        @Attribute(.externalStorage) var appearanceEmbeddingValue: Data?
        var optedInAtValue: Date
        var versionValue: Int
        var updatedAt: Date
        var profileLink: PlayerProfile?

        init(id: UUID = UUID(), faceEmbedding: Data?, appearanceEmbedding: Data?, optedInAt: Date, version: Int) {
            self.id = id
            faceEmbeddingValue = faceEmbedding
            appearanceEmbeddingValue = appearanceEmbedding
            optedInAtValue = optedInAt
            versionValue = version
            updatedAt = optedInAt
        }
    }
}

/// V2: RecognitionData moved to its own backup-excluded store (`RecognitionSchemaV1`);
/// PlayerProfile gained `recognitionRevokedAt` and lost the relationship.
enum CompetitiveSchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }
    static var models: [any PersistentModel.Type] {
        [PlayerProfile.self, Session.self, Game.self, Shot.self, ArchetypeSnapshot.self, Highlight.self]
    }
}

enum TrainingSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    static var models: [any PersistentModel.Type] {
        [TrainingProfile.self, DrillProgress.self, TrainingAttempt.self, BiasRecord.self]
    }
}

enum RecognitionSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    static var models: [any PersistentModel.Type] { [RecognitionData.self] }
}

enum CompetitiveMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [CompetitiveSchemaV1.self, CompetitiveSchemaV2.self] }
    static var stages: [MigrationStage] { [v1ToV2] }

    /// Copies every V1 RecognitionData row into Recognition.store (next to Competitive.store), then deletes the
    /// rows here so the entity can be dropped. If the copy fails the migration throws and V1 stays intact.
    /// Freed pages are scrubbed afterwards by `PersistenceStack` (see `RecognitionMigration`).
    static var v1ToV2: MigrationStage {
        MigrationStage.custom(
        fromVersion: CompetitiveSchemaV1.self, toVersion: CompetitiveSchemaV2.self,
        willMigrate: { ctx in
            guard let storeURL = ctx.container.configurations.first?.url else {
                throw RecognitionMigration.Failure.noStoreURL
            }
            let rows = try ctx.fetch(FetchDescriptor<CompetitiveSchemaV1.RecognitionData>())
            let records = rows.compactMap { r in
                r.profileLink.map {
                    RecognitionRecord(id: r.id, profileID: $0.id, faceEmbedding: r.faceEmbeddingValue,
                                      appearanceEmbedding: r.appearanceEmbeddingValue, optedInAt: r.optedInAtValue,
                                      version: r.versionValue, updatedAt: r.updatedAt)
                }
            }
            let dir = storeURL.deletingLastPathComponent()
            try RecognitionStoreFiles.write(records, in: dir)
            for r in rows { ctx.delete(r) }
            try ctx.save()
            RecognitionMigration.markMigrated(storeURL)
        },
        didMigrate: nil)
    }
}

enum TrainingMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [TrainingSchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}

enum RecognitionMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [RecognitionSchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}

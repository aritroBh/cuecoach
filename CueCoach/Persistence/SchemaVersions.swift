import Foundation
import SwiftData

// Versioned schemas per store so future model changes get an explicit migration plan.
// V1 is the first shipped shape; add V2 + a MigrationStage here when a model changes.

enum CompetitiveSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    static var models: [any PersistentModel.Type] {
        [PlayerProfile.self, RecognitionData.self, Session.self, Game.self, Shot.self,
         ArchetypeSnapshot.self, Highlight.self]
    }
}

enum TrainingSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    static var models: [any PersistentModel.Type] {
        [TrainingProfile.self, DrillProgress.self, TrainingAttempt.self, BiasRecord.self]
    }
}

enum CompetitiveMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [CompetitiveSchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}

enum TrainingMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [TrainingSchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}

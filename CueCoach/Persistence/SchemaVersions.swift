import Foundation
import SwiftData
import Geometry
import Rules
import Engine

// Versioned schemas per store so model changes get an explicit migration plan.
// Unchanged models are shared between versions; a model whose shape changes gets a frozen copy in the old
// version (see CompetitiveSchemaV1.PlayerProfile).

/// V1: first shipped shape. RecognitionData lived here (and so in every iCloud/Finder device backup).
enum CompetitiveSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    static var models: [any PersistentModel.Type] {
        [PlayerProfile.self, RecognitionData.self, CompetitiveSchemaV2.Session.self, CompetitiveSchemaV2.Game.self,
         CompetitiveSchemaV2.Shot.self, ArchetypeSnapshot.self, CompetitiveSchemaV2.Highlight.self]
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

    // Frozen V1/V2 shapes of the Session → Game → Shot/Highlight graph. The whole component is frozen because a
    // relationship to a live type pulls the live (V3) Shot into this schema. Stored properties and relationships only;
    // names and types must stay exactly as shipped (entity hashes guarded by `ShotIsGuessMigrationTests`).

    @Model
    final class Session {
        @Attribute(.unique) var id: UUID
        var startedAtValue: Date
        var endedAtValue: Date?
        var ruleSetRaw: String
        var formatRaw: String
        var tableSizeRaw: String
        var peerDeviceNamesValue: [String]
        var voteTallyData: Data
        var updatedAt: Date
        @Relationship(deleteRule: .cascade, inverse: \Game.sessionLink)
        var gamesLink: [Game] = []

        init(id: UUID = UUID(), startedAt: Date, ruleSet: RuleSetID, format: GameFormat, tableSize: TableSize) {
            self.id = id
            startedAtValue = startedAt
            ruleSetRaw = ruleSet.rawValue
            formatRaw = format.rawValue
            tableSizeRaw = tableSize.rawValue
            peerDeviceNamesValue = []
            voteTallyData = Blob.encode([RuleSetID: Int]())
            updatedAt = startedAt
        }
    }

    @Model
    final class Game {
        @Attribute(.unique) var id: UUID
        var sessionLink: Session?
        var indexValue: Int
        var ruleSetRaw: String
        var teamsData: Data
        var winnerTeamValue: Int?
        var winProbSeriesValue: [Double]
        var startedAtValue: Date
        var endedAtValue: Date?
        var updatedAt: Date
        @Relationship(deleteRule: .cascade, inverse: \Shot.gameLink)
        var shotsLink: [Shot] = []
        @Relationship(deleteRule: .cascade, inverse: \Highlight.gameLink)
        var highlightsLink: [Highlight] = []

        init(id: UUID = UUID(), index: Int, ruleSet: RuleSetID, teams: [StoredTeam], winnerTeam: Int?,
             startedAt: Date, endedAt: Date?) {
            self.id = id
            indexValue = index
            ruleSetRaw = ruleSet.rawValue
            teamsData = Blob.encode(teams)
            winnerTeamValue = winnerTeam
            winProbSeriesValue = []
            startedAtValue = startedAt
            endedAtValue = endedAt
            updatedAt = endedAt ?? startedAt
        }
    }

    @Model
    final class Highlight {
        @Attribute(.unique) var id: UUID
        var gameLink: Game?
        var shotIDValue: UUID
        var kindRaw: String
        var clipFileValue: String
        var labelValue: String
        var scoreValue: Double
        var updatedAt: Date

        init(id: UUID = UUID(), shotID: UUID, kind: HighlightKind, clipFile: String, label: String, score: Double,
             updatedAt: Date) {
            self.id = id
            shotIDValue = shotID
            kindRaw = kind.rawValue
            clipFileValue = clipFile
            labelValue = label
            scoreValue = score
            self.updatedAt = updatedAt
        }
    }

    @Model
    final class Shot {
        @Attribute(.unique) var id: UUID
        var gameLink: Game?
        var indexValue: Int
        var shooterIDValue: UUID
        var attributionSourceRaw: String
        var preStateData: Data
        var postStateData: Data
        var calledPocketRaw: String?
        var firstContactNumber: Int?
        var railsAfterContactValue: Int
        var pocketedData: Data
        var foulsData: Data
        var featuresData: Data
        var madeValue: Bool
        var onTargetValue: Bool
        var cueResultRaw: String
        var decisionRatingRaw: String
        var executionRatingData: Data
        var wpaDeltaValue: Double
        var isClutchValue: Bool
        var timeOnShotValue: Double
        var clipRefValue: String?
        var updatedAt: Date

        init(id: UUID = UUID(), index: Int, shooterID: UUID, attributionSource: AttributionSource,
             preState: TableState, postState: TableState, calledPocket: Pocket?, firstContact: BallID?,
             railsAfterContact: Int, pocketed: [BallID: Pocket], fouls: [Foul], features: StoredShotFeatures,
             made: Bool, onTarget: Bool, cueResult: CueResult, decisionRating: DecisionRating,
             executionRating: ExecutionRating, wpaDelta: Double, isClutch: Bool, timeOnShot: Double,
             clipRef: String?, updatedAt: Date = .now) {
            self.id = id
            indexValue = index
            shooterIDValue = shooterID
            attributionSourceRaw = attributionSource.rawValue
            preStateData = Blob.encode(preState)
            postStateData = Blob.encode(postState)
            calledPocketRaw = calledPocket?.rawValue
            firstContactNumber = firstContact?.number
            railsAfterContactValue = railsAfterContact
            pocketedData = Blob.encode(pocketed)
            foulsData = Blob.encode(fouls)
            featuresData = Blob.encode(features)
            madeValue = made
            onTargetValue = onTarget
            cueResultRaw = cueResult.rawValue
            decisionRatingRaw = decisionRating.rawValue
            executionRatingData = Blob.encode(executionRating)
            wpaDeltaValue = wpaDelta
            isClutchValue = isClutch
            timeOnShotValue = timeOnShot
            clipRefValue = clipRef
            self.updatedAt = updatedAt
        }
    }
}

/// V3 (D43, plan 012): `Shot` gained `isGuess` (default false), so V2 → V3 is a lightweight stage.
enum CompetitiveSchemaV3: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(3, 0, 0) }
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
    static var schemas: [any VersionedSchema.Type] {
        [CompetitiveSchemaV1.self, CompetitiveSchemaV2.self, CompetitiveSchemaV3.self]
    }
    static var stages: [MigrationStage] { [v1ToV2, v2ToV3] }

    /// D43: adds `Shot.isGuess`; every existing row reads as not a guess.
    static var v2ToV3: MigrationStage {
        MigrationStage.lightweight(fromVersion: CompetitiveSchemaV2.self, toVersion: CompetitiveSchemaV3.self)
    }

    /// Copies every V1 RecognitionData row into Recognition.store (next to Competitive.store), then deletes the
    /// rows here so the entity can be dropped. If the copy fails the migration throws and V1 stays intact.
    /// Freed pages are scrubbed afterwards by `PersistenceStack`; a marker file keeps that retryable across crashes.
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
            // Durable before the delete: a crash anywhere after this point still gets scrubbed on the next open.
            try RecognitionMigration.markScrubPending(in: dir)
            for r in rows { ctx.delete(r) }
            try ctx.save()
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

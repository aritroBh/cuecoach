import Foundation
import SwiftData

/// Owns the two SwiftData containers. Competitive and training data live in separate store files
/// and separate schemas, so training rows can never be counted as competitive stats.
/// Local-only: no CloudKit (free Personal Team).
@MainActor
final class PersistenceStack {
    static let competitiveModels: [any PersistentModel.Type] = CompetitiveSchemaV1.models
    static let trainingModels: [any PersistentModel.Type] = TrainingSchemaV1.models

    enum StoreKind: Sendable { case competitive, training, trainingCompensation }

    /// Test seam: called right before each store is saved during an import; throwing simulates a save failure.
    var beforeSave: ((StoreKind) throws -> Void)?

    let competitiveContainer: ModelContainer
    let trainingContainer: ModelContainer
    var competitiveContext: ModelContext { competitiveContainer.mainContext }
    var trainingContext: ModelContext { trainingContainer.mainContext }

    /// - Parameters:
    ///   - inMemory: tests only; nothing touches disk.
    ///   - directory: where `Competitive.store` / `Training.store` live (default: Application Support).
    init(inMemory: Bool = false, directory: URL? = nil) throws {
        let dir = directory ?? URL.applicationSupportDirectory
        if !inMemory {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Self.protect(dir)
        }
        competitiveContainer = try Self.container(name: "Competitive", schema: CompetitiveSchemaV1.self,
                                                  plan: CompetitiveMigrationPlan.self, dir: dir, inMemory: inMemory)
        trainingContainer = try Self.container(name: "Training", schema: TrainingSchemaV1.self,
                                               plan: TrainingMigrationPlan.self, dir: dir, inMemory: inMemory)
    }

    /// Recognition templates live in `Competitive.store` (and its external-storage blobs): new files in the store
    /// directory are encrypted while the phone is locked, except a store SQLite already holds open (CX-5).
    static let storeProtection = FileProtectionType.completeUnlessOpen

    static func protect(_ dir: URL) throws {
        try FileManager.default.setAttributes([.protectionKey: storeProtection], ofItemAtPath: dir.path)
    }

    private static func container(name: String, schema versioned: any VersionedSchema.Type,
                                  plan: any SchemaMigrationPlan.Type, dir: URL,
                                  inMemory: Bool) throws -> ModelContainer {
        let schema = Schema(versionedSchema: versioned)
        let config = inMemory
            ? ModelConfiguration(name, schema: schema, isStoredInMemoryOnly: true, allowsSave: true,
                                 groupContainer: .none, cloudKitDatabase: .none)
            : ModelConfiguration(name, schema: schema, url: dir.appendingPathComponent("\(name).store"),
                                 allowsSave: true, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, migrationPlan: plan, configurations: [config])
    }
}

import Foundation
import SwiftData
import Geometry
import Rules

extension PersistenceStack {
    // MARK: Export

    /// Serialises both stores to `BackupV1` JSON. Recognition embeddings are left out unless
    /// `includeRecognition` is set. Session guests are never exported. Rows are sorted by id.
    func exportBackup(includeRecognition: Bool = false, exportedAt: Date = .now) throws -> Data {
        try BackupV1(exportedAt: exportedAt, includesRecognition: includeRecognition,
                     competitive: competitiveSection(includeRecognition: includeRecognition),
                     training: trainingSection()).encoded()
    }

    private func all<M: PersistentModel>(_: M.Type, _ ctx: ModelContext) throws -> [M] {
        try ctx.fetch(FetchDescriptor<M>())
    }
    private func sorted<D>(_ xs: [D], _ id: (D) -> UUID) -> [D] { xs.sorted { id($0).uuidString < id($1).uuidString } }

    private func competitiveSection(includeRecognition: Bool) throws -> BackupV1.Competitive {
        let c = competitiveContext
        var comp = BackupV1.Competitive()
        comp.profiles = sorted(try all(PlayerProfile.self, c).filter { !$0.isSessionGuest }.map {
            .init(id: $0.id, name: $0.name, avatarSymbol: $0.avatarSymbol, avatarColor: $0.avatarColor,
                  isLocalOwner: $0.isLocalOwner, createdAt: $0.createdAt, updatedAt: $0.updatedAt,
                  skillModel: $0.skillModel,
                  recognition: includeRecognition ? $0.recognition.map {
                      .init(id: $0.id, faceEmbedding: $0.faceEmbedding, appearanceEmbedding: $0.appearanceEmbedding,
                            optedInAt: $0.optedInAt, version: $0.version, updatedAt: $0.updatedAt)
                  } : nil)
        }, \.id)
        comp.sessions = sorted(try all(Session.self, c).map {
            .init(id: $0.id, startedAt: $0.startedAt, endedAt: $0.endedAt, ruleSet: $0.ruleSet, format: $0.format,
                  tableSize: $0.tableSize, peerDeviceNames: $0.peerDeviceNames,
                  voteTally: Dictionary(uniqueKeysWithValues: $0.voteTally.map { ($0.key.rawValue, $0.value) }),
                  updatedAt: $0.updatedAt)
        }, \.id)
        comp.games = sorted(try all(Game.self, c).map {
            .init(id: $0.id, sessionID: $0.session?.id, index: $0.index, ruleSet: $0.ruleSet, teams: $0.teams,
                  winnerTeam: $0.winnerTeam, winProbSeries: $0.winProbSeries, startedAt: $0.startedAt,
                  endedAt: $0.endedAt, updatedAt: $0.updatedAt)
        }, \.id)
        comp.shots = sorted(try all(Shot.self, c).map {
            .init(id: $0.id, gameID: $0.game?.id, index: $0.index, shooterID: $0.shooterID,
                  attributionSource: $0.attributionSource, preState: $0.preState, postState: $0.postState,
                  calledPocket: $0.calledPocket, firstContact: $0.firstContact,
                  railsAfterContact: $0.railsAfterContact,
                  pocketed: Dictionary(uniqueKeysWithValues: $0.pocketed.map { (String($0.key.number), $0.value) }),
                  fouls: $0.fouls, features: $0.features, made: $0.made, onTarget: $0.onTarget,
                  cueResult: $0.cueResult, decisionRating: $0.decisionRating, executionRating: $0.executionRating,
                  wpaDelta: $0.wpaDelta, isClutch: $0.isClutch, timeOnShot: $0.timeOnShot, clipRef: $0.clipRef,
                  updatedAt: $0.updatedAt)
        }, \.id)
        comp.archetypes = sorted(try all(ArchetypeSnapshot.self, c).map {
            .init(id: $0.id, playerID: $0.playerID, computedAt: $0.computedAt, gamesCount: $0.gamesCount,
                  shotsCount: $0.shotsCount, vector: $0.vector, tags: $0.tags, proComp: $0.proComp,
                  updatedAt: $0.updatedAt)
        }, \.id)
        comp.highlights = sorted(try all(Highlight.self, c).map {
            .init(id: $0.id, gameID: $0.game?.id, shotID: $0.shotID, kind: $0.kind, clipFile: $0.clipFile,
                  label: $0.label, score: $0.score, updatedAt: $0.updatedAt)
        }, \.id)
        return comp
    }

    private func trainingSection() throws -> BackupV1.Training {
        let t = trainingContext
        var train = BackupV1.Training()
        train.profiles = sorted(try all(TrainingProfile.self, t).map {
            .init(id: $0.id, playerID: $0.playerID, createdAt: $0.createdAt, updatedAt: $0.updatedAt)
        }, \.id)
        train.drillProgress = sorted(try all(DrillProgress.self, t).map {
            .init(id: $0.id, playerID: $0.playerID, drill: $0.drill, level: $0.level,
                  recentResults: $0.recentResults, levelHistory: $0.levelHistory, updatedAt: $0.updatedAt)
        }, \.id)
        train.attempts = sorted(try all(TrainingAttempt.self, t).map {
            .init(id: $0.id, progressID: $0.progress?.id, at: $0.at, setup: $0.setup, result: $0.result,
                  made: $0.made, features: $0.features, updatedAt: $0.updatedAt)
        }, \.id)
        train.biases = sorted(try all(BiasRecord.self, t).map {
            .init(id: $0.id, playerID: $0.playerID, drill: $0.drill, axis: $0.axis, sign: $0.sign,
                  attemptsWindow: $0.attemptsWindow, detectedAt: $0.detectedAt, resolvedAt: $0.resolvedAt,
                  updatedAt: $0.updatedAt)
        }, \.id)
        return train
    }

    // MARK: Import

    /// Merges a backup into both stores by UUID: unknown rows are inserted, known rows are overwritten
    /// only when the backup's `updatedAt` is strictly newer. Re-importing the same file is a no-op.
    /// Never deletes local rows (a backup without recognition data keeps local embeddings).
    ///
    /// All-or-nothing across both stores:
    /// 1. version + parent references are validated before anything is touched (`BackupError`);
    /// 2. training is saved first; if that fails, both contexts roll back;
    /// 3. if the competitive save then fails, the training store is restored from a pre-import snapshot.
    ///
    /// Device-local fields are never taken from a backup: `isLocalOwner` of existing profiles is kept;
    /// a new profile becomes the local owner only if this phone has none yet (fresh-phone restore).
    /// Recognition rows are read only when the manifest's `includesRecognition` is true.
    func importBackup(_ data: Data) throws {
        let backup = try BackupV1.decode(data)
        try validateParents(backup)
        let c = competitiveContext, t = trainingContext
        let trainingSnapshot = try trainingSection()
        do {
            try mergeCompetitive(backup.competitive, includeRecognition: backup.includesRecognition, into: c)
            try mergeTraining(backup.training, into: t)
            try beforeSave?(.training)
            try t.save()
        } catch {
            c.rollback()
            t.rollback()
            throw error
        }
        do {
            try beforeSave?(.competitive)
            try c.save()
        } catch {
            c.rollback()
            try compensateTraining(before: trainingSnapshot, imported: backup.training)
            throw error
        }
    }

    /// Rejects the backup if any child points at a parent that is neither in the backup nor on this device.
    private func validateParents(_ b: BackupV1) throws {
        let sessions = Set(b.competitive.sessions.map(\.id)).union(try all(Session.self, competitiveContext).map(\.id))
        let games = Set(b.competitive.games.map(\.id)).union(try all(Game.self, competitiveContext).map(\.id))
        let progress = Set(b.training.drillProgress.map(\.id))
            .union(try all(DrillProgress.self, trainingContext).map(\.id))
        func check(_ child: String, _ id: UUID, _ parent: UUID?, in known: Set<UUID>) throws {
            if let parent, !known.contains(parent) {
                throw BackupError.missingParent(child: child, childID: id, parentID: parent)
            }
        }
        for g in b.competitive.games { try check("Game", g.id, g.sessionID, in: sessions) }
        for s in b.competitive.shots { try check("Shot", s.id, s.gameID, in: games) }
        for h in b.competitive.highlights { try check("Highlight", h.id, h.gameID, in: games) }
        for a in b.training.attempts { try check("TrainingAttempt", a.id, a.progressID, in: progress) }
    }

    /// Compensation after a failed competitive save, non-destructive and in one save:
    /// rows the import updated get their pre-import values back (`before` holds them), and only the rows
    /// the import inserted (ids absent from `before`) are deleted. Pre-existing rows are never deleted;
    /// if this save fails too, the training store keeps the imported state (nothing lost).
    private func compensateTraining(before: BackupV1.Training, imported: BackupV1.Training) throws {
        let t = trainingContext
        let importedIDs = Set(imported.profiles.map(\.id)).union(imported.drillProgress.map(\.id))
            .union(imported.attempts.map(\.id)).union(imported.biases.map(\.id))
        let beforeIDs = Set(before.profiles.map(\.id)).union(before.drillProgress.map(\.id))
            .union(before.attempts.map(\.id)).union(before.biases.map(\.id))
        let inserted = importedIDs.subtracting(beforeIDs)
        var old = before
        old.profiles.removeAll { !importedIDs.contains($0.id) }
        old.drillProgress.removeAll { !importedIDs.contains($0.id) }
        old.attempts.removeAll { !importedIDs.contains($0.id) }
        old.biases.removeAll { !importedIDs.contains($0.id) }
        do {
            // Restore first (re-parents attempts back), then delete inserted rows so cascades can't reach old rows.
            try mergeTraining(old, into: t, force: true)
            for m in try all(TrainingAttempt.self, t) where inserted.contains(m.id) { t.delete(m) }
            for m in try all(BiasRecord.self, t) where inserted.contains(m.id) { t.delete(m) }
            for m in try all(DrillProgress.self, t) where inserted.contains(m.id) { t.delete(m) }
            for m in try all(TrainingProfile.self, t) where inserted.contains(m.id) { t.delete(m) }
            try beforeSave?(.trainingCompensation)
            try t.save()
        } catch {
            t.rollback()
            throw error
        }
    }

    private func mergeCompetitive(_ b: BackupV1.Competitive, includeRecognition: Bool,
                                  into ctx: ModelContext) throws {
        var hasOwner = try ctx.fetchCount(FetchDescriptor<PlayerProfile>(predicate: #Predicate { $0.isLocalOwner })) > 0

        let profiles = try upsert(b.profiles, ctx, id: \PlayerProfile.id, dtoID: \BackupV1.Profile.id,
            newer: { isNewer($0.updatedAt, than: $1.updatedAt) },
            make: { (d: BackupV1.Profile) -> PlayerProfile in
                // isLocalOwner is device-local: only a fresh phone (no owner yet) adopts the backup's owner.
                let owner = d.isLocalOwner && !hasOwner
                if owner { hasOwner = true }
                return PlayerProfile(id: d.id, name: d.name, avatarSymbol: d.avatarSymbol, avatarColor: d.avatarColor,
                                     isLocalOwner: owner, createdAt: d.createdAt)
            },
            apply: { d, m in
                m.name = d.name; m.avatarSymbol = d.avatarSymbol; m.avatarColor = d.avatarColor
                m.createdAt = d.createdAt; m.skillModel = d.skillModel
                m.updatedAt = d.updatedAt
            })
        for d in b.profiles where includeRecognition {
            guard let r = d.recognition, let profile = profiles[d.id] else { continue }
            let profileStamp = profile.updatedAt
            defer { profile.updatedAt = profileStamp }   // linking embeddings isn't a profile edit
            if let existing = profile.recognition {
                guard isNewer(r.updatedAt, than: existing.updatedAt) else { continue }
                if existing.id != r.id { profile.recognition = nil; ctx.delete(existing) }
            }
            let row = profile.recognition ?? {
                let n = RecognitionData(id: r.id, faceEmbedding: nil, appearanceEmbedding: nil,
                                        optedInAt: r.optedInAt, version: r.version)
                ctx.insert(n)
                profile.recognition = n
                return n
            }()
            row.faceEmbedding = r.faceEmbedding; row.appearanceEmbedding = r.appearanceEmbedding
            row.optedInAt = r.optedInAt; row.version = r.version; row.updatedAt = r.updatedAt
        }

        let sessions = try upsert(b.sessions, ctx, id: \.id, dtoID: \.id, newer: { isNewer($0.updatedAt, than: $1.updatedAt) },
            make: { Session(id: $0.id, startedAt: $0.startedAt, ruleSet: $0.ruleSet, format: $0.format,
                            tableSize: $0.tableSize) },
            apply: { d, m in
                m.startedAt = d.startedAt; m.endedAt = d.endedAt; m.ruleSet = d.ruleSet; m.format = d.format
                m.tableSize = d.tableSize; m.peerDeviceNames = d.peerDeviceNames
                m.voteTally = Dictionary(uniqueKeysWithValues: d.voteTally.compactMap { k, v in
                    RuleSetID(rawValue: k).map { ($0, v) } })
                m.updatedAt = d.updatedAt
            })

        let games = try upsert(b.games, ctx, id: \.id, dtoID: \.id, newer: { isNewer($0.updatedAt, than: $1.updatedAt) },
            make: { Game(id: $0.id, index: $0.index, ruleSet: $0.ruleSet, teams: $0.teams, startedAt: $0.startedAt) },
            apply: { d, m in
                m.session = d.sessionID.flatMap { sessions[$0] }
                m.index = d.index; m.ruleSet = d.ruleSet; m.teams = d.teams; m.winnerTeam = d.winnerTeam
                m.winProbSeries = d.winProbSeries; m.startedAt = d.startedAt; m.endedAt = d.endedAt
                m.updatedAt = d.updatedAt
            })

        _ = try upsert(b.shots, ctx, id: \.id, dtoID: \.id, newer: { isNewer($0.updatedAt, than: $1.updatedAt) },
            make: { d in
                Shot(id: d.id, index: d.index, shooterID: d.shooterID, attributionSource: d.attributionSource,
                     preState: d.preState, postState: d.postState, calledPocket: d.calledPocket,
                     firstContact: d.firstContact, railsAfterContact: d.railsAfterContact, pocketed: [:],
                     fouls: d.fouls, features: d.features, made: d.made, onTarget: d.onTarget,
                     cueResult: d.cueResult, decisionRating: d.decisionRating, executionRating: d.executionRating,
                     wpaDelta: d.wpaDelta, isClutch: d.isClutch, timeOnShot: d.timeOnShot, clipRef: d.clipRef,
                     updatedAt: d.updatedAt)
            },
            apply: { d, m in
                m.game = d.gameID.flatMap { games[$0] }
                m.index = d.index; m.shooterID = d.shooterID; m.attributionSource = d.attributionSource
                m.preState = d.preState; m.postState = d.postState; m.calledPocket = d.calledPocket
                m.firstContact = d.firstContact; m.railsAfterContact = d.railsAfterContact
                m.pocketed = Dictionary(uniqueKeysWithValues: d.pocketed.compactMap { k, v in
                    Int(k).flatMap(BallID.init).map { ($0, v) } })
                m.fouls = d.fouls; m.features = d.features; m.made = d.made; m.onTarget = d.onTarget
                m.cueResult = d.cueResult; m.decisionRating = d.decisionRating
                m.executionRating = d.executionRating; m.wpaDelta = d.wpaDelta; m.isClutch = d.isClutch
                m.timeOnShot = d.timeOnShot; m.clipRef = d.clipRef; m.updatedAt = d.updatedAt
            })

        _ = try upsert(b.archetypes, ctx, id: \.id, dtoID: \.id, newer: { isNewer($0.updatedAt, than: $1.updatedAt) },
            make: { ArchetypeSnapshot(id: $0.id, playerID: $0.playerID, computedAt: $0.computedAt,
                                      gamesCount: $0.gamesCount, shotsCount: $0.shotsCount, vector: $0.vector,
                                      tags: $0.tags, proComp: $0.proComp) },
            apply: { d, m in
                m.playerID = d.playerID; m.computedAt = d.computedAt; m.gamesCount = d.gamesCount
                m.shotsCount = d.shotsCount; m.vector = d.vector; m.tags = d.tags; m.proComp = d.proComp
                m.updatedAt = d.updatedAt
            })

        _ = try upsert(b.highlights, ctx, id: \.id, dtoID: \.id, newer: { isNewer($0.updatedAt, than: $1.updatedAt) },
            make: { Highlight(id: $0.id, shotID: $0.shotID, kind: $0.kind, clipFile: $0.clipFile, label: $0.label,
                              score: $0.score) },
            apply: { d, m in
                m.game = d.gameID.flatMap { games[$0] }
                m.shotID = d.shotID; m.kind = d.kind; m.clipFile = d.clipFile; m.label = d.label
                m.score = d.score; m.updatedAt = d.updatedAt
            })
    }

    private func mergeTraining(_ b: BackupV1.Training, into ctx: ModelContext, force: Bool = false) throws {
        _ = try upsert(b.profiles, ctx, id: \.id, dtoID: \.id, newer: { force || isNewer($0.updatedAt, than: $1.updatedAt) },
            make: { TrainingProfile(id: $0.id, playerID: $0.playerID, createdAt: $0.createdAt) },
            apply: { d, m in m.playerID = d.playerID; m.createdAt = d.createdAt; m.updatedAt = d.updatedAt })

        let progress = try upsert(b.drillProgress, ctx, id: \.id, dtoID: \.id, newer: { force || isNewer($0.updatedAt, than: $1.updatedAt) },
            make: { DrillProgress(id: $0.id, playerID: $0.playerID, drill: $0.drill, level: $0.level) },
            apply: { d, m in
                m.playerID = d.playerID; m.drill = d.drill
                m.level = min(max(d.level, DrillProgress.levels.lowerBound), DrillProgress.levels.upperBound)
                m.recentResults = d.recentResults; m.levelHistory = d.levelHistory; m.updatedAt = d.updatedAt
            })

        _ = try upsert(b.attempts, ctx, id: \.id, dtoID: \.id, newer: { force || isNewer($0.updatedAt, than: $1.updatedAt) },
            make: { TrainingAttempt(id: $0.id, at: $0.at, setup: $0.setup, result: $0.result, made: $0.made,
                                    features: $0.features) },
            apply: { d, m in
                m.progress = d.progressID.flatMap { progress[$0] }
                m.at = d.at; m.setup = d.setup; m.result = d.result; m.made = d.made; m.features = d.features
                m.updatedAt = d.updatedAt
            })

        _ = try upsert(b.biases, ctx, id: \.id, dtoID: \.id, newer: { force || isNewer($0.updatedAt, than: $1.updatedAt) },
            make: { BiasRecord(id: $0.id, playerID: $0.playerID, drill: $0.drill, axis: $0.axis, sign: $0.sign,
                               attemptsWindow: $0.attemptsWindow, detectedAt: $0.detectedAt) },
            apply: { d, m in
                m.playerID = d.playerID; m.drill = d.drill; m.axis = d.axis; m.sign = d.sign
                m.attemptsWindow = d.attemptsWindow; m.detectedAt = d.detectedAt; m.resolvedAt = d.resolvedAt
                m.updatedAt = d.updatedAt
            })
    }

    /// Strictly newer at millisecond grain (the backup's precision), so re-imports are no-ops.
    private func isNewer(_ incoming: Date, than local: Date) -> Bool {
        BackupV1.millis(incoming) > BackupV1.millis(local)
    }

    /// Insert-or-newer-wins for one model type. Returns every row of that type by id (for linking children).
    private func upsert<M: PersistentModel, D>(
        _ dtos: [D], _ ctx: ModelContext, id: KeyPath<M, UUID>, dtoID: KeyPath<D, UUID>,
        newer: (D, M) -> Bool, make: (D) -> M, apply: (D, M) -> Void
    ) throws -> [UUID: M] {
        var rows = Dictionary(try ctx.fetch(FetchDescriptor<M>()).map { ($0[keyPath: id], $0) },
                              uniquingKeysWith: { a, _ in a })
        for d in dtos {
            if let existing = rows[d[keyPath: dtoID]] {
                if newer(d, existing) { apply(d, existing) }
            } else {
                let m = make(d)
                ctx.insert(m)
                apply(d, m)
                rows[d[keyPath: dtoID]] = m
            }
        }
        return rows
    }
}

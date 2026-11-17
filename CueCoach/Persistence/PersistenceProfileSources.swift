import Foundation
import SwiftData
import Geometry
import Rules
import Engine
import Stats
import Training

/// Competitive `ProfileStatsSource` backed by `PersistenceStack` (`Competitive.store` only) + `CueCore/Stats`.
/// D51: unconfirmed island games appear in `history` with `isUnconfirmed = true`, and are excluded from all competitive
/// aggregates, archetypes, make grids, badges, and pro comparisons until confirmed.
/// D43: guessed shots (`isGuess == true`) and shots lacking a cue-ball pre-state are excluded from shot-bucket stats.
final class PersistenceProfileStatsSource: ProfileStatsSource, @unchecked Sendable {
    private let stack: PersistenceStack

    @MainActor init(stack: PersistenceStack) { self.stack = stack }

    func profile(_ id: UUID) async throws -> ProfileSummary { try await loadProfile(id) }
    func archetype(_ id: UUID) async throws -> ArchetypeView? { try await loadArchetype(id) }
    func makeGrid(_ id: UUID) async throws -> [HeatCell] { try await loadMakeGrid(id) }
    func badges(_ id: UUID) async throws -> [EarnedBadge] { try await loadBadges(id) }
    func proComp(_ id: UUID) async throws -> ProCompView? { try await loadProComp(id) }
    func history(_ id: UUID) async throws -> [SessionSummary] { try await loadHistory(id) }
    func updateProfile(_ id: UUID, name: String, avatarSymbol: String) async throws {
        try await saveProfileEdit(id, name: name, avatarSymbol: avatarSymbol)
    }

    // MARK: - MainActor SwiftData projections

    @MainActor private func fetchOwnerOrProfile(_ id: UUID) throws -> PlayerProfile {
        let ctx = stack.competitiveContext
        if let p = try ctx.fetch(FetchDescriptor<PlayerProfile>(predicate: #Predicate { $0.id == id })).first {
            return p
        }
        throw SetupError.notOwner
    }

    /// Confirmed, finished competitive games projected into `CueCore/Stats.CompetitiveGame`.
    @MainActor static func competitiveGames(in ctx: ModelContext) throws -> [(model: Game, stats: CompetitiveGame)] {
        let rows = try ctx.fetch(FetchDescriptor<Game>()).sorted { $0.startedAt < $1.startedAt }
        return rows.compactMap { g -> (Game, CompetitiveGame)? in
            guard !g.isUnconfirmed, let winner = g.winnerTeam, g.endedAt != nil else { return nil }
            var teamOf: [UUID: Int] = [:]
            for (ti, t) in g.teams.enumerated() {
                for pid in t.memberIDs { teamOf[pid] = ti }
            }
            let ordered = g.shots.sorted { $0.index < $1.index }
            let cShots: [CompetitiveShot] = ordered.compactMap { s in
                // D43 + design §3: skip guessed shots and shots with unknown cue-ball preState so buckets never lie.
                guard !s.isGuess else { return nil }
                let isBreak = s.index == 0 && ordered.count > 1 && s.preState.balls.count >= 9
                if !isBreak && s.preState.balls[.cue] == nil { return nil }
                let team = teamOf[s.shooterID] ?? 0
                let f = ShotFeatures(
                    cutBucket: Stats.CutBucket(rawValue: s.features.cutBucket.rawValue) ?? .c0to15,
                    distanceBucket: Stats.DistanceBucket(rawValue: s.features.distanceBucket.rawValue) ?? .short,
                    pocketType: Stats.PocketType(rawValue: s.features.pocketType.rawValue) ?? .corner,
                    kind: Stats.ShotKind(rawValue: s.features.kind.rawValue) ?? .plain)
                let cueRes = Stats.CueResult(rawValue: s.cueResult.rawValue) ?? .notApplicable
                let objCount = s.pocketed.keys.filter { !$0.isCue }.count
                return CompetitiveShot(id: s.id, shooterID: s.shooterID, team: team, isBreak: isBreak,
                                       features: f, made: s.made, onTarget: s.onTarget, cueResult: cueRes,
                                       fouls: s.fouls, objectBallsPocketed: objCount, wpaDelta: s.wpaDelta,
                                       isClutch: s.isClutch, timeOnShot: s.timeOnShot,
                                       decisionRating: s.decisionRating.rawValue)
            }
            return (g, CompetitiveGame(id: g.id, ruleSet: g.ruleSet, startedAt: g.startedAt,
                                       teamOf: teamOf, winnerTeam: winner, shots: cShots))
        }
    }

    @MainActor private func loadProfile(_ id: UUID) throws -> ProfileSummary {
        let ctx = stack.competitiveContext
        let p = try fetchOwnerOrProfile(id)
        let games = try Self.competitiveGames(in: ctx).map(\.stats)
        let a = Aggregates.career(games, player: id)
        return ProfileSummary(id: p.id, name: p.name, avatarSymbol: p.avatarSymbol, avatarColor: p.avatarColor,
                              games: a.games, wins: a.wins, shots: a.shots, makes: a.makes)
    }

    @MainActor private func loadArchetype(_ id: UUID) throws -> ArchetypeView? {
        let ctx = stack.competitiveContext
        let games = try Self.competitiveGames(in: ctx).map(\.stats)
        let a = Aggregates.career(games, player: id)
        guard a.games > 0 else { return nil }
        let vec = ArchetypeVector(a)
        let allPlayers = Set(games.flatMap(\.players)).subtracting([id])
        let friendVecs = allPlayers.map { ArchetypeVector(Aggregates.career(games, player: $0)) }
        let tags = Archetypes.tags(for: vec, friends: friendVecs)
        let pros = try? ProProfiles.bundled()

        let existing = try ctx.fetch(FetchDescriptor<CueCoach.ArchetypeSnapshot>())
            .filter { $0.playerID == id }
            .sorted { $0.computedAt < $1.computedAt }

        if Archetypes.isUnlocked(a), let snap = Archetypes.snapshot(player: id, games: games, friends: friendVecs,
                                                                    at: .now, pros: pros) {
            if existing.last.map({ $0.gamesCount < snap.gamesCount || $0.shotsCount < snap.shotsCount }) ?? true {
                let storedPro = snap.proComp.map { StoredProComp(proID: $0.proID, similarity: $0.similarity, sharedTraits: $0.sharedTraits) }
                let row = CueCoach.ArchetypeSnapshot(playerID: id, computedAt: snap.computedAt,
                                                     gamesCount: snap.gamesCount, shotsCount: snap.shotsCount,
                                                     vector: snap.vector, tags: snap.tags.map(\.rawValue),
                                                     proComp: storedPro)
                ctx.insert(row)
                try? ctx.save()
            }
        }
        let updated = try ctx.fetch(FetchDescriptor<CueCoach.ArchetypeSnapshot>())
            .filter { $0.playerID == id }
            .sorted { $0.computedAt < $1.computedAt }
        let previous = updated.count >= 2 ? updated[updated.count - 2].vector : nil
        return ArchetypeView(vector: vec.stringKeyed, tags: tags.map(\.rawValue), previous: previous)
    }

    @MainActor private func loadMakeGrid(_ id: UUID) throws -> [HeatCell] {
        let ctx = stack.competitiveContext
        let pairs = try Self.competitiveGames(in: ctx)
        struct Key: Hashable { var cut: StoredShotFeatures.CutBucket; var dist: StoredShotFeatures.DistanceBucket }
        var counts: [Key: (attempts: Int, makes: Int)] = [:]
        for (game, _) in pairs {
            let ordered = game.shots.sorted { $0.index < $1.index }
            for s in ordered where s.shooterID == id && !s.isGuess {
                let isBreak = s.index == 0 && ordered.count > 1 && s.preState.balls.count >= 9
                guard !isBreak, s.features.kind != .safety, s.preState.balls[.cue] != nil else { continue }
                let key = Key(cut: s.features.cutBucket, dist: s.features.distanceBucket)
                var cur = counts[key] ?? (0, 0)
                cur.attempts += 1
                if s.made { cur.makes += 1 }
                counts[key] = cur
            }
        }
        return counts.map { HeatCell(cut: $0.key.cut, distance: $0.key.dist, attempts: $0.value.attempts, makes: $0.value.makes) }
    }

    @MainActor private func loadBadges(_ id: UUID) throws -> [EarnedBadge] {
        let ctx = stack.competitiveContext
        let pairs = try Self.competitiveGames(in: ctx)
        var out: [EarnedBadge] = []
        for (g, cg) in pairs where cg.players.contains(id) {
            let date = g.endedAt ?? g.startedAt
            let ga = Aggregates.game(cg, player: id)
            for s in g.shots where s.shooterID == id && !s.isGuess && s.decisionRating == .brilliant {
                out.append(EarnedBadge(id: "brilliant-\(s.id)", name: "Brilliant", symbol: "sparkles", earnedAt: date))
            }
            if ga.breakAndRuns > 0 {
                out.append(EarnedBadge(id: "bnr-\(g.id)", name: "Break & Run", symbol: "bolt.fill", earnedAt: date))
            }
            if ga.runOuts > 0 {
                out.append(EarnedBadge(id: "runout-\(g.id)", name: "Run-out", symbol: "repeat", earnedAt: date))
            }
            if ga.wins > 0, ga.attempts >= 2, ga.makes == ga.attempts, ga.fouls == 0 {
                out.append(EarnedBadge(id: "clean-\(g.id)", name: "Clean Rack", symbol: "checkmark.seal.fill", earnedAt: date))
            }
        }
        return out
    }

    @MainActor private func loadProComp(_ id: UUID) throws -> ProCompView? {
        let ctx = stack.competitiveContext
        let games = try Self.competitiveGames(in: ctx).map(\.stats)
        let a = Aggregates.career(games, player: id)
        guard Archetypes.isUnlocked(a) else { return nil }
        let vec = ArchetypeVector(a)
        let pros = try ProProfiles.bundled()
        guard let match = ProComp.nearest(to: vec, among: pros),
              let pro = pros.first(where: { $0.id == match.proID }) else { return nil }
        return ProCompView(proName: pro.name, similarity: match.similarity,
                           sharedTraits: match.sharedTraits, proVector: pro.vector.stringKeyed)
    }

    @MainActor private func loadHistory(_ id: UUID) throws -> [SessionSummary] {
        let ctx = stack.competitiveContext
        let allGames = try ctx.fetch(FetchDescriptor<Game>())
        let playerGames = allGames.filter { g in
            g.teams.contains { $0.memberIDs.contains(id) } || g.shots.contains { $0.shooterID == id }
        }
        var bySession: [UUID: (session: Session?, games: [Game])] = [:]
        for g in playerGames {
            let sid = g.session?.id ?? g.id
            var entry = bySession[sid] ?? (g.session, [])
            if entry.session == nil { entry.session = g.session }
            entry.games.append(g)
            bySession[sid] = entry
        }
        return bySession.map { sid, entry in
            let sortedGames = entry.games.sorted { ($0.index, $0.startedAt) < ($1.index, $1.startedAt) }
            let summaries = sortedGames.map { g -> GameSummary in
                let team = g.teams.firstIndex { $0.memberIDs.contains(id) }
                let won: Bool? = if let w = g.winnerTeam, let team { w == team } else { nil }
                return GameSummary(id: g.id, index: g.index, won: won, isUnconfirmed: g.isUnconfirmed)
            }
            let first = sortedGames.first
            return SessionSummary(id: sid,
                                  startedAt: entry.session?.startedAt ?? first?.startedAt ?? .now,
                                  ruleSet: entry.session?.ruleSet ?? first?.ruleSet ?? .default,
                                  format: entry.session?.format ?? .oneVsOne,
                                  games: summaries)
        }
        .sorted { $0.startedAt > $1.startedAt }
    }

    @MainActor private func saveProfileEdit(_ id: UUID, name: String, avatarSymbol: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SetupError.blankName }
        let ctx = stack.competitiveContext
        guard let p = try ctx.fetch(FetchDescriptor<PlayerProfile>(predicate: #Predicate { $0.id == id && $0.isLocalOwner })).first else {
            throw SetupError.notOwner
        }
        p.name = trimmed
        p.avatarSymbol = avatarSymbol
        p.updatedAt = .now
        do { try ctx.save() } catch { ctx.rollback(); throw error }
    }
}

/// Training `TrainingProfileSource` backed solely by `Training.store` (never touches `Competitive.store`, SPEC §4/§10).
final class PersistenceTrainingSource: TrainingProfileSource, @unchecked Sendable {
    private let stack: PersistenceStack

    @MainActor init(stack: PersistenceStack) { self.stack = stack }

    func drills(_ playerID: UUID) async throws -> [DrillLevel] { try await loadDrills(playerID) }
    func activeBias(_ playerID: UUID) async throws -> BiasHint? { try await loadActiveBias(playerID) }

    @MainActor private func loadDrills(_ playerID: UUID) throws -> [DrillLevel] {
        let ctx = stack.trainingContext
        let rows = try ctx.fetch(FetchDescriptor<DrillProgress>()).filter { $0.playerID == playerID }
        let byDrill = Dictionary(rows.map { ($0.drill, $0) }, uniquingKeysWith: { a, b in a.updatedAt >= b.updatedAt ? a : b })
        guard !byDrill.isEmpty else { return [] }
        return DrillID.allCases.compactMap { d in
            guard let r = byDrill[d.rawValue] else { return nil }
            return DrillLevel(drill: d.rawValue, name: TrainingPickerModel.name(d), level: r.level)
        }
    }

    @MainActor private func loadActiveBias(_ playerID: UUID) throws -> BiasHint? {
        let ctx = stack.trainingContext
        let rows = try ctx.fetch(FetchDescriptor<BiasRecord>()).filter { $0.playerID == playerID && $0.resolvedAt == nil }
        guard let newest = rows.max(by: { $0.detectedAt < $1.detectedAt }) else { return nil }
        return BiasHint(axis: newest.axis, sign: newest.sign)
    }
}

/// Post-game mutations on a persisted `Game` opened from Profile History (D49 shooter fix, D47 dispute pick, D53 confirm/delete).
@MainActor enum PersistedGameReviewEditor {
    static func makeModel(stack: PersistenceStack, gameID: UUID, onChanged: @escaping () -> Void,
                          onDismiss: @escaping () -> Void) -> GameReviewModel {
        let m = GameReviewModel(source: PersistenceGameReviewSource(stack: stack, gameID: gameID))
        var refreshTask: Task<Void, Never>?
        var refreshGen = 0
        func scheduleAsyncRefresh() {
            refreshTask?.cancel()
            refreshGen += 1
            let gen = refreshGen
            refreshTask = Task { @MainActor [weak m] in
                guard let updated = try? await refreshEngineMetrics(gameID: gameID, stack: stack),
                      !Task.isCancelled, gen == refreshGen else { return }
                m?.refresh(updated)
                onChanged()
            }
        }
        m.onDone = {
            refreshTask?.cancel()
            onDismiss()
        }
        m.onConfirmGame = {
            try? StackGameRecorder(stack: stack).confirmGame(id: gameID)
            onChanged()
            return try? loadData(stack: stack, gameID: gameID)
        }
        m.onDeleteGame = {
            refreshTask?.cancel()
            try? StackGameRecorder(stack: stack).deleteGame(id: gameID)
            onChanged()
            onDismiss()
        }
        m.onCorrectShooter = { shotID, player in
            let next = try? correctShooter(
                gameID: gameID, shotID: shotID, to: player, stack: stack,
                onDeleted: { refreshTask?.cancel(); onDismiss() })
            onChanged()
            if next != nil { scheduleAsyncRefresh() }
            return next
        }
        m.onResolveOutcome = { shotID, outcome in
            let next = try? resolveOutcome(
                gameID: gameID, shotID: shotID, to: outcome, stack: stack,
                onDeleted: { refreshTask?.cancel(); onDismiss() })
            onChanged()
            if next != nil { scheduleAsyncRefresh() }
            return next
        }
        m.onPlayClip = { [weak m] shotID in
            let ctx = stack.competitiveContext
            let clipBase = stack.directory ?? ShotClipStore.defaultBaseDirectory
            guard let game = (try? ctx.fetch(FetchDescriptor<Game>(predicate: #Predicate { $0.id == gameID })))?.first else { return }
            let rel = game.highlights.first(where: { $0.shotID == shotID && !$0.clipFile.isEmpty })?.clipFile
                ?? game.shots.first(where: { $0.id == shotID })?.clipRef
            guard let rel, let url = ShotClipStore.resolveURL(relativePath: rel, baseDirectory: clipBase) else { return }
            m?.presentClip(shotID: shotID, url: url)
        }
        return m
    }

    static func loadData(stack: PersistenceStack, gameID: UUID) throws -> GameReviewData {
        let ctx = stack.competitiveContext
        guard let game = try ctx.fetch(FetchDescriptor<Game>(predicate: #Predicate { $0.id == gameID })).first else {
            throw ReviewLoadError()
        }
        return GameReviewData(game: game, profiles: try ctx.fetch(FetchDescriptor<PlayerProfile>()))
    }

    static func correctShooter(gameID: UUID, shotID: UUID, to player: ReviewPlayer, stack: PersistenceStack,
                               onDeleted: (() -> Void)? = nil) throws -> GameReviewData? {
        let ctx = stack.competitiveContext
        guard let game = try ctx.fetch(FetchDescriptor<Game>(predicate: #Predicate { $0.id == gameID })).first,
              let target = game.shots.first(where: { $0.id == shotID }),
              let newTeam = game.teams.firstIndex(where: { $0.memberIDs.contains(player.id) }) else { return nil }
        target.shooterID = player.id
        target.attributionSource = .tap
        return try replayAndSave(game: game, fromShotID: shotID, forcedTeam: newTeam, forcedShooterID: player.id,
                                 stack: stack, onDeleted: onDeleted)
    }

    static func resolveOutcome(gameID: UUID, shotID: UUID, to outcome: ShotOutcome, stack: PersistenceStack,
                               onDeleted: (() -> Void)? = nil) throws -> GameReviewData? {
        let ctx = stack.competitiveContext
        guard let game = try ctx.fetch(FetchDescriptor<Game>(predicate: #Predicate { $0.id == gameID })).first,
              let target = game.shots.first(where: { $0.id == shotID }) else { return nil }
        target.fullOutcome = outcome
        target.pocketed = outcome.pocketed
        target.firstContact = outcome.firstContact
        target.calledPocket = outcome.calledPocket
        target.made = outcome.pocketed.keys.contains { !$0.isCue }
        target.onTarget = target.made
        target.needsTap = false
        target.alternateOutcome = nil
        let targetTeam = game.teams.firstIndex(where: { $0.memberIDs.contains(target.shooterID) })
        return try replayAndSave(game: game, fromShotID: shotID, forcedTeam: targetTeam,
                                 forcedShooterID: target.shooterID, stack: stack, onDeleted: onDeleted)
    }

    private static func replayAndSave(game: Game, fromShotID: UUID?, forcedTeam: Int?, forcedShooterID: UUID?,
                                      stack: PersistenceStack, onDeleted: (() -> Void)?) throws -> GameReviewData? {
        let ctx = stack.competitiveContext
        let ordered = game.shots.sorted { $0.index < $1.index }
        let (engine, start) = TargetLegality.startingGame(game.ruleSet, teams: max(2, game.teams.count))
        var state = start
        var currentTeam = 0
        var nextSlot = Array(repeating: 0, count: max(2, game.teams.count))
        var replayRotation = false
        for s in ordered {
            if s.id == fromShotID {
                if let ft = forcedTeam { currentTeam = ft }
                if game.teams.indices.contains(currentTeam), let fsid = forcedShooterID,
                   let slot = game.teams[currentTeam].shootingOrder.firstIndex(of: fsid) {
                    nextSlot[currentTeam] = slot
                }
                replayRotation = true
            } else if !replayRotation, let t = game.teams.firstIndex(where: { $0.memberIDs.contains(s.shooterID) }) {
                currentTeam = t
                if let slot = game.teams[t].shootingOrder.firstIndex(of: s.shooterID) {
                    nextSlot[t] = slot
                }
            } else if replayRotation {
                if s.attributionSource == .tap, let tapTeam = game.teams.firstIndex(where: { $0.memberIDs.contains(s.shooterID) }) {
                    currentTeam = tapTeam
                    if let slot = game.teams[tapTeam].shootingOrder.firstIndex(of: s.shooterID) {
                        nextSlot[tapTeam] = slot
                    }
                } else if game.teams.indices.contains(currentTeam), !game.teams[currentTeam].shootingOrder.isEmpty {
                    let order = game.teams[currentTeam].shootingOrder
                    s.shooterID = order[nextSlot[currentTeam] % order.count]
                }
            }
            state.shooter = currentTeam
            let out = reconstructedOutcome(for: s)
            let res = engine.apply(out, to: state)
            s.fouls = res.fouls
            let madeObject = out.pocketed.keys.contains { !$0.isCue }
            s.made = madeObject
            s.onTarget = madeObject
            if replayRotation {
                s.decisionRating = RuleRating.classify(res, shooter: state.shooter, pocketedObjectBall: madeObject)
                s.executionRating = ExecutionRating(result: madeObject ? .made : .miss, position: .notApplicable)
                s.alternative = nil
            }
            state = res.nextState
            if res.turnPasses, game.teams.count >= 2 {
                nextSlot[currentTeam] = nextSlot[currentTeam] + 1
                currentTeam = (currentTeam + 1) % game.teams.count
            }
        }
        guard let winner = state.winner else {
            // D54: no longer finished → remove the saved row so unfinished racks never remain in Competitive.store.
            try StackGameRecorder(stack: stack).deleteGame(id: game.id)
            onDeleted?()
            return nil
        }
        game.winnerTeam = winner
        recomputeRuleConsistentMetrics(game: game, ordered: ordered, winner: winner, ctx: ctx)
        try ctx.save()
        return GameReviewData(game: game, profiles: try ctx.fetch(FetchDescriptor<PlayerProfile>()))
    }

    static func reconstructedOutcome(for s: Shot) -> ShotOutcome {
        s.fullOutcome ?? ShotOutcome(
            isBreak: s.index == 0,
            firstContact: s.firstContact,
            noContact: s.fouls.contains(.noContact),
            pocketed: s.pocketed,
            offTable: Set<BallID>(s.fouls.compactMap { f -> BallID? in
                switch f {
                case .cueBallOffTable: return .cue
                case .objectBallOffTable(let b): return b
                default: return nil
                }
            }),
            anyRailAfterContact: s.fouls.contains(.noRailAfterContact) ? false : (s.railsAfterContact > 0 ? true : nil),
            objectBallsToRailOnBreak: s.fouls.contains(.illegalBreak) ? 0 : nil,
            calledPocket: s.calledPocket,
            cueBallStartedAboveHeadString: s.fouls.contains(.badCueBallPlacement) ? false : nil,
            cueBallCrossedHeadStringFirst: s.fouls.contains(.badPlayFromAboveHeadString) ? false : nil)
    }

    private static func recomputeRuleConsistentMetrics(game: Game, ordered: [Shot], winner: Int, ctx: ModelContext) {
        var series: [Double] = [0.5]
        var wp0 = 0.5
        for (idx, s) in ordered.enumerated() {
            let team = game.teams.firstIndex(where: { $0.memberIDs.contains(s.shooterID) }) ?? 0
            let shooterBefore = team == 0 ? wp0 : (1.0 - wp0)
            let isFinal = idx == ordered.count - 1
            let nextWP0: Double
            if isFinal {
                nextWP0 = winner == 0 ? 1.0 : 0.0
            } else {
                let swing: Double = if !s.fouls.isEmpty {
                    -0.18
                } else if s.made {
                    0.10
                } else {
                    -0.06
                }
                nextWP0 = min(0.95, max(0.05, wp0 + (team == 0 ? swing : -swing)))
            }
            let shooterAfter = team == 0 ? nextWP0 : (1.0 - nextWP0)
            s.wpaDelta = shooterAfter - shooterBefore
            s.isClutch = abs(s.wpaDelta) >= 0.25 && abs(wp0 - 0.5) <= 0.25
            wp0 = nextWP0
            series.append(wp0)
        }
        game.winProbSeries = series

        // Prune or refresh Shot of the Game so an overturned winner never retains the losing side's stale highlight.
        let winningIDs = Set(game.teams.indices.contains(winner) ? game.teams[winner].memberIDs : [])
        for h in Array(game.highlights) where h.kind == .shotOfGame {
            let shot = ordered.first { $0.id == h.shotID }
            if shot == nil || !winningIDs.contains(shot!.shooterID) || !(shot!.fouls.isEmpty) {
                ctx.delete(h)
            }
        }
        if game.highlights.first(where: { $0.kind == .shotOfGame }) == nil,
           let bestShot = ordered.filter({ winningIDs.contains($0.shooterID) && $0.fouls.isEmpty && !$0.isGuess })
               .max(by: { $0.wpaDelta < $1.wpaDelta }) {
            let label = bestShot.decisionRating == .brilliant ? "Brilliant Shot" : "Rack Winner"
            let h = Highlight(shotID: bestShot.id, kind: .shotOfGame,
                              clipFile: bestShot.clipRef ?? "", label: label, score: max(0.1, bestShot.wpaDelta))
            ctx.insert(h)
            h.game = game
        }
    }

    @discardableResult
    static func refreshEngineMetrics(gameID: UUID, stack: PersistenceStack) async throws -> GameReviewData? {
        let ctx = stack.competitiveContext
        guard let game = try ctx.fetch(FetchDescriptor<Game>(predicate: #Predicate { $0.id == gameID })).first else {
            return nil
        }
        let ordered = game.shots.sorted { $0.index < $1.index }
        guard ordered.contains(where: { !$0.isGuess && $0.preState.balls[.cue] != nil }) else {
            return nil
        }
        let profiles = try ctx.fetch(FetchDescriptor<PlayerProfile>())
        let byID = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
        let sessionShots: [SessionShot] = ordered.map { s in
            let p = byID[s.shooterID]
            let shell = ShellPlayer(id: s.shooterID, name: p?.name ?? "Player",
                                    symbol: p?.avatarSymbol ?? "person.fill",
                                    colorName: p?.avatarColor ?? "teal")
            let team = game.teams.firstIndex(where: { $0.memberIDs.contains(s.shooterID) }) ?? 0
            return SessionShot(
                id: s.id, index: s.index, shooter: shell, team: team,
                rating: s.decisionRating, pocketed: s.pocketed, fouls: s.fouls,
                isGuess: s.isGuess,
                before: s.preState.balls.mapValues(\.position),
                after: s.postState.balls.mapValues(\.position),
                attribution: s.attributionSource, firstContact: s.firstContact,
                needsTap: s.needsTap, alternateOutcome: s.alternateOutcome,
                outcome: reconstructedOutcome(for: s), clipRef: s.clipRef)
        }
        let tableSize = game.session?.tableSize ?? .sevenFoot
        let summary = await SessionEngineEvaluator().evaluateRack(
            ruleSet: game.ruleSet, tableSize: tableSize,
            teamsCount: max(2, game.teams.count), shots: sessionShots)
        guard !Task.isCancelled,
              let freshGame = try ctx.fetch(FetchDescriptor<Game>(predicate: #Predicate { $0.id == gameID })).first else {
            return nil
        }
        for s in freshGame.shots {
            if let e = summary.byShotID[s.id] {
                s.decisionRating = e.rating
                s.executionRating = e.executionRating
                s.wpaDelta = e.wpaDelta
                s.isClutch = e.isClutch
                s.alternative = e.alternative
            }
        }
        if !summary.winProbSeries.isEmpty {
            freshGame.winProbSeries = summary.winProbSeries
        }
        if let sotg = summary.shotOfGame {
            if let existing = freshGame.highlights.first(where: { $0.kind == .shotOfGame }) {
                let sameShot = existing.shotID == sotg.shotID
                existing.shotID = sotg.shotID
                existing.label = sotg.label
                existing.score = sotg.score
                if !sameShot {
                    existing.clipFile = freshGame.shots.first(where: { $0.id == sotg.shotID })?.clipRef ?? ""
                }
            } else {
                let clip = freshGame.shots.first(where: { $0.id == sotg.shotID })?.clipRef ?? ""
                let h = Highlight(shotID: sotg.shotID, kind: .shotOfGame, clipFile: clip,
                                  label: sotg.label, score: sotg.score)
                ctx.insert(h)
                h.game = freshGame
            }
        }
        try ctx.save()
        return GameReviewData(game: freshGame, profiles: try ctx.fetch(FetchDescriptor<PlayerProfile>()))
    }
}

import Foundation
import SwiftData
import Geometry
import Rules
import Engine
import Stats
import Training
import Testing
@testable import CueCoach

@MainActor
@Suite(.serialized) struct PersistenceProfileStatsTests {
    private func makeStackWithOwner() throws -> (PersistenceStack, PlayerProfile, PlayerProfile) {
        let stack = try PersistenceStack(inMemory: true)
        let ctx = stack.competitiveContext
        let owner = PlayerProfile(name: "Aritro", avatarSymbol: "hare.fill", avatarColor: "teal", isLocalOwner: true)
        let rival = PlayerProfile(name: "Rival", avatarSymbol: "bolt.fill", avatarColor: "orange", isLocalOwner: false)
        ctx.insert(owner)
        ctx.insert(rival)
        try ctx.save()
        return (stack, owner, rival)
    }

    private func samplePreState(cueX: Double = 0.5, objX: Double = 1.2) -> TableState {
        let spec = TableSpec(size: .sevenFoot)
        return TableState(spec: spec, balls: [
            .cue: BallState(position: Vec2(cueX, 0.5)),
            BallID(1)!: BallState(position: Vec2(objX, 0.55)),
            .eight: BallState(position: Vec2(1.5, 0.6)),
        ])
    }

    private func makeShot(index: Int, shooterID: UUID, team: Int, made: Bool = true,
                          isGuess: Bool = false, rating: DecisionRating = .best,
                          pocketed: [BallID: Pocket]? = nil, firstContact: BallID? = BallID(1)!) -> RecordedShot {
        let pre = samplePreState()
        let post = samplePreState(cueX: 0.7, objX: 1.4)
        let pock = pocketed ?? (made ? [BallID(1)!: .footRight] : [:])
        return RecordedShot(
            id: UUID(), index: index, shooterID: shooterID, team: team,
            attributionSource: .turnOrder, preState: pre, postState: post,
            calledPocket: nil, firstContact: firstContact, railsAfterContact: 1,
            pocketed: pock, fouls: [],
            features: StoredShotFeatures(cutBucket: .c15to30, distanceBucket: .mid, pocketType: .corner, kind: .plain),
            made: made, onTarget: made, cueResult: .inZone, decisionRating: rating,
            executionRating: ExecutionRating(result: made ? .made : .miss, position: .inZone),
            wpaDelta: made ? 0.08 : -0.05, isClutch: index >= 15, timeOnShot: 12,
            clipRef: nil, isGuess: isGuess)
    }

    @Test func viewModelLoadsUnlockedCareerFromPersistenceStack() async throws {
        let (stack, owner, rival) = try makeStackWithOwner()
        let recorder = StackGameRecorder(stack: stack)
        let teams = [
            StoredTeam(memberIDs: [owner.id], shootingOrder: [owner.id]),
            StoredTeam(memberIDs: [rival.id], shootingOrder: [rival.id]),
        ]
        for rack in 0..<3 {
            let shots = (0..<18).map { idx in
                makeShot(index: idx, shooterID: owner.id, team: 0, made: true,
                         rating: (rack == 0 && idx == 17) ? .brilliant : .best)
            }
            let start = Date(timeIntervalSince1970: Double(1_700_000_000 + rack * 600))
            try recorder.record(FinishedGame(
                id: UUID(), ruleSet: .barEight, tableSize: .sevenFoot, format: .oneVsOne,
                teams: teams, winnerTeam: 0, winProbSeries: Array(repeating: 0.7, count: 19),
                startedAt: start, endedAt: start.addingTimeInterval(300), shots: shots))
        }

        let vm = PlayerProfileViewModel(playerID: owner.id,
                                        stats: PersistenceProfileStatsSource(stack: stack),
                                        training: PersistenceTrainingSource(stack: stack))
        await vm.load()
        #expect(vm.phase == .loaded)
        let content = try #require(vm.content)
        #expect(content.unlock == .unlocked)
        #expect(content.summary.games == 3)
        #expect(content.summary.wins == 3)
        #expect(content.summary.shots == 54)
        #expect(content.summary.makes == 54)
        #expect(content.proComp != nil)
        #expect(content.topArchetype != nil)
        #expect(content.badges.contains { $0.name == "Brilliant" })
        #expect(content.badges.contains { $0.name == "Clean Rack" })
        let cell = content.heat.first { $0.cut == .c15to30 && $0.distance == .mid }
        #expect(cell?.hasData == true)
        let rawGrid = try await PersistenceProfileStatsSource(stack: stack).makeGrid(owner.id)
        #expect(rawGrid.first?.attempts == 54)
        #expect(rawGrid.first?.makes == 54)
        #expect(content.history.flatMap(\.sessions).count == 3)
    }

    @Test func unconfirmedGamesAppearMarkedInHistoryAndStayOutOfStatsUntilConfirmed() async throws {
        let (stack, owner, rival) = try makeStackWithOwner()
        let recorder = StackGameRecorder(stack: stack)
        let gameID = UUID()
        let teams = [
            StoredTeam(memberIDs: [owner.id], shootingOrder: [owner.id]),
            StoredTeam(memberIDs: [rival.id], shootingOrder: [rival.id]),
        ]
        try recorder.record(FinishedGame(
            id: gameID, ruleSet: .barEight, tableSize: .sevenFoot, format: .oneVsOne,
            teams: teams, winnerTeam: 0, winProbSeries: [0.5, 1.0],
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_000_120),
            shots: [makeShot(index: 0, shooterID: owner.id, team: 0, made: true)],
            isUnconfirmed: true))

        let stats = PersistenceProfileStatsSource(stack: stack)
        let beforeSummary = try await stats.profile(owner.id)
        #expect(beforeSummary.games == 0, "D51: unconfirmed island game excluded from competitive stats")
        let beforeHistory = try await stats.history(owner.id)
        #expect(beforeHistory.first?.games.first?.isUnconfirmed == true)

        var didNotifyChange = false
        let reviewModel = PersistedGameReviewEditor.makeModel(
            stack: stack, gameID: gameID,
            onChanged: { didNotifyChange = true },
            onDismiss: {})
        reviewModel.confirmGame()
        #expect(didNotifyChange)

        let afterSummary = try await stats.profile(owner.id)
        #expect(afterSummary.games == 1, "D53: confirming in Game Review promotes the rack into stats")
        let afterHistory = try await stats.history(owner.id)
        #expect(afterHistory.first?.games.first?.isUnconfirmed == false)
    }

    @Test func guessedShotsAreSkippedInPotStatsAndMakeGrid() async throws {
        let (stack, owner, rival) = try makeStackWithOwner()
        let recorder = StackGameRecorder(stack: stack)
        let teams = [
            StoredTeam(memberIDs: [owner.id], shootingOrder: [owner.id]),
            StoredTeam(memberIDs: [rival.id], shootingOrder: [rival.id]),
        ]
        try recorder.record(FinishedGame(
            id: UUID(), ruleSet: .barEight, tableSize: .sevenFoot, format: .oneVsOne,
            teams: teams, winnerTeam: 0, winProbSeries: [0.5, 0.7, 1.0],
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_000_120),
            shots: [
                makeShot(index: 0, shooterID: owner.id, team: 0, made: true, isGuess: false),
                makeShot(index: 1, shooterID: owner.id, team: 0, made: false, isGuess: true),
            ]))

        let stats = PersistenceProfileStatsSource(stack: stack)
        let summary = try await stats.profile(owner.id)
        #expect(summary.shots == 1)
        #expect(summary.makes == 1)
        let grid = try await stats.makeGrid(owner.id)
        #expect(grid.reduce(0) { $0 + $1.attempts } == 1)
    }

    @Test func trainingSourceReadsTrainingStoreWithoutTouchingCompetitiveStore() async throws {
        let (stack, owner, _) = try makeStackWithOwner()
        let tctx = stack.trainingContext
        tctx.insert(DrillProgress(playerID: owner.id, drill: DrillID.increasingCuts.rawValue, level: 3))
        tctx.insert(BiasRecord(playerID: owner.id, drill: DrillID.increasingCuts.rawValue,
                               axis: .cut, sign: 1, attemptsWindow: 10, detectedAt: .now))
        try tctx.save()

        let training = PersistenceTrainingSource(stack: stack)
        let drills = try await training.drills(owner.id)
        let bias = try await training.activeBias(owner.id)
        #expect(drills == [DrillLevel(drill: "increasingCuts", name: "Cuts", level: 3)])
        #expect(bias == BiasHint(axis: .cut, sign: 1))
        let compGames = try stack.competitiveContext.fetch(FetchDescriptor<Game>())
        #expect(compGames.isEmpty)
    }

    @Test func persistedReviewShooterCorrectionFlipsWinnerOrDeletesUnfinishedRack() throws {
        let (stack, owner, rival) = try makeStackWithOwner()
        let recorder = StackGameRecorder(stack: stack)
        let gameID = UUID()
        let earlyEightID = UUID()
        let teams = [
            StoredTeam(memberIDs: [owner.id], shootingOrder: [owner.id]),
            StoredTeam(memberIDs: [rival.id], shootingOrder: [rival.id]),
        ]
        var s0 = makeShot(index: 0, shooterID: owner.id, team: 0, made: true, pocketed: [BallID(1)!: .footRight])
        var s1 = makeShot(index: 1, shooterID: owner.id, team: 0, made: false, pocketed: [:])
        var s2 = makeShot(index: 2, shooterID: rival.id, team: 1, made: true, pocketed: [.eight: .footLeft], firstContact: .eight)
        s0.id = UUID(); s1.id = UUID(); s2.id = earlyEightID
        try recorder.record(FinishedGame(
            id: gameID, ruleSet: .barEight, tableSize: .sevenFoot, format: .oneVsOne,
            teams: teams, winnerTeam: 0, winProbSeries: [0.5, 0.6, 0.5, 1.0],
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_000_120),
            shots: [s0, s1, s2]))

        // Reassign the early-8 shot from Rival (team 1) to Owner (team 0) → winner flips from team 0 to team 1!
        let ownerReview = ReviewPlayer(id: owner.id, name: owner.name, symbol: owner.avatarSymbol, colorName: owner.avatarColor)
        let flipped = try #require(try PersistedGameReviewEditor.correctShooter(
            gameID: gameID, shotID: earlyEightID, to: ownerReview, stack: stack))
        #expect(flipped.winnerTeam == 1)
        let saved = try #require(try stack.competitiveContext.fetch(FetchDescriptor<Game>()).first)
        #expect(saved.winnerTeam == 1)

        // D54: resolving the decisive early-8 shot into an ordinary legal miss leaves the rack unfinished and deletes it!
        var deletedCallbackFired = false
        let afterUnfinish = try PersistedGameReviewEditor.resolveOutcome(
            gameID: gameID, shotID: earlyEightID,
            to: ShotOutcome(firstContact: BallID(1)!, pocketed: [:]),
            stack: stack, onDeleted: { deletedCallbackFired = true })
        #expect(afterUnfinish == nil)
        #expect(deletedCallbackFired)
        #expect(try stack.competitiveContext.fetch(FetchDescriptor<Game>()).isEmpty)
    }

    @Test func persistedReviewPreservesFullNoContactOutcomeOnNineBallThreeFoul() throws {
        let (stack, owner, rival) = try makeStackWithOwner()
        let mate1 = PlayerProfile(name: "Mate", avatarSymbol: "flame.fill", avatarColor: "red", isLocalOwner: false)
        let mate0 = PlayerProfile(name: "Partner", avatarSymbol: "leaf.fill", avatarColor: "green", isLocalOwner: false)
        stack.competitiveContext.insert(mate0)
        stack.competitiveContext.insert(mate1)
        try stack.competitiveContext.save()

        let recorder = StackGameRecorder(stack: stack)
        let gameID = UUID()
        let teams = [
            StoredTeam(memberIDs: [owner.id, mate0.id], shootingOrder: [owner.id, mate0.id]),
            StoredTeam(memberIDs: [rival.id, mate1.id], shootingOrder: [rival.id, mate1.id]),
        ]
        // WPA 9-ball: Team 0 misses legal 1-ball contact on shots 0, 2, 4; Team 1 commits 3 consecutive `.noContact` fouls on shots 1, 3, 5 → Team 0 wins!
        let legalMiss = ShotOutcome(firstContact: BallID(1)!, pocketed: [:])
        let noContactFoul = ShotOutcome(noContact: true)
        var shots: [RecordedShot] = []
        let sequence: [(UUID, Int, ShotOutcome)] = [
            (owner.id, 0, legalMiss),
            (rival.id, 1, noContactFoul),
            (mate0.id, 0, legalMiss),
            (mate1.id, 1, noContactFoul),
            (owner.id, 0, legalMiss),
            (rival.id, 1, noContactFoul),
        ]
        for (idx, item) in sequence.enumerated() {
            var rs = makeShot(index: idx, shooterID: item.0, team: item.1, made: false, pocketed: [:],
                              firstContact: item.2.firstContact)
            rs.fouls = item.2.noContact ? [.noContact] : []
            rs.fullOutcome = item.2
            shots.append(rs)
        }
        try recorder.record(FinishedGame(
            id: gameID, ruleSet: .wpaNine, tableSize: .nineFoot, format: .twoVsTwo,
            teams: teams, winnerTeam: 0, winProbSeries: [0.5, 0.48, 0.55, 0.52, 0.65, 0.62, 1.0],
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_000_240),
            shots: shots))

        // Correcting shot 1 between Team 1 teammates preserves `fullOutcome` (`noContact: true`) and Team 0's 3-foul win!
        let mate1Review = ReviewPlayer(id: mate1.id, name: mate1.name, symbol: mate1.avatarSymbol, colorName: mate1.avatarColor)
        let updated = try #require(try PersistedGameReviewEditor.correctShooter(
            gameID: gameID, shotID: shots[1].id, to: mate1Review, stack: stack))
        #expect(updated.winnerTeam == 0)
        #expect(updated.isFinished)
        #expect(try stack.competitiveContext.fetch(FetchDescriptor<Game>()).count == 1)
    }

    @Test func legacyNoRailFoulAndWinnerFlipUpdateWinProbAndPruneStaleHighlight() throws {
        let (stack, owner, rival) = try makeStackWithOwner()
        let mate1 = PlayerProfile(name: "Mate", avatarSymbol: "flame.fill", avatarColor: "red", isLocalOwner: false)
        let mate0 = PlayerProfile(name: "Partner", avatarSymbol: "leaf.fill", avatarColor: "green", isLocalOwner: false)
        stack.competitiveContext.insert(mate0)
        stack.competitiveContext.insert(mate1)
        try stack.competitiveContext.save()

        let recorder = StackGameRecorder(stack: stack)
        let gameID = UUID()
        let teams = [
            StoredTeam(memberIDs: [owner.id, mate0.id], shootingOrder: [owner.id, mate0.id]),
            StoredTeam(memberIDs: [rival.id, mate1.id], shootingOrder: [rival.id, mate1.id]),
        ]
        // Legacy rows (`fullOutcome == nil`) with `.noRailAfterContact` fouls on Team 1's 3 turns → Team 0 wins by 3-foul!
        var shots: [RecordedShot] = []
        for idx in 0..<6 {
            let isTeam1 = idx % 2 == 1
            let shooter = isTeam1 ? (idx == 3 ? mate1.id : rival.id) : (idx == 2 ? mate0.id : owner.id)
            var rs = makeShot(index: idx, shooterID: shooter, team: isTeam1 ? 1 : 0,
                              made: false, pocketed: [:], firstContact: BallID(1)!)
            rs.railsAfterContact = isTeam1 ? 0 : 1
            rs.fouls = isTeam1 ? [.noRailAfterContact] : []
            rs.fullOutcome = nil   // simulate pre-V4 legacy row
            shots.append(rs)
        }
        try recorder.record(FinishedGame(
            id: gameID, ruleSet: .wpaNine, tableSize: .nineFoot, format: .twoVsTwo,
            teams: teams, winnerTeam: 0, winProbSeries: [0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 1.0],
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_000_240),
            shots: shots,
            shotOfGame: RecordedHighlight(shotID: shots[0].id, label: "Great Shot", score: 0.4)))

        let mate1Review = ReviewPlayer(id: mate1.id, name: mate1.name, symbol: mate1.avatarSymbol, colorName: mate1.avatarColor)
        let kept = try #require(try PersistedGameReviewEditor.correctShooter(
            gameID: gameID, shotID: shots[1].id, to: mate1Review, stack: stack))
        #expect(kept.winnerTeam == 0, "Legacy `.noRailAfterContact` foul is reconstructed even when `fullOutcome` is nil")
        #expect(kept.winProb.last == 1.0)

        // Also verify that flipping a Bar-8 winner updates `winProb` to end at 0.0 (Team 1 win) and drops Team 0's stale SotG!
        let flipID = UUID()
        var b0 = makeShot(index: 0, shooterID: owner.id, team: 0, made: true, pocketed: [BallID(1)!: .footRight])
        var b1 = makeShot(index: 1, shooterID: rival.id, team: 1, made: true, pocketed: [.eight: .footLeft], firstContact: .eight)
        b0.id = UUID(); b1.id = UUID()
        try recorder.record(FinishedGame(
            id: flipID, ruleSet: .barEight, tableSize: .sevenFoot, format: .oneVsOne,
            teams: [StoredTeam(memberIDs: [owner.id], shootingOrder: [owner.id]),
                    StoredTeam(memberIDs: [rival.id], shootingOrder: [rival.id])],
            winnerTeam: 0, winProbSeries: [0.5, 0.7, 1.0],
            startedAt: Date(timeIntervalSince1970: 1_700_001_000),
            endedAt: Date(timeIntervalSince1970: 1_700_001_120),
            shots: [b0, b1],
            shotOfGame: RecordedHighlight(shotID: b0.id, label: "Brilliant Shot", score: 0.8)))

        let ownerReview = ReviewPlayer(id: owner.id, name: owner.name, symbol: owner.avatarSymbol, colorName: owner.avatarColor)
        let flipped = try #require(try PersistedGameReviewEditor.correctShooter(
            gameID: flipID, shotID: b1.id, to: ownerReview, stack: stack))
        #expect(flipped.winnerTeam == 1)
        #expect(flipped.winProb.last == 0.0, "Win-prob series updates to match flipped winner")
        #expect(flipped.shotOfGame?.shotID != b0.id, "Losing team's stale SotG highlight is pruned")
    }
}

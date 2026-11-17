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
            .cue: BallState(position: Point2D(cueX, 0.5)),
            BallID(1)!: BallState(position: Point2D(objX, 0.55)),
            .eight: BallState(position: Point2D(1.5, 0.6)),
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
            features: StoredShotFeatures(cutBucket: .c15to30, distanceBucket: .medium, pocketType: .corner, kind: .plain),
            made: made, onTarget: made, cueResult: .good, decisionRating: rating,
            executionRating: ExecutionRating(result: made ? .made : .miss, position: .good),
            wpaDelta: made ? 0.08 : -0.05, isClutch: index >= 15, timeOnShot: 12,
            clipRef: nil, isGuess: isGuess)
    }

    @Test func profileUnlocksArchetypeProCompHeatGridAndBadgesFromSavedRacks() throws {
        let (stack, owner, rival) = try makeStackWithOwner()
        let recorder = StackGameRecorder(stack: stack)
        let teams = [
            StoredTeam(memberIDs: [owner.id], shootingOrder: [owner.id]),
            StoredTeam(memberIDs: [rival.id], shootingOrder: [rival.id]),
        ]
        // Record 3 confirmed racks with 18 shots each (54 total shots ≥ 50 unlock threshold).
        for rack in 0..<3 {
            var shots: [RecordedShot] = []
            for idx in 0..<18 {
                let rating: DecisionRating = (rack == 0 && idx == 17) ? .brilliant : .best
                shots.append(makeShot(index: idx, shooterID: owner.id, team: 0, made: true, rating: rating))
            }
            let start = Date(timeIntervalSince1970: Double(1_700_000_000 + rack * 600))
            try recorder.record(FinishedGame(
                id: UUID(), ruleSet: .barEight, tableSize: .sevenFoot, format: .oneVsOne,
                teams: teams, winnerTeam: 0, winProbSeries: Array(repeating: 0.7, count: 19),
                startedAt: start, endedAt: start.addingTimeInterval(300), shots: shots))
        }
        return
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
        #expect(content.archetype != nil)
        #expect(content.badges.contains { $0.name == "Brilliant" })
        #expect(content.badges.contains { $0.name == "Clean Rack" })
        #expect(content.heat.contains { $0.cut == .c15to30 && $0.distance == .medium && $0.attempts == 54 && $0.makes == 54 })
        #expect(content.history.count == 3)
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
        #expect(try stack.competitiveContext.fetch(FetchDescriptor<Game>()).isEmpty)
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
    }
}

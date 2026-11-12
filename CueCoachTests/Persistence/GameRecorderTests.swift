import Foundation
import SwiftData
import Testing
import Geometry
import Rules
import Engine
import Stats
import Training
@testable import CueCoach

/// Plan 011: a finished rack is saved to the competitive store on its winning commit (D40, D45), by one writer.
@MainActor
@Suite struct GameRecorderTests {
    let a1 = ShellPlayer(id: UUID(), name: "A1", symbol: "hare.fill", colorName: "teal")
    let b1 = ShellPlayer(id: UUID(), name: "B1", symbol: "bolt.fill", colorName: "orange")
    var config: GameConfig { GameConfig(ruleSet: .barEight, tableSize: .sevenFoot, teams: [[a1], [b1]]) }

    static func pot(_ n: Int) -> ShotOutcome { ShotOutcome(firstContact: BallID(n)!, pocketed: [BallID(n)!: .footLeft]) }
    static let miss = ShotOutcome(firstContact: BallID(1)!)
    /// The 8 on an open table: the shooter loses the rack.
    static let eightEarly = ShotOutcome(firstContact: .eight, pocketed: [.eight: .footLeft])

    func solo(_ stack: PersistenceStack) -> GameSessionModel {
        let g = GameSessionModel(config: config)
        g.recorder = StackGameRecorder(stack: stack)
        return g
    }

    func games(_ stack: PersistenceStack) throws -> [Game] { try stack.competitiveContext.fetch(FetchDescriptor<Game>()) }
    func shots(_ stack: PersistenceStack) throws -> [Shot] {
        try stack.competitiveContext.fetch(FetchDescriptor<Shot>()).sorted { $0.index < $1.index }
    }
    func sessions(_ stack: PersistenceStack) throws -> [CueCoach.Session] {
        try stack.competitiveContext.fetch(FetchDescriptor<CueCoach.Session>())
    }

    /// A1 pots the 1, misses; B1 sinks the 8 early: team 0 wins on the third shot.
    func playARack(_ g: GameSessionModel) {
        g.shotSettled(SettledShot(rating: .best, turnPasses: false, outcome: Self.pot(1)))
        g.shotSettled(SettledShot(rating: .mistake, turnPasses: true, outcome: Self.miss))
        g.shotSettled(SettledShot(rating: .blunder, turnPasses: true, outcome: Self.eightEarly))
    }

    @Test func finishedSoloRackWritesOneGameWithItsShots() throws {
        let stack = try PersistenceStack(inMemory: true)
        let g = solo(stack)
        playARack(g)
        let saved = try games(stack)
        #expect(saved.count == 1)
        let game = try #require(saved.first)
        #expect(game.winnerTeam == 0)
        #expect(game.endedAt != nil)
        #expect(game.id == g.shots.first?.id, "Game.id = the first committed shot id")
        #expect(game.teams.map(\.memberIDs) == [[a1.id], [b1.id]])
        #expect(game.ruleSet == .barEight)
        let rows = try shots(stack)
        #expect(rows.map(\.index) == [0, 1, 2])
        #expect(rows.map(\.id) == g.shots.map(\.id))
        #expect(rows.map(\.shooterID) == [a1.id, a1.id, b1.id])
        #expect(rows.map(\.decisionRating) == [.best, .mistake, .blunder])
        #expect(game.shots.count == 3)
        let session = try #require(try sessions(stack).first)
        #expect(try sessions(stack).count == 1)
        #expect(session.tableSize == .sevenFoot && session.format == .oneVsOne && session.ruleSet == .barEight)
        #expect(game.session?.id == session.id)
    }

    @Test func fieldTableIsFollowed() throws {
        let stack = try PersistenceStack(inMemory: true)
        let g = solo(stack)
        playARack(g)
        let rows = try shots(stack)
        try #require(rows.count == 3)
        for r in rows {
            #expect(r.attributionSource == .turnOrder)
            #expect(r.calledPocket == nil)
            #expect(r.railsAfterContact == 0)
            #expect(r.cueResult == .notApplicable)
            #expect(r.wpaDelta == 0)
            #expect(r.isClutch == false)
            #expect(r.timeOnShot == -1)
            #expect(r.clipRef == nil)
            #expect(r.onTarget == r.made)
            #expect(r.executionRating == ExecutionRating(result: r.made ? .made : .miss, position: .notApplicable))
        }
        #expect(rows.map(\.made) == [true, false, true])
        #expect(rows[0].pocketed == [BallID(1)!: .footLeft])
        #expect(rows[0].firstContact == BallID(1))
        #expect(rows[2].fouls == g.shots[2].fouls)
        #expect(try games(stack).first?.winProbSeries == [])
    }

    @Test func featuresComeFromPositionsWhenTheCueIsInPre() throws {
        let stack = try PersistenceStack(inMemory: true)
        let g = solo(stack)
        let before = [BallID.cue: Vec2(0.3, 0.25), BallID(1)!: Vec2(1.75, 0.8)]
        let after = [BallID.cue: Vec2(1.2, 0.5)]
        g.shotSettled(SettledShot(rating: .best, turnPasses: false, before: before, after: after, outcome: Self.pot(1)))
        g.shotSettled(SettledShot(rating: .blunder, turnPasses: true, outcome: Self.eightEarly))
        let spec = TableSpec(size: .sevenFoot)
        let expected = ShotFeatures.extract(pre: TableState(spec: spec, balls: before.mapValues { BallState(position: $0) }),
                                            post: TableState(spec: spec, balls: after.mapValues { BallState(position: $0) }),
                                            trace: ShotTraceSummary(events: []))
        #expect(expected != ShotFeatures.neutral, "fixture must not be the neutral shot")
        let row = try #require(try shots(stack).first)
        #expect(row.features.cutBucket.rawValue == expected.cutBucket.rawValue)
        #expect(row.features.distanceBucket.rawValue == expected.distanceBucket.rawValue)
        #expect(row.features.pocketType.rawValue == expected.pocketType.rawValue)
        #expect(row.features.kind.rawValue == expected.kind.rawValue)
        #expect(row.preState.balls[.cue]?.position == Vec2(0.3, 0.25))
        #expect(row.postState.balls[.cue]?.position == Vec2(1.2, 0.5))
    }

    @Test func neutralFeaturesWhenNoCueInPre() throws {
        let stack = try PersistenceStack(inMemory: true)
        let g = solo(stack)
        g.shotSettled(SettledShot(rating: .best, turnPasses: false, before: [BallID(1)!: Vec2(1.75, 0.8)],
                                  outcome: Self.pot(1)))
        g.shotSettled(SettledShot(rating: .blunder, turnPasses: true, outcome: Self.eightEarly))
        let rows = try shots(stack)
        try #require(rows.count == 2)
        let n = ShotFeatures.neutral
        for r in rows {
            #expect(r.features.cutBucket.rawValue == n.cutBucket.rawValue)
            #expect(r.features.distanceBucket.rawValue == n.distanceBucket.rawValue)
            #expect(r.features.pocketType.rawValue == n.pocketType.rawValue)
            #expect(r.features.kind.rawValue == n.kind.rawValue)
        }
        #expect(rows[1].preState.balls.isEmpty, "an empty before stores an empty ball map")
    }

    @Test func gapShotsAreNotSaved() throws {
        let stack = try PersistenceStack(inMemory: true)
        let g = solo(stack)
        g.shotSettled(SettledShot(rating: .best, turnPasses: false, outcome: Self.pot(1)))          // 0
        g.shotLost()                                                                                // 1: gap
        g.shotSettled(SettledShot(rating: .good, turnPasses: false, isGuess: true, outcome: Self.pot(2)))   // 2: guess
        g.shotSettled(SettledShot(rating: .blunder, turnPasses: true, outcome: Self.eightEarly))   // 3: A1 loses
        let game = try #require(try games(stack).first)
        #expect(game.winnerTeam == 1)
        #expect(game.id == g.shots[0].id)
        let rows = try shots(stack)
        #expect(rows.map(\.index) == [0, 2, 3], "only the gap leaves a hole; the others keep their original index")
        #expect(rows.map(\.id) == [g.shots[0].id, g.shots[2].id, g.shots[3].id])
    }

    /// D43 (plan 012): a D31 guess is saved, flagged, so review can show it and stats can skip it.
    @Test func recorderSavesAGuessedShotFlagged() throws {
        let stack = try PersistenceStack(inMemory: true)
        let g = solo(stack)
        g.shotSettled(SettledShot(rating: .good, turnPasses: false, isGuess: true, outcome: Self.pot(2)))   // 0: guess
        g.shotSettled(SettledShot(rating: .mistake, turnPasses: true, outcome: Self.miss))                 // 1
        g.shotSettled(SettledShot(rating: .blunder, turnPasses: true, outcome: Self.eightEarly))           // 2: B1 loses
        let rows = try shots(stack)
        #expect(rows.map(\.index) == [0, 1, 2])
        #expect(rows.map(\.isGuess) == [true, false, false])
        #expect(rows[0].pocketed == [BallID(2)!: .footLeft], "the best guess is kept as pocketed")
        #expect(rows[0].decisionRating == .good)
        #expect(g.finishedGame()?.shots.map(\.isGuess) == [true, false, false])
    }

    @Test func recordingAgainUpdatesTheGuessFlagInPlace() throws {
        let stack = try PersistenceStack(inMemory: true)
        let g = solo(stack)
        playARack(g)
        var game = try #require(g.finishedGame())
        game.shots[1].isGuess = true
        let recorder = StackGameRecorder(stack: stack)
        try recorder.record(game)
        #expect(try shots(stack).map(\.isGuess) == [false, true, false])
        #expect(try shots(stack).count == 3)
    }

    @Test func midRackEndSavesNothing() throws {
        let stack = try PersistenceStack(inMemory: true)
        let r = AppRouter()
        r.recorder = StackGameRecorder(stack: stack)
        r.startGame(config)
        guard case .live(let s)? = r.stage else { Issue.record("not live"); return }
        s.settled(SettledShot(rating: .best, turnPasses: false, outcome: Self.pot(1)))
        r.endGame()
        r.finishReview()
        #expect(try games(stack).isEmpty)
        #expect(try shots(stack).isEmpty)
        #expect(try sessions(stack).isEmpty)
    }

    /// D45: the winning commit saves; the app is then killed (no endGame) and the rack is kept.
    @Test func winningCommitSavesBeforeEnd() throws {
        let stack = try PersistenceStack(inMemory: true)
        let r = AppRouter()
        r.recorder = StackGameRecorder(stack: stack)
        r.startGame(config)
        guard case .live(let s)? = r.stage, let g = s.game else { Issue.record("not live"); return }
        g.shotSettled(SettledShot(rating: .best, turnPasses: false, outcome: Self.pot(1)))
        #expect(try games(stack).isEmpty, "no winner yet")
        g.shotSettled(SettledShot(rating: .blunder, turnPasses: true, outcome: Self.eightEarly))
        #expect(try games(stack).count == 1)
        #expect(try shots(stack).count == 2)
    }

    @Test func hostSavesOnTheWinningCommitOnly() throws {
        let stack = try PersistenceStack(inMemory: true)
        let g = solo(stack)
        let link = FakeGameMeshLink(isHost: true)
        g.mesh = link
        g.shotSettled(SettledShot(rating: .best, turnPasses: false, outcome: Self.pot(1)))
        g.shotSettled(SettledShot(rating: .blunder, turnPasses: true, outcome: Self.eightEarly))
        #expect(try games(stack).isEmpty, "appended, not committed")
        link.commit()
        #expect(try games(stack).count == 1)
        #expect(try shots(stack).count == 2)
    }

    /// The commit is the majority: a host whose winning shot never commits (no majority acked it) writes nothing.
    @Test func hostWithoutMajorityNeverWrites() throws {
        let stack = try PersistenceStack(inMemory: true)
        let g = solo(stack)
        let link = FakeGameMeshLink(isHost: true)
        g.mesh = link
        g.shotSettled(SettledShot(rating: .best, turnPasses: false, outcome: Self.pot(1)))
        link.commit()                                   // the first shot commits
        g.shotSettled(SettledShot(rating: .blunder, turnPasses: true, outcome: Self.eightEarly))
        link.receive(link.log, commitSeq: 1)            // the winning shot stays an uncommitted tail
        #expect(try games(stack).isEmpty)
    }

    /// Codex plan 011 review 1: the commit quorum can shrink (a lone survivor commits alone); the game quorum can't.
    @Test func hostWithoutGameQuorumNeverWrites() throws {
        let stack = try PersistenceStack(inMemory: true)
        let g = solo(stack)
        let link = FakeGameMeshLink(isHost: true)
        link.hasGameQuorum = false
        g.mesh = link
        playARack(g)
        link.commit()
        #expect(g.reviewData().winnerTeam == 0)
        #expect(try games(stack).isEmpty)
    }

    /// Codex plan 011 review 2: a failed save retries the rack as it stood at its winning commit.
    @Test func aRetryAfterAFailedSaveKeepsTheWinningBoundary() throws {
        let stack = try PersistenceStack(inMemory: true)
        let g = GameSessionModel(config: config)
        let flaky = FlakyRecorder(StackGameRecorder(stack: stack))
        g.recorder = flaky
        playARack(g)
        #expect(try games(stack).isEmpty, "the first save threw")
        g.shotSettled(SettledShot(rating: .okay, turnPasses: true, outcome: Self.miss))   // a post-win commit retries
        #expect(g.shots.count == 4)
        #expect(try games(stack).count == 1)
        #expect(try shots(stack).map(\.id) == g.shots.prefix(3).map(\.id))
        #expect(flaky.recorded.count == 1)
    }

    func winningLog() -> [LogEntry] {
        [GameEvent.shot(MeshShotRecord(shotID: UUID(), shooterTeam: 0, outcome: Self.pot(1), postState: nil)),
         .shot(MeshShotRecord(shotID: UUID(), shooterTeam: 0, outcome: Self.eightEarly, postState: nil))]
            .enumerated().map { LogEntry(seq: UInt64($0.offset + 1), term: 1, event: $0.element) }
    }

    @Test func joinerNeverWrites() throws {
        let stack = try PersistenceStack(inMemory: true)
        let g = solo(stack)
        let link = FakeGameMeshLink(isHost: false)
        g.mesh = link
        link.receive(winningLog(), commitSeq: 2)
        #expect(g.reviewData().winnerTeam == 1)
        #expect(try games(stack).isEmpty)
    }

    /// Codex plan 010 review: the guard is `isHost`, never `!isJoiner`. A discovering phone never saves.
    @Test func discoveringPhoneNeverWrites() throws {
        let stack = try PersistenceStack(inMemory: true)
        let g = solo(stack)
        let link = DiscoveringLink()
        g.mesh = link
        link.onCommittedLog?(winningLog(), 2)
        #expect(g.reviewData().winnerTeam == 1)
        #expect(try games(stack).isEmpty)
    }

    @Test func endingTwiceWritesOnce() throws {
        let stack = try PersistenceStack(inMemory: true)
        let r = AppRouter()
        r.recorder = StackGameRecorder(stack: stack)
        r.startGame(config)
        guard case .live(let s)? = r.stage, let g = s.game else { Issue.record("not live"); return }
        playARack(g)
        g.shotSettled(SettledShot(rating: .okay, turnPasses: true, outcome: Self.miss))   // a later commit
        r.endGame()
        r.endGame()
        r.liveClosed()
        #expect(try games(stack).count == 1)
        #expect(try shots(stack).count == 3)
        #expect(try sessions(stack).count == 1)
    }

    /// Upsert by id: recording the same game again updates the rows in place, never a second row.
    @Test func recordingAgainUpdatesInPlace() throws {
        let stack = try PersistenceStack(inMemory: true)
        let g = solo(stack)
        playARack(g)
        var again = try #require(g.finishedGame())
        let recorder = StackGameRecorder(stack: stack)
        try recorder.record(again)
        again.winnerTeam = 1
        again.shots[0].decisionRating = .okay
        try recorder.record(again)
        #expect(try games(stack).count == 1)
        #expect(try shots(stack).count == 3)
        #expect(try sessions(stack).count == 1)
        #expect(try games(stack).first?.winnerTeam == 1)
        #expect(try shots(stack).first?.decisionRating == .okay)
        #expect(try games(stack).first?.shots.count == 3)
    }

    @Test func finishedGameIsNilWithoutAWinner() {
        let g = GameSessionModel(config: config)
        #expect(g.finishedGame() == nil)
        g.shotSettled(SettledShot(rating: .best, turnPasses: false, outcome: Self.pot(1)))
        #expect(g.finishedGame() == nil)
        g.shotSettled(SettledShot(rating: .blunder, turnPasses: true, outcome: Self.eightEarly))
        #expect(g.finishedGame()?.winnerTeam == 1)
    }

    /// Design §5: training never reaches the recorder.
    @Test func trainingNeverWritesACompetitiveGame() throws {
        let stack = try PersistenceStack(inMemory: true)
        let r = AppRouter()
        r.recorder = StackGameRecorder(stack: stack)
        r.startTraining(drill: .straightIn, level: .full)
        guard case .live(let s)? = r.stage else { Issue.record("not live"); return }
        s.aimStarted()
        s.settled(SettledShot(rating: .best, turnPasses: false, outcome: Self.eightEarly))
        s.ballsSettled()
        r.liveClosed()
        r.endGame()
        #expect(try games(stack).isEmpty)
        #expect(try shots(stack).isEmpty)
        #expect(try sessions(stack).isEmpty)
    }
}

/// Throws on its first `fails` calls, then forwards.
@MainActor final class FlakyRecorder: GameRecorder {
    struct Failed: Error {}
    var fails = 1
    private(set) var recorded: [FinishedGame] = []
    let inner: any GameRecorder
    init(_ inner: any GameRecorder) { self.inner = inner }
    func record(_ game: FinishedGame) throws {
        if fails > 0 { fails -= 1; throw Failed() }
        recorded.append(game)
        try inner.record(game)
    }
}

/// Codex plan 011 review 1, over real sessions on one `MemoryHub`: only a majority of the game's members saves.
@MainActor
@Suite(.serialized) struct GameQuorumSaveTests {
    let a = ShellPlayer(id: UUID(), name: "A1", symbol: "hare.fill", colorName: "teal")
    let b = ShellPlayer(id: UUID(), name: "B1", symbol: "bolt.fill", colorName: "orange")

    func game(_ stack: PersistenceStack, on link: MeshGameLink) -> GameSessionModel {
        let g = GameSessionModel(config: GameConfig(ruleSet: .barEight, tableSize: .sevenFoot, teams: [[a], [b]]))
        g.recorder = StackGameRecorder(stack: stack)
        g.mesh = link
        return g
    }

    /// A1 pots the 1, then sinks the 8 early: team 1 wins.
    func playARack(_ g: GameSessionModel) {
        g.shotSettled(SettledShot(rating: .best, turnPasses: false, outcome: GameRecorderTests.pot(1)))
        g.shotSettled(SettledShot(rating: .blunder, turnPasses: true, outcome: GameRecorderTests.eightEarly))
    }

    func gameCount(_ stack: PersistenceStack) throws -> Int { try stack.competitiveContext.fetchCount(FetchDescriptor<Game>()) }

    @Test func loneSurvivorOfATwoPhoneGameCommitsTheWinButNeverSaves() async throws {
        let hub = MemoryHub()
        let sessions = [MeshGameLinkTests.session(hub, device: 18), MeshGameLinkTests.session(hub, device: 16)]
        let links = sessions.map { MeshGameLink(session: $0) }
        links.forEach { $0.start() }
        #expect(await poll { links[0].isHost && links[1].isJoiner && links[1].gameMembers.count == 2 })
        #expect(links[0].hasGameQuorum, "both phones present")
        let stack = try PersistenceStack(inMemory: true)
        let g = game(stack, on: links[1])
        links[0].stop()
        hub.kill(sessions[0].localPeer)
        #expect(await poll(4) { links[1].isHost })
        playARack(g)
        #expect(await poll(3) { g.reviewData().winnerTeam == 1 }, "the lone survivor commits alone")
        #expect(!links[1].hasGameQuorum)
        #expect(try gameCount(stack) == 0)
        links[1].stop()
    }

    @Test func threePhoneGameWithTwoLeftStillSaves() async throws {
        let hub = MemoryHub()
        let sessions = (0..<3).map { MeshGameLinkTests.session(hub, device: 15 + $0) }
        let links = sessions.map { MeshGameLink(session: $0) }
        links.forEach { $0.start() }
        #expect(await poll { links[2].isHost && links[1].isJoiner && links[1].gameMembers.count == 3 })
        let stack = try PersistenceStack(inMemory: true)
        let g = game(stack, on: links[1])
        links[2].stop()
        hub.kill(sessions[2].localPeer)
        #expect(await poll(4) { links[1].isHost })
        playARack(g)
        #expect(await poll(3) { g.reviewData().winnerTeam == 1 })
        #expect(links[1].hasGameQuorum, "2 of 3")
        #expect(await poll(2) { (try? gameCount(stack)) == 1 })
        links[0].stop(); links[1].stop()
    }
}

/// Role unresolved: neither host nor joiner.
@MainActor final class DiscoveringLink: GameMeshLink {
    var peerCount = 2
    var isStopped = false
    var isHost: Bool { false }
    var isJoiner: Bool { false }
    var hasGameQuorum: Bool { false }
    var commitSeq: UInt64 = 0
    var onCommittedLog: (@MainActor ([LogEntry], UInt64) -> Void)?
    func start() {}
    func stop() {}
    func append(_ event: GameEvent) {}
}

import Foundation
import Testing
import Geometry
import Rules
import Engine
@testable import CueCoach

@MainActor
@Suite struct GameSessionModelTests {
    let a1 = ShellPlayer(id: UUID(), name: "A1", symbol: "hare.fill", colorName: "teal")
    let a2 = ShellPlayer(id: UUID(), name: "A2", symbol: "leaf.fill", colorName: "green")
    let b1 = ShellPlayer(id: UUID(), name: "B1", symbol: "bolt.fill", colorName: "orange")
    let b2 = ShellPlayer(id: UUID(), name: "B2", symbol: "flame.fill", colorName: "red")

    func teams() -> GameSessionModel {
        GameSessionModel(config: GameConfig(ruleSet: .barEight, tableSize: .eightFoot, teams: [[a1, a2], [b1, b2]]))
    }

    // Bar-8 outcomes on the open table the game starts from. The fold rates and rotates from the outcome (plan 009).
    /// A legal pot: the shooter keeps the table.
    static func pot(_ n: Int) -> ShotOutcome { ShotOutcome(firstContact: BallID(n)!, pocketed: [BallID(n)!: .footLeft]) }
    /// Nothing pocketed: the turn passes.
    static let miss = ShotOutcome(firstContact: BallID(1)!)
    /// The 8 on an open table: the shooter loses the rack.
    static let eightEarly = ShotOutcome(firstContact: .eight, pocketed: [.eight: .footLeft])

    @Test func firstShooterIsA1() {
        let s = teams()
        #expect(s.shooter == a1)
        #expect(s.shootingTeam == 0)
    }

    @Test func turnsRotateA1B1A2B2ThenWrap() {
        let s = teams()
        var seen: [String] = []
        for _ in 0..<5 { seen.append(s.shooter.name); s.passTurn() }
        #expect(seen == ["A1", "B1", "A2", "B2", "A1"])
    }

    @Test func legalPotKeepsTheSameShooter() {
        let s = teams()
        s.shotSettled(SettledShot(rating: .best, turnPasses: false, outcome: Self.pot(1)))
        #expect(s.shooter == a1)
        s.shotSettled(rating: .mistake, turnPasses: true)
        #expect(s.shooter == b1)
    }

    @Test func waitingShooterIsTheOtherTeamsNextPlayer() {
        let s = teams()
        #expect(s.waitingShooter == b1)
        s.passTurn()
        #expect(s.waitingShooter == a2)
    }

    @Test func joinerWithoutLineupHasNoTurnDiscs() {
        let s = GameSessionModel(config: GameConfig(ruleSet: .barEight, tableSize: .sevenFoot, teams: []))
        #expect(!s.hasLineup)
        s.handTurn(toTeam: 1)
        #expect(s.turnIndex == 0)
    }

    @Test func handToOtherTeamIsTheOneTapCorrection() {
        let s = teams()
        s.handTurn(toTeam: 1)
        #expect(s.shooter == b1)
        s.handTurn(toTeam: 1)   // already theirs: no change
        #expect(s.shooter == b1)
    }

    @Test func ratedShotsAreRecordedWithTheShooter() {
        let s = teams()
        s.shotSettled(rating: .great, turnPasses: true)
        s.shotSettled(rating: .blunder, turnPasses: true)
        #expect(s.shots.map(\.rating) == [.great, .blunder])
        #expect(s.shots.map(\.shooter) == [a1, b1])
        #expect(s.shots.map(\.team) == [0, 1])
    }

    @Test func badgeSignalNamesShooterAndTeam() throws {
        let s = teams()
        let sig = try #require(s.shotSettled(rating: .good, turnPasses: true))
        #expect(sig.rating == .good)
        #expect(sig.shooterName == "A1")
        #expect(sig.team == 0)
    }

    @Test func reviewDataHasTeamsShotsAndTable() {
        let s = teams()
        s.shotSettled(rating: .best, turnPasses: false)
        let d = s.reviewData()
        #expect(d.teams.map { $0.map(\.name) } == [["A1", "A2"], ["B1", "B2"]])
        #expect(d.shots.map(\.index) == [0])
        #expect(d.shots.first?.rating == .best)
        #expect(d.tableSize == .eightFoot)
        #expect(!d.isFinished)            // rack still on: the review must not claim a finished game
        #expect(d.winnerTeam == nil)
    }

    // Fix round (review finding 3): the header follows the rules state, not hardcoded values.
    @Test func reviewHeaderFollowsTheRulesWinner() {
        let s = teams()
        s.shotSettled(SettledShot(rating: .blunder, turnPasses: true, outcome: Self.eightEarly))   // A1 loses the rack
        let d = s.reviewData()
        #expect(d.winnerTeam == 1)
        #expect(d.score == [0, 1])        // one rack this session, won by team B
        #expect(d.isFinished)
    }

    @Test func quittingMidRackIsNotFinished() {
        let s = teams()
        s.shotSettled(rating: .good, turnPasses: true)
        let d = s.reviewData()
        #expect(!d.isFinished)
        #expect(d.winnerTeam == nil)
        #expect(d.score == [0, 0])
    }

    @Test func reviewShotsCarryTheSettledShotsResult() throws {
        let s = teams()
        s.shotSettled(SettledShot(rating: .mistake, turnPasses: true, isGuess: false,
                                  outcome: ShotOutcome(firstContact: BallID(3)!,
                                                       pocketed: [BallID(3)!: .footLeft, .cue: .sideRight])))
        s.shotSettled(SettledShot(rating: .good, turnPasses: false, isGuess: true,
                                  outcome: ShotOutcome(firstContact: BallID(9)!, pocketed: [BallID(9)!: .headRight])))
        let d = s.reviewData()
        try #require(d.shots.count == 2)
        #expect(d.shots[0].pocketed == [BallID(3)!: .footLeft, .cue: .sideRight])
        #expect(d.shots[0].fouls == [.scratch])
        #expect(!d.shots[0].isGuess)
        #expect(d.shots[1].pocketed == [BallID(9)!: .headRight])
        #expect(d.shots[1].fouls.isEmpty)
        #expect(d.shots[1].isGuess, "D31 best guess: never shown as camera-confirmed")
        #expect(d.shots[1].shooter?.name == "B1")
    }

    @Test func reviewWithNoShotsIsEmpty() {
        let d = teams().reviewData()
        #expect(d.shots.isEmpty)
    }

    @Test func reorderingATeamKeepsTheCurrentShooter() {
        let s = teams()
        s.passTurn()                      // B1 shooting
        s.swap(team: 0, 0, 1)             // team A order becomes A2, A1
        #expect(s.shooter == b1)
        #expect(s.rotation.map(\.name) == ["A2", "B1", "A1", "B2"])
        s.passTurn()
        #expect(s.shooter == a1)          // next A player in the new order
    }

    // Fix round (review finding 2): swapping the shooter's slot must not skip the other team's pending visit.
    @Test func swappingTheShootersSlotKeepsTheNextVisit() {
        let s = teams()                   // A1 shooting; order A1, B1, A2, B2
        s.swap(team: 0, 0, 1)             // team A order becomes A2, A1
        #expect(s.shooter == a1)          // A1 keeps the turn
        #expect(s.waitingShooter == b1)
        var seen: [String] = []
        for _ in 0..<4 { s.passTurn(); seen.append(s.shooter.name) }
        #expect(seen == ["B1", "A2", "B2", "A1"])
    }

    @Test func reorderIgnoresBadIndices() {
        let s = teams()
        s.swap(team: 0, 0, 5)
        s.swap(team: 3, 0, 1)
        #expect(s.rotation.map(\.name) == ["A1", "B1", "A2", "B2"])
    }

    @Test func pauseToggles() {
        let s = teams()
        #expect(!s.isMenuOpen)
        s.isMenuOpen = true
        #expect(s.isMenuOpen)
    }

    @Test func liveTeamMVPIsTheWinningTeamsBestRatedShooter() {
        let s = teams()
        // Rotation A1, B1, A2, B2 (D17). Team A (0) wins. A2 rates better than A1; B1 rates best but loses.
        s.shotSettled(rating: .okay, turnPasses: true)       // A1
        s.shotSettled(rating: .brilliant, turnPasses: true)  // B1 (losing team: never MVP)
        s.shotSettled(rating: .great, turnPasses: true)      // A2
        s.shotSettled(SettledShot(rating: .blunder, turnPasses: true, outcome: Self.eightEarly))   // B2 loses the rack
        let data = s.reviewData()
        #expect(!GameReviewModel(data: data).isLocked)
        for _ in 0..<20 { #expect(GameReviewModel(data: data).mvp?.player.name == "A2") }
    }

    // MARK: D38 / D41 (plan 008): a lost shot with no guess leaves a gap and asks who shoots next.

    @Test func tappingTheOtherDiscAfterALostShotHandsTheTurnAndKeepsTheGap() throws {
        let s = teams()
        var pushed: [Set<BallID>] = []
        s.legalChanged = { pushed.append($0) }
        s.shotLost()
        #expect(s.needsShooter)
        s.handTurn(toTeam: 1)
        #expect(!s.needsShooter)
        #expect(s.shooter == b1)
        #expect(pushed.count == 1, "the chosen team's legal targets are pushed")
        let gap = try #require(s.shots.first)
        #expect(gap.rating == nil)
        #expect(gap.shooter == a1 && gap.team == 0, "D41: a disc tap never changes the recorded shot")
    }

    @Test func tappingTheActiveDiscConfirmsTheSameShooter() {
        let s = teams()
        var pushed: [Set<BallID>] = []
        s.legalChanged = { pushed.append($0) }
        s.shotLost()
        let turns = s.turnIndex
        s.handTurn(toTeam: 0)
        #expect(!s.needsShooter)
        #expect(s.shooter == a1)
        #expect(s.turnIndex == turns, "same team: no hand-over")
        #expect(pushed.count == 1)
        s.handTurn(toTeam: 0)   // no ask open: still a no-op
        #expect(pushed.count == 1)
    }

    @Test func aNewShotClearsTheAsk() {
        let s = teams()
        let session = LiveSession(mode: .game, game: s, drill: nil)
        session.shotLost()
        #expect(s.needsShooter)
        session.aimStarted()
        #expect(!s.needsShooter)
        #expect(s.shooter == a1, "nobody tapped: the current shooter keeps the turn")
    }

    @Test func gapShotsNeverBecomeMVP() throws {
        // Team game, no WPA: A1 only has a gap, A2 a rated shot; team A wins.
        let s = teams()
        s.shotLost()                                          // A1: gap
        s.handTurn(toTeam: 1)                                 // B1
        s.shotSettled(rating: .okay, turnPasses: true)        // B1 → A2
        s.shotSettled(SettledShot(rating: .good, turnPasses: false, outcome: Self.pot(1)))   // A2 keeps the table
        s.shotSettled(rating: .okay, turnPasses: true)        // A2 misses → B2
        s.shotSettled(SettledShot(rating: .blunder, turnPasses: true, outcome: Self.eightEarly))   // B2 loses the rack
        let mvp = try #require(GameReviewModel(data: s.reviewData()).mvp)
        #expect(mvp.player.name == "A2")
        #expect(mvp.bestShot.rating != nil)
        // One-on-one: the winner's gap comes first; the best shot is still a rated one.
        let one = GameSessionModel(config: GameConfig(ruleSet: .barEight, tableSize: .eightFoot, teams: [[a1], [b1]]))
        one.shotLost()                                        // A1: gap
        one.handTurn(toTeam: 0)
        one.shotSettled(SettledShot(rating: .good, turnPasses: false, outcome: Self.pot(1)))   // A1 keeps the table
        one.shotSettled(rating: .okay, turnPasses: true)      // A1 misses → B1
        one.shotSettled(SettledShot(rating: .blunder, turnPasses: true, outcome: Self.eightEarly))   // B1 loses the rack
        let m1 = try #require(GameReviewModel(data: one.reviewData()).mvp)
        #expect(m1.player.name == "A1")
        #expect(m1.bestShot.rating != nil, "a gap is never the MVP's best shot")
    }

    // MARK: Plan 009: every phone folds one shot log (D39, D41, D38 via the log)

    func meshGame(host: Bool) -> (GameSessionModel, FakeGameMeshLink) {
        let s = teams()
        let link = FakeGameMeshLink(isHost: host)
        s.mesh = link
        return (s, link)
    }

    func record(_ outcome: ShotOutcome, rating: DecisionRating? = nil, team: Int = 0, id: UUID = UUID()) -> GameEvent {
        .shot(MeshShotRecord(shotID: id, shooterTeam: team, outcome: outcome, postState: nil, decisionRating: rating))
    }

    func entries(_ events: [GameEvent]) -> [LogEntry] {
        events.enumerated().map { LogEntry(seq: UInt64($0.offset + 1), term: 1, event: $0.element) }
    }

    @Test func soloSettleFoldsAtOnceAndShowsTheBadge() throws {
        let s = teams()
        let sig = try #require(s.shotSettled(SettledShot(rating: .good, turnPasses: false, outcome: Self.pot(1))))
        let shot = try #require(s.shots.first)
        #expect(s.shots.count == 1)
        #expect(shot.rating == .good && shot.shooter == a1 && shot.team == 0)
        #expect(shot.pocketed == [BallID(1)!: .footLeft])
        #expect(sig.shotID == shot.id)
        #expect(s.badge.current?.rating == .good)
        #expect(s.shooter == a1, "a legal pot keeps the table")
        s.shotSettled(SettledShot(rating: .mistake, turnPasses: true, outcome: Self.miss))
        #expect(s.shooter == b1)
        #expect(s.shots.map(\.rating) == [.good, .mistake])
    }

    @Test func hostSettleAppendsAShotAndShowsNothingUntilCommitted() throws {
        let (s, link) = meshGame(host: true)
        let before = [BallID.cue: Vec2(0.5, 0.5), BallID(1)!: Vec2(1, 0.5)]
        let sig = s.shotSettled(SettledShot(rating: .good, turnPasses: false, isGuess: true, before: before,
                                            after: [.cue: Vec2(0.9, 0.6)], outcome: Self.pot(1)))
        #expect(sig == nil)
        try #require(link.log.count == 1)
        guard case .shot(let r) = link.log[0].event else { Issue.record("not a shot"); return }
        #expect(r.shooterTeam == 0 && r.decisionRating == .good && r.isGuess)
        #expect(r.outcome == Self.pot(1))
        #expect(r.preState?.spec == TableSpec(size: .eightFoot))
        #expect(r.preState?.balls.mapValues(\.position) == before)
        #expect(r.postState?.balls.mapValues(\.position) == [.cue: Vec2(0.9, 0.6)])
        #expect(s.shots.isEmpty)
        #expect(s.badge.current == nil)
        #expect(s.turnIndex == 0)
    }

    @Test func hostSettleBadgeAndTurnFollowTheCommit() throws {
        let (s, link) = meshGame(host: true)
        s.shotSettled(SettledShot(rating: .okay, turnPasses: true, outcome: Self.miss))
        #expect(s.shooter == a1)
        link.commit()
        let shot = try #require(s.shots.first)
        guard case .shot(let r) = link.log[0].event else { Issue.record("not a shot"); return }
        #expect(shot.id == r.shotID)
        #expect(shot.rating == .okay && shot.shooter == a1)
        #expect(s.badge.current?.shotID == r.shotID)
        #expect(s.shooter == b1)
    }

    @Test func clientSettleAppendsNothing() {
        let (s, link) = meshGame(host: false)
        let sig = s.shotSettled(SettledShot(rating: .blunder, turnPasses: true, outcome: Self.miss))
        s.shotLost()
        #expect(sig == nil)
        #expect(link.log.isEmpty && link.proposals.isEmpty, "D39: only the host rates")
        #expect(s.shots.isEmpty)
        #expect(s.badge.current == nil)
        #expect(!s.needsShooter)
        #expect(s.shooter == a1)
    }

    @Test func clientShowsTheHostsCommittedRating() throws {
        let (s, link) = meshGame(host: false)
        s.shotSettled(SettledShot(rating: .blunder, turnPasses: true, outcome: Self.miss))   // its own camera: dropped
        let id = UUID()
        link.receive(entries([record(Self.pot(1), rating: .brilliant, id: id)]), commitSeq: 1)
        let shot = try #require(s.shots.first)
        #expect(s.shots.count == 1)
        #expect(shot.id == id && shot.rating == .brilliant && shot.shooter == a1)
        #expect(s.badge.current?.rating == .brilliant)
        #expect(s.shooter == a1)
        #expect(s.rules.1.groups?[0] == .solids, "the client's rules state follows the host's shot")
    }

    @Test func aRecordWithoutARatingIsClassifiedFromTheRules() throws {
        let (s, link) = meshGame(host: false)
        link.receive(entries([record(Self.pot(1)), record(Self.eightEarly)]), commitSeq: 2)
        #expect(s.shots.map(\.rating) == [.good, .blunder])
        #expect(s.reviewData().winnerTeam == 1)
    }

    @Test func foldCarriesBeforeAfterIntoSessionShots() throws {
        let before = [BallID.cue: Vec2(0.5, 0.5), BallID(1)!: Vec2(1, 0.5)]
        let after = [BallID.cue: Vec2(0.9, 0.6)]
        let solo = teams()
        solo.shotSettled(SettledShot(rating: .good, turnPasses: false, before: before, after: after, outcome: Self.pot(1)))
        let s1 = try #require(solo.shots.first)
        #expect(s1.before == before && s1.after == after)
        let (host, link) = meshGame(host: true)
        host.shotSettled(SettledShot(rating: .good, turnPasses: false, before: before, after: after, outcome: Self.pot(1)))
        link.commit()
        let s2 = try #require(host.shots.first)
        #expect(s2.before == before && s2.after == after)
        let (client, cl) = meshGame(host: false)
        cl.receive(link.log, commitSeq: 1)
        let s3 = try #require(client.shots.first)
        #expect(s3.before == before && s3.after == after)
        let empty = teams()
        empty.shotSettled(SettledShot(rating: .okay, turnPasses: true, outcome: Self.miss))
        #expect(empty.shots.first?.before.isEmpty == true && empty.shots.first?.after.isEmpty == true)
    }

    @Test func discTapAppendsNextShooterAndChangesNoRecordedShot() throws {
        let (s, link) = meshGame(host: true)
        s.shotSettled(SettledShot(rating: .okay, turnPasses: true, outcome: Self.miss))   // A1 misses → B1
        link.commit()
        var pushed: [Set<BallID>] = []
        s.legalChanged = { pushed.append($0) }
        s.handTurn(toTeam: 0)
        #expect(link.log.last?.event == .nextShooter(team: 0))
        #expect(s.shooter == b1, "nothing changes before the commit")
        #expect(pushed.isEmpty)
        link.commit()
        #expect(s.shooter == a2)
        #expect(pushed.count == 1, "the new shooter's legal targets are pushed once")
        let shot = try #require(s.shots.first)
        #expect(s.shots.count == 1)
        #expect(shot.shooter == a1 && shot.team == 0, "D41: a disc tap never edits a recorded shot")
        // A client's tap is a proposal to the host.
        let (c, cl) = meshGame(host: false)
        c.handTurn(toTeam: 1)
        #expect(cl.proposals == [.nextShooter(team: 1)])
        #expect(c.shooter == a1)
    }

    @Test func discTapBeforeTheFirstShotWorks() {
        let solo = teams()
        solo.handTurn(toTeam: 1)
        #expect(solo.shooter == b1)
        #expect(solo.shots.isEmpty)
        let (s, link) = meshGame(host: true)
        s.handTurn(toTeam: 1)
        #expect(link.log.map(\.event) == [.nextShooter(team: 1)])
        link.commit()
        #expect(s.shooter == b1)
        #expect(s.rules.1.shooter == 1)
    }

    @Test func shooterCorrectionMovesThatShotAndReplaysTheRotation() throws {
        let (s, link) = meshGame(host: false)
        let x = UUID(), y = UUID()
        link.receive(entries([record(Self.miss, rating: .okay, id: x), record(Self.miss, rating: .okay, id: y)]), commitSeq: 2)
        #expect(s.shots.map(\.shooter) == [a1, b1])
        link.receive(entries([record(Self.miss, rating: .okay, id: x), record(Self.miss, rating: .okay, id: y),
                              .shooterCorrection(shotID: x, team: 1)]), commitSeq: 3)
        try #require(s.shots.count == 2)
        #expect(s.shots[0].id == x && s.shots[0].team == 1 && s.shots[0].shooter == b1)
        #expect(s.shots[0].attribution == .tap)
        #expect(s.shots[1].id == y && s.shots[1].team == 0 && s.shots[1].shooter == a2)
        #expect(s.shots[1].attribution == .turnOrder)
        #expect(s.shooter == b2)
    }

    @Test func lostShotFoldsToAGapAndAsksForTheShooter() throws {
        let (s, link) = meshGame(host: true)
        let start = s.rules.1
        s.shotLost()
        guard case .shotLost(let id, let team)? = link.log.last?.event else { Issue.record("no shotLost"); return }
        #expect(team == 0)
        #expect(s.shots.isEmpty && !s.needsShooter, "nothing shows before the commit")
        link.commit()
        let gap = try #require(s.shots.first)
        #expect(gap.id == id && gap.rating == nil && gap.shooter == a1 && gap.team == 0)
        #expect(s.needsShooter)
        #expect(s.rules.1 == start, "a gap changes no rules state")
        #expect(s.badge.current == nil)
    }

    @Test func nextShooterClearsTheAsk() throws {
        let (s, link) = meshGame(host: true)
        s.shotLost()
        link.commit()
        s.handTurn(toTeam: 1)
        #expect(link.log.last?.event == .nextShooter(team: 1))
        link.commit()
        #expect(!s.needsShooter)
        #expect(s.shooter == b1)
        #expect(s.shots.first?.shooter == a1 && s.shots.first?.rating == nil, "the gap keeps its shooter")
        // The active team confirms itself while asked: still a logged event.
        let (t, tl) = meshGame(host: true)
        t.shotLost(); tl.commit()
        t.handTurn(toTeam: 0)
        tl.commit()
        #expect(tl.log.last?.event == .nextShooter(team: 0))
        #expect(!t.needsShooter && t.shooter == a1)
    }

    @Test func refoldIsIdempotentAndBadgeFiresOncePerShot() throws {
        let (s, link) = meshGame(host: false)
        let log = entries([record(Self.miss, rating: .okay)])
        link.receive(log, commitSeq: 1)
        #expect(s.badge.current?.rating == .okay)
        s.aimStarted(); s.aimEnded()
        #expect(s.badge.current == nil)
        link.receive(log, commitSeq: 1)
        #expect(s.badge.current == nil, "a re-fold never re-fires a shot's badge")
        #expect(s.shots.count == 1 && s.shooter == b1 && s.turnIndex == 1)
        let two = entries([record(Self.miss, rating: .okay), record(Self.pot(9), rating: .great, team: 1)])
        link.receive([log[0], two[1]], commitSeq: 2)
        #expect(s.badge.current?.rating == .great)
        #expect(s.shots.count == 2)
    }

    @Test func aLateJoinerShowsOnlyTheNewestBadge() {
        let (s, link) = meshGame(host: false)
        link.receive(entries([record(Self.miss, rating: .okay), record(Self.miss, rating: .mistake)]), commitSeq: 2)
        #expect(s.shots.count == 2)
        #expect(s.badge.current?.rating == .mistake)
    }

    @Test func uncommittedTailNeverShows() {
        let (s, link) = meshGame(host: false)
        link.receive(entries([record(Self.miss, rating: .okay), record(Self.miss, rating: .blunder)]), commitSeq: 1)
        #expect(s.shots.map(\.rating) == [.okay])
        #expect(s.badge.current?.rating == .okay)
        #expect(s.shooter == b1)
    }

    @Test func soloSwapKeepsTodaysBehaviour() {
        let s = teams()
        s.shotSettled(SettledShot(rating: .okay, turnPasses: true, outcome: Self.miss))   // A1 → B1
        s.swap(team: 0, 0, 1)                                                             // A: A2, A1
        #expect(s.rotation.map(\.name) == ["A2", "B1", "A1", "B2"])
        #expect(s.shooter == b1)
        s.shotSettled(SettledShot(rating: .okay, turnPasses: true, outcome: Self.miss))   // B1 → A's next slot
        #expect(s.shooter == a1)
        s.shotSettled(SettledShot(rating: .okay, turnPasses: true, outcome: Self.miss))   // A1 → B2
        #expect(s.shooter == b2)
        #expect(s.shots.map(\.shooter) == [a1, b1, a1])
        #expect(s.rotation.map(\.name) == ["A2", "B1", "A1", "B2"], "later re-folds keep the swap")
        // A swap of the shooter's own slot keeps them shooting through later folds.
        let t = teams()
        t.swap(team: 0, 0, 1)
        t.shotSettled(SettledShot(rating: .good, turnPasses: false, outcome: Self.pot(1)))
        #expect(t.shooter == a1 && t.shots.first?.shooter == a1)
    }

    @Test func meshSwapSurvivesACommit() {
        let (s, link) = meshGame(host: true)
        s.swap(team: 0, 0, 1)                    // A: A2, A1; A1 keeps the turn
        s.shotSettled(SettledShot(rating: .okay, turnPasses: true, outcome: Self.miss))
        link.commit()
        #expect(s.shots.first?.shooter == a1)
        #expect(s.rotation.map(\.name) == ["A2", "B1", "A1", "B2"])
        #expect(s.shooter == b1)
    }
}

/// Test double for the game's mesh link: a host appends to its log, a client proposes; `commit`/`receive` stand in
/// for the majority ack and the host's log arriving.
@MainActor final class FakeGameMeshLink: GameMeshLink {
    var peerCount = 2
    var isStopped = false
    let isHost: Bool
    private(set) var commitSeq: UInt64 = 0
    var onCommittedLog: (@MainActor ([LogEntry], UInt64) -> Void)?
    private(set) var log: [LogEntry] = []
    private(set) var proposals: [GameEvent] = []

    init(isHost: Bool) { self.isHost = isHost }
    func start() {}
    func stop() { isStopped = true }
    func append(_ event: GameEvent) {
        if isHost { log.append(LogEntry(seq: UInt64(log.count + 1), term: 1, event: event)) } else { proposals.append(event) }
    }
    /// A majority acked the whole log.
    func commit() {
        commitSeq = UInt64(log.count)
        onCommittedLog?(log, commitSeq)
    }
    /// The host's log reached this client.
    func receive(_ entries: [LogEntry], commitSeq: UInt64) {
        log = entries
        self.commitSeq = commitSeq
        onCommittedLog?(entries, commitSeq)
    }
}

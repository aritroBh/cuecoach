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
        s.shotSettled(rating: .best, turnPasses: false)
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

    @Test func badgeSignalNamesShooterAndTeam() {
        let s = teams()
        let sig = s.shotSettled(rating: .good, turnPasses: true)
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
        s.shotSettled(rating: .good, turnPasses: true)
        var g = s.rules.1
        g.phase = .over(winner: 1)
        s.rulesAdvanced(g)
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
        s.shotSettled(SettledShot(rating: .mistake, turnPasses: true, pocketed: [BallID(3)!: .footLeft, .cue: .sideRight],
                                  fouls: [.scratch]))
        s.shotSettled(SettledShot(rating: .good, turnPasses: false, pocketed: [BallID(9)!: .headRight], isGuess: true))
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
        var g = s.rules.1; g.phase = .over(winner: 0); s.rulesAdvanced(g)
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
        s.shotSettled(rating: .good, turnPasses: false)       // A2
        var g = s.rules.1; g.phase = .over(winner: 0); s.rulesAdvanced(g)
        let mvp = try #require(GameReviewModel(data: s.reviewData()).mvp)
        #expect(mvp.player.name == "A2")
        #expect(mvp.bestShot.rating != nil)
        // One-on-one: the winner's gap comes first; the best shot is still a rated one.
        let one = GameSessionModel(config: GameConfig(ruleSet: .barEight, tableSize: .eightFoot, teams: [[a1], [b1]]))
        one.shotLost()                                        // A1: gap
        one.handTurn(toTeam: 0)
        one.shotSettled(rating: .good, turnPasses: false)     // A1
        var g1 = one.rules.1; g1.phase = .over(winner: 0); one.rulesAdvanced(g1)
        let m1 = try #require(GameReviewModel(data: one.reviewData()).mvp)
        #expect(m1.player.name == "A1")
        #expect(m1.bestShot.rating != nil, "a gap is never the MVP's best shot")
    }
}

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
        #expect(d.isFinished)
        #expect(d.winnerTeam == nil)
    }

    @Test func reviewWithNoShotsIsEmpty() {
        let d = teams().reviewData()
        #expect(d.shots.isEmpty)
    }

    @Test func pauseToggles() {
        let s = teams()
        #expect(!s.isMenuOpen)
        s.isMenuOpen = true
        #expect(s.isMenuOpen)
    }
}

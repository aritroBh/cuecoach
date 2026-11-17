import Foundation
import SwiftData
import Geometry
import Rules
import Engine
import Testing
@testable import CueCoach

@MainActor
@Suite(.serialized) struct SessionEngineEvaluatorTests {
    private let p1 = ShellPlayer(id: UUID(), name: "A1", symbol: "hare.fill", colorName: "teal")
    private let p2 = ShellPlayer(id: UUID(), name: "B1", symbol: "bolt.fill", colorName: "orange")

    @Test func engineEvaluatorPopulatesWinProbAlternativeAndShotOfGameAndPersistsThem() async throws {
        let stack = try PersistenceStack(inMemory: true)
        let config = GameConfig(ruleSet: .wpaNine, tableSize: .sevenFoot, teams: [[p1], [p2]])
        let game = GameSessionModel(config: config)
        game.recorder = StackGameRecorder(stack: stack)
        game.engineEvaluator = SessionEngineEvaluator(seed: 42)

        let spec = TableSpec(size: .sevenFoot)
        let corner = spec.pocketCenter(.footRight)
        // Hanger setup: 1-ball near foot-right corner, 9-ball also on table.
        let layout: [BallID: Vec2] = [
            .cue: Vec2(0.8, 0.5),
            .one: Vec2(corner.x - 0.12, corner.y - 0.10),
            .nine: Vec2(corner.x - 0.22, corner.y - 0.08),
        ]

        // Shot 0 (break): legal dry break passes turn to Team 1.
        game.shotSettled(SettledShot(
            rating: .book, turnPasses: true,
            before: layout, after: layout,
            outcome: ShotOutcome(firstContact: .one, objectBallsToRailOnBreak: 4,
                                 objectBallsPastHeadStringOrPocketedOnBreak: 3)))

        // Shot 1 (Team 1): misses completely (foul no-contact) when 1-ball hanger was available → EngineAlternative!
        let afterFoul: [BallID: Vec2] = [
            .cue: Vec2(0.6, 0.4),
            .one: layout[.one]!,
            .nine: layout[.nine]!,
        ]
        game.shotSettled(SettledShot(
            rating: .mistake, turnPasses: true, fouls: [.noContact],
            before: layout, after: afterFoul,
            outcome: ShotOutcome(noContact: true)))

        // Shot 2 (Team 0): legally contacts the 1-ball and combos the 9-ball into foot-right to win the rack!
        let afterWin: [BallID: Vec2] = [
            .cue: Vec2(1.1, 0.55),
            .one: Vec2(1.4, 0.65),
        ]
        game.shotSettled(SettledShot(
            rating: .great, turnPasses: false,
            pocketed: [.nine: .footRight],
            before: afterFoul, after: afterWin,
            outcome: ShotOutcome(firstContact: .one, pocketed: [.nine: .footRight])))

        await game.awaitEngineEvaluation()

        let review = game.reviewData()
        #expect(review.winnerTeam == 0)
        #expect(review.winProb.count == 4, "Opening + 3 shots = 4 win-prob points")
        #expect(review.winProb.last == 1.0, "Team 0 won, so final Team-A win prob is 1.0")
        #expect(review.shots[1].alternative != nil, "Foul when a hanger was available produces an EngineAlternative ghost")
        #expect(review.shots[2].wpaDelta > 0)
        let sotg = try #require(review.shotOfGame)
        #expect(sotg.shotID == review.shots[2].id || sotg.shotID == review.shots[1].id)

        // Verify persisted Game + Shot + Highlight in Competitive.store were updated by the async pass.
        let savedGame = try #require(try stack.competitiveContext.fetch(FetchDescriptor<Game>()).first)
        #expect(savedGame.winProbSeries.count == 4)
        let savedShots = savedGame.shots.sorted { $0.index < $1.index }
        #expect(savedShots[1].alternative != nil)
        #expect(!savedGame.highlights.isEmpty)
        #expect(savedGame.highlights.first?.kind == .shotOfGame)
    }

    @Test func highlightLabelsFollowTwoWordNoDigitsRule() {
        for r in DecisionRating.allCases {
            for won in [false, true] {
                for safe in [false, true] {
                    let label = SessionEngineEvaluator.highlightLabel(rating: r, wonRack: won, isSafety: safe)
                    let words = label.split(separator: " ")
                    #expect(words.count >= 1 && words.count <= 2)
                    #expect(!label.contains(where: \.isNumber))
                }
            }
        }
    }
}

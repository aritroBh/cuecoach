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
        let one = BallID(1)!
        let layout: [BallID: Vec2] = [
            .cue: Vec2(0.8, 0.5),
            one: Vec2(corner.x - 0.12, corner.y - 0.10),
            .nine: Vec2(corner.x - 0.22, corner.y - 0.08),
        ]

        // Shot 0 (break): legal dry break passes turn to Team 1.
        game.shotSettled(SettledShot(
            rating: .book, turnPasses: true,
            before: layout, after: layout,
            outcome: ShotOutcome(firstContact: one, objectBallsToRailOnBreak: 4,
                                 objectBallsPastHeadStringOrPocketedOnBreak: 3)))

        // Shot 1 (Team 1): misses completely (foul no-contact) when 1-ball hanger was available → EngineAlternative!
        let afterFoul: [BallID: Vec2] = [
            .cue: Vec2(0.6, 0.4),
            one: layout[one]!,
            .nine: layout[.nine]!,
        ]
        game.shotSettled(SettledShot(
            rating: .mistake, turnPasses: true, fouls: [.noContact],
            before: layout, after: afterFoul,
            outcome: ShotOutcome(noContact: true)))

        // Shot 2 (Team 0): legally contacts the 1-ball and combos the 9-ball into foot-right to win the rack!
        let afterWin: [BallID: Vec2] = [
            .cue: Vec2(1.1, 0.55),
            one: Vec2(1.4, 0.65),
        ]
        game.shotSettled(SettledShot(
            rating: .great, turnPasses: false,
            pocketed: [.nine: .footRight],
            before: afterFoul, after: afterWin,
            outcome: ShotOutcome(firstContact: one, pocketed: [.nine: .footRight])))

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
                    #expect(label.allSatisfy { !$0.isNumber })
                }
            }
        }
    }

    @Test func foundationModelLabelValidatorEnforcesTwoWordsNoDigitsAndRefusalFallback() {
        let fb = "Rack Winner"
        #expect(FoundationModelLabeller.validated("bank wizard", fallback: fb) == "Bank Wizard")
        #expect(FoundationModelLabeller.validated("  clutch  ", fallback: fb) == "Clutch")
        // Rejects digits (D23 / vlm-benchmark Gemma "early 8-ball" failure mode).
        #expect(FoundationModelLabeller.validated("Early 8-Ball", fallback: fb) == fb)
        #expect(FoundationModelLabeller.validated("9 Ball", fallback: fb) == fb)
        // Rejects > 2 words, empty, game-echo tokens, and guardrail refusal strings.
        #expect(FoundationModelLabeller.validated("Three Word Label", fallback: fb) == fb)
        #expect(FoundationModelLabeller.validated("Eight Ball", fallback: fb) == fb)
        #expect(FoundationModelLabeller.validated("   ", fallback: fb) == fb)
        #expect(FoundationModelLabeller.validated("Sorry cannot", fallback: fb) == fb)
        #expect(FoundationModelLabeller.validated(nil, fallback: fb) == fb)
        // Sanitizes even a malformed fallback to the ultimate 2-word constant.
        #expect(FoundationModelLabeller.validated(nil, fallback: "Bad 9 Fallback") == FoundationModelLabeller.ultimateFallback)
    }

    private struct StubHighlightLabeller: HighlightLabelling {
        let response: String?
        func rawCandidate(for context: HighlightLabelContext) async -> String? { response }
    }

    @Test func evaluatorUsesFoundationModelLabelPostRackAndFallsBackOnInvalidOutput() async {
        let spec = TableSpec(size: .sevenFoot)
        let corner = spec.pocketCenter(.footRight)
        let one = BallID(1)!
        let pre: [BallID: Vec2] = [
            .cue: Vec2(0.8, 0.5),
            one: Vec2(corner.x - 0.12, corner.y - 0.10),
            .nine: Vec2(corner.x - 0.22, corner.y - 0.08),
        ]
        let post: [BallID: Vec2] = [.cue: Vec2(1.0, 0.55), one: Vec2(1.3, 0.65)]
        let winShot = SessionShot(
            id: UUID(), index: 0, shooter: p1, team: 0, rating: .great,
            pocketed: [.nine: .footRight], fouls: [], isGuess: false,
            before: pre, after: post, attribution: .turnOrder, firstContact: one,
            outcome: ShotOutcome(firstContact: one, pocketed: [.nine: .footRight]))

        let validEval = SessionEngineEvaluator(seed: 7, labeller: StubHighlightLabeller(response: "golden combo"))
        let validSummary = await validEval.evaluateRack(
            ruleSet: .wpaNine, tableSize: .sevenFoot, teamsCount: 2, shots: [winShot])
        #expect(validSummary.shotOfGame?.label == "Golden Combo")

        let badEval = SessionEngineEvaluator(seed: 7, labeller: StubHighlightLabeller(response: "Early 9 Ball"))
        let badSummary = await badEval.evaluateRack(
            ruleSet: .wpaNine, tableSize: .sevenFoot, teamsCount: 2, shots: [winShot])
        #expect(badSummary.shotOfGame?.label == "Rack Winner")
    }

    @Test func learnedSkillsFromCompetitiveHistoryExcludeUnconfirmedGamesAndDefaultNewPlayers() throws {
        let stack = try PersistenceStack(inMemory: true)
        let ctx = stack.competitiveContext
        let veteran = PlayerProfile(name: "Veteran", avatarSymbol: "star.fill", avatarColor: "teal", isLocalOwner: true)
        let rookie = PlayerProfile(name: "Rookie", avatarSymbol: "bolt.fill", avatarColor: "orange", isLocalOwner: false)
        ctx.insert(veteran)
        ctx.insert(rookie)

        let tbl = TableState(spec: TableSpec(size: .sevenFoot), balls: [.cue: BallState(position: Vec2(0.5, 0.5))])
        let features = StoredShotFeatures(cutBucket: .c15to30, distanceBucket: .mid, pocketType: .corner, kind: .plain)
        let teams = [
            StoredTeam(memberIDs: [veteran.id], shootingOrder: [veteran.id]),
            StoredTeam(memberIDs: [rookie.id], shootingOrder: [rookie.id]),
        ]
        let confirmedGame = Game(index: 0, ruleSet: .barEight, teams: teams, winnerTeam: 0,
                                 startedAt: .now, endedAt: .now, isUnconfirmed: false)
        ctx.insert(confirmedGame)

        // 16 clean pots for veteran → stronger (tighter noise) than `.reference`.
        for idx in 0..<16 {
            let s = Shot(
                index: idx, shooterID: veteran.id, attributionSource: .turnOrder,
                preState: tbl, postState: tbl, calledPocket: nil, firstContact: BallID(1),
                railsAfterContact: 1, pocketed: [BallID(1)!: .footRight], fouls: [],
                features: features, made: true, onTarget: true, cueResult: .inZone,
                decisionRating: .good, executionRating: ExecutionRating(result: .made, position: .inZone),
                wpaDelta: 0.05, isClutch: false, timeOnShot: 8.0, clipRef: nil, isGuess: false)
            s.game = confirmedGame
            ctx.insert(s)
        }

        // Unconfirmed island game for rookie (20 misses) MUST be ignored per D51/D53.
        let islandGame = Game(index: 0, ruleSet: .barEight, teams: teams, winnerTeam: 1,
                              startedAt: .now, endedAt: .now, isUnconfirmed: true)
        ctx.insert(islandGame)
        for idx in 0..<20 {
            let s = Shot(
                index: idx, shooterID: rookie.id, attributionSource: .turnOrder,
                preState: tbl, postState: tbl, calledPocket: nil, firstContact: BallID(2),
                railsAfterContact: 1, pocketed: [:], fouls: [],
                features: features, made: false, onTarget: false, cueResult: .notApplicable,
                decisionRating: .okay, executionRating: ExecutionRating(result: .miss, position: .notApplicable),
                wpaDelta: -0.05, isClutch: false, timeOnShot: 8.0, clipRef: nil, isGuess: false)
            s.game = islandGame
            ctx.insert(s)
        }
        // 15 intentional safeties + 15 disputed needsTap shots on confirmedGame for rookie MUST NOT count as missed pots.
        let safetyFeatures = StoredShotFeatures(cutBucket: .c15to30, distanceBucket: .mid, pocketType: .corner, kind: .safety)
        for idx in 16..<31 {
            let s = Shot(
                index: idx, shooterID: rookie.id, attributionSource: .turnOrder,
                preState: tbl, postState: tbl, calledPocket: nil, firstContact: BallID(2),
                railsAfterContact: 1, pocketed: [:], fouls: [],
                features: safetyFeatures, made: false, onTarget: true, cueResult: .notApplicable,
                decisionRating: .good, executionRating: ExecutionRating(result: .miss, position: .notApplicable),
                wpaDelta: 0.04, isClutch: false, timeOnShot: 8.0, clipRef: nil, isGuess: false,
                fullOutcome: ShotOutcome(firstContact: BallID(2), calledSafety: true))
            s.game = confirmedGame
            ctx.insert(s)
        }
        for idx in 31..<46 {
            let s = Shot(
                index: idx, shooterID: rookie.id, attributionSource: .turnOrder,
                preState: tbl, postState: tbl, calledPocket: nil, firstContact: BallID(2),
                railsAfterContact: 1, pocketed: [:], fouls: [],
                features: features, made: false, onTarget: false, cueResult: .notApplicable,
                decisionRating: .okay, executionRating: ExecutionRating(result: .miss, position: .notApplicable),
                wpaDelta: -0.04, isClutch: false, timeOnShot: 8.0, clipRef: nil, isGuess: false,
                needsTap: true)
            s.game = confirmedGame
            ctx.insert(s)
        }
        try ctx.save()

        let skills = PersistenceProfileStatsSource.learnedSkills(in: ctx, excludingGameID: nil)
        let vetSkill = try #require(skills[veteran.id])
        #expect(vetSkill.sigmaAim < SkillModel.reference.sigmaAim)
        #expect(skills[rookie.id] == nil, "Unconfirmed games, safeties, and disputed shots must not train competitive SkillModel")
        #expect(PersistenceProfileStatsSource.learnedSkills(in: ctx, excludingGameID: confirmedGame.id)[veteran.id] == nil)
    }
}

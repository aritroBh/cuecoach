import Foundation
import Geometry
import Rules
import Testing
@testable import Stats

@Suite("Rate")
struct RateTests {
    @Test func valueIsNilWithoutAttempts() {
        #expect(Rate().value == nil)
        #expect(Rate(successes: 1, attempts: 4).value == 0.25)
    }
    @Test func addition() {
        #expect(Rate(successes: 1, attempts: 2) + Rate(successes: 2, attempts: 3) == Rate(successes: 3, attempts: 5))
    }
    @Test func record() {
        var r = Rate()
        r.record(true); r.record(false); r.record(true)
        #expect(r == Rate(successes: 2, attempts: 3))
    }
}

@Suite("Aggregates — per game (SPEC §6)")
struct GameAggregateTests {
    @Test func attemptsMakesMissesOnTarget() {
        let g = cgame([
            cshot(alice, team: 0, made: true),
            cshot(alice, team: 0, made: true),
            cshot(alice, team: 0, made: false, onTarget: true),
            cshot(bob, team: 1, made: false),
            cshot(alice, team: 0, made: false),
        ])
        let a = Aggregates.game(g, player: alice)
        #expect(a.shots == 4)
        #expect(a.attempts == 4)
        #expect(a.makes == 2)
        #expect(a.misses == 2)
        #expect(a.pot == Rate(successes: 2, attempts: 4))
        #expect(a.onTarget == Rate(successes: 3, attempts: 4))
        #expect(Aggregates.game(g, player: bob).attempts == 1)
    }

    @Test func breaksAndSafetiesAreNotPotAttempts() {
        let g = cgame([
            cshot(alice, team: 0, made: true, isBreak: true, pocketedCount: 2),
            cshot(alice, team: 0, made: false, features: feat(kind: .safety)),
            cshot(bob, team: 1, made: false),
        ])
        let a = Aggregates.game(g, player: alice)
        #expect(a.shots == 2)
        #expect(a.attempts == 0)
        #expect(a.pot.value == nil)
    }

    @Test func potByBucket() {
        let g = cgame([
            cshot(alice, team: 0, made: true, features: feat(.c45to60, .long, .side, .bank)),
            cshot(alice, team: 0, made: false, features: feat(.c45to60, .mid, .corner, .plain)),
            cshot(alice, team: 0, made: true, features: feat(.c0to15, .long, .corner, .combo)),
        ])
        let a = Aggregates.game(g, player: alice)
        #expect(a.potByCut[.c45to60] == Rate(successes: 1, attempts: 2))
        #expect(a.potByCut[.c0to15] == Rate(successes: 1, attempts: 1))
        #expect(a.potByCut[.c60plus] == nil)
        #expect(a.potByDistance[.long] == Rate(successes: 2, attempts: 2))
        #expect(a.potByDistance[.mid] == Rate(successes: 0, attempts: 1))
        #expect(a.potByPocket[.side] == Rate(successes: 1, attempts: 1))
        #expect(a.potByPocket[.corner] == Rate(successes: 1, attempts: 2))
        #expect(a.potByKind[.bank] == Rate(successes: 1, attempts: 1))
        #expect(a.potByKind[.combo] == Rate(successes: 1, attempts: 1))
        #expect(a.potByKind[.safety] == nil)
    }

    @Test func positionSuccess_ignoresNotApplicable() {
        let g = cgame([
            cshot(alice, team: 0, made: true, cue: .inZone),
            cshot(alice, team: 0, made: true, cue: .outOfZone),
            cshot(alice, team: 0, made: true, cue: .inZone),
            cshot(alice, team: 0, made: false, cue: .notApplicable),
        ])
        #expect(Aggregates.game(g, player: alice).position == Rate(successes: 2, attempts: 3))
    }

    @Test func safetySuccess_opponentFailsNextShot() {
        let g = cgame([
            cshot(alice, team: 0, features: feat(kind: .safety)),
            cshot(bob, team: 1, made: false),                         // success for alice
            cshot(alice, team: 0, features: feat(kind: .safety)),
            cshot(bob, team: 1, made: true),                          // failure
            cshot(bob, team: 1, features: feat(kind: .safety)),
            cshot(alice, team: 0, made: true, fouled: true),         // a foul is a success for bob
            cshot(alice, team: 0, features: feat(kind: .safety), fouled: true), // fouled safety = failure
            cshot(bob, team: 1, made: false),
            cshot(alice, team: 0, features: feat(kind: .safety)),     // game ends: not counted
        ], winner: 0)
        #expect(Aggregates.game(g, player: alice).safety == Rate(successes: 1, attempts: 3))
        #expect(Aggregates.game(g, player: bob).safety == Rate(successes: 1, attempts: 1))
    }

    @Test func safetySuccess_teammateFollowUpIsSkipped() {
        // 2v2: the next shot by the *opposing team* decides, regardless of who on it shoots.
        let g = cgame([
            cshot(alice, team: 0, features: feat(kind: .safety)),
            cshot(bob, team: 1, made: false),
        ], players: [alice: 0, carol: 0, bob: 1])
        #expect(Aggregates.game(g, player: alice).safety == Rate(successes: 1, attempts: 1))
    }

    @Test func breakStats() {
        let g1 = cgame([cshot(alice, team: 0, made: true, isBreak: true, pocketedCount: 3)])
        let g2 = cgame([cshot(alice, team: 0, isBreak: true, pocketedCount: 0)])
        let g3 = cgame([cshot(alice, team: 0, made: true, fouled: true, isBreak: true, pocketedCount: 1)])
        let a = Aggregates.career([g1, g2, g3], player: alice)
        #expect(a.breaks.count == 3)
        #expect(a.breaks.ballsPocketed == 4)
        #expect(a.breaks.dry == 1)
        #expect(a.breaks.fouls == 1)
        #expect(abs(a.breaks.meanBallsPocketed! - 4.0 / 3) < 1e-12)
        #expect(BreakStats().meanBallsPocketed == nil)
    }

    @Test func foulsCountShotsWithAFoul() {
        let g = cgame([
            cshot(alice, team: 0, fouled: true),
            cshot(bob, team: 1, fouled: true),
            cshot(alice, team: 0, made: true),
        ])
        #expect(Aggregates.game(g, player: alice).fouls == 1)
    }

    @Test func wpaTotalAndClutchConversion() {
        let g = cgame([
            cshot(alice, team: 0, made: true, wpa: 0.12, clutch: true),
            cshot(alice, team: 0, made: false, wpa: -0.30, clutch: true),
            cshot(bob, team: 1, made: true, wpa: 0.4),
            cshot(alice, team: 0, made: true, fouled: true, wpa: -0.02, clutch: true),
            cshot(alice, team: 0, made: true, wpa: 0.05),
        ])
        let a = Aggregates.game(g, player: alice)
        #expect(abs(a.totalWPA - (-0.15)) < 1e-12)
        #expect(a.clutch == Rate(successes: 1, attempts: 3))
    }

    @Test func meanTimeOnShot() {
        let g = cgame([cshot(alice, team: 0, time: 10), cshot(alice, team: 0, time: 20), cshot(bob, team: 1, time: 99)])
        #expect(Aggregates.game(g, player: alice).meanTimeOnShot == 15)
        #expect(Aggregates.game(g, player: carol).meanTimeOnShot == nil)
    }

    @Test func gamesPlayedAndWon() {
        let g = cgame([cshot(alice, team: 0, made: true)], winner: 0)
        #expect(Aggregates.game(g, player: alice).games == 1)
        #expect(Aggregates.game(g, player: alice).wins == 1)
        #expect(Aggregates.game(g, player: bob).games == 1)   // on the roster
        #expect(Aggregates.game(g, player: bob).wins == 0)
        #expect(Aggregates.game(g, player: carol).games == 0) // not in this game
    }

    @Test func emptyAggregatesAreZero() {
        let a = Aggregates()
        #expect(a.shots == 0 && a.games == 0 && a.totalWPA == 0 && a.pot.value == nil && a.runOuts == 0)
    }
}

@Suite("Aggregates — run-outs and break-and-runs")
struct RunOutTests {
    @Test func breakAndRun() {
        let g = cgame([
            cshot(alice, team: 0, made: true, isBreak: true, pocketedCount: 1),
            cshot(alice, team: 0, made: true), cshot(alice, team: 0, made: true),
        ], winner: 0)
        let a = Aggregates.game(g, player: alice)
        #expect(a.breakAndRuns == 1)
        #expect(a.runOuts == 0)
    }

    @Test func runOutAfterOpponentVisit() {
        let g = cgame([
            cshot(bob, team: 1, isBreak: true, pocketedCount: 0),
            cshot(alice, team: 0, made: true), cshot(alice, team: 0, made: true), cshot(alice, team: 0, made: true),
        ], winner: 0)
        #expect(Aggregates.game(g, player: alice).runOuts == 1)
        #expect(Aggregates.game(g, player: alice).breakAndRuns == 0)
        #expect(Aggregates.game(g, player: bob).runOuts == 0)
    }

    @Test func shortWinningVisitIsNotARunOut() {
        let g = cgame([
            cshot(bob, team: 1, isBreak: true),
            cshot(alice, team: 0, made: true), cshot(alice, team: 0, made: true),
        ], winner: 0)
        #expect(Aggregates.game(g, player: alice).runOuts == 0)
    }

    @Test func losingTeamNeverRunsOut() {
        let g = cgame([
            cshot(bob, team: 1, isBreak: true),
            cshot(alice, team: 0, made: true), cshot(alice, team: 0, made: true), cshot(alice, team: 0, made: true),
        ], winner: 1)  // e.g. alice pocketed the 8 early on the last shot
        #expect(Aggregates.game(g, player: alice).runOuts == 0)
    }

    @Test func foulOrMissInVisitBreaksTheRun() {
        let g = cgame([
            cshot(bob, team: 1, isBreak: true),
            cshot(alice, team: 0, made: true), cshot(alice, team: 0, made: true, fouled: true),
            cshot(alice, team: 0, made: true), cshot(alice, team: 0, made: true),
        ], winner: 0)
        #expect(Aggregates.game(g, player: alice).runOuts == 0)
    }

    @Test func unfinishedGameHasNoRunOut() {
        let g = cgame([cshot(alice, team: 0, made: true, isBreak: true), cshot(alice, team: 0, made: true),
                       cshot(alice, team: 0, made: true), cshot(alice, team: 0, made: true)], winner: nil)
        let a = Aggregates.game(g, player: alice)
        #expect(a.runOuts == 0 && a.breakAndRuns == 0)
    }

    @Test func minimumIsConfigurable() {
        let g = cgame([cshot(bob, team: 1, isBreak: true), cshot(alice, team: 0, made: true)], winner: 0)
        #expect(Aggregates.game(g, player: alice, policy: AggregatePolicy(minRunOutShots: 1)).runOuts == 1)
    }
}

@Suite("Aggregates — career and trends")
struct CareerTests {
    @Test func careerSumsGames() {
        let g1 = cgame([cshot(alice, team: 0, made: true, wpa: 0.1)], winner: 0, at: 1)
        let g2 = cgame([cshot(alice, team: 0, made: false, wpa: -0.2)], winner: 1, at: 2)
        let a = Aggregates.career([g1, g2], player: alice)
        #expect(a.games == 2 && a.wins == 1)
        #expect(a.pot == Rate(successes: 1, attempts: 2))
        #expect(abs(a.totalWPA - (-0.1)) < 1e-12)
        #expect(a == Aggregates.game(g1, player: alice) + Aggregates.game(g2, player: alice))
    }

    @Test func careerDeduplicatesGamesByID() {
        let g = cgame([cshot(alice, team: 0, made: true)])
        #expect(Aggregates.career([g, g], player: alice).games == 1)
    }

    @Test func perPlayerCoversRoster() {
        let g = cgame([cshot(alice, team: 0, made: true), cshot(bob, team: 1)])
        let m = Aggregates.perPlayer(g)
        #expect(Set(m.keys) == [alice, bob])
        #expect(m[alice]?.makes == 1)
    }

    @Test func seriesIsChronological() {
        let late = cgame([cshot(alice, team: 0, made: false)], at: 200)
        let early = cgame([cshot(alice, team: 0, made: true)], at: 100)
        let other = cgame([cshot(bob, team: 1, made: true)], players: [bob: 1, carol: 0], at: 150)
        let s = Aggregates.series([late, other, early], player: alice) { $0.pot.value }
        #expect(s == [1.0, 0.0])
    }

    @Test func trendDirection() {
        #expect(Trend(series: [0.2, 0.2, 0.2, 0.6, 0.6, 0.6], window: 3) == .improving)
        #expect(Trend(series: [0.6, 0.6, 0.6, 0.2, 0.2, 0.2], window: 3) == .declining)
        #expect(Trend(series: [0.5, 0.5, 0.5, 0.52, 0.5, 0.5], window: 3) == .steady)
        #expect(Trend(series: [0.5, 0.9], window: 3) == .insufficientData)
        #expect(Trend(series: [nil, nil, nil, 0.1, 0.1, 0.1], window: 3) == .insufficientData)
    }

    @Test func aggregatesAreCodable() throws {
        let g = cgame([cshot(alice, team: 0, made: true, features: feat(.c30to45, .mid, .side, .bank), cue: .inZone)])
        let a = Aggregates.game(g, player: alice)
        #expect(try JSONDecoder().decode(Aggregates.self, from: JSONEncoder().encode(a)) == a)
    }

    @Test func competitiveShotIsCodable() throws {
        let s = cshot(alice, team: 0, made: true, fouled: true, isBreak: true, pocketedCount: 2, wpa: 0.3, clutch: true)
        #expect(try JSONDecoder().decode(CompetitiveShot.self, from: JSONEncoder().encode(s)) == s)
        let g = cgame([s])
        #expect(try JSONDecoder().decode(CompetitiveGame.self, from: JSONEncoder().encode(g)) == g)
    }

    @Test func cueResultRawValuesMatchApp() {
        #expect(CueResult.allCases.map(\.rawValue) == ["inZone", "outOfZone", "notApplicable"])
    }
}

@Suite("Aggregates — decision ratings (SPEC §6 per-shot ratings, supplied by the app from Engine)")
struct DecisionRatingAggregateTests {
    private func rated(_ who: UUID, team: Int, _ r: String?) -> CompetitiveShot {
        var s = cshot(who, team: team, made: true); s.decisionRating = r; return s
    }

    @Test func countsRatingsPerPlayerAndCareer() {
        let g1 = cgame([rated(alice, team: 0, "blunder"), rated(bob, team: 1, "great"),
                        rated(alice, team: 0, "great"), rated(alice, team: 0, nil)])
        let g2 = cgame([rated(alice, team: 0, "blunder")])
        #expect(Aggregates.game(g1, player: alice).decisionRatings == ["blunder": 1, "great": 1])
        #expect(Aggregates.game(g1, player: bob).decisionRatings == ["great": 1])
        #expect(Aggregates.career([g1, g2], player: alice).decisionRatings == ["blunder": 2, "great": 1])
    }

    @Test func ratingDefaultsToNilAndDecodesOldRows() throws {
        let s = cshot(alice, team: 0)
        #expect(s.decisionRating == nil)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(s)) as! [String: Any]
        json.removeValue(forKey: "decisionRating")
        let back = try JSONDecoder().decode(CompetitiveShot.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(back == s)
    }
}

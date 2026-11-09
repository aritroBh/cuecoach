import Foundation
import SwiftData
import Testing
import Geometry
import Rules
import Engine
@testable import CueCoach

@MainActor
@Suite struct GameReviewModelTests {
    let a1 = ReviewPlayer(id: UUID(), name: "Sam", symbol: "hare.fill", colorName: "orange")
    let b1 = ReviewPlayer(id: UUID(), name: "Ana", symbol: "tortoise.fill", colorName: "pink")

    func table(cue: Vec2 = Vec2(0.5, 0.5), eight: Vec2 = Vec2(1.5, 0.5)) -> TableState {
        var s = TableState(spec: TableSpec(size: .sevenFoot))
        s.balls[.cue] = BallState(position: cue)
        s.balls[.eight] = BallState(position: eight)
        return s
    }

    func shot(_ i: Int, _ r: DecisionRating?, by p: ReviewPlayer, team: Int, wpa: Double = 0,
              alt: EngineAlternative? = nil, broken: Bool = false) -> ReviewShot {
        ReviewShot(id: UUID(), index: i, shooter: p, team: team, rating: r,
                   pre: broken ? nil : table(), post: broken ? nil : table(cue: Vec2(1, 0.3)),
                   pocketed: [:], fouls: [], paths: [:], alternative: alt, wpaDelta: wpa)
    }

    func data(shots: [ReviewShot], series: [Double]? = nil, finished: Bool = true, winner: Int? = 0,
              sotg: UUID? = nil, teams: [[ReviewPlayer]]? = nil) -> GameReviewData {
        GameReviewData(gameIndex: 2, teams: teams ?? [[a1], [b1]], score: [8, 5], winnerTeam: winner,
                       isFinished: finished, winProb: series ?? Array(repeating: 0.5, count: shots.count + 1),
                       shots: shots, shotOfGame: sotg.map { ReviewHighlight(shotID: $0, label: "Bank Escape", hasClip: false) },
                       tableSize: .sevenFoot)
    }

    var alt: EngineAlternative {
        EngineAlternative(ghostCue: Vec2(1.2, 0.5), cuePath: [Vec2(0.5, 0.5), Vec2(1.2, 0.5)],
                          objectBall: .eight, objectPath: [Vec2(1.5, 0.5), Vec2(2.03, 0)], pocket: .footLeft)
    }

    @Test func loadsFromSourceAndSelectsShotOfTheGame() async {
        let shots = (0..<5).map { shot($0, .good, by: a1, team: 0) }
        let src = InMemoryGameReviewSource(data(shots: shots, sotg: shots[3].id))
        let m = GameReviewModel(source: src)
        #expect(m.phase == .loading)
        await m.load()
        #expect(m.phase == .loaded)
        #expect(m.selectedShot?.id == shots[3].id)
        #expect(m.shotOfGame?.id == shots[3].id)
    }

    @Test func failingSourceShowsError() async {
        let m = GameReviewModel(source: InMemoryGameReviewSource(nil))
        await m.load()
        #expect(m.phase == .failed)
    }

    @MainActor final class FlakySource: GameReviewSource {
        var fails: Int
        let payload: GameReviewData
        init(fails: Int, payload: GameReviewData) { self.fails = fails; self.payload = payload }
        func load() async throws -> GameReviewData {
            if fails > 0 { fails -= 1; throw ReviewLoadError() }
            return payload
        }
    }

    @Test func retryAfterFailureLoads() async {
        let shots = (0..<2).map { shot($0, .good, by: a1, team: 0) }
        let m = GameReviewModel(source: FlakySource(fails: 1, payload: data(shots: shots)))
        await m.load()
        #expect(m.phase == .failed)
        #expect(m.canRetry)
        await m.retry()
        #expect(m.phase == .loaded)
        #expect(m.shots.count == 2)
    }

    @Test func retryWithoutSourceIsUnavailable() async {
        let m = GameReviewModel(data: data(shots: []))
        #expect(!m.canRetry)
        await m.retry()
        #expect(m.phase == .loaded)
    }

    @Test func chartNeedsFourPoints() {
        let three = (0..<3).map { shot($0, .good, by: a1, team: 0) }
        let m = GameReviewModel(data: data(shots: three, series: [0.5, 0.6, 0.4]))
        #expect(!m.showsChart)
        let four = (0..<4).map { shot($0, .good, by: a1, team: 0) }
        #expect(GameReviewModel(data: data(shots: four)).showsChart)
    }

    @Test func winProbBeforeAndAfterUseSeriesOffset() {
        let shots = (0..<3).map { shot($0, .good, by: a1, team: 0) }
        let m = GameReviewModel(data: data(shots: shots, series: [0.5, 0.6, 0.7, 0.2]))
        #expect(m.winProbBefore(shots[1]) == 0.6)
        #expect(m.winProbAfter(shots[1]) == 0.7)
        // Series one per shot (no opening point): before shot 0 = 0.5.
        let n = GameReviewModel(data: data(shots: shots, series: [0.6, 0.7, 0.2]))
        #expect(n.winProbBefore(shots[0]) == 0.5)
        #expect(n.winProbAfter(shots[0]) == 0.6)
    }

    @Test func chartMarkersOnlySpecialAndBadShots() {
        let rs: [DecisionRating] = [.book, .brilliant, .good, .great, .mistake, .okay, .blunder, .inaccuracy]
        let shots = rs.enumerated().map { shot($0.offset, $0.element, by: a1, team: 0) }
        let m = GameReviewModel(data: data(shots: shots))
        #expect(m.chartMarkers.map(\.rating) == [.brilliant, .great, .mistake, .blunder])
    }

    @Test func selectionNextPreviousAndNearest() {
        let shots = (0..<4).map { shot($0, .good, by: a1, team: 0) }
        let m = GameReviewModel(data: data(shots: shots))
        m.select(shots[0].id)
        m.selectPrevious()
        #expect(m.selectedShot?.id == shots[0].id)
        m.selectNext()
        #expect(m.selectedShot?.id == shots[1].id)
        m.selectNearest(chartX: 2.6)
        #expect(m.selectedShot?.id == shots[3].id)
        m.selectNext()
        #expect(m.selectedShot?.id == shots[3].id)
    }

    @Test func alternativeShownOnlyBelowBest() {
        let good = shot(0, .good, by: a1, team: 0, alt: alt)
        let best = shot(1, .best, by: a1, team: 0, alt: alt)
        let unrated = shot(2, nil, by: a1, team: 0, alt: alt)
        let m = GameReviewModel(data: data(shots: [good, best, unrated]))
        #expect(m.showsAlternative(good))
        #expect(!m.showsAlternative(best))
        #expect(!m.showsAlternative(unrated))
    }

    @Test func mvpOneVsOneIsWinnersBestShot() {
        let shots = [shot(0, .good, by: a1, team: 0, wpa: 0.1),
                     shot(1, .brilliant, by: b1, team: 1, wpa: 0.5),
                     shot(2, .great, by: a1, team: 0, wpa: 0.3)]
        let m = GameReviewModel(data: data(shots: shots, winner: 0))
        #expect(m.mvp?.player.id == a1.id)
        #expect(m.mvp?.bestShot.id == shots[2].id)
    }

    @Test func mvpTeamGameIsHighestTotalWPA() {
        let a2 = ReviewPlayer(id: UUID(), name: "Bo", symbol: "bolt.fill", colorName: "purple")
        let b2 = ReviewPlayer(id: UUID(), name: "Kim", symbol: "flame.fill", colorName: "red")
        let shots = [shot(0, .good, by: a1, team: 0, wpa: 0.1),
                     shot(1, .great, by: b2, team: 1, wpa: 0.25),
                     shot(2, .good, by: a2, team: 0, wpa: 0.2),
                     shot(3, .good, by: b2, team: 1, wpa: 0.1)]
        let m = GameReviewModel(data: data(shots: shots, winner: 0, teams: [[a1, a2], [b1, b2]]))
        #expect(m.mvp?.player.id == b2.id)
        #expect(m.mvp?.bestShot.id == shots[1].id)
    }

    @Test func emptyAndLockedStates() {
        let e = GameReviewModel(data: data(shots: [shot(0, nil, by: a1, team: 0)]))
        #expect(e.isEmpty)
        let shots = (0..<4).map { shot($0, .good, by: a1, team: 0) }
        let l = GameReviewModel(data: data(shots: shots, finished: false, winner: nil))
        #expect(l.isLocked)
        #expect(l.mvp == nil)
        #expect(l.shotOfGame == nil)
    }

    @Test func undecodableShotIsUnavailable() {
        let s = shot(0, .good, by: a1, team: 0, broken: true)
        let m = GameReviewModel(data: data(shots: [s]))
        #expect(!m.isReplayAvailable(s))
        #expect(m.timelineStyle(s).symbol == "circle.dashed")
    }

    @Test func accessibilityUsesDirectionWordsNoNumbers() {
        let shots = (0..<2).map { shot($0, .brilliant, by: a1, team: 0) }
        let m = GameReviewModel(data: data(shots: shots, series: [0.5, 0.8, 0.8]))
        #expect(m.accessibilityLabel(shots[0]) == "Shot 1, Sam, Brilliant, Team A win chance up")
        #expect(m.accessibilityLabel(shots[1]) == "Shot 2, Sam, Brilliant, Team A win chance steady")
        #expect(m.accessibilityLabel(shots[0]).rangeOfCharacter(from: CharacterSet(charactersIn: "%")) == nil)
    }

    /// The eval-bar fallback (chart hidden, < 4 points) speaks direction words like every other win-chance path:
    /// never a percentage or any number (no numeric-precise advice).
    @Test func evalBarsAccessibilityUsesDirectionWordsNoNumbers() {
        let shots = (0..<2).map { shot($0, .good, by: a1, team: 0) }
        let up = GameReviewModel(data: data(shots: shots, series: [0.5, 0.6, 0.72]))
        #expect(up.evalBarsAccessibilityLabel == "Team A win chance up, Team A ahead")
        let down = GameReviewModel(data: data(shots: shots, series: [0.5, 0.4, 0.3]))
        #expect(down.evalBarsAccessibilityLabel == "Team A win chance down, Team B ahead")
        let even = GameReviewModel(data: data(shots: shots, series: [0.5, 0.51, 0.5]))
        #expect(even.evalBarsAccessibilityLabel == "Team A win chance steady, Even")
        for m in [up, down, even] {
            let label = m.evalBarsAccessibilityLabel ?? ""
            #expect(label.rangeOfCharacter(from: CharacterSet.decimalDigits.union(CharacterSet(charactersIn: "%"))) == nil)
        }
        #expect(GameReviewModel(data: data(shots: [])).evalBarsAccessibilityLabel == nil)
    }

    /// The chart's spoken y values share the same standing words.
    @Test func winChanceStandingWords() {
        #expect(GameReviewModel.standingWords(0.8) == "Team A ahead")
        #expect(GameReviewModel.standingWords(0.2) == "Team B ahead")
        #expect(GameReviewModel.standingWords(0.5) == "Even")
    }

    @Test func fallbackPathsAreStraightLinesForMovedBalls() {
        var pre = table(), post = table(cue: Vec2(1, 0.3))
        pre.balls[BallID(3)!] = BallState(position: Vec2(1.8, 0.2))
        post.balls[BallID(3)!] = BallState(position: Vec2(1.8, 0.2), motion: .pocketed)
        let paths = ReviewPaths.straight(pre: pre, post: post, pocketed: [BallID(3)!: .footLeft])
        #expect(paths[.cue] == [Vec2(0.5, 0.5), Vec2(1, 0.3)])
        #expect(paths[.eight] == nil)
        #expect(paths[BallID(3)!]?.last == pre.spec.pocketCenter(.footLeft))
    }

    @Test func adapterBuildsFromPersistedGame() throws {
        let stack = try PersistenceStack(inMemory: true)
        let ctx = stack.competitiveContext
        let ownerID = UUID(), guestID = UUID()
        ctx.insert(PlayerProfile(id: ownerID, name: "Ari", avatarSymbol: "person.fill", avatarColor: "teal", isLocalOwner: true))
        ctx.insert(PlayerProfile(id: guestID, name: "Sam", avatarSymbol: "hare.fill", avatarColor: "orange"))
        let session = Session(startedAt: .now, ruleSet: .barEight, format: .oneVsOne, tableSize: .eightFoot)
        ctx.insert(session)
        let teams = [StoredTeam(memberIDs: [ownerID], shootingOrder: [ownerID]),
                     StoredTeam(memberIDs: [guestID], shootingOrder: [guestID])]
        let g0 = Game(index: 0, ruleSet: .barEight, teams: teams, winnerTeam: 1, startedAt: .now, endedAt: .now)
        let g1 = Game(index: 1, ruleSet: .barEight, teams: teams, winnerTeam: 0, winProbSeries: [0.5, 0.7],
                      startedAt: .now, endedAt: .now)
        g0.session = session; g1.session = session
        ctx.insert(g0); ctx.insert(g1)
        let s = Shot(index: 0, shooterID: guestID, attributionSource: .auto, preState: table(), postState: table(cue: Vec2(1, 0.2)),
                     calledPocket: nil, firstContact: .eight, railsAfterContact: 0, pocketed: [:], fouls: [.scratch],
                     features: StoredShotFeatures(cutBucket: .c0to15, distanceBucket: .short, pocketType: .corner, kind: .plain),
                     made: false, onTarget: false, cueResult: .notApplicable, decisionRating: .mistake,
                     executionRating: ExecutionRating(result: .miss, position: .notApplicable), wpaDelta: -0.2,
                     isClutch: false, timeOnShot: 4, clipRef: nil)
        s.game = g1
        ctx.insert(s)
        let h = Highlight(shotID: s.id, kind: .shotOfGame, clipFile: "", label: "Bank Escape", score: 1)
        h.game = g1
        ctx.insert(h)
        try ctx.save()

        let d = GameReviewData(game: g1, profiles: try ctx.fetch(FetchDescriptor<PlayerProfile>()))
        #expect(d.gameIndex == 1)
        #expect(d.score == [1, 1])
        #expect(d.teams[1].first?.name == "Sam")
        #expect(d.shots.first?.team == 1)
        #expect(d.shots.first?.rating == .mistake)
        #expect(d.shots.first?.fouls == [.scratch])
        #expect(d.shots.first?.paths[.cue]?.count == 2)
        #expect(d.shotOfGame?.label == "Bank Escape")
        #expect(d.shotOfGame?.hasClip == false)
        #expect(d.tableSize == .eightFoot)
        #expect(d.isFinished)
    }

    // MARK: Replay layout

    @Test(arguments: [CGSize(width: 218, height: 100), CGSize(width: 361, height: 166), CGSize(width: 300, height: 120),
                      CGSize(width: 120, height: 300), CGSize(width: 900, height: 200)])
    func everyPocketMapsInsideTheCanvas(size: CGSize) {
        for t in TableSize.allCases {
            let spec = TableSpec(size: t)
            let l = ReplayLayout(size: size, spec: spec)
            let canvas = CGRect(origin: .zero, size: size)
            for p in spec.pockets {
                let c = l.point(spec.pocketCenter(p))
                #expect(canvas.insetBy(dx: -0.001, dy: -0.001).contains(c), "\(p) at \(c) outside \(size)")
                #expect(l.table.insetBy(dx: -0.001, dy: -0.001).contains(c))
            }
            // Same scale on both axes: the felt keeps the table's 2:1.
            #expect(abs(l.felt.width / l.felt.height - spec.length / spec.width) < 0.001)
            #expect(l.table.width <= size.width + 0.001 && l.table.height <= size.height + 0.001)
        }
    }

    @Test func replayAspectFillsTheCanvasExactly() {
        let spec = TableSpec(size: .eightFoot)
        let a = ReplayLayout.aspect(spec)
        let l = ReplayLayout(size: CGSize(width: 300 * a, height: 300), spec: spec)
        #expect(abs(l.table.width - 300 * a) < 0.01 && abs(l.table.height - 300) < 0.01)
    }

    // MARK: Inferred vs traced paths

    @Test func pathsWithoutTraceAreMarkedInferred() throws {
        let stack = try PersistenceStack(inMemory: true)
        let ctx = stack.competitiveContext
        let id = UUID()
        ctx.insert(PlayerProfile(id: id, name: "Sam", avatarSymbol: "hare.fill", avatarColor: "orange"))
        let teams = [StoredTeam(memberIDs: [id], shootingOrder: [id]), StoredTeam(memberIDs: [], shootingOrder: [])]
        let g = Game(index: 0, ruleSet: .barEight, teams: teams, winnerTeam: 0, startedAt: .now, endedAt: .now)
        ctx.insert(g)
        let s = Shot(index: 0, shooterID: id, attributionSource: .auto, preState: table(), postState: table(cue: Vec2(1, 0.2)),
                     calledPocket: nil, firstContact: .eight, railsAfterContact: 0, pocketed: [:], fouls: [],
                     features: StoredShotFeatures(cutBucket: .c0to15, distanceBucket: .short, pocketType: .corner, kind: .plain),
                     made: false, onTarget: false, cueResult: .notApplicable, decisionRating: .good,
                     executionRating: ExecutionRating(result: .miss, position: .notApplicable), wpaDelta: 0,
                     isClutch: false, timeOnShot: 4, clipRef: nil)
        s.game = g
        ctx.insert(s)
        try ctx.save()
        let profiles = try ctx.fetch(FetchDescriptor<PlayerProfile>())
        let inferred = GameReviewData(game: g, profiles: profiles)
        #expect(inferred.shots[0].pathsAreTraced == false)
        let m = GameReviewModel(data: inferred)
        #expect(!m.showsActualLegend(inferred.shots[0]))
        let traced = GameReviewData(game: g, profiles: profiles, analysis: FixedAnalysis(path: [Vec2(0.5, 0.5), Vec2(1, 0.2)]))
        #expect(traced.shots[0].pathsAreTraced)
        #expect(GameReviewModel(data: traced).showsActualLegend(traced.shots[0]))
    }

    // MARK: Shot of the Game clip

    @Test func playClipCallsHookOnlyWhenAClipExists() {
        let shots = [shot(0, .good, by: a1, team: 0), shot(1, .brilliant, by: a1, team: 0)]
        var d = data(shots: shots, sotg: shots[1].id)
        d.shotOfGame?.hasClip = true
        let m = GameReviewModel(data: d)
        var played: [UUID] = []
        m.onPlayClip = { played.append($0) }
        #expect(m.canPlayShotOfGameClip)
        m.playShotOfGameClip()
        #expect(played == [shots[1].id])

        d.shotOfGame?.hasClip = false
        let n = GameReviewModel(data: d)
        n.onPlayClip = { played.append($0) }
        #expect(!n.canPlayShotOfGameClip)
        n.playShotOfGameClip()
        #expect(played.count == 1)
    }
}

@MainActor private final class FixedAnalysis: ReviewShotAnalysis {
    let path: [Vec2]
    init(path: [Vec2]) { self.path = path }
    func actualPaths(shotID: UUID) -> [BallID: [Vec2]]? { [.cue: path] }
    func alternative(shotID: UUID) -> EngineAlternative? { nil }
}

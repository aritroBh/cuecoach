import Foundation
import Geometry
import Engine

/// In-memory sample games for previews, tests and the debug router.
@MainActor enum GameReviewSamples {
    static let sam = ReviewPlayer(id: UUID(), name: "Sam", symbol: "hare.fill", colorName: "orange")
    static let bo = ReviewPlayer(id: UUID(), name: "Bo", symbol: "bolt.fill", colorName: "purple")
    static let ana = ReviewPlayer(id: UUID(), name: "Ana", symbol: "tortoise.fill", colorName: "pink")
    static let kim = ReviewPlayer(id: UUID(), name: "Kim", symbol: "flame.fill", colorName: "red")

    private static let spec = TableSpec(size: .eightFoot)

    private static func rack(_ seed: Int) -> TableState {
        var s = TableState(spec: spec)
        let L = spec.length, W = spec.width
        s.balls[.cue] = BallState(position: Vec2(L * 0.22, W * (0.35 + 0.05 * Double(seed % 4))))
        let spots: [(Int, Double, Double)] = [(1, 0.62, 0.30), (2, 0.80, 0.70), (3, 0.70, 0.18), (6, 0.88, 0.40),
                                              (8, 0.55, 0.55), (9, 0.40, 0.80), (11, 0.33, 0.25), (14, 0.92, 0.85)]
        for (n, x, y) in spots { s.balls[BallID(n)!] = BallState(position: Vec2(L * x, W * y)) }
        return s
    }

    private static func shot(_ i: Int, _ r: DecisionRating?, _ p: ReviewPlayer, team: Int, wpa: Double,
                             pocket: (Int, Pocket)? = nil, foul: Bool = false, alt: Bool = false,
                             broken: Bool = false) -> ReviewShot {
        let pre = rack(i)
        var post = pre
        let L = spec.length, W = spec.width
        let cueEnd = Vec2(L * (0.45 + 0.03 * Double(i % 5)), W * (0.2 + 0.06 * Double(i % 7)))
        post.balls[.cue]?.position = cueEnd
        var pocketed: [BallID: Pocket] = [:]
        var paths: [BallID: [Vec2]] = [:]
        if let (n, pk) = pocket, let b = BallID(n) {
            post.balls[b]?.motion = .pocketed
            pocketed[b] = pk
            let contact = pre.balls[b]!.position + (pre.balls[b]!.position - spec.pocketCenter(pk)).normalized * (TableSpec.ballRadius * 2)
            paths[.cue] = [pre.balls[.cue]!.position, contact, cueEnd]
            paths[b] = [pre.balls[b]!.position, spec.pocketCenter(pk)]
        } else {
            paths[.cue] = [pre.balls[.cue]!.position, Vec2(L * 0.5, 0.03), cueEnd]
        }
        if foul {
            pocketed[.cue] = .sideRight
            post.balls[.cue]?.motion = .pocketed
            paths[.cue] = [pre.balls[.cue]!.position, spec.pocketCenter(.sideRight)]
        }
        let alternative = alt ? EngineAlternative(
            ghostCue: pre.balls[BallID(3)!]!.position + Vec2(-TableSpec.ballRadius * 2, TableSpec.ballRadius * 0.6),
            cuePath: [pre.balls[.cue]!.position, pre.balls[BallID(3)!]!.position + Vec2(-TableSpec.ballRadius * 2, TableSpec.ballRadius * 0.6)],
            objectBall: BallID(3)!, objectPath: [pre.balls[BallID(3)!]!.position, spec.pocketCenter(.sideLeft)],
            pocket: .sideLeft) : nil
        return ReviewShot(id: UUID(), index: i, shooter: p, team: team, rating: r,
                          pre: broken ? nil : pre, post: broken ? nil : post,
                          pocketed: pocketed, fouls: foul ? [.scratch] : [], paths: paths,
                          alternative: alternative, wpaDelta: wpa, pathsAreTraced: true)
    }

    static func finished() -> GameReviewData {
        var shots: [ReviewShot] = [
            shot(0, .book, sam, team: 0, wpa: 0.02),
            shot(1, .good, kim, team: 1, wpa: 0.04, pocket: (9, .headRight)),
            shot(2, .inaccuracy, kim, team: 1, wpa: -0.05, alt: true),
            shot(3, .great, bo, team: 0, wpa: 0.14, pocket: (1, .footLeft)),
            shot(4, .okay, bo, team: 0, wpa: 0.01),
            shot(5, .mistake, ana, team: 1, wpa: -0.12, alt: true),
            shot(6, .brilliant, sam, team: 0, wpa: 0.31, pocket: (6, .footLeft)),
            shot(7, .best, sam, team: 0, wpa: 0.05, pocket: (2, .footRight)),
            shot(8, .miss, sam, team: 0, wpa: -0.08, alt: true),
            shot(9, .blunder, kim, team: 1, wpa: -0.2, foul: true, alt: true),
            shot(10, .good, bo, team: 0, wpa: 0.06, pocket: (3, .footLeft)),
            shot(11, .best, bo, team: 0, wpa: 0.1, pocket: (8, .sideLeft)),
        ]
        // A D31 best guess (lost to a relock): review flags it rather than showing it as camera-confirmed.
        shots[10].isGuess = true
        let series = [0.5, 0.52, 0.48, 0.53, 0.67, 0.68, 0.56, 0.87, 0.92, 0.84, 0.96, 0.98, 1.0]
        return GameReviewData(gameIndex: 2, teams: [[sam, bo], [ana, kim]], score: [2, 1], winnerTeam: 0, isFinished: true,
                              winProb: series, shots: shots,
                              shotOfGame: ReviewHighlight(shotID: shots[6].id, label: "Bank Escape", hasClip: true),
                              tableSize: .eightFoot)
    }

    /// The selected shot's state failed to decode.
    static func withBrokenShot() -> GameReviewData {
        var d = finished()
        d.shots[6] = shot(6, nil, sam, team: 0, wpa: 0.31, broken: true)
        d.shotOfGame = ReviewHighlight(shotID: d.shots[6].id, label: "Bank Escape", hasClip: false)
        return d
    }

    static func inProgress() -> GameReviewData {
        var d = finished()
        d.shots = Array(d.shots.prefix(6))
        d.winProb = Array(d.winProb.prefix(7))
        d.isFinished = false
        d.winnerTeam = nil
        d.score = [1, 1]
        return d
    }

    static func empty() -> GameReviewData {
        GameReviewData(gameIndex: 0, teams: [[sam], [kim]], score: [0, 0], winnerTeam: nil, isFinished: true,
                       winProb: [0.5], shots: [shot(0, nil, sam, team: 0, wpa: 0)], shotOfGame: nil, tableSize: .eightFoot)
    }

    /// Fewer than four points: chart hides, eval bars show. No physics trace yet: paths are inferred.
    static func short() -> GameReviewData {
        var d = finished()
        d.shots = Array(d.shots.prefix(2)).map { s in
            var s = s
            if let pre = s.pre, let post = s.post {
                s.paths = ReviewPaths.straight(pre: pre, post: post, pocketed: s.pocketed)
            }
            s.pathsAreTraced = false
            return s
        }
        d.winProb = [0.5, 0.52, 0.48]
        d.teams = [[sam], [kim]]
        d.shotOfGame = ReviewHighlight(shotID: d.shots[1].id, label: "Clean Break", hasClip: false)
        return d
    }
}

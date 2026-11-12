import Foundation
import SwiftData
import Geometry
import Rules
import Engine

struct ReviewPlayer: Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    var symbol: String
    var colorName: String
}

/// The engine's preferred shot, ghosted in the replay.
struct EngineAlternative: Hashable, Sendable {
    var ghostCue: Vec2
    var cuePath: [Vec2]
    var objectBall: BallID
    var objectPath: [Vec2]
    var pocket: Pocket
}

struct ReviewShot: Identifiable, Hashable, Sendable {
    var id: UUID
    var index: Int
    var shooter: ReviewPlayer?
    var team: Int
    /// nil = unrated (engine timeout).
    var rating: DecisionRating?
    /// nil = state failed to decode.
    var pre: TableState?
    var post: TableState?
    var pocketed: [BallID: Pocket]
    var fouls: [Foul]
    /// Actual ball paths (table metres). Physics trace when available, else straight pre→post.
    var paths: [BallID: [Vec2]]
    var alternative: EngineAlternative?
    var wpaDelta: Double
    /// True when `paths` came from a physics trace. False = inferred straight before→after segments, which can
    /// cut through balls and rails (banks, kicks), so the diagram draws only faint displacement arrows.
    var pathsAreTraced = false
    /// D31: the shot was lost to a relock; `pocketed` is a best guess, never shown as camera-confirmed.
    var isGuess = false
}

struct ReviewHighlight: Hashable, Sendable {
    var shotID: UUID
    var label: String
    var hasClip: Bool
}

struct GameReviewData: Hashable, Sendable {
    var gameIndex: Int
    var teams: [[ReviewPlayer]]
    /// Games won per team in the session so far.
    var score: [Int]
    var winnerTeam: Int?
    var isFinished: Bool
    /// P(Team A wins), `shots.count + 1` points (opening + after each shot) or one per shot.
    var winProb: [Double]
    var shots: [ReviewShot]
    var shotOfGame: ReviewHighlight?
    var tableSize: TableSize
}

// MARK: - Dependencies (local protocols)

@MainActor protocol GameReviewSource: AnyObject {
    func load() async throws -> GameReviewData
}

/// Physics traces and engine alternatives (Engine/Physics agents implement this later).
@MainActor protocol ReviewShotAnalysis: AnyObject {
    func actualPaths(shotID: UUID) -> [BallID: [Vec2]]?
    func alternative(shotID: UUID) -> EngineAlternative?
}

struct ReviewLoadError: Error {}

@MainActor final class InMemoryGameReviewSource: GameReviewSource {
    let data: GameReviewData?
    var delay: Duration?
    init(_ data: GameReviewData?, delay: Duration? = nil) { self.data = data; self.delay = delay }
    func load() async throws -> GameReviewData {
        if let delay { try await Task.sleep(for: delay) }
        guard let data else { throw ReviewLoadError() }
        return data
    }
}

enum ReviewPaths {
    /// Straight segments for every ball that moved; pocketed balls end in their pocket.
    static func straight(pre: TableState, post: TableState, pocketed: [BallID: Pocket]) -> [BallID: [Vec2]] {
        var out: [BallID: [Vec2]] = [:]
        for (id, before) in pre.balls where before.motion != .pocketed {
            let end: Vec2?
            if let pocket = pocketed[id] { end = pre.spec.pocketCenter(pocket) }
            else if let after = post.balls[id], after.motion != .pocketed { end = after.position }
            else { end = nil }
            if let end, end.distance(to: before.position) > 0.005 { out[id] = [before.position, end] }
        }
        return out
    }
}

// MARK: - Persistence adapter (reads only)

extension GameReviewData {
    @MainActor
    init(game: Game, profiles: [PlayerProfile], analysis: (any ReviewShotAnalysis)? = nil) {
        let byID = Dictionary(profiles.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func player(_ id: UUID) -> ReviewPlayer? {
            byID[id].map { ReviewPlayer(id: $0.id, name: $0.name, symbol: $0.avatarSymbol, colorName: $0.avatarColor) }
        }
        let stored = game.teams
        let teams = stored.map { t in t.shootingOrder.compactMap(player) }
        func team(of id: UUID) -> Int { stored.firstIndex { $0.memberIDs.contains(id) } ?? 0 }

        let shots = game.shots.sorted { $0.index < $1.index }.map { s -> ReviewShot in
            let pre = s.preState, post = s.postState
            // A D31 guess has no camera-seen after table: no replay rather than a made-up one (as live review).
            let decodable = !pre.balls.isEmpty && !s.isGuess
            let pocketed = s.pocketed
            let traced = analysis?.actualPaths(shotID: s.id)
            let paths = s.isGuess ? [:]
                : traced ?? (decodable ? ReviewPaths.straight(pre: pre, post: post, pocketed: pocketed) : [:])
            return ReviewShot(id: s.id, index: s.index, shooter: player(s.shooterID), team: team(of: s.shooterID),
                              rating: s.decisionRating, pre: decodable ? pre : nil, post: decodable ? post : nil,
                              pocketed: pocketed, fouls: s.fouls, paths: paths,
                              alternative: analysis?.alternative(shotID: s.id), wpaDelta: s.wpaDelta,
                              pathsAreTraced: traced != nil && !s.isGuess, isGuess: s.isGuess)
        }

        var score = [0, 0]
        for g in game.session?.games ?? [game] where g.index <= game.index && g.endedAt != nil {
            if let w = g.winnerTeam, score.indices.contains(w) { score[w] += 1 }
        }
        let sotg = game.highlights.first { $0.kind == .shotOfGame }.map {
            ReviewHighlight(shotID: $0.shotID, label: $0.label, hasClip: !$0.clipFile.isEmpty)
        }
        self.init(gameIndex: game.index, teams: teams.count == 2 ? teams : teams + Array(repeating: [], count: max(0, 2 - teams.count)),
                  score: score, winnerTeam: game.winnerTeam, isFinished: game.endedAt != nil,
                  winProb: game.winProbSeries, shots: shots, shotOfGame: sotg,
                  tableSize: game.session?.tableSize ?? shots.first?.pre?.spec.size ?? .sevenFoot)
    }
}

/// Loads a persisted game from the competitive store.
@MainActor final class PersistenceGameReviewSource: GameReviewSource {
    let stack: PersistenceStack
    let gameID: UUID
    let analysis: (any ReviewShotAnalysis)?
    init(stack: PersistenceStack, gameID: UUID, analysis: (any ReviewShotAnalysis)? = nil) {
        self.stack = stack; self.gameID = gameID; self.analysis = analysis
    }
    func load() async throws -> GameReviewData {
        let id = gameID
        let ctx = stack.competitiveContext
        guard let game = try ctx.fetch(FetchDescriptor<Game>(predicate: #Predicate { $0.id == id })).first else { throw ReviewLoadError() }
        return GameReviewData(game: game, profiles: try ctx.fetch(FetchDescriptor<PlayerProfile>()), analysis: analysis)
    }
}

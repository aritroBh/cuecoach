import Foundation

// Per-game and career aggregates (SPEC §6). Computed from `CompetitiveShot`s on demand — never stored
// (docs/SCHEMA.md: "computed ... so they can never drift from source data").

/// successes / attempts; `value` is `nil` when there were no attempts.
public struct Rate: Hashable, Codable, Sendable {
    public var successes: Int
    public var attempts: Int
    public init(successes: Int = 0, attempts: Int = 0) {
        self.successes = successes
        self.attempts = attempts
    }
    public var value: Double? { attempts > 0 ? Double(successes) / Double(attempts) : nil }
    public mutating func record(_ success: Bool) {
        attempts += 1
        if success { successes += 1 }
    }
    public static func + (a: Rate, b: Rate) -> Rate {
        Rate(successes: a.successes + b.successes, attempts: a.attempts + b.attempts)
    }
}

public struct BreakStats: Hashable, Codable, Sendable {
    public var count = 0
    public var ballsPocketed = 0
    /// Breaks that pocketed nothing.
    public var dry = 0
    /// Breaks with any foul (scratch, illegal break …).
    public var fouls = 0
    public init() {}
    public var meanBallsPocketed: Double? { count > 0 ? Double(ballsPocketed) / Double(count) : nil }
    public static func + (a: BreakStats, b: BreakStats) -> BreakStats {
        var r = BreakStats()
        r.count = a.count + b.count
        r.ballsPocketed = a.ballsPocketed + b.ballsPocketed
        r.dry = a.dry + b.dry
        r.fouls = a.fouls + b.fouls
        return r
    }
}

/// House conventions for derived stats (not specified by SPEC §6; flagged for user review).
public struct AggregatePolicy: Hashable, Codable, Sendable {
    /// A game-winning visit (not starting with the break) needs at least this many shots to be a run-out.
    public var minRunOutShots: Int
    public init(minRunOutShots: Int = 3) { self.minRunOutShots = minRunOutShots }
    public static let standard = AggregatePolicy()
}

public struct Aggregates: Hashable, Codable, Sendable {
    public var games = 0
    public var wins = 0
    /// Every shot taken (breaks and safeties included).
    public var shots = 0
    /// Pot attempts (not breaks, not safeties).
    public var attempts = 0
    public var makes = 0
    public var misses: Int { attempts - makes }
    public var pot = Rate()
    public var onTarget = Rate()
    public var potByCut: [CutBucket: Rate] = [:]
    public var potByDistance: [DistanceBucket: Rate] = [:]
    public var potByPocket: [PocketType: Rate] = [:]
    public var potByKind: [ShotKind: Rate] = [:]
    /// Cue ball in the intended zone (shots with a zone only).
    public var position = Rate()
    /// Safety succeeded: the opposing team's next shot pocketed nothing or fouled. A fouled safety fails;
    /// a safety with no following opposing shot is not counted.
    public var safety = Rate()
    public var breaks = BreakStats()
    /// Shots with at least one foul.
    public var fouls = 0
    public var runOuts = 0
    public var breakAndRuns = 0
    public var totalWPA = 0.0
    /// Clutch pot attempts made without a foul.
    public var clutch = Rate()
    public var totalTimeOnShot = 0.0
    public var timedShots = 0

    public init() {}

    public var meanTimeOnShot: Double? { timedShots > 0 ? totalTimeOnShot / Double(timedShots) : nil }

    // MARK: Computation

    /// One player's aggregates for one game. A player not on the roster and with no shots gets `Aggregates()`.
    public static func game(_ g: CompetitiveGame, player: UUID, policy: AggregatePolicy = .standard) -> Aggregates {
        var a = Aggregates()
        guard g.players.contains(player) else { return a }
        a.games = 1
        let team = g.teamOf[player] ?? g.shots.first { $0.shooterID == player }?.team
        if let w = g.winnerTeam, w == team { a.wins = 1 }

        for (i, s) in g.shots.enumerated() where s.shooterID == player {
            a.shots += 1
            a.totalWPA += s.wpaDelta
            if s.timeOnShot.isFinite, s.timeOnShot >= 0 { a.totalTimeOnShot += s.timeOnShot; a.timedShots += 1 }
            if s.fouled { a.fouls += 1 }
            switch s.cueResult {
            case .inZone: a.position.record(true)
            case .outOfZone: a.position.record(false)
            case .notApplicable: break
            }
            if s.isBreak {
                a.breaks.count += 1
                a.breaks.ballsPocketed += max(0, s.objectBallsPocketed)
                if s.objectBallsPocketed <= 0 { a.breaks.dry += 1 }
                if s.fouled { a.breaks.fouls += 1 }
            } else if s.isSafety {
                if s.fouled {
                    a.safety.record(false)
                } else if let reply = g.shots[(i + 1)...].first(where: { $0.team != s.team }) {
                    a.safety.record(!reply.made || reply.fouled)
                }
            } else {
                a.attempts += 1
                if s.made { a.makes += 1 }
                a.pot.record(s.made)
                a.onTarget.record(s.onTarget)
                a.potByCut[s.features.cutBucket, default: Rate()].record(s.made)
                a.potByDistance[s.features.distanceBucket, default: Rate()].record(s.made)
                a.potByPocket[s.features.pocketType, default: Rate()].record(s.made)
                a.potByKind[s.features.kind, default: Rate()].record(s.made)
                if s.isClutch { a.clutch.record(s.made && !s.fouled) }
            }
        }

        // Run-outs: the final visit (consecutive shots by one player) wins the game with no miss or foul.
        if let w = g.winnerTeam, let last = g.shots.last, last.shooterID == player, last.team == w {
            let start = (g.shots.lastIndex { $0.shooterID != player } ?? -1) + 1
            let visit = g.shots[start...]
            let clean = visit.allSatisfy { !$0.fouled && $0.made && !$0.isSafety }
            if clean {
                if start == 0, visit.first?.isBreak == true { a.breakAndRuns = 1 }
                else if visit.first?.isBreak == false, visit.count >= policy.minRunOutShots { a.runOuts = 1 }
            }
        }
        return a
    }

    /// Career aggregates over distinct games (deduplicated by game id).
    public static func career(_ games: [CompetitiveGame], player: UUID, policy: AggregatePolicy = .standard) -> Aggregates {
        var seen = Set<UUID>()
        return games.filter { seen.insert($0.id).inserted }
            .map { game($0, player: player, policy: policy) }
            .reduce(Aggregates(), +)
    }

    /// Aggregates for every player in the game.
    public static func perPlayer(_ g: CompetitiveGame, policy: AggregatePolicy = .standard) -> [UUID: Aggregates] {
        Dictionary(uniqueKeysWithValues: g.players.map { ($0, game(g, player: $0, policy: policy)) })
    }

    /// Per-game values of `metric`, oldest first, for games the player took part in.
    public static func series(_ games: [CompetitiveGame], player: UUID, policy: AggregatePolicy = .standard,
                              _ metric: (Aggregates) -> Double?) -> [Double?] {
        var seen = Set<UUID>()
        return games.filter { $0.players.contains(player) && seen.insert($0.id).inserted }
            .sorted { $0.startedAt < $1.startedAt }
            .map { metric(game($0, player: player, policy: policy)) }
    }

    public static func + (a: Aggregates, b: Aggregates) -> Aggregates {
        var r = Aggregates()
        r.games = a.games + b.games
        r.wins = a.wins + b.wins
        r.shots = a.shots + b.shots
        r.attempts = a.attempts + b.attempts
        r.makes = a.makes + b.makes
        r.pot = a.pot + b.pot
        r.onTarget = a.onTarget + b.onTarget
        r.potByCut = a.potByCut.merging(b.potByCut, uniquingKeysWith: +)
        r.potByDistance = a.potByDistance.merging(b.potByDistance, uniquingKeysWith: +)
        r.potByPocket = a.potByPocket.merging(b.potByPocket, uniquingKeysWith: +)
        r.potByKind = a.potByKind.merging(b.potByKind, uniquingKeysWith: +)
        r.position = a.position + b.position
        r.safety = a.safety + b.safety
        r.breaks = a.breaks + b.breaks
        r.fouls = a.fouls + b.fouls
        r.runOuts = a.runOuts + b.runOuts
        r.breakAndRuns = a.breakAndRuns + b.breakAndRuns
        r.totalWPA = a.totalWPA + b.totalWPA
        r.clutch = a.clutch + b.clutch
        r.totalTimeOnShot = a.totalTimeOnShot + b.totalTimeOnShot
        r.timedShots = a.timedShots + b.timedShots
        return r
    }
}

/// Direction of a per-game series: mean of the last `window` values vs the `window` before them.
public enum Trend: String, Codable, Sendable {
    case improving, declining, steady, insufficientData

    public init(series: [Double?], window: Int = 5, tolerance: Double = 0.05) {
        let v = series.compactMap { $0 }.filter(\.isFinite)
        guard window > 0, v.count >= 2 * window else { self = .insufficientData; return }
        let recent = v.suffix(window).reduce(0, +) / Double(window)
        let before = v.dropLast(window).suffix(window).reduce(0, +) / Double(window)
        let d = recent - before
        self = d > tolerance ? .improving : d < -tolerance ? .declining : .steady
    }
}

// Encode enum-keyed dictionaries as JSON objects.
extension CutBucket: CodingKeyRepresentable {}
extension DistanceBucket: CodingKeyRepresentable {}
extension PocketType: CodingKeyRepresentable {}
extension ShotKind: CodingKeyRepresentable {}

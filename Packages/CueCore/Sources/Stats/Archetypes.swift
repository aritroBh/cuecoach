import Foundation

// Play-style archetypes (SPEC §7). Competitive data only: inputs are `CompetitiveGame`s.

/// Archetype vector dimensions, each in [0, 1]. Raw values are the persisted vector keys and the
/// `ProProfiles.json` trait keys — never rename a case.
public enum ArchetypeDimension: String, CaseIterable, Codable, Sendable, CodingKeyRepresentable {
    /// Pot % on thin cuts (≥ 45°).
    case cut
    /// Pot % on long shots.
    case long
    /// Pot % into side pockets.
    case side
    /// Clutch conversion.
    case clutch
    /// Safety success rate.
    case safety
    /// Mean object balls pocketed per break ÷ 3, clamped to 1.
    case breakPower
    /// (Run-outs + break-and-runs) per game.
    case runOut
    /// Pot % on banks and kicks.
    case bank
    /// Overall pot %.
    case pot
    /// Cue-ball position success.
    case position
}

/// The eight SPEC §7 archetypes. Raw values are persisted (`ArchetypeSnapshot.tags`) — never rename.
public enum ArchetypeTag: String, CaseIterable, Codable, Sendable {
    case cutArtist, longGun, sidePocketSniper, iceVeins, safetyChess, cannonBreak, runOutMachine, bankWizard

    public var dimension: ArchetypeDimension {
        switch self {
        case .cutArtist: .cut
        case .longGun: .long
        case .sidePocketSniper: .side
        case .iceVeins: .clutch
        case .safetyChess: .safety
        case .cannonBreak: .breakPower
        case .runOutMachine: .runOut
        case .bankWizard: .bank
        }
    }

    /// Badge label, ≤ 2 words (SPEC §7). Foundation Models may rename later; this is the deterministic fallback.
    public var label: String {
        switch self {
        case .cutArtist: "Cut Artist"
        case .longGun: "Long Gun"
        case .sidePocketSniper: "Side-Pocket Sniper"
        case .iceVeins: "Ice Veins"
        case .safetyChess: "Safety Chess"
        case .cannonBreak: "Cannon Break"
        case .runOutMachine: "Run-out Machine"
        case .bankWizard: "Bank Wizard"
        }
    }

    /// SF Symbol for the icon badge.
    public var symbolName: String {
        switch self {
        case .cutArtist: "scissors"
        case .longGun: "scope"
        case .sidePocketSniper: "arrow.down.right.and.arrow.up.left"
        case .iceVeins: "snowflake"
        case .safetyChess: "checkerboard.shield"
        case .cannonBreak: "burst.fill"
        case .runOutMachine: "bolt.fill"
        case .bankWizard: "wand.and.stars"
        }
    }
}

public struct ArchetypeVector: Hashable, Codable, Sendable {
    /// Only dimensions with enough samples are present.
    public var values: [ArchetypeDimension: Double]

    public init(values: [ArchetypeDimension: Double]) { self.values = values }

    public subscript(_ d: ArchetypeDimension) -> Double? { values[d] }

    /// Builds the vector from career aggregates, dropping dimensions below the policy's sample minimums.
    public init(_ a: Aggregates, policy: ArchetypePolicy = .standard) {
        let m = policy.minSamples
        var v: [ArchetypeDimension: Double] = [:]
        func put(_ d: ArchetypeDimension, _ r: Rate) {
            if r.attempts >= m[d, default: 1], let x = r.value { v[d] = x }
        }
        put(.cut, (a.potByCut[.c45to60] ?? Rate()) + (a.potByCut[.c60plus] ?? Rate()))
        put(.long, a.potByDistance[.long] ?? Rate())
        put(.side, a.potByPocket[.side] ?? Rate())
        put(.clutch, a.clutch)
        put(.safety, a.safety)
        put(.bank, (a.potByKind[.bank] ?? Rate()) + (a.potByKind[.kick] ?? Rate()))
        put(.pot, a.pot)
        put(.position, a.position)
        if a.breaks.count >= m[.breakPower, default: 1], let mean = a.breaks.meanBallsPocketed {
            v[.breakPower] = min(1, max(0, mean / policy.breakBallsForFullScale))
        }
        if a.games >= m[.runOut, default: 1], a.games > 0 {
            v[.runOut] = min(1, Double(a.runOuts + a.breakAndRuns) / Double(a.games))
        }
        values = v
    }

    /// Persisted form (`ArchetypeSnapshot.vector`).
    public var stringKeyed: [String: Double] {
        Dictionary(uniqueKeysWithValues: values.map { ($0.key.rawValue, $0.value) })
    }

    /// Unknown keys (from a newer app version) are ignored.
    public init(stringKeyed: [String: Double]) {
        values = Dictionary(uniqueKeysWithValues: stringKeyed.compactMap { k, v in
            ArchetypeDimension(rawValue: k).map { ($0, v) }
        })
    }

    /// Radar-chart spokes in tag order; `nil` = not enough data yet.
    public var radar: [(ArchetypeDimension, Double?)] {
        ArchetypeTag.allCases.map { ($0.dimension, values[$0.dimension]) }
    }
}

/// Thresholds for archetypes. Unlock values are from SPEC §7; the rest are house defaults (estimated
/// amateur baselines, not sourced) awaiting user review.
public struct ArchetypePolicy: Hashable, Codable, Sendable {
    public var unlockGames: Int
    public var unlockShots: Int
    public var minSamples: [ArchetypeDimension: Int]
    /// Absolute floor a value must reach for its tag (also needs to stand out vs friends when there are enough).
    public var baseline: [ArchetypeTag: Double]
    /// z-score vs the friend group needed for a tag.
    public var zThreshold: Double
    /// Friends with a value on a dimension needed before the z-score test applies.
    public var minFriends: Int
    public var breakBallsForFullScale: Double

    public init(unlockGames: Int = 3, unlockShots: Int = 50,
                minSamples: [ArchetypeDimension: Int] = [.cut: 10, .long: 10, .side: 10, .clutch: 5, .safety: 5,
                                                         .breakPower: 3, .runOut: 3, .bank: 5, .pot: 20, .position: 10],
                baseline: [ArchetypeTag: Double] = [.cutArtist: 0.45, .longGun: 0.5, .sidePocketSniper: 0.6,
                                                    .iceVeins: 0.65, .safetyChess: 0.6, .cannonBreak: 0.5,
                                                    .runOutMachine: 0.25, .bankWizard: 0.35],
                zThreshold: Double = 1.0, minFriends: Int = 3, breakBallsForFullScale: Double = 3) {
        self.unlockGames = unlockGames
        self.unlockShots = unlockShots
        self.minSamples = minSamples
        self.baseline = baseline
        self.zThreshold = zThreshold
        self.minFriends = minFriends
        self.breakBallsForFullScale = breakBallsForFullScale
    }

    public static let standard = ArchetypePolicy()
}

/// Append-only (docs/SCHEMA.md `ArchetypeSnapshot`).
public struct ArchetypeSnapshot: Hashable, Codable, Sendable {
    public var playerID: UUID
    public var computedAt: Date
    public var gamesCount: Int
    public var shotsCount: Int
    public var vector: [String: Double]
    public var tags: [ArchetypeTag]
    public var proComp: ProComp?

    public init(playerID: UUID, computedAt: Date, gamesCount: Int, shotsCount: Int,
                vector: [String: Double], tags: [ArchetypeTag], proComp: ProComp? = nil) {
        self.playerID = playerID
        self.computedAt = computedAt
        self.gamesCount = gamesCount
        self.shotsCount = shotsCount
        self.vector = vector
        self.tags = tags
        self.proComp = proComp
    }
}

public enum Archetypes {
    public static func isUnlocked(_ a: Aggregates, policy: ArchetypePolicy = .standard) -> Bool {
        a.games >= policy.unlockGames && a.shots >= policy.unlockShots
    }

    /// Tags whose value clears the absolute baseline and, when ≥ `minFriends` friends have that dimension,
    /// also a z-score ≥ `zThreshold` vs those friends (zero spread: strictly above their mean).
    /// Sorted strongest first (z when available, else margin over the baseline).
    public static func tags(for v: ArchetypeVector, friends: [ArchetypeVector],
                            policy: ArchetypePolicy = .standard) -> [ArchetypeTag] {
        var scored: [(ArchetypeTag, Double)] = []
        for tag in ArchetypeTag.allCases {
            guard let x = v[tag.dimension], let base = policy.baseline[tag], x >= base else { continue }
            let peers = friends.compactMap { $0[tag.dimension] }
            if peers.count >= policy.minFriends {
                let mean = peers.reduce(0, +) / Double(peers.count)
                let sd = (peers.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(peers.count)).squareRoot()
                if sd > 1e-12 {
                    let z = (x - mean) / sd
                    if z >= policy.zThreshold { scored.append((tag, z)) }
                } else if x > mean + 1e-12 {
                    scored.append((tag, policy.zThreshold))
                }
            } else {
                scored.append((tag, x - base))
            }
        }
        return scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.rawValue < $1.0.rawValue }.map(\.0)
    }

    /// Snapshot for `player` from their competitive games, or `nil` while locked (SPEC §7).
    /// `friends` = the other players' vectors (friend group). `pros`, when given, adds the pro comp (SPEC §8).
    public static func snapshot(player: UUID, games: [CompetitiveGame], friends: [ArchetypeVector], at: Date,
                                pros: [ProProfile]? = nil, policy: ArchetypePolicy = .standard) -> ArchetypeSnapshot? {
        let a = Aggregates.career(games, player: player)
        guard isUnlocked(a, policy: policy) else { return nil }
        let v = ArchetypeVector(a, policy: policy)
        return ArchetypeSnapshot(playerID: player, computedAt: at, gamesCount: a.games, shotsCount: a.shots,
                                 vector: v.stringKeyed, tags: tags(for: v, friends: friends, policy: policy),
                                 proComp: pros.flatMap { ProComp.nearest(to: v, among: $0) })
    }
}

/// One player's archetype evolution. Snapshots can only be appended, in time order.
public struct ArchetypeHistory: Hashable, Codable, Sendable {
    public enum AppendError: Error, Equatable { case wrongPlayer, outOfOrder }

    public let playerID: UUID
    public private(set) var snapshots: [ArchetypeSnapshot]

    public init(playerID: UUID) {
        self.playerID = playerID
        snapshots = []
    }

    public var latest: ArchetypeSnapshot? { snapshots.last }

    public mutating func append(_ s: ArchetypeSnapshot) throws {
        guard s.playerID == playerID else { throw AppendError.wrongPlayer }
        if let last = snapshots.last, s.computedAt < last.computedAt || s.gamesCount < last.gamesCount {
            throw AppendError.outOfOrder
        }
        snapshots.append(s)
    }

    /// Call after every competitive game. Returns `true` when a snapshot was appended (i.e. unlocked).
    @discardableResult
    public mutating func recompute(games: [CompetitiveGame], friends: [ArchetypeVector], at: Date,
                                   pros: [ProProfile]? = nil, policy: ArchetypePolicy = .standard) throws -> Bool {
        guard let s = Archetypes.snapshot(player: playerID, games: games, friends: friends, at: at,
                                          pros: pros, policy: policy) else { return false }
        try append(s)
        return true
    }
}

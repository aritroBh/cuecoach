import Foundation
import Geometry
import Rules

/// One island's view of one shot (mesh-identity.md §2.5 `IslandShot`).
public struct IslandShot: Hashable, Sendable {
    public var id: UUID
    /// Stroke start on the game clock, seconds.
    public var strokeTime: Double
    /// Ball positions before the shot, table metres. Empty = unknown: time alone aligns.
    public var preState: [BallID: Vec2]
    public var outcome: ShotOutcome
    /// Higher wins a disagreement; ties go to the smaller id.
    public var confidence: Double

    public init(id: UUID, strokeTime: Double, preState: [BallID: Vec2], outcome: ShotOutcome, confidence: Double) {
        self.id = id; self.strokeTime = strokeTime; self.preState = preState; self.outcome = outcome
        self.confidence = confidence
    }
}

/// One physical shot after a merge.
public struct MergedShot: Hashable, Sendable {
    /// The kept view.
    public var shot: IslandShot
    /// The views disagreed on the outcome: D47 asks one tap (plan 013b).
    public var needsTap: Bool
    /// Every view folded into it, sorted.
    public var members: [UUID]

    public init(shot: IslandShot, needsTap: Bool, members: [UUID]) {
        self.shot = shot; self.needsTap = needsTap; self.members = members
    }
}

/// Deterministic merge of island shot tails after a heal (§2.5 item 3).
public enum IslandMerge {
    /// Stroke times of one shot seen by two phones differ by at most this much on the game clock (s).
    public static let timeTolerance = 0.5

    /// The same physical shot: the same id, or strokes within `timeTolerance` with every ball both views know within
    /// one ball radius. An empty pre-state (unknown) matches on time alone; two known states with no common ball never do.
    public static func aligned(_ a: IslandShot, _ b: IslandShot, ballRadius: Double = TableSpec.ballRadius) -> Bool {
        if a.id == b.id { return true }
        guard abs(a.strokeTime - b.strokeTime) <= timeTolerance else { return false }
        if a.preState.isEmpty || b.preState.isEmpty { return true }
        var common = 0
        for (ball, p) in a.preState {
            guard let q = b.preState[ball] else { continue }
            guard p.distance(to: q) <= ballRadius else { return false }
            common += 1
        }
        return common > 0
    }

    /// One entry per physical shot any island saw, in stroke order (earliest view, then kept id). A shot takes at most
    /// one view per island (two views with the same id always join). Same outcome → one shot; different outcomes →
    /// the most confident view (ties: smaller id) with `needsTap`. A view nobody else saw is kept.
    /// The result depends only on the islands' contents, never on their order or the order inside one.
    public static func merge(_ islands: [[IslandShot]], ballRadius: Double = TableSpec.ballRadius) -> [MergedShot] {
        // Canonical island numbering: equal islands are interchangeable, so ties in the sort don't matter.
        let canonical = islands.map { $0.sorted(by: before) }
            .sorted { $0.map(\.id.uuidString).lexicographicallyPrecedes($1.map(\.id.uuidString)) }
        let views = canonical.enumerated()
            .flatMap { i, island in island.map { (shot: $0, island: i) } }
            .sorted { before($0.shot, $1.shot) || (!before($1.shot, $0.shot) && $0.island < $1.island) }
        var clusters: [[(shot: IslandShot, island: Int)]] = []
        for v in views {
            let fits = clusters.firstIndex { c in
                c.allSatisfy { m in (m.island != v.island || m.shot.id == v.shot.id) && aligned(m.shot, v.shot, ballRadius: ballRadius) }
            }
            if let i = fits { clusters[i].append(v) } else { clusters.append([v]) }
        }
        return clusters.map { c -> (start: Double, merged: MergedShot) in
            let shots = c.map(\.shot)
            let kept = shots.max { a, b in
                a.confidence != b.confidence ? a.confidence < b.confidence : a.id.uuidString > b.id.uuidString
            }!
            let members = Set(shots.map(\.id)).sorted { $0.uuidString < $1.uuidString }
            return (shots.map(\.strokeTime).min()!,
                    MergedShot(shot: kept, needsTap: Set(shots.map(\.outcome)).count > 1, members: members))
        }
        .sorted { $0.start != $1.start ? $0.start < $1.start : $0.merged.shot.id.uuidString < $1.merged.shot.id.uuidString }
        .map(\.merged)
    }

    /// Canonical view order: stroke time, then id.
    private static func before(_ a: IslandShot, _ b: IslandShot) -> Bool {
        a.strokeTime != b.strokeTime ? a.strokeTime < b.strokeTime : a.id.uuidString < b.id.uuidString
    }
}

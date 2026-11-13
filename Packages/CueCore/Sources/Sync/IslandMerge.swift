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

/// What one phone recorded for one stroke: a shot (with its pre-state) or a gap, with its stroke time on the game
/// clock (nil = unknown: no clock fit).
public struct StrokeView: Hashable, Sendable {
    public var id: UUID
    public var time: Double?
    public var preState: [BallID: Vec2]
    public var isGap: Bool

    public init(id: UUID, time: Double?, preState: [BallID: Vec2], isGap: Bool) {
        self.id = id; self.time = time; self.preState = preState; self.isGap = isGap
    }
}

/// Deterministic merge of island shot tails after a heal (§2.5 item 3).
public enum IslandMerge {
    /// Stroke times of one shot seen by two phones differ by at most this much on the game clock (s).
    public static let timeTolerance = 0.5

    /// The same physical shot: the same id, or strokes within `timeTolerance` with every ball both views know within
    /// one ball radius. An empty pre-state (unknown) matches on time alone; two known states with no common ball never do.
    public static func aligned(_ a: IslandShot, _ b: IslandShot, ballRadius: Double = TableSpec.ballRadius) -> Bool {
        sameStroke(StrokeView(id: a.id, time: a.strokeTime, preState: a.preState, isGap: false),
                   StrokeView(id: b.id, time: b.strokeTime, preState: b.preState, isGap: false), ballRadius: ballRadius)
    }

    /// Every ball both pre-states know is within one ball radius, and they share at least `minCommon` balls.
    private static func preStatesAgree(_ a: [BallID: Vec2], _ b: [BallID: Vec2], ballRadius: Double, minCommon: Int) -> Bool {
        var common = 0
        for (ball, p) in a {
            guard let q = b[ball] else { continue }
            guard p.distance(to: q) <= ballRadius else { return false }
            common += 1
        }
        return common >= minCommon
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

    /// The one rule for "same physical stroke", used everywhere the mesh asks it (Codex 013a review 3):
    /// - the same id;
    /// - both timed: strokes within `timeTolerance`, and, for two shots, every ball both pre-states know within one
    ///   ball radius (an unknown pre-state matches on time alone); a gap matches any result in the window;
    /// - otherwise (a side has no game time): only two shots whose known pre-states share at least two balls, all
    ///   within one radius. An untimed gap never matches anything but its own id.
    public static func sameStroke(_ a: StrokeView, _ b: StrokeView, ballRadius: Double = TableSpec.ballRadius) -> Bool {
        if a.id == b.id { return true }
        if let ta = a.time, let tb = b.time {
            guard abs(ta - tb) <= timeTolerance else { return false }
            if a.isGap || b.isGap || a.preState.isEmpty || b.preState.isEmpty { return true }
            return preStatesAgree(a.preState, b.preState, ballRadius: ballRadius, minCommon: 1)
        }
        guard !a.isGap, !b.isGap, !a.preState.isEmpty, !b.preState.isEmpty else { return false }
        return preStatesAgree(a.preState, b.preState, ballRadius: ballRadius, minCommon: 2)
    }

    /// Canonical view order: stroke time, then id.
    private static func before(_ a: IslandShot, _ b: IslandShot) -> Bool {
        a.strokeTime != b.strokeTime ? a.strokeTime < b.strokeTime : a.id.uuidString < b.id.uuidString
    }
}

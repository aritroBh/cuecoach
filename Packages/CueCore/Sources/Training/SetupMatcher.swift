import Geometry

/// Drill setup ghost circles turn green when real balls sit on them (SPEC §10).
public enum SetupMatcher {
    /// For each ghost, whether a distinct detected ball lies within `tolerance` (metres).
    /// Maximum bipartite matching: one ball never satisfies two ghosts, and how many ghosts are
    /// matched (so `isReady`) never depends on order. A contested ball goes to the ghost it is
    /// nearer to; only an exact distance tie falls back to ghost order.
    /// Ball identity is ignored (any ball can satisfy any ghost) — open product question.
    public static func match(ghosts: [Vec2], detected: [Vec2], tolerance: Double) -> [Bool] {
        let near: [[Int]] = ghosts.map { g in
            detected.indices.filter { detected[$0].distance(to: g) <= tolerance }
                .sorted { detected[$0].distance(to: g) < detected[$1].distance(to: g) }
        }
        func nearest(_ g: Int) -> Double { near[g].first.map { detected[$0].distance(to: ghosts[g]) } ?? .infinity }
        let order = ghosts.indices.sorted { a, b in nearest(a) != nearest(b) ? nearest(a) < nearest(b) : a < b }
        var ballOwner = [Int?](repeating: nil, count: detected.count)
        func augment(_ g: Int, _ seen: inout [Bool]) -> Bool {
            for b in near[g] where !seen[b] {
                seen[b] = true
                if ballOwner[b] == nil || augment(ballOwner[b]!, &seen) { ballOwner[b] = g; return true }
            }
            return false
        }
        for g in order {
            var seen = [Bool](repeating: false, count: detected.count)
            _ = augment(g, &seen)
        }
        var matched = [Bool](repeating: false, count: ghosts.count)
        for case let g? in ballOwner { matched[g] = true }
        return matched
    }

    /// Ready to shoot when every ghost is matched.
    public static func isReady(_ matched: [Bool]) -> Bool { !matched.isEmpty && matched.allSatisfy { $0 } }
}

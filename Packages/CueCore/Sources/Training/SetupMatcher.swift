import Geometry

/// Drill setup ghost circles turn green when real balls sit on them (SPEC §10).
public enum SetupMatcher {
    /// For each ghost, whether a distinct detected ball lies within `tolerance` (metres).
    /// Uses maximum bipartite matching, so one ball never satisfies two ghosts and the
    /// result doesn't depend on ghost order.
    public static func match(ghosts: [Vec2], detected: [Vec2], tolerance: Double) -> [Bool] {
        let near: [[Int]] = ghosts.map { g in
            detected.indices.filter { detected[$0].distance(to: g) <= tolerance }
        }
        var ballOwner = [Int?](repeating: nil, count: detected.count)
        func augment(_ g: Int, _ seen: inout [Bool]) -> Bool {
            for b in near[g] where !seen[b] {
                seen[b] = true
                if ballOwner[b] == nil || augment(ballOwner[b]!, &seen) { ballOwner[b] = g; return true }
            }
            return false
        }
        for g in ghosts.indices {
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

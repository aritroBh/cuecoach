import Foundation

/// Optimal one-to-one assignment (Hungarian / Kuhn–Munkres, O(n³)) on a rectangular cost matrix.
/// Pairs whose cost exceeds `gate` are dropped afterwards.
enum Assignment {
    /// `cost[r][c]`; returns (row, col) pairs.
    static func solve(_ cost: [[Double]], gate: Double = .infinity) -> [(Int, Int)] {
        let rows = cost.count
        guard rows > 0, let cols = cost.first?.count, cols > 0 else { return [] }
        let n = max(rows, cols)
        let big = 1e9
        // Square, padded matrix (1-indexed algorithm).
        var a = [[Double]](repeating: [Double](repeating: big, count: n + 1), count: n + 1)
        for r in 0..<rows { for c in 0..<cols { a[r + 1][c + 1] = min(big, cost[r][c]) } }
        var u = [Double](repeating: 0, count: n + 1), v = u
        var p = [Int](repeating: 0, count: n + 1), way = p
        for i in 1...n {
            p[0] = i
            var j0 = 0
            var minv = [Double](repeating: .infinity, count: n + 1)
            var used = [Bool](repeating: false, count: n + 1)
            repeat {
                used[j0] = true
                let i0 = p[j0]
                var delta = Double.infinity, j1 = 0
                for j in 1...n where !used[j] {
                    let cur = a[i0][j] - u[i0] - v[j]
                    if cur < minv[j] { minv[j] = cur; way[j] = j0 }
                    if minv[j] < delta { delta = minv[j]; j1 = j }
                }
                for j in 0...n {
                    if used[j] { u[p[j]] += delta; v[j] -= delta } else { minv[j] -= delta }
                }
                j0 = j1
            } while p[j0] != 0
            repeat {
                let j1 = way[j0]
                p[j0] = p[j1]
                j0 = j1
            } while j0 != 0
        }
        var out: [(Int, Int)] = []
        for j in 1...n {
            let r = p[j] - 1, c = j - 1
            if r < rows, c < cols, cost[r][c] <= gate { out.append((r, c)) }
        }
        return out.sorted { $0.0 < $1.0 }
    }
}

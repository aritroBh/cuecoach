import Foundation
import Geometry
import simd

/// LiDAR depth (ARKit sceneDepth): metres along the camera's viewing axis, aligned with the captured image.
struct DepthMap: Sendable {
    var width: Int
    var height: Int
    var depth: [Float]
    /// ARConfidenceLevel raw values (0 low, 1 medium, 2 high); nil = all trusted.
    var confidence: [UInt8]?

    func value(_ x: Int, _ y: Int) -> Float { depth[y * width + x] }
}

/// Finds balls as bumps on the cloth in LiDAR depth — independent of colour, so green/blue balls on
/// green felt still show up (they sit 57 mm proud of the cloth).
struct DepthBallFinder: Sendable {
    var minHeight = 0.012     // m above the cloth
    var maxHeight = 0.075
    var cell = 0.012          // m grid for clustering
    var minPoints = 3
    var maxExtent = 0.095     // bigger clusters are hands/arms/cues
    var minTop = 0.035        // m: some point of the cluster must be ball-tall

    func find(depth: DepthMap, camera: CameraModel, table: TableFrame) -> [Vec2] {
        let k = camera.intrinsics.scaled(toWidth: Double(depth.width), height: Double(depth.height))
        let spec = table.spec
        let toTable = table.tableToWorld.inverse * camera.cameraToWorld
        let gw = Int(spec.length / cell) + 1, gh = Int(spec.width / cell) + 1
        var grid = [[Vec2]](repeating: [], count: gw * gh)
        var top = [Double](repeating: 0, count: gw * gh)   // tallest point per cell
        for y in 0..<depth.height {
            for x in 0..<depth.width {
                if let c = depth.confidence, c[y * depth.width + x] < 1 { continue }
                let z = Double(depth.value(x, y))
                guard z.isFinite, z > 0.1, z < 6 else { continue }
                let pc = SIMD4((Double(x) + 0.5 - k.cx) / k.fx * z, -(Double(y) + 0.5 - k.cy) / k.fy * z, -z, 1)
                let t = toTable * pc
                guard t.z >= minHeight, t.z <= maxHeight,
                      t.x > 0, t.y > 0, t.x < spec.length, t.y < spec.width else { continue }
                let gi = Int(t.y / cell) * gw + Int(t.x / cell)
                grid[gi].append(Vec2(t.x, t.y))
                top[gi] = max(top[gi], t.z)
            }
        }
        // 8-connected clusters of occupied cells.
        var seen = [Bool](repeating: false, count: gw * gh)
        var out: [Vec2] = []
        for start in grid.indices where !grid[start].isEmpty && !seen[start] {
            var stack = [start], pts: [Vec2] = []
            var tallest = 0.0
            seen[start] = true
            while let i = stack.popLast() {
                pts += grid[i]
                tallest = max(tallest, top[i])
                let cx = i % gw, cy = i / gw
                for dy in -1...1 { for dx in -1...1 {
                    let nx = cx + dx, ny = cy + dy
                    guard nx >= 0, ny >= 0, nx < gw, ny < gh else { continue }
                    let j = ny * gw + nx
                    if !seen[j] && !grid[j].isEmpty { seen[j] = true; stack.append(j) }
                } }
            }
            // A ball's cap reaches ~57 mm; stray noise points barely clear the threshold.
            guard pts.count >= minPoints, tallest >= minTop else { continue }
            let xs = pts.map(\.x), ys = pts.map(\.y)
            guard xs.max()! - xs.min()! <= maxExtent, ys.max()! - ys.min()! <= maxExtent else { continue }
            var c = pts.reduce(Vec2.zero, +) / Double(pts.count)
            // Only the camera-facing cap is visible: push the centroid away from the camera by ~R/3.
            let camT = toTable * SIMD4(0, 0, 0, 1)
            let away = (c - Vec2(camT.x, camT.y)).normalized
            c += away * (TableSpec.ballRadius / 3)
            out.append(c)
        }
        // One ball can split into two sparse clusters: merge centres closer than a ball diameter.
        var merged: [(c: Vec2, n: Double)] = []
        for c in out {
            if let i = merged.firstIndex(where: { $0.c.distance(to: c) < 2 * TableSpec.ballRadius * 0.9 }) {
                let m = merged[i]
                merged[i] = ((m.c * m.n + c) / (m.n + 1), m.n + 1)
            } else { merged.append((c, 1)) }
        }
        return merged.map(\.c)
    }
}

/// Merges depth-found balls into colour detections: any depth ball with no colour detection nearby is added,
/// classified from the image at that spot (colour may still say "unknown").
enum DepthFusion {
    static func merge(_ dets: [BallDetection], depthBalls: [Vec2], image: PixelImage, geometry: FrameGeometry,
                      radius: Double = 0.04) -> [BallDetection] {
        var out = dets
        for b in depthBalls where !dets.contains(where: { $0.tablePoint.distance(to: b) < radius }) {
            guard let px = geometry.ball.apply(b) else { continue }
            let rpx = TableSpec.ballRadius * geometry.ball.maxScale(at: b)
            let cls = ClassicalBallDetector.classify(image, sourcePoint: px, radiusPx: rpx)
            out.append(BallDetection(imagePoint: px, tablePoint: b, radiusPx: rpx, confidence: 0.55,
                                     kind: cls.kind, tentativeNumber: cls.number))
        }
        return out
    }
}

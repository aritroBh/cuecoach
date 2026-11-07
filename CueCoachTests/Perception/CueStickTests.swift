import Foundation
import Geometry
import Testing
@testable import CueCoach

struct CueLineDetectorTests {
    func observe(stickDir: Vec2, tipGap: Double, wrists: [Vec2] = []) throws -> (CueObservation?, Vec2) {
        var scene = SyntheticTableScene.demo()
        let cue = scene.balls[0].position
        let u = stickDir.normalized
        scene.stick = .init(tip: cue - u * (TableSpec.ballRadius + tipGap), direction: u, length: 1.0)
        let cg = try #require(scene.render())
        let img = try #require(PixelImage(cgImage: cg))
        let geo = FrameGeometry(frame: scene.frame, camera: scene.camera)
        let others = scene.balls.dropFirst().map(\.position)
        return (CueLineDetector().detect(in: img, geometry: geo, cue: cue, others: others, wrists: wrists), u)
    }

    @Test(arguments: [0.0, 0.5, -0.7, 1.2])
    func findsTheCueDirection(angle: Double) throws {
        // Stick behind the cue ball, aiming along `angle` (table x is toward the foot).
        let (o, u) = try observe(stickDir: Vec2(cos(angle), sin(angle)), tipGap: 0.03)
        let obs = try #require(o)
        let err = acos(max(-1, min(1, obs.direction.dot(u)))) * 180 / .pi
        #expect(err < 3, "direction off by \(err)°")
        #expect(abs(obs.tipDistance - (TableSpec.ballRadius + 0.03)) < 0.03, "tip \(obs.tipDistance)")
    }

    @Test func noStickNoObservation() throws {
        let scene = SyntheticTableScene.demo()
        let cg = try #require(scene.render())
        let img = try #require(PixelImage(cgImage: cg))
        let geo = FrameGeometry(frame: scene.frame, camera: scene.camera)
        #expect(CueLineDetector().detect(in: img, geometry: geo, cue: scene.balls[0].position,
                                         others: scene.balls.dropFirst().map(\.position)) == nil)
    }
}

struct CueAimTrackerTests {
    func obs(_ angle: Double, tip: Double = 0.1) -> CueObservation {
        CueObservation(direction: Vec2(cos(angle), sin(angle)), tipDistance: tip, confidence: 0.9)
    }

    @Test func smoothsAcrossTheAngleWrap() {
        var t = CueAimTracker()
        _ = t.update(obs(.pi - 0.02), at: 0)
        for i in 1...10 { _ = t.update(obs(-.pi + 0.02), at: Double(i) / 30) }
        let d = t.direction!
        #expect(abs(abs(atan2(d.y, d.x)) - .pi) < 0.03)
    }

    @Test func strokeIsTheTipClosingFast() {
        var t = CueAimTracker()
        var strokes = 0
        // Practice strokes: slow back-and-forth (0.2 m/s) — not a stroke.
        for i in 0..<30 { if t.update(obs(0.3, tip: 0.10 + 0.04 * sin(Double(i) * 0.2)), at: Double(i) / 30) { strokes += 1 } }
        #expect(strokes == 0)
        // Final stroke: 0.15 → 0.03 m in 3 frames (1.2 m/s).
        var tip = 0.15
        for i in 30..<34 { tip -= 0.04; if t.update(obs(0.3, tip: max(0.03, tip)), at: Double(i) / 30) { strokes += 1 } }
        #expect(strokes == 1)
        #expect(t.strokeRecent(at: 34 / 30.0))
        #expect(!t.strokeRecent(at: 3))
    }

    @Test func forgetsTheCueAfterItLeaves() {
        var t = CueAimTracker()
        _ = t.update(obs(0.1), at: 0)
        #expect(t.cueVisible(at: 0.5))
        _ = t.update(nil, at: 1.5)
        #expect(t.direction == nil && !t.cueVisible(at: 1.5))
    }
}

struct LiveAimTraceTests {
    let spec = TableSpec(size: .sevenFoot)
    let R = TableSpec.ballRadius

    @Test func hitsTheFirstBallOnTheLine() throws {
        let cue = Vec2(0.5, 0.5)
        let near = Vec2(1.0, 0.5 + R), far = Vec2(1.5, 0.5)
        let tr = LiveAimTrace.trace(cue: cue, direction: Vec2(1, 0), balls: [far, near], spec: spec)
        #expect(tr.hitIndex == 1)
        let g = try #require(tr.ghost)
        #expect(abs(g.distance(to: near) - 2 * R) < 1e-9)
        #expect(tr.objectDirection!.y > 0)   // half-ball-ish hit pushes the object up
    }

    @Test func missEndsAtTheCushion() {
        let tr = LiveAimTrace.trace(cue: Vec2(0.5, 0.5), direction: Vec2(0, 1), balls: [Vec2(1.5, 0.5)], spec: spec)
        #expect(tr.hitIndex == nil)
        #expect(abs(tr.end.y - (spec.width - R)) < 1e-9)
    }

    @Test func convergenceRisesAsAimMeetsTheSuggestion() {
        let cue = Vec2(0.5, 0.5), ghost = Vec2(1.5, 0.5)
        #expect(LiveAimTrace.convergence(live: Vec2(1, 0), cue: cue, suggestedGhost: ghost) == 1)
        let off = LiveAimTrace.convergence(live: Vec2(cos(0.05), sin(0.05)), cue: cue, suggestedGhost: ghost)
        #expect(off > 0 && off < 1)
        #expect(LiveAimTrace.convergence(live: Vec2(0, 1), cue: cue, suggestedGhost: ghost) == 0)
    }
}

struct StrokeGatedShotStartTests {
    @Test func cueVisibleWithoutStrokeDoesNotStartAShot() {
        var s = ShotSegmenter(spec: TableSpec(size: .sevenFoot))
        func b(_ p: Vec2, _ v: Vec2 = .zero) -> TrackedBall {
            TrackedBall(id: 1, position: p, velocity: v, kind: .cue, tentativeNumber: nil, confirmed: true)
        }
        _ = s.update(tracks: [b(Vec2(0.5, 0.5))], cueID: 1, atRest: true, at: 0, strokeRecent: false)
        for i in 1...4 { _ = s.update(tracks: [b(Vec2(0.5, 0.5), Vec2(0.3, 0))], cueID: 1, atRest: false, at: Double(i) / 30, strokeRecent: false) }
        #expect(!s.inShot)   // e.g. the player nudged the cue ball with a hand
        for i in 5...7 { _ = s.update(tracks: [b(Vec2(0.5, 0.5), Vec2(0.3, 0))], cueID: 1, atRest: false, at: Double(i) / 30, strokeRecent: true) }
        #expect(s.inShot)
    }
}

struct DepthBallTests {
    @Test func depthFindsBallsThatColourMisses() throws {
        var scene = SyntheticTableScene.demo()
        let W = scene.frame.spec.width
        // A green ball (6) on green felt and a blue one: colour alone can't separate them from the cloth.
        scene.balls.append(.init(position: Vec2(1.1, W * 0.6), color: (20, 120, 60)))
        let depth = scene.renderDepth(noise: 0.004)
        let found = DepthBallFinder().find(depth: depth, camera: scene.camera, table: scene.frame)
        for b in scene.balls {
            let d = found.map { $0.distance(to: b.position) }.min() ?? 1
            #expect(d < 0.03, "ball at \(b.position) nearest depth blob \(d) m")
        }
        #expect(found.count == scene.balls.count, "found \(found.count)")

        let cg = try #require(scene.render())
        let img = try #require(PixelImage(cgImage: cg))
        let geo = FrameGeometry(frame: scene.frame, camera: scene.camera)
        let colour = ClassicalBallDetector().detect(in: img, geometry: geo)
        let merged = DepthFusion.merge(colour, depthBalls: found, image: img, geometry: geo)
        #expect(merged.count == scene.balls.count, "colour \(colour.count) merged \(merged.count)")
        #expect(merged.contains { $0.tablePoint.distance(to: Vec2(1.1, W * 0.6)) < 0.03 })
    }

    @Test func flatClothHasNoDepthBalls() {
        var scene = SyntheticTableScene.demo()
        scene.balls = []
        #expect(DepthBallFinder().find(depth: scene.renderDepth(noise: 0.004), camera: scene.camera, table: scene.frame).isEmpty)
    }
}

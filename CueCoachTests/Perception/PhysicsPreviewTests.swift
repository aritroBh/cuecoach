import Foundation
import Geometry
import Physics
import Testing
@testable import CueCoach

struct PhysicsPreviewTests {
    let spec = TableSpec(size: .sevenFoot)
    let preview = PhysicsShotPreview()

    func straightShot() -> (cue: Vec2, obj: Vec2, balls: [BallID: Vec2]) {
        let obj = Vec2(spec.length - 0.45, 0.45)
        let u = (AimPlanner.aimPoint(.footLeft, spec: spec) - obj).normalized
        let cue = obj - u * 0.7
        return (cue, obj, [.cue: cue, BallID(3)!: obj])
    }

    @Test func overlayPathsAreTheSimulatorsPaths() throws {
        let s = straightShot()
        let p = try #require(preview.preview(cue: s.cue, object: BallID(3)!, pocket: .footLeft, balls: s.balls, spec: spec))
        #expect(p.outcome == .make)
        // Re-simulate the exact suggested stroke independently.
        let state = TableState(spec: spec, balls: s.balls.mapValues { BallState(position: $0) })
        let tr = Simulator().simulate(state, stroke: Stroke(direction: p.direction, speed: PhysicsShotPreview.speeds[p.power - 1],
                                                            tipOffset: p.spin.tip))
        let path = tr.path(of: BallID(3)!, sampleDT: 0.02)
        #expect(path == p.objectPath)
        #expect(tr.events.contains { if case .pocket(BallID(3)!, .footLeft) = $0.event { return true }; return false })
        let cueEnd = tr.final.balls[.cue]?.position
        #expect(p.cuePath.last == cueEnd)
    }

    /// Physics pocket labels follow Geometry (foot end at x = length): a shot into (L, 0) is footLeft.
    @Test func previewTowardFootLeftReportsFootLeft() throws {
        let s = straightShot()
        #expect(spec.pocketCenter(.footLeft) == Vec2(spec.length, 0))
        let p = try #require(preview.preview(cue: s.cue, object: BallID(3)!, pocket: .footLeft, balls: s.balls, spec: spec))
        #expect(p.outcome == .make)
        // And asking for the wrong pocket must not count as a make.
        let state = TableState(spec: spec, balls: s.balls.mapValues { BallState(position: $0) })
        let wrong = preview.run(state: state, object: BallID(3)!, pocket: .headLeft, direction: p.direction,
                                speed: PhysicsShotPreview.speeds[p.power - 1], spin: p.spin, power: p.power)
        #expect(wrong.outcome != .make)
    }

    @Test func straightInChoosesNoScratch() throws {
        let s = straightShot()
        let p = try #require(preview.preview(cue: s.cue, object: BallID(3)!, pocket: .footLeft, balls: s.balls, spec: spec))
        #expect(p.outcome == .make)
        #expect(p.spin != .follow)   // rolling straight in follows the object ball into the pocket
    }

    @Test func refinementCompensatesThrowOnACut() throws {
        let obj = Vec2(spec.length - 0.5, 0.35)
        let target = AimPlanner.aimPoint(.footLeft, spec: spec)
        let u = (target - obj).normalized
        let cue = obj - u.rotated(by: 0.6) * 0.8      // ~35° cut
        let balls: [BallID: Vec2] = [.cue: cue, BallID(5)!: obj]
        let state = TableState(spec: spec, balls: balls.mapValues { BallState(position: $0) })
        let plain = (AimPlanner.ghostBall(object: obj, pocket: target) - cue).normalized
        let refined = preview.refinedDirection(cue: cue, object: BallID(5)!, obj: obj, target: target, state: state,
                                               speed: 1.4, spin: .stun)
        func err(_ d: Vec2) -> Double {
            let tr = Simulator().simulate(state, stroke: Stroke(direction: d, speed: 1.4, tipOffset: .zero))
            let p = tr.path(of: BallID(5)!, sampleDT: 0.02).first { $0.distance(to: obj) > 0.1 }!
            return abs(atan2(u.cross((p - obj).normalized), u.dot((p - obj).normalized)))
        }
        #expect(err(refined) < err(plain))
        #expect(err(refined) < 0.01)
    }

    @Test func pipelineAimUsesPhysicsPaths() async throws {
        let scene = SyntheticTableScene.demo()
        let cg = try #require(scene.render())
        let img = try #require(PixelImage(cgImage: cg))
        let p = PerceptionPipeline()
        await p.setTable(scene.frame)
        var last: PerceptionResult?
        for i in 0..<30 { last = await p.process(PerceptionFrame(image: img, camera: scene.camera, timestamp: Double(i) / 30)) }
        let aim = try #require(last?.aim)
        #expect(aim.outcome != nil)
        #expect(aim.objectPath.count > 2)    // a sampled path, not the 2-point geometric segment
    }
}

struct IdentityAndPathTests {
    func t(_ id: Int, _ n: Int?) -> TrackedBall {
        TrackedBall(id: id, position: Vec2(Double(id) * 0.1, 0.5), velocity: .zero, kind: .solid, tentativeNumber: n, confirmed: true)
    }

    @Test func idsAreUniqueAndCueIsZero() {
        let ids = BallIdentity.assign([t(1, 0), t(2, 3), t(3, 3), t(4, 9), t(5, nil)], cueID: 1)
        #expect(ids[1] == .cue)
        #expect(ids[4] == BallID(9))
        #expect(Set(ids.values).count == ids.count)
        #expect(ids[2] != BallID(3) || ids[3] != BallID(3))  // duplicate guesses aren't both trusted
    }

    @Test func douglasPeuckerKeepsTheBounce() {
        var pts: [Vec2] = []
        for i in 0...20 { pts.append(Vec2(Double(i) * 0.05, Double(i) * 0.02)) }        // to the rail
        for i in 1...20 { pts.append(Vec2(1 + Double(i) * 0.05, 0.4 - Double(i) * 0.02)) } // bounce back
        let segs = OverlayPath.segments(pts, max: 8)
        #expect(segs.count == 2)
        #expect(segs[0].1.distance(to: Vec2(1, 0.4)) < 1e-9)
    }

    @Test func dashesFollowThePolyline() {
        let pts = [Vec2(0, 0), Vec2(0.5, 0), Vec2(0.5, 0.5)]
        let d = OverlayPath.dashes(pts, dash: 0.04, gap: 0.03, skip: 0.0, max: 40)
        #expect(d.count > 10)
        for (a, b) in d {
            #expect(a.distance(to: b) <= 0.0401 + 1e-9)
            #expect((a.y == 0 && b.y == 0) || (abs(a.x - 0.5) < 1e-9 || abs(b.x - 0.5) < 1e-9))
        }
    }

    @Test func cacheKeyIsStableUnderJitter() {
        let b: [BallID: Vec2] = [.cue: Vec2(0.5, 0.5), BallID(2)!: Vec2(1, 0.4)]
        let jit: [BallID: Vec2] = [.cue: Vec2(0.5011, 0.4992), BallID(2)!: Vec2(1.0009, 0.4004)]
        let k1 = PreviewCache.key(cue: b[.cue]!, object: BallID(2)!, pocket: .footLeft, balls: b)
        let k2 = PreviewCache.key(cue: jit[.cue]!, object: BallID(2)!, pocket: .footLeft, balls: jit)
        #expect(k1 == k2)
    }
}


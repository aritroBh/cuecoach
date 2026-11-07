import CoreVideo
import Foundation
import Geometry
import simd
import Testing
@testable import CueCoach

struct BallDetectorTests {
    let scene = SyntheticTableScene.demo()

    func detections(_ scene: SyntheticTableScene) throws -> [BallDetection] {
        let cg = try #require(scene.render())
        let img = try #require(PixelImage(cgImage: cg, maxWidth: 960))
        let geo = FrameGeometry(frame: scene.frame, camera: scene.camera)
        return ClassicalBallDetector().detect(in: img, geometry: geo)
    }

    @Test func findsEveryNonGreenBallNearItsTruePixel() throws {
        let dets = try detections(scene)
        #expect(dets.count == scene.balls.count, "got \(dets.count): \(dets.map(\.kind))")
        for b in scene.balls {
            let truth = try #require(scene.imagePoint(b))
            let nearest = try #require(dets.min { $0.imagePoint.distance(to: truth) < $1.imagePoint.distance(to: truth) })
            #expect(nearest.imagePoint.distance(to: truth) < 4, "px error \(nearest.imagePoint.distance(to: truth))")
            #expect(nearest.tablePoint.distance(to: b.position) < 0.02, "table error \(nearest.tablePoint.distance(to: b.position))")
        }
    }

    @Test func classifiesCueEightAndStripe() throws {
        let dets = try detections(scene)
        func det(at p: Vec2) -> BallDetection? { dets.min { $0.tablePoint.distance(to: p) < $1.tablePoint.distance(to: p) } }
        #expect(det(at: scene.balls[0].position)?.kind == .cue)
        #expect(det(at: scene.balls[2].position)?.kind == .eight)
        #expect(det(at: scene.balls[3].position)?.kind == .stripe)
        #expect(det(at: scene.balls[3].position)?.tentativeNumber == 9)
        #expect(det(at: scene.balls[1].position)?.kind == .solid)
        #expect(det(at: scene.balls[1].position)?.tentativeNumber == 3)
        #expect(det(at: scene.balls[4].position)?.tentativeNumber == 2)
    }

    @Test func emptyTableHasNoDetections() throws {
        var s = scene; s.balls = []
        #expect(try detections(s).isEmpty)
    }

    @Test func touchingBallsAreSeparated() throws {
        var s = scene
        let R = TableSpec.ballRadius
        let c = Vec2(1.2, 0.5)
        s.balls = [.init(position: c, color: (200, 32, 30)),
                   .init(position: c + Vec2(2 * R, 0), color: (240, 120, 20)),
                   .init(position: c + Vec2(R, 1.732 * R), color: (30, 60, 190))]
        let dets = try detections(s)
        #expect(dets.count == 3, "got \(dets.count)")
    }

    @Test func worksFromAnObliqueCornerView() throws {
        var s = scene
        s.camera = CameraModel.lookAt(eye: SIMD3(1.3, 1.7, 1.5), target: SIMD3(0, 0.76, -0.2),
                                      intrinsics: scene.camera.intrinsics)
        let dets = try detections(s)
        let visible = s.balls.filter { b in s.imagePoint(b).map { $0.x > 20 && $0.x < 1900 && $0.y > 20 && $0.y < 1060 } ?? false }
        #expect(dets.count >= visible.count - 1, "got \(dets.count) of \(visible.count)")
    }
}

struct FeltProposerTests {
    @Test func proposesTableCornersFromFelt() throws {
        let scene = SyntheticTableScene.demo()
        let img = try #require(PixelImage(cgImage: try #require(scene.render())))
        let quad = try #require(FeltQuadProposer.propose(img))
        #expect(quad.count == 4)
        // Raycast to the table plane, inset the cushion → compare with playing-surface corners.
        let world = quad.compactMap { scene.camera.intersect(pixel: $0, with: scene.plane) }
        #expect(world.count == 4)
        let inner = TableFitter.insetQuad(world, by: SyntheticTableScene.cushionWidth)
        let fit = try #require(TableFitter.fit(corners: inner, viewer: scene.camera.position))
        #expect(fit.sizing.size == .sevenFoot)
        #expect(abs(fit.measuredLength - scene.frame.spec.length) < 0.06, "L \(fit.measuredLength)")
        let truth = scene.frame.corners.map { scene.frame.world($0) }
        for p in inner {
            let d = truth.map { simd_distance($0, p) }.min()!
            #expect(d < 0.05, "corner off by \(d) m")
        }
    }

    @Test func noFeltNoProposal() {
        let gray = PixelImage(width: 64, height: 48, rgb: [UInt8](repeating: 128, count: 64 * 48 * 3))
        #expect(FeltQuadProposer.propose(gray) == nil)
    }
}

struct TrackerTests {
    func det(_ p: Vec2, _ k: BallKind = .solid) -> BallDetection {
        BallDetection(imagePoint: .zero, tablePoint: p, radiusPx: 10, confidence: 1, kind: k, tentativeNumber: nil)
    }

    @Test func stillBallsWithJitterReachRest() {
        var tr = SimpleBallTracker()
        var rng = SplitMix(seed: 1)
        let balls = [Vec2(0.5, 0.5), Vec2(1.2, 0.3), Vec2(1.6, 0.8)]
        var rested = false
        for f in 0..<40 {
            let dets = balls.map { det($0 + Vec2(rng.gauss() * 0.002, rng.gauss() * 0.002)) }
            let out = tr.update(dets, at: Double(f) / 30)
            #expect(out.count == 3)
            if tr.isAtRest { rested = true }
        }
        #expect(rested)
    }

    @Test func movingBallBlocksRestThenSettles() {
        var tr = SimpleBallTracker()
        var t = 0.0
        for _ in 0..<20 { _ = tr.update([det(Vec2(0.5, 0.5)), det(Vec2(1.5, 0.5))], at: t); t += 1 / 30.0 }
        #expect(tr.isAtRest)
        var x = 0.5
        for _ in 0..<20 {
            x += 1.0 / 30   // 1 m/s
            _ = tr.update([det(Vec2(x, 0.5)), det(Vec2(1.5, 0.5))], at: t); t += 1 / 30.0
        }
        #expect(!tr.isAtRest)
        var restAt: Int?
        for f in 0..<40 {
            _ = tr.update([det(Vec2(x, 0.5)), det(Vec2(1.5, 0.5))], at: t); t += 1 / 30.0
            if tr.isAtRest && restAt == nil { restAt = f }
        }
        #expect(restAt != nil)
        #expect((restAt ?? 0) >= 10)
    }

    @Test func identityFollowsAMovingBall() {
        var tr = SimpleBallTracker()
        var t = 0.0, x = 0.4
        var id: Int?
        for _ in 0..<30 {
            x += 0.02
            let out = tr.update([det(Vec2(x, 0.4), .cue), det(Vec2(1.8, 0.8), .eight)], at: t); t += 1 / 30.0
            let cue = out.first { $0.kind == .cue }
            if id == nil { id = cue?.id }
            #expect(cue?.id == id)
        }
        let out = tr.update([det(Vec2(x + 0.02, 0.4), .cue)], at: t)
        #expect(abs((out.first { $0.id == id }?.velocity.x ?? 0) - 0.6) < 0.15)
    }

    @Test func briefDropoutKeepsTrack() {
        var tr = SimpleBallTracker()
        var t = 0.0
        for _ in 0..<10 { _ = tr.update([det(Vec2(1, 0.5))], at: t); t += 1 / 30.0 }
        let id = tr.update([det(Vec2(1, 0.5))], at: t).first?.id
        for _ in 0..<5 { t += 1 / 30.0; _ = tr.update([], at: t) }
        t += 1 / 30.0
        #expect(tr.update([det(Vec2(1, 0.5))], at: t).first?.id == id)
    }

    @Test func majorityVoteSmoothsClass() {
        var tr = SimpleBallTracker()
        var out: [TrackedBall] = []
        for f in 0..<10 { out = tr.update([det(Vec2(1, 0.5), f % 4 == 0 ? .stripe : .solid)], at: Double(f) / 30) }
        #expect(out.first?.kind == .solid)
    }
}

struct AimPlannerTests {
    let spec = TableSpec(size: .sevenFoot)

    @Test func ghostBallSitsTwoRadiiBehindObject() {
        let obj = Vec2(1.0, 0.5), pocket = Vec2(2.0, 0.5)
        let g = AimPlanner.ghostBall(object: obj, pocket: pocket)
        #expect(abs(g.x - (1.0 - 2 * TableSpec.ballRadius)) < 1e-12 && abs(g.y - 0.5) < 1e-12)
    }

    @Test func picksTheStraightInShot() throws {
        let W = spec.width, L = spec.length
        // Object near the foot-right corner, cue on the same diagonal.
        let obj = Vec2(L - 0.3, W - 0.15)
        let dir = (spec.pocketCenter(.footRight) - obj).normalized
        let cue = obj - dir * 0.8
        let s = try #require(AimPlanner.suggest(cue: cue, objects: [obj, Vec2(0.4, 0.2)], spec: spec))
        #expect(s.pocket == .footRight)
        #expect(s.cut < 0.1)
    }

    @Test func blockedPathIsAvoided() {
        let cue = Vec2(0.5, 0.5), obj = Vec2(1.5, 0.5)
        let blocker = Vec2(1.0, 0.5)
        let s = AimPlanner.suggest(cue: cue, objects: [obj, blocker], spec: spec)
        if let s { #expect(AimPlanner.clear(from: cue, to: s.ghost,
                                              of: [obj, blocker].filter { $0 != s.object }, radius: 2 * TableSpec.ballRadius)) }
    }

    @Test func nothingToShootAtGivesNil() {
        #expect(AimPlanner.suggest(cue: Vec2(1, 0.5), objects: [], spec: spec) == nil)
    }
}

struct PixelImageTests {
    @Test func ycbcrRoundTrip() {
        for c in [(200, 30, 30), (24, 112, 74), (240, 240, 236), (18, 18, 20)] as [(Int, Int, Int)] {
            let y = YCbCr.fromRGB(UInt8(c.0), UInt8(c.1), UInt8(c.2))
            let back = YCbCr.toRGB(y.0, y.1, y.2)
            #expect(abs(Int(back.0) - c.0) <= 2 && abs(Int(back.1) - c.1) <= 2 && abs(Int(back.2) - c.2) <= 2)
        }
    }

    @Test func biplanarBufferDownsamples() throws {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 1920, 1440, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, nil, &pb)
        let buf = try #require(pb)
        CVPixelBufferLockBaseAddress(buf, [])
        let y = YCbCr.fromRGB(200, 30, 30)
        let yp = CVPixelBufferGetBaseAddressOfPlane(buf, 0)!.assumingMemoryBound(to: UInt8.self)
        let cp = CVPixelBufferGetBaseAddressOfPlane(buf, 1)!.assumingMemoryBound(to: UInt8.self)
        let yrb = CVPixelBufferGetBytesPerRowOfPlane(buf, 0), crb = CVPixelBufferGetBytesPerRowOfPlane(buf, 1)
        for r in 0..<1440 { memset(yp + r * yrb, Int32(y.0), 1920) }
        for r in 0..<720 { for x in 0..<960 { cp[r * crb + 2 * x] = y.1; cp[r * crb + 2 * x + 1] = y.2 } }
        CVPixelBufferUnlockBaseAddress(buf, [])
        let img = try #require(PixelImage(pixelBuffer: buf, maxWidth: 960))
        #expect(img.width == 960 && img.height == 720 && img.scale == 2)
        let p = img.pixel(400, 300)
        #expect(abs(Int(p.0) - 200) <= 3 && abs(Int(p.1) - 30) <= 3)
    }
}

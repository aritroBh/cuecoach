import CoreGraphics
import CoreVideo
import Foundation
import Geometry
import simd
import Testing
@testable import CueCoach

struct AssignmentTests {
    @Test func optimalBeatsGreedy() {
        // Greedy takes (0,0)=1 then (1,1)=10 → 11; optimal is (0,1)+(1,0) = 2+2 = 4.
        let pairs = Assignment.solve([[1, 2], [2, 10]])
        #expect(pairs.map { $0.1 } == [1, 0])
    }

    @Test func rectangularAndGated() {
        let pairs = Assignment.solve([[0.1, 5, 5], [5, 5, 0.2]], gate: 1)
        #expect(pairs.count == 2)
        #expect(pairs[0] == (0, 0) || pairs[0].1 == 0)
        #expect(Assignment.solve([[5.0]], gate: 1).isEmpty)
    }

    @Test func trackerKeepsIdentitiesWhenBallsCross() {
        var tr = KalmanBallTracker()
        func det(_ p: Vec2) -> BallDetection {
            BallDetection(imagePoint: .zero, tablePoint: p, radiusPx: 10, confidence: 1, kind: .solid, tentativeNumber: nil)
        }
        var t = 0.0
        var a = Vec2(0.5, 0.50), b = Vec2(0.5, 0.56)
        var idA: Int?, idB: Int?
        for _ in 0..<12 {
            let out = tr.update([det(a), det(b)], at: t)
            idA = out.min { $0.position.distance(to: a) < $1.position.distance(to: a) }?.id
            idB = out.min { $0.position.distance(to: b) < $1.position.distance(to: b) }?.id
            t += 1 / 30.0
        }
        // Both move in parallel at 0.9 m/s, 6 cm apart: greedy matching would steal across.
        for _ in 0..<20 {
            a += Vec2(0.03, 0); b += Vec2(0.03, 0)
            let out = tr.update([det(b), det(a)], at: t); t += 1 / 30.0
            let na = out.min { $0.position.distance(to: a) < $1.position.distance(to: a) }?.id
            let nb = out.min { $0.position.distance(to: b) < $1.position.distance(to: b) }?.id
            #expect(na == idA && nb == idB)
        }
    }
}

struct ShotSegmenterTests {
    let spec = TableSpec(size: .sevenFoot)

    func ball(_ id: Int, _ p: Vec2, _ v: Vec2 = .zero) -> TrackedBall {
        TrackedBall(id: id, position: p, velocity: v, kind: id == 1 ? .cue : .solid, tentativeNumber: nil, confirmed: true)
    }

    @Test func objectBallMovingFirstDoesNotStartAShot() {
        var s = ShotSegmenter(spec: spec)
        _ = s.update(tracks: [ball(1, Vec2(0.5, 0.5)), ball(2, Vec2(1, 0.5))], cueID: 1, atRest: true, at: 0)
        for i in 1...5 {
            _ = s.update(tracks: [ball(1, Vec2(0.5, 0.5)), ball(2, Vec2(1, 0.5), Vec2(0.5, 0))], cueID: 1, atRest: false, at: Double(i) / 30)
        }
        #expect(!s.inShot)
    }

    @Test func recordsStartFirstContactRailPocketAndEnd() throws {
        var s = ShotSegmenter(spec: spec)
        let R = TableSpec.ballRadius
        var t = 0.0
        let obj0 = Vec2(1.4, 0.5)
        _ = s.update(tracks: [ball(1, Vec2(0.6, 0.5)), ball(2, obj0)], cueID: 1, atRest: true, at: t)
        // Cue rolls to the object at 1.5 m/s.
        var cue = Vec2(0.6, 0.5)
        while cue.distance(to: obj0) > 2 * R + 0.005 {
            t += 1 / 30.0; cue += Vec2(0.05, 0)
            _ = s.update(tracks: [ball(1, cue, Vec2(1.5, 0)), ball(2, obj0)], cueID: 1, atRest: false, at: t)
        }
        #expect(s.inShot)
        // Object heads for the foot-right corner; cue drifts to the left rail and bounces.
        var obj = obj0
        let toPocket = (spec.pocketCenter(.footRight) - obj0).normalized
        var cueV = Vec2(0, -1.5)
        for _ in 0..<40 {
            t += 1 / 30.0
            obj += toPocket * 0.04
            cue += cueV / 30
            if cue.y < R + 0.005 { cueV = Vec2(0, 0.4) }
            let tracks = obj.distance(to: spec.pocketCenter(.footRight)) < 0.05 ? [ball(1, cue, cueV)]
                : [ball(1, cue, cueV), ball(2, obj, toPocket * 1.2)]
            _ = s.update(tracks: tracks, cueID: 1, atRest: false, at: t)
            if tracks.count == 1 { break }
        }
        t += 1 / 30.0
        let ended = s.update(tracks: [ball(1, cue)], cueID: 1, atRest: true, at: t)
        let rec = try #require(ended)
        #expect(rec.cueID == 1)
        #expect(rec.firstContact == 2)
        #expect(rec.pocketed[2] == .footRight)
        #expect(rec.rails.contains { $0.id == 1 && $0.rail == .left })
        #expect(rec.preState[2] == obj0)
        #expect(rec.finalState[2] == nil)
        #expect(!s.inShot)
    }
}

struct LocatorPlaneTests {
    @Test func floorIsNeverTheTable() {
        let cam = SyntheticRig.camera()
        let floor = LocatorPlane(center: SIMD3(0, 0, 0), extent: SIMD2(6, 6), isTable: false)
        let table = LocatorPlane(center: SIMD3(0, 0.75, -0.1), extent: SIMD2(0.8, 0.5), isTable: false)
        let p = LocatorMath.plane(for: Vec2(960, 540), camera: cam, planes: [floor, table])
        #expect(p.map { abs($0.point.y - 0.75) < 1e-9 } == true)
        // Only the floor known (table plane not detected yet): a 0 m "table" right under a ray is allowed
        // only when no table-height plane exists; with a table-height plane present the floor is excluded.
        let p2 = LocatorMath.plane(for: Vec2(960, 1070), camera: cam, planes: [floor, table])
        #expect(p2 == nil || abs(p2!.point.y - 0.75) < 1e-9)
    }

    @Test func coffeeTableHeightIsRejectedWhenFloorKnown() {
        let cam = SyntheticRig.camera()
        let floor = LocatorPlane(center: SIMD3(0, 0, 0), extent: SIMD2(6, 6), isTable: false)
        let low = LocatorPlane(center: SIMD3(0, 0.42, -0.1), extent: SIMD2(2, 2), isTable: false)
        #expect(LocatorMath.plane(for: Vec2(960, 540), camera: cam, planes: [floor, low]) == nil)
    }
}

struct PipelineLegalityTests {
    @Test func aimNeverTargetsTheEightOnAnOpenTable() async throws {
        var scene = SyntheticTableScene.demo()
        let W = scene.frame.spec.width, L = scene.frame.spec.length
        scene.balls = [.init(position: Vec2(0.5, W / 2), color: (240, 240, 236)),
                       .init(position: Vec2(L * 0.7, W / 2), color: (18, 18, 20))]
        let cg = try #require(scene.render())
        let img = try #require(PixelImage(cgImage: cg))
        let p = PerceptionPipeline()
        await p.setTable(scene.frame)
        var last: PerceptionResult?
        for i in 0..<30 { last = await p.process(PerceptionFrame(image: img, camera: scene.camera, timestamp: Double(i) / 30)) }
        let r = try #require(last)
        #expect(r.atRest)
        #expect(r.confirmed.count == 2)
        #expect(r.marks.values.contains(.illegal))
        #expect(r.aim == nil)
    }

    @Test func ballScaleIsAboutOneOnACorrectTable() async throws {
        let scene = SyntheticTableScene.demo()
        let cg = try #require(scene.render())
        let img = try #require(PixelImage(cgImage: cg))
        let dets = ClassicalBallDetector().detect(in: img, geometry: FrameGeometry(frame: scene.frame, camera: scene.camera))
        let s = try #require(BallScale.median(dets, geometry: FrameGeometry(frame: scene.frame, camera: scene.camera)))
        #expect(abs(s - 1) < 0.15, "scale \(s)")
    }
}

struct FalseCueTests {
    @Test func smallWhiteFeltMarkIsNotABall() throws {
        var scene = SyntheticTableScene.demo()
        scene.balls = []
        let cg = try #require(scene.render())
        // Paint a chalk-mark-sized white dot (≈ 0.35 ball radius) on the cloth.
        let ctx = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        let geo = FrameGeometry(frame: scene.frame, camera: scene.camera)
        let spot = geo.cloth.apply(scene.frame.spec.headSpot)!
        let r = TableSpec.ballRadius * geo.ball.maxScale(at: scene.frame.spec.headSpot) * 0.35
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: spot.x - r, y: CGFloat(cg.height) - spot.y - r, width: 2 * r, height: 2 * r))
        let marked = try #require(ctx.makeImage())
        let img = try #require(PixelImage(cgImage: marked))
        #expect(ClassicalBallDetector().detect(in: img, geometry: geo).isEmpty)
    }
}

struct ThermalExtrasTests {
    @Test func heavyExtrasShedFirst() {
        #expect(CapturePolicy.extras(.max) == .init(mesh: true, smoothedDepth: true, personOcclusion: true))
        #expect(!CapturePolicy.extras(.high).mesh)
        #expect(!CapturePolicy.extras(.survival).personOcclusion)
    }
}

struct ReviewRound3Tests {
    @Test func relockingDimsAndDistrustsTheTable() {
        let s = LiveStatus.derive(planeFound: true, corners: 4, calibrated: true, trackingOK: true, bumped: false, relocking: true)
        #expect(s == .relocking && s.showsRecalibratePulse && !s.trustsTable)
        #expect(LiveStatus.calibrated.trustsTable && !LiveStatus.trackingLost.trustsTable)
    }

    @Test func staleAndOutOfOrderResultsAreDropped() {
        var o = FrameOrdering()
        let a = o.accept(seq: 5, epoch: 1, currentEpoch: 1)
        let b = o.accept(seq: 4, epoch: 1, currentEpoch: 1)    // older frame finished late
        let c = o.accept(seq: 9, epoch: 0, currentEpoch: 1)    // from before a tracking change
        let d = o.accept(seq: 10, epoch: 1, currentEpoch: 1)
        #expect(a && !b && !c && d)
    }

    func ball(_ id: Int, _ p: Vec2, _ v: Vec2 = .zero) -> TrackedBall {
        TrackedBall(id: id, position: p, velocity: v, kind: id == 1 ? .cue : .solid, tentativeNumber: nil, confirmed: true)
    }

    @Test func vanishedMovingBallBlocksShotEnd() {
        var s = ShotSegmenter(spec: TableSpec(size: .sevenFoot))
        var t = 0.0
        _ = s.update(tracks: [ball(1, Vec2(0.5, 0.5)), ball(2, Vec2(1.2, 0.5))], cueID: 1, atRest: true, at: t)
        for _ in 0..<3 { t += 1 / 30; _ = s.update(tracks: [ball(1, Vec2(0.6, 0.5), Vec2(1, 0)), ball(2, Vec2(1.2, 0.5))], cueID: 1, atRest: false, at: t) }
        #expect(s.inShot)
        // Ball 2 moves mid-table, then a player's arm hides it; the visible cue ball has stopped.
        for _ in 0..<5 { t += 1 / 30; _ = s.update(tracks: [ball(1, Vec2(1.1, 0.5)), ball(2, Vec2(1.4, 0.5), Vec2(0.8, 0))], cueID: 1, atRest: false, at: t) }
        t += 1 / 30
        let e1 = s.update(tracks: [ball(1, Vec2(1.1, 0.5))], cueID: 1, atRest: true, at: t)
        t += 0.8
        let e2 = s.update(tracks: [ball(1, Vec2(1.1, 0.5))], cueID: 1, atRest: true, at: t)
        #expect(e1 == nil && e2 == nil)
        // It reappears at rest → the shot can end.
        t += 1 / 30
        let rec = s.update(tracks: [ball(1, Vec2(1.1, 0.5)), ball(2, Vec2(1.6, 0.5))], cueID: 1, atRest: true, at: t)
        #expect(rec != nil && rec?.finalState[2] == Vec2(1.6, 0.5))
    }

    @Test func blockedBestShotFallsBackToAClearOne() throws {
        let spec = TableSpec(size: .sevenFoot)
        let cue = Vec2(0.5, 0.5)
        let easy = Vec2(1.0, 0.5)          // straight toward the foot... but an illegal ball sits in the way
        let blocker = Vec2(0.75, 0.5)
        let other = Vec2(0.9, 0.85)
        let s = try #require(AimPlanner.suggest(cue: cue, objects: [easy, other], blockers: [blocker], spec: spec))
        #expect(AimPlanner.clear(from: s.cue, to: s.ghost, of: [blocker], radius: 2 * TableSpec.ballRadius))
        #expect(AimPlanner.clear(from: s.object, to: s.pocketPoint, of: [blocker], radius: 2 * TableSpec.ballRadius))
    }

    @Test func lidarRejectsAFlatBallSizedWhiteMark() throws {
        var scene = SyntheticTableScene.demo()
        let real = scene.balls[0]
        scene.balls = [real]
        let geo = FrameGeometry(frame: scene.frame, camera: scene.camera)
        let depth = scene.renderDepth()
        let fake = BallDetection(imagePoint: geo.ball.apply(Vec2(1.5, 0.6))!, tablePoint: Vec2(1.5, 0.6), radiusPx: 12,
                                 confidence: 1, kind: .cue, tentativeNumber: 0)
        let truth = BallDetection(imagePoint: geo.ball.apply(real.position)!, tablePoint: real.position, radiusPx: 12,
                                  confidence: 1, kind: .cue, tentativeNumber: 0)
        let kept = DepthFusion.verify([fake, truth], depth: depth, camera: scene.camera, table: scene.frame)
        #expect(kept.count == 1 && kept[0].tablePoint == real.position)
    }
}

struct BufferReuseTests {
    func makeBuffer() -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 1920, 1440, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, nil, &pb)
        let buf = pb!
        CVPixelBufferLockBaseAddress(buf, [])
        let y = YCbCr.fromRGB(24, 112, 74)
        let yp = CVPixelBufferGetBaseAddressOfPlane(buf, 0)!.assumingMemoryBound(to: UInt8.self)
        let cp = CVPixelBufferGetBaseAddressOfPlane(buf, 1)!.assumingMemoryBound(to: UInt8.self)
        for r in 0..<1440 { memset(yp + r * CVPixelBufferGetBytesPerRowOfPlane(buf, 0), Int32(y.0), 1920) }
        let crb = CVPixelBufferGetBytesPerRowOfPlane(buf, 1)
        for r in 0..<720 { for x in 0..<960 { cp[r * crb + 2 * x] = y.1; cp[r * crb + 2 * x + 1] = y.2 } }
        CVPixelBufferUnlockBaseAddress(buf, [])
        return buf
    }

    @Test func steadyStateReusesStorage() throws {
        let pb = makeBuffer()
        var buffer: [UInt8] = []
        var first: UnsafeRawPointer?
        do {
            let img = try #require(PixelImage.convert(pb, maxWidth: 960, into: &buffer))
            #expect(img.width == 960)
            first = buffer.withUnsafeBytes { UnsafeRawPointer($0.baseAddress) }
        }
        _ = try #require(PixelImage.convert(pb, maxWidth: 960, into: &buffer))
        let second = buffer.withUnsafeBytes { UnsafeRawPointer($0.baseAddress) }
        #expect(first == second, "storage was reallocated")
    }

    @Test func fixedPointMatchesFloatConversion() {
        for (y, cb, cr) in [(30, 90, 200), (200, 128, 128), (120, 40, 60), (16, 128, 128), (235, 240, 16)] as [(UInt8, UInt8, UInt8)] {
            for vr in [false, true] {
                let a = YCbCr.toRGB(y, cb, cr, videoRange: vr), b = YCbCr.toRGBFast(y, cb, cr, videoRange: vr)
                #expect(abs(Int(a.0) - Int(b.0)) <= 2 && abs(Int(a.1) - Int(b.1)) <= 2 && abs(Int(a.2) - Int(b.2)) <= 2)
            }
        }
    }
}

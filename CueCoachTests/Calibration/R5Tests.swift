import Foundation
import Geometry
import Rules
import Engine
import simd
import Testing
@testable import CueCoach

/// Codex r5 + user decisions + app-shell hooks.
struct RuleRatingTests {
    let engine = TargetLegality.defaultGame().0
    let game = TargetLegality.defaultGame().1
    let ids: [Int: BallID] = [1: .cue, 2: BallID(3)!, 3: .eight, 4: BallID(11)!]

    func record(first: Int?, pocketed: [Int: Pocket], rails: Bool = true) -> ShotRecord {
        ShotRecord(start: 0, end: 1, preState: [:], finalState: [:], cueID: 1, firstContact: first,
                   rails: rails ? [(id: 1, rail: .left)] : [], pocketed: pocketed)
    }

    @Test func legalPotIsGood() {
        let r = RuleRating.rate(record(first: 2, pocketed: [2: .footLeft]), ids: ids, engine: engine, game: game)
        #expect(r.result.fouls.isEmpty)
        #expect(r.rating == .good)
    }

    @Test func earlyEightIsNeverGood() {
        // Open table, the 8 pocketed: a loss of game in bar 8-ball — not "Good".
        let r = RuleRating.rate(record(first: 3, pocketed: [3: .footLeft]), ids: ids, engine: engine, game: game)
        #expect(r.rating != .good && [DecisionRating.mistake, .blunder].contains(r.rating))
    }

    @Test func scratchWhilePottingIsAFoul() {
        let r = RuleRating.rate(record(first: 2, pocketed: [2: .footLeft, 1: .sideLeft]), ids: ids, engine: engine, game: game)
        #expect(!r.result.fouls.isEmpty)
        #expect(r.rating == .mistake || r.rating == .blunder)
    }

    /// Codex r6: no contact *seen* is unknown, so it is not rated as a no-contact foul.
    @Test func unseenContactIsNotAFoul() {
        let r = RuleRating.rate(record(first: nil, pocketed: [:], rails: false), ids: ids, engine: engine, game: game)
        #expect(!r.result.fouls.contains(.noContact))
    }
}

@MainActor
struct BadgeAndHooksTests {
    func result(moving: Bool = false, liveAim: Bool = false, shot: ShotRecord? = nil, atRest: Bool = true,
                started: Bool = false, t: Double = 0) -> PerceptionResult {
        let cue = TrackedBall(id: 1, position: Vec2(0.5, 0.5), velocity: moving ? Vec2(0.8, 0) : .zero, kind: .cue,
                              tentativeNumber: 0, confirmed: true)
        var r = PerceptionResult(timestamp: t, detections: [], tracks: [cue], marks: [1: .cue], atRest: atRest, aim: nil, detectMs: 0)
        r.shot = shot
        r.shotStarted = started
        if liveAim { r.liveAim = LiveAimTrace(cue: Vec2(0.5, 0.5), end: Vec2(1, 0.5), hitIndex: nil, ghost: nil, objectDirection: nil) }
        r.ballIDs = [1: .cue, 2: BallID(3)!]
        return r
    }

    @Test func badgeHidesOnAimOrMotion() {
        let m = LiveModel(mode: .game)
        m.showBadge(BadgeStyle.of(.good))
        #expect(m.badge != nil)
        m.noteResult(result(liveAim: true))
        #expect(m.badge == nil, "next player aiming: no text")
        m.showBadge(BadgeStyle.of(.good))
        m.noteResult(result(moving: true, atRest: false))
        #expect(m.badge == nil, "balls moving: no text")
    }

    @Test func shellDrawsTheBadgeWhenHooked() {
        let m = LiveModel(mode: .game)
        var settled: [(DecisionRating, Bool)] = []
        m.hooks = LiveHooks(aimStarted: {}, aimEnded: {}, aimCancelled: {}, ballsSettled: {},
                            settled: { settled.append(($0, $1)) })
        let shot = ShotRecord(start: 0, end: 1, preState: [:], finalState: [:], cueID: 1, firstContact: 2,
                              rails: [], pocketed: [2: .footLeft])
        m.noteResult(result(shot: shot))
        #expect(settled.count == 1 && settled[0].0 == .good && settled[0].1 == false)
        #expect(m.badge == nil)   // the shell shows it
    }

    @Test func aimLifecycleOrder() {
        var a = AimEvents()
        var log: [AimEvents.Event] = []
        log += a.update(cueVisible: false, atRest: true, shotStarted: false, shotEnded: false, at: 0)
        log += a.update(cueVisible: true, atRest: true, shotStarted: false, shotEnded: false, at: 0.1)   // aim
        log += a.update(cueVisible: true, atRest: true, shotStarted: false, shotEnded: false, at: 0.2)
        log += a.update(cueVisible: true, atRest: false, shotStarted: true, shotEnded: false, at: 0.3)   // stroke
        log += a.update(cueVisible: false, atRest: true, shotStarted: false, shotEnded: true, at: 3)     // settled
        log += a.update(cueVisible: true, atRest: true, shotStarted: false, shotEnded: false, at: 4)     // next aim
        log += a.update(cueVisible: false, atRest: true, shotStarted: false, shotEnded: false, at: 4.2)
        log += a.update(cueVisible: false, atRest: true, shotStarted: false, shotEnded: false, at: 5.5)  // walked away
        #expect(log == [.aimStarted, .aimEnded, .settled, .aimStarted, .aimCancelled])
    }

    @Test func hooksFireThroughTheModel() {
        let m = LiveModel(mode: .training(level: 2))
        var events: [String] = []
        m.hooks = LiveHooks(aimStarted: { events.append("start") }, aimEnded: { events.append("end") },
                            aimCancelled: { events.append("cancel") }, ballsSettled: { events.append("settled") },
                            settled: { _, _ in events.append("rated") })
        m.noteResult(result(liveAim: true, t: 0))
        m.noteResult(result(moving: true, atRest: false, started: true, t: 0.5))
        let shot = ShotRecord(start: 0.5, end: 2, preState: [:], finalState: [:], cueID: 1, firstContact: nil, rails: [], pocketed: [:])
        m.noteResult(result(shot: shot, t: 2))
        #expect(events == ["start", "end", "settled"])   // training: no rating
    }
}

struct LockR5Tests {
    @Test func checkGlyphOnlyWhenLocked() {
        for f in [nil, LockFailure.badShape, .unstable, .partialTable] {
            #expect(CoachingSymbol.of(failure: f, locked: false) != "checkmark")
        }
        #expect(CoachingSymbol.of(failure: nil, locked: true) == "checkmark")
        // A stable-but-invalid estimate (high confidence, not locked) still gets the fallback after 4 s.
        #expect(FallbackPolicy.offer(unlockedFor: 4.5, sameFailureFor: nil))
    }

    @Test func partialViewsAskForASecondLook() {
        #expect(LockFailure.from(autoRejection: "view too shallow") == .partialTable)
        #expect(LockFailure.from(autoRejection: "edge refine (partial: need second view)") == .partialTable)
        #expect(LockFailure.from(autoRejection: "cloth touches frame") == .partialTable)
        #expect(LockFailure.from(autoRejection: "tracking limited") == .unstable)
        #expect(LockFailure.partialTable.symbol == "arrow.up.left.and.arrow.down.right")
    }

    @Test func tableFillingTheFrameSaysStepBack() throws {
        var scene = SyntheticTableScene.demo()
        scene.camera = CameraModel.lookAt(eye: SIMD3(0.0, 1.2, -0.3), target: SIMD3(0, 0.76, -0.3), up: SIMD3(0, 0, -1), intrinsics: scene.camera.intrinsics)
        let cg = try #require(scene.render())
        let px = try #require(PixelImage(cgImage: cg))
        let a = FeltQuadProposer.analyze(px)
        #expect(a.failure == .tooClose, "got \(String(describing: a.failure))")
    }

    /// Codex r5: a table-sized green rug on the floor must not lock (no rails, no pockets).
    @Test func greenRugOnTheFloorNeverLocks() async throws {
        var rug = SyntheticTableScene.demo()
        rug.hasRailsAndPockets = false
        rug.balls = []
        // Same layout, but on the floor (y = 0) with the phone 1.3 m above it.
        let spec = rug.frame.spec
        var m = rug.frame.tableToWorld
        m.columns.3.y = 0
        rug.frame = TableFrame(tableToWorld: m, spec: spec)
        rug.camera = CameraModel.lookAt(eye: SIMD3(0.1, 1.3, 2.0), target: SIMD3(0, 0, -0.25), intrinsics: rug.camera.intrinsics)
        let cg = try #require(rug.render())
        let img = try #require(PixelImage(cgImage: cg))
        let depth = rug.renderDepth(width: 256, height: 144)
        let floor = LocatorPlane(center: rug.frame.world(Vec2(spec.length / 2, spec.width / 2)), extent: SIMD2(3, 3), isTable: false)
        let loc = AutoTableLocating()
        var locked = false
        for i in 0..<60 {
            let e = await loc.ingest(LocatorFrame(image: img, camera: rug.camera, planes: [floor], timestamp: Double(i) / 15, depth: depth))
            if e?.locked == true { locked = true }
        }
        #expect(!locked)
    }

    /// Codex autocal-r4 MAJOR: pocket evidence belongs to the surface it was seen on. Lock a real table (mouths
    /// seen), then pan without a pause to a table-sized cloth elsewhere with no pockets: the old evidence must
    /// not authorise a lock on it.
    @Test func pocketEvidenceDoesNotCarryToAnotherSurface() async throws {
        let table = SyntheticTableScene.demo()
        var rug = SyntheticTableScene.demo()
        rug.hasRailsAndPockets = false
        rug.balls = []
        let shift = SIMD3<Double>(2.5, 0, 0)   // another cloth at table height, 2.5 m to the side
        var m = rug.frame.tableToWorld
        m.columns.3 += SIMD4(shift, 0)
        rug.frame = TableFrame(tableToWorld: m, spec: rug.frame.spec)
        rug.camera = CameraModel.lookAt(eye: SIMD3(0.1, 2.15, 2.45) + shift, target: SIMD3(0, 0.76, -0.25) + shift,
                                        intrinsics: table.camera.intrinsics)
        let tcg = try #require(table.render()), rcg = try #require(rug.render())
        let ti = try #require(PixelImage(cgImage: tcg))
        let ri = try #require(PixelImage(cgImage: rcg))
        let td = table.renderDepth(width: 256, height: 144), rd = rug.renderDepth(width: 256, height: 144)
        let kp = MouthsAtPockets(Self.pocketPixels(table))
        let loc = AutoTableLocating(keypoints: kp)
        var t = 0.0, lockedTable = false
        for _ in 0..<60 where !lockedTable {
            let e = await loc.ingest(LocatorFrame(image: ti, camera: table.camera, planes: [Self.plane(table)], timestamp: t, depth: td))
            lockedTable = e?.locked == true
            t += 1.0 / 15
        }
        #expect(lockedTable)
        kp.pixels = []
        let rugCorners = rug.frame.corners.map { rug.frame.world($0) }
        var lockedRug = false
        for _ in 0..<90 {
            let e = await loc.ingest(LocatorFrame(image: ri, camera: rug.camera, planes: [Self.plane(rug)], timestamp: t, depth: rd))
            if let e, e.locked, e.corners.allSatisfy({ c in rugCorners.contains { simd_distance($0, c) < 0.3 } }) { lockedRug = true }
            t += 1.0 / 15
        }
        #expect(!lockedRug)
    }

    /// The ARKit table plane under a scene's cloth (as on the phone).
    static func plane(_ s: SyntheticTableScene) -> LocatorPlane {
        LocatorPlane(center: s.frame.world(Vec2(s.frame.spec.length / 2, s.frame.spec.width / 2)), extent: SIMD2(1, 0.6), isTable: true)
    }

    /// Pixels of a scene's six pocket centres (the keypoint model's mouths), in the rendered image.
    static func pocketPixels(_ s: SyntheticTableScene) -> [AutoTableKeypoint] {
        s.frame.spec.pockets.compactMap { pk in
            s.camera.project(s.frame.world(s.frame.spec.pocketCenter(pk))).map {
                AutoTableKeypoint(kind: pk.isSide ? .sideMouth : .cornerMouth, pixel: SIMD2($0.x, $0.y), confidence: 0.9)
            }
        }
    }

    /// Codex rerun MAJOR: a slow pan (each step < 0.3 m) must not drag the evidence along to another surface.
    @Test func pocketEvidenceDoesNotDriftToAnotherSurface() async throws {
        let table = SyntheticTableScene.demo()
        let tcg = try #require(table.render())
        let ti = try #require(PixelImage(cgImage: tcg))
        let kp = MouthsAtPockets(Self.pocketPixels(table))
        let loc = AutoTableLocating(keypoints: kp)
        var t = 0.0, lockedTable = false
        for _ in 0..<60 where !lockedTable {
            let e = await loc.ingest(LocatorFrame(image: ti, camera: table.camera, planes: [Self.plane(table)], timestamp: t,
                                                  depth: table.renderDepth(width: 256, height: 144)))
            lockedTable = e?.locked == true
            t += 1.0 / 15
        }
        #expect(lockedTable)
        kp.pixels = []
        let tableCentre = table.frame.world(Vec2(table.frame.spec.length / 2, table.frame.spec.width / 2))
        var badLock = false
        for step in 1...12 {
            var rug = SyntheticTableScene.demo()
            rug.hasRailsAndPockets = false
            rug.balls = []
            let shift = SIMD3<Double>(0.1 * Double(step), 0, 0)
            var m = rug.frame.tableToWorld
            m.columns.3 += SIMD4(shift, 0)
            rug.frame = TableFrame(tableToWorld: m, spec: rug.frame.spec)
            rug.camera = CameraModel.lookAt(eye: SIMD3(0.1, 2.15, 2.45) + shift, target: SIMD3(0, 0.76, -0.25) + shift,
                                            intrinsics: table.camera.intrinsics)
            let rcg = try #require(rug.render())
            let ri = try #require(PixelImage(cgImage: rcg))
            let rd = rug.renderDepth(width: 256, height: 144)
            for _ in 0..<4 {
                let e = await loc.ingest(LocatorFrame(image: ri, camera: rug.camera, planes: [Self.plane(rug)], timestamp: t, depth: rd))
                if let e, e.locked {
                    let c = e.corners.reduce(SIMD3<Double>(), +) / Double(max(1, e.corners.count))
                    if simd_distance(c, tableCentre) > 0.4 { badLock = true }
                }
                t += 1.0 / 15
            }
        }
        #expect(!badLock)
    }

    /// Codex autocal rerun: mouths count only where the candidate pose has pockets (mouths of another table in view
    /// are not evidence for this one).
    @Test func onlyMouthsAtTheCandidatesPocketsCount() {
        let pockets: [SIMD2<Double>] = [SIMD2(100, 100), SIMD2(500, 100)]
        #expect(AutoTableLocating.matchedMouths([SIMD2(104, 98), SIMD2(900, 900)], pocketPixels: pockets, tolerance: 20) == 1)
        #expect(AutoTableLocating.matchedMouths([SIMD2(104, 98), SIMD2(102, 101)], pocketPixels: pockets, tolerance: 20) == 1)
        #expect(AutoTableLocating.matchedMouths([], pocketPixels: pockets, tolerance: 20) == 0)
    }

    @Test func twoTapsFillTheTable() throws {
        let truth = SyntheticRig.frame(.eightFoot)
        let headL = truth.world(Vec2(0, 0)), headR = truth.world(Vec2(0, truth.spec.width))
        let viewer = SyntheticRig.camera().position
        let four = try #require(TwoTapTable.corners(headR + SIMD3(0.01, 0, -0.008), headL, viewer: viewer, size: .eightFoot))
        let tc = truth.corners.map { truth.world($0) }
        for c in four { #expect(tc.map { simd_distance($0, c) }.min()! < 0.03) }
        // Without a remembered size, the tapped width picks the preset.
        let auto = try #require(TwoTapTable.corners(headL, headR, viewer: viewer, size: nil))
        #expect(abs(simd_distance(auto[1], auto[2]) - truth.spec.length) < 0.02)
    }

    @Test func staleFrameAndMeasuredSize() {
        #expect(TableHealth.isStale(ballScale: 1.4, detections: 6))
        #expect(!TableHealth.isStale(ballScale: 1.05, detections: 6))
        #expect(!TableHealth.isStale(ballScale: 2, detections: 1))
        let d = UserDefaults(suiteName: "r5-\(UUID())")!
        TableHealth.rememberMeasured(.nineFoot, defaults: d)
        #expect(TableHealth.measuredSize(defaults: d) == .nineFoot)
        #expect(d.string(forKey: "cc.table.measured") == "nineFoot")
    }

    /// The bundled tablekp model finds pocket mouths on the synthetic table.
    @Test func keypointModelFindsPocketMouths() throws {
        let kp = try #require(CoreMLTableKeypointProvider.shared, "TableKeypoints model missing from the bundle")
        let scene = SyntheticTableScene.demo()
        let cg = try #require(scene.render())
        let img = try #require(PixelImage(cgImage: cg))
        let k = scene.camera.intrinsics.scaled(toWidth: Double(img.width), height: Double(img.height))
        kp.minInterval = 0
        let pts = kp.keypoints(in: AutoRGBImage(width: img.width, height: img.height, rgb: img.rgb),
                               intrinsics: AutoIntrinsics(fx: k.fx, fy: k.fy, cx: k.cx, cy: k.cy, width: k.width, height: k.height))
        #expect(pts.count >= 4, "got \(pts.count) keypoints")
    }
}

struct SizeAmbiguityTests {
    @Test func betweenEightAndNineIsNotTrusted() {
        let eight = TableSize.eightFoot.playingLength, nine = TableSize.nineFoot.playingLength
        #expect(SizeAmbiguity.isAmbiguous(measuredLength: (eight + nine) / 2, snapped: .eightFoot))
        #expect(!SizeAmbiguity.isAmbiguous(measuredLength: eight + 0.01, snapped: .eightFoot))
        #expect(!SizeAmbiguity.isAmbiguous(measuredLength: nine - 0.02, snapped: .nineFoot))
        #expect(!SizeAmbiguity.isAmbiguous(measuredLength: 2.2, snapped: nil))
        // A short 76" bar box is still clearly a 7 ft, not an 8 ft.
        #expect(!SizeAmbiguity.isAmbiguous(measuredLength: 76 * 0.0254, snapped: .sevenFoot))
    }
}

/// Keypoint fake: mouths at given pixels (none when empty).
final class MouthsAtPockets: TableKeypointProvider, @unchecked Sendable {
    var pixels: [AutoTableKeypoint]
    init(_ p: [AutoTableKeypoint]) { pixels = p }
    func keypoints(in image: AutoRGBImage, intrinsics: AutoIntrinsics) -> [AutoTableKeypoint] { pixels }
}

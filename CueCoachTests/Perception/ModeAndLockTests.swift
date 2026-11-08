import CoreGraphics
import Foundation
import Geometry
import Engine
import Training
import Testing
@testable import CueCoach

struct LiveModeTests {
    @Test func gameShowsRulesHelpersOnly() {
        let v = OverlayVisibility.of(.game)
        #expect(!v.line1 && !v.line2 && !v.line3 && !v.suggestedGhost && !v.shotDock && !v.liveCueLine)
        #expect(v.legalRings && v.illegalWarning && v.ratingBadge)
    }

    /// Training levels are the Training module's AssistLevel (1 full … 4 none, D1), the value the shell passes;
    /// what shows while aiming is `AssistLevel.visibleWhileAiming(in:)`, with D24's Line 3 only in position play.
    @Test func trainingFullAssistShowsLines1And2GhostAndDock() {
        let v = OverlayVisibility.of(.training(level: 1), drill: .straightIn)
        #expect(v.line1 && v.line2 && v.suggestedGhost && v.liveCueLine && v.shotDock)
        #expect(!v.line3 && !v.ratingBadge)   // D24: Line 3 only for position play
        #expect(OverlayVisibility.of(.training(level: 1), drill: .positionPlay).line3)
    }

    @Test func trainingLevel2IsTheObjectLineOnly() {
        let v = OverlayVisibility.of(.training(level: 2), drill: .straightIn)
        #expect(v.line2 && !v.line1 && !v.line3 && !v.suggestedGhost && !v.shotDock && !v.liveCueLine)
    }

    @Test func trainingLevel3IsTheGhostOnly() {
        let v = OverlayVisibility.of(.training(level: 3), drill: .straightIn)
        #expect(v.suggestedGhost && !v.line1 && !v.line2 && !v.line3 && !v.shotDock)
    }

    /// D1: level 4 hides everything while aiming (rings and the rules helpers stay).
    @Test func trainingLevel4HidesEverythingWhileAiming() {
        let v = OverlayVisibility.of(.training(level: 4), drill: .positionPlay)
        #expect(!v.line1 && !v.line2 && !v.line3 && !v.suggestedGhost && !v.shotDock && !v.liveCueLine)
        #expect(v.legalRings)
    }

    /// The shell's picker value reaches Live unchanged, on the same scale.
    @Test func shellAssistLevelMeansTheSameInLive() {
        #expect(ShellLiveMode.training(.full).liveMode == .training(level: 1))
        #expect(OverlayVisibility.of(ShellLiveMode.training(.none).liveMode, drill: .straightIn).line1 == false)
    }

    @Test func badgesAreIconColourAndAWord() {
        for c in DecisionRating.allCases {
            let b = BadgeStyle.of(c)
            #expect(b.word.split(separator: " ").count <= 2 && !b.symbol.isEmpty)
        }
    }

    /// Integration: standalone Live draws the shell's post-shot badge (Screens/PostShot), one vocabulary, so the
    /// aiming-path code (Live/Perception/Calibration) holds no text at all.
    @Test func liveBadgeIsTheSharedPostShotBadge() {
        for c in DecisionRating.allCases {
            let live = BadgeStyle.of(c), shell = RatingBadgeStyle.of(c)
            #expect(live.rating == c)
            #expect(live.symbol == shell.symbol && live.word == shell.words)
        }
    }

}

/// Bar conditions the locator must survive (A2).
struct BarConditionsTests {
    func analyze(_ scene: SyntheticTableScene) throws -> FeltAnalysis {
        let cg = try #require(scene.render())
        let img = try #require(PixelImage(cgImage: cg))
        return FeltQuadProposer.analyze(img)
    }

    func cornersMatch(_ scene: SyntheticTableScene, _ quad: [Vec2]) -> Double {
        let c = SyntheticTableScene.cushionWidth, s = scene.frame.spec
        let truth = [Vec2(-c, -c), Vec2(-c, s.width + c), Vec2(s.length + c, s.width + c), Vec2(s.length + c, -c)]
            .compactMap { scene.camera.project(scene.frame.world($0, height: SyntheticTableScene.railTopHeight)) }
        return truth.map { t in quad.map { $0.distance(to: t) }.min()! }.max()!
    }

    @Test(arguments: [("blue", 30, 70, 160), ("red", 150, 30, 40), ("grey", 110, 112, 115), ("tan", 170, 145, 100)])
    func anyClothColour(name: String, r: Int, g: Int, b: Int) throws {
        var scene = SyntheticTableScene.demo()
        scene.feltColor = (UInt8(r), UInt8(g), UInt8(b))
        if name == "grey" { scene.railColor = (60, 40, 28) }
        let a = try analyze(scene)
        let quad = try #require(a.quad, "\(name): \(String(describing: a.failure))")
        #expect(cornersMatch(scene, quad) < 14, "\(name) corners off by \(cornersMatch(scene, quad)) px")
    }

    @Test func lampHotspot() throws {
        var scene = SyntheticTableScene.demo()
        scene.lampGain = 1.9
        let a = try analyze(scene)
        let quad = try #require(a.quad, "\(String(describing: a.failure))")
        #expect(cornersMatch(scene, quad) < 14)
    }

    @Test func darkRails() throws {
        var scene = SyntheticTableScene.demo()
        scene.railColor = (22, 16, 12)
        let quad = try #require(try analyze(scene).quad)
        #expect(cornersMatch(scene, quad) < 14)
    }

    @Test func standingTooCloseSaysStepBack() throws {
        var scene = SyntheticTableScene.demo()
        scene.camera = CameraModel.lookAt(eye: SIMD3(0.1, 1.55, 0.9), target: SIMD3(0, 0.76, -0.4),
                                          intrinsics: scene.camera.intrinsics)
        let a = try analyze(scene)
        #expect(a.quad == nil)
        #expect(a.failure == .partialTable || a.failure == .tooClose)
    }

    @Test func farAwaySaysMoveCloser() throws {
        var scene = SyntheticTableScene.demo()
        scene.camera = CameraModel.lookAt(eye: SIMD3(0.1, 4.5, 9), target: SIMD3(0, 0.76, -0.1),
                                          intrinsics: scene.camera.intrinsics)
        let a = try analyze(scene)
        #expect(a.failure == .tooFar || a.failure == .noFelt)
    }

    @Test func blueClothLocksEndToEnd() async throws {
        var scene = SyntheticTableScene.demo()
        scene.feltColor = (30, 70, 160)
        let cg = try #require(scene.render())
        let img = try #require(PixelImage(cgImage: cg))
        let s = scene.frame.spec
        let plane = LocatorPlane(center: scene.frame.world(Vec2(s.length / 2, s.width / 2)), extent: SIMD2(1, 0.6), isTable: true)
        let loc = FeltQuadLocator()
        var last: TableEstimate?
        for i in 0..<8 { last = await loc.ingest(LocatorFrame(image: img, camera: scene.camera, planes: [plane], timestamp: Double(i) * 0.25)) }
        #expect(last?.locked == true)
    }

    @Test func noPlaneIsReported() async throws {
        let scene = SyntheticTableScene.demo()
        let cg = try #require(scene.render())
        let img = try #require(PixelImage(cgImage: cg))
        let e = await FeltQuadLocator().ingest(LocatorFrame(image: img, camera: scene.camera, planes: [], timestamp: 0))
        #expect(e?.failure == .noPlane)
    }
}

struct CodexR4Tests {
    func ball(_ id: Int, _ p: Vec2, _ v: Vec2 = .zero) -> TrackedBall {
        TrackedBall(id: id, position: p, velocity: v, kind: id == 1 ? .cue : .solid, tentativeNumber: nil, confirmed: true)
    }

    @Test func occludedNearAPocketIsNotPocketed() {
        let spec = TableSpec(size: .sevenFoot)
        var s = ShotSegmenter(spec: spec)
        var t = 0.0
        let nearPocket = spec.pocketCenter(.footLeft) + Vec2(-0.05, 0.03)
        _ = s.update(tracks: [ball(1, Vec2(0.5, 0.5)), ball(2, nearPocket)], cueID: 1, atRest: true, at: t)
        for _ in 0..<3 { t += 1 / 30; _ = s.update(tracks: [ball(1, Vec2(0.6, 0.5), Vec2(1, 0)), ball(2, nearPocket)], cueID: 1, atRest: false, at: t) }
        // Ball 2 nudged slowly AWAY from the pocket, then an arm hides it.
        for _ in 0..<4 { t += 1 / 30; _ = s.update(tracks: [ball(1, Vec2(1.0, 0.5)), ball(2, nearPocket, Vec2(-0.2, 0.1))], cueID: 1, atRest: false, at: t) }
        for _ in 0..<20 { t += 1 / 30; _ = s.update(tracks: [ball(1, Vec2(1.0, 0.5))], cueID: 1, atRest: true, at: t) }
        // Not closed (ball unresolved), and when it closes at the cap, it's missing — not pocketed.
        t += 9
        let rec = s.update(tracks: [ball(1, Vec2(1.0, 0.5))], cueID: 1, atRest: true, at: t)
        #expect(rec?.pocketed[2] == nil)
        #expect(rec?.missing.contains(2) == true)
    }

    @Test func previewCacheKeyIncludesTheTable() {
        let b: [BallID: Vec2] = [.cue: Vec2(0.5, 0.5), BallID(2)!: Vec2(1, 0.4)]
        let k7 = PreviewCache.key(cue: b[.cue]!, object: BallID(2)!, pocket: .footLeft, balls: b, spec: TableSpec(size: .sevenFoot))
        let k9 = PreviewCache.key(cue: b[.cue]!, object: BallID(2)!, pocket: .footLeft, balls: b, spec: TableSpec(size: .nineFoot))
        #expect(k7 != k9)
    }

    @Test func flatWhiteMarkFailsTheShadingCheck() throws {
        var scene = SyntheticTableScene.demo()
        scene.balls = [scene.balls[0]]   // a real (shaded) cue ball
        let cg = try #require(scene.render())
        let ctx = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        let geo = FrameGeometry(frame: scene.frame, camera: scene.camera)
        let markAt = Vec2(1.5, 0.6)
        let px = geo.ball.apply(markAt)!
        let r = TableSpec.ballRadius * geo.ball.maxScale(at: markAt)
        ctx.setFillColor(CGColor(srgbRed: 0.95, green: 0.95, blue: 0.93, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: px.x - r, y: CGFloat(cg.height) - px.y - r, width: 2 * r, height: 2 * r))
        let marked = try #require(ctx.makeImage())
        let img = try #require(PixelImage(cgImage: marked))
        let realPx = geo.ball.apply(scene.balls[0].position)!
        let realR = TableSpec.ballRadius * geo.ball.maxScale(at: scene.balls[0].position)
        #expect(ClassicalBallDetector.hasBallShading(img, sourcePoint: realPx, radiusPx: realR))
        #expect(!ClassicalBallDetector.hasBallShading(img, sourcePoint: px, radiusPx: r))
    }

    @Test func shooterIsThePersonNearestTheCueBall() {
        let scene = SyntheticTableScene.demo()
        let geo = FrameGeometry(frame: scene.frame, camera: scene.camera)
        let cue = scene.balls[0].position
        let nearW = geo.ball.apply(cue + Vec2(-0.3, 0.05))!
        let farW = geo.ball.apply(Vec2(1.9, 0.9))!
        let w = ShooterPicker.wrists(of: [[farW], [nearW, nearW]], nearestTo: cue, geometry: geo)
        #expect(w.count == 2 && w[0] == nearW)
    }

    @Test func tentativeBallsBlockTheAim() async throws {
        // A blocker seen for only 1 frame (tentative) must still stop a suggestion through it.
        let spec = TableSpec(size: .sevenFoot)
        let cue = Vec2(0.5, 0.5), target = Vec2(1.0, 0.5), blocker = Vec2(0.75, 0.5)
        let s = AimPlanner.suggest(cue: cue, objects: [target], blockers: [blocker], spec: spec)
        if let s { #expect(AimPlanner.clear(from: s.cue, to: s.ghost, of: [blocker], radius: 2 * TableSpec.ballRadius)) }
    }
}

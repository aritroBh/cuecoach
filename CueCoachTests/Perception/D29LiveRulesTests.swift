import Foundation
import Geometry
import Rules
import Testing
@testable import CueCoach

/// D29 (user, 2026-11-08): no illegal-target warning (red ring + buzz) on a ball whose identity is unknown, even if
/// it could be the 8; and a shot starts from an impulsive cue-ball launch even when the cue stick isn't seen.
struct D29LegalityTests {
    func legal(groups: [Int: BallGroup]? = nil, eightOnly: Bool = false) -> Set<BallID> {
        let (engine, base) = TargetLegality.defaultGame()
        var g = base
        if let groups { g.groups = groups; g.phase = .inPlay }
        if eightOnly { g.groups = [0: .solids, 1: .stripes]; g.phase = .inPlay; g.onTable = [.cue, .eight] }
        return engine.legalTargets(g)
    }

    @Test func groupOnlyBallIsNeverRedWhenItCouldBeTheEight() {
        let l = legal(eightOnly: true)
        #expect(l == [.eight])
        // A ball read as "solid" with no number could be a misread 8: no warning.
        #expect(TargetLegality.mark(kind: .solid, number: nil, legal: l) == .unknown)
        #expect(TargetLegality.mark(kind: .stripe, number: nil, legal: l) == .unknown)
    }

    @Test func unnumberedEightOrGroupBallOnAnAssignedTableIsNotAWarning() {
        let l = legal(groups: [0: .solids, 1: .stripes])
        #expect(TargetLegality.mark(kind: .stripe, number: nil, legal: l) == .unknown)
        #expect(TargetLegality.mark(kind: .eight, number: nil, legal: l) == .unknown)
        // Identified: warn.
        #expect(TargetLegality.mark(kind: .stripe, number: 11, legal: l) == .illegal)
        #expect(TargetLegality.mark(kind: .eight, number: 8, legal: l) == .illegal)
        // A legal group still shows its (green) ring.
        #expect(TargetLegality.mark(kind: .solid, number: nil, legal: l) == .legal)
    }
}

/// Scripted detector: per-frame detections by timestamp.
struct ScriptedBallDetector: BallDetector {
    var frames: @Sendable (Double) -> [BallDetection]
    func detect(in image: PixelImage, geometry: FrameGeometry) -> [BallDetection] { [] }
    func detect(in image: PixelImage, geometry: FrameGeometry, feltReference: (UInt8, UInt8, UInt8)?,
                timestamp: Double) -> [BallDetection] { frames(timestamp) }
}

struct D29PipelineTests {
    let scene = SyntheticTableScene.demo()
    var blank: PixelImage { PixelImage(width: 64, height: 36, rgb: [UInt8](repeating: 0, count: 64 * 36 * 3), scale: 30,
                                       sourceWidth: 1920, sourceHeight: 1080) }

    func det(_ p: Vec2, _ kind: BallKind, _ n: Int?) -> BallDetection {
        let geo = FrameGeometry(frame: scene.frame, camera: scene.camera)
        let px = geo.ball.apply(p) ?? p
        return BallDetection(imagePoint: px, tablePoint: p, radiusPx: 12, confidence: 1, kind: kind, tentativeNumber: n)
    }

    /// A numbered ball whose class votes disagree (a flickering 11 vs 3) is not identified: no red ring.
    @Test func flickeringIdentityIsNotAWarning() async throws {
        let W = scene.frame.spec.width, L = scene.frame.spec.length
        let cue = Vec2(0.5, W / 2), obj = Vec2(L * 0.6, W / 2)
        let me = self
        let p = PerceptionPipeline(detector: ScriptedBallDetector { t in
            let i = Int((t * 30).rounded())
            return [me.det(cue, .cue, 0), i % 2 == 0 ? me.det(obj, .stripe, 11) : me.det(obj, .solid, 3)]
        })
        await p.setTable(scene.frame)
        let (engine, base) = TargetLegality.defaultGame()
        var g = base; g.groups = [0: .solids, 1: .stripes]; g.phase = .inPlay
        await p.setLegal(engine.legalTargets(g))
        var last: PerceptionResult?
        for i in 0..<30 { last = await p.process(PerceptionFrame(image: blank, camera: scene.camera, timestamp: Double(i) / 30)) }
        let r = try #require(last)
        #expect(r.confirmed.count == 2)
        #expect(!r.marks.values.contains(.illegal), "\(r.marks)")
    }

    /// No cue stick anywhere: the cue ball leaves rest impulsively → the pipeline starts a shot and Live emits
    /// a balanced aimStarted + aimEnded to the shell.
    @MainActor @Test func impulsiveLaunchWithoutAStickStartsAShotInLive() async throws {
        let W = scene.frame.spec.width, L = scene.frame.spec.length
        let rest = Vec2(0.5, W / 2), obj = Vec2(L * 0.7, W * 0.3)
        let me = self
        // At rest for 1 s, then launched at 2 m/s along +x.
        let p = PerceptionPipeline(detector: ScriptedBallDetector { t in
            let x = t <= 1 ? rest.x : min(L - 0.1, rest.x + 2 * (t - 1))
            return [me.det(Vec2(x, rest.y), .cue, 0), me.det(obj, .solid, 3)]
        })
        await p.setTable(scene.frame)
        let model = LiveModel(mode: .game)
        @MainActor final class Log { var events: [String] = [] }
        let log = Log()
        model.hooks = LiveHooks(aimStarted: { log.events.append("start") }, aimEnded: { log.events.append("end") },
                                aimCancelled: { log.events.append("cancel") }, ballsSettled: {}, settled: { _, _ in })
        var started = false
        for i in 0..<45 {
            guard let r = await p.process(PerceptionFrame(image: blank, camera: scene.camera, timestamp: Double(i) / 30))
            else { continue }
            #expect(r.liveAim == nil)   // no stick in view at any point
            if r.shotStarted { started = true }
            model.drive(r)
        }
        #expect(started)
        #expect(log.events == ["start", "end"])
    }
}

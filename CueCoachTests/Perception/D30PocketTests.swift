import Foundation
import Geometry
import Rules
import Engine
import Testing
@testable import CueCoach

/// D30 "look, then ask" (user, 2026-11-08): a pocket the segmenter isn't sure of (a slow make) is resolved by
/// looking after the balls settle; only if that's still ambiguous does Live ask with a one-tap, icon-only confirm.
/// Rules, the badge and the turn wait on it; nobody answering leaves the shot pending (never a guess).
@MainActor
struct D30PocketTests {
    @MainActor final class Spy {
        var settled: [(DecisionRating, Bool)] = []
        var advanced: GameState?
    }

    /// Bar 8, groups set, the shooter (solids) has only the 3 left.
    func lastSolidGame() -> (RulesEngine, GameState) {
        let (engine, base) = TargetLegality.startingGame(.barEight)
        var g = base
        g.groups = [0: .solids, 1: .stripes]
        g.phase = .inPlay
        g.shooter = 0
        g.onTable = Set([BallID.cue, BallID(3)!, .eight] + (9...15).map { BallID($0)! })
        return (engine, g)
    }

    func model(_ spy: Spy) -> LiveModel {
        let m = LiveModel(mode: .game)
        var h = LiveHooks(aimStarted: {}, aimEnded: {}, aimCancelled: {}, ballsSettled: {},
                          settled: { r, p in spy.settled.append((r, p)) })
        let game = lastSolidGame()
        h.currentGame = { game }
        h.gameAdvanced = { spy.advanced = $0 }
        m.hooks = h
        return m
    }

    let cue = TrackedBall(id: 1, position: Vec2(1.2, 0.6), velocity: .zero, kind: .cue, tentativeNumber: 0, confirmed: true)

    /// The 3 died into the foot-left corner at 0.12 m/s: recorded as an uncertain pocket.
    func slowMake() -> ShotRecord {
        var r = ShotRecord(start: 0, end: 3, preState: [1: Vec2(0.5, 0.5), 2: Vec2(0.3, 0.2)], finalState: [1: Vec2(1.2, 0.6)],
                           cueID: 1, firstContact: 2, rails: [], pocketed: [:])
        r.uncertainPockets = [2: .footLeft]
        return r
    }

    func result(_ t: Double, shot: ShotRecord? = nil, inView: Set<Pocket> = Set(Pocket.allCases),
                occupied: Set<Pocket> = [], extra: [TrackedBall] = [], liveAim: Bool = false) -> PerceptionResult {
        var r = PerceptionResult(timestamp: t, detections: [], tracks: [cue] + extra, marks: [1: .cue], atRest: true, aim: nil,
                                 detectMs: 0)
        r.shot = shot
        r.ballIDs = [1: .cue, 2: BallID(3)!]
        r.pocketsInView = inView
        r.pocketsOccupied = occupied
        if liveAim { r.liveAim = LiveAimTrace(cue: .zero, end: Vec2(1, 0), hitIndex: nil, ghost: nil, objectDirection: nil) }
        return r
    }

    func play(_ m: LiveModel, from t0: Double, seconds: Double, inView: Set<Pocket> = Set(Pocket.allCases),
              occupied: Set<Pocket> = []) {
        var t = t0
        while t < t0 + seconds { t += 1.0 / 15; m.drive(result(t, inView: inView, occupied: occupied)) }
    }

    @Test func slowMakeOfTheLastSolidIsSeenGoneAndTheShooterIsOnTheEight() {
        let spy = Spy(), m = model(spy)
        m.drive(result(3, shot: slowMake()))
        #expect(spy.settled.isEmpty, "Rules wait for the look")
        play(m, from: 3, seconds: 1.5)
        #expect(spy.settled.count == 1)
        #expect(spy.settled.first?.1 == false, "a made ball of the shooter's group keeps the turn")
        let next = try? #require(spy.advanced)
        #expect(next?.onTable.contains(BallID(3)!) == false)
        let (engine, _) = lastSolidGame()
        #expect(next.map { engine.legalTargets($0).contains(.eight) } == true, "on the 8: no red ring on it")
    }

    @Test func ballSeenInTheJawsStaysOnTheTable() {
        let spy = Spy(), m = model(spy)
        m.drive(result(3, shot: slowMake()))
        play(m, from: 3, seconds: 1.5, occupied: [.footLeft])
        #expect(spy.settled.count == 1)
        #expect(spy.settled.first?.1 == true, "nothing dropped: the turn passes")
        #expect(spy.advanced?.onTable.contains(BallID(3)!) == true)
        #expect(m.pocketConfirm == nil)
    }

    @Test func ballSeenElsewhereOnTheTableStaysOnTheTable() {
        let spy = Spy(), m = model(spy)
        m.drive(result(3, shot: slowMake()))
        let three = TrackedBall(id: 7, position: Vec2(0.4, 0.4), velocity: .zero, kind: .solid, tentativeNumber: 3, confirmed: true)
        var t = 3.0
        while t < 4.5 {
            t += 1.0 / 15
            var r = result(t, extra: [three]); r.ballIDs[7] = BallID(3)!
            m.drive(r)
        }
        #expect(spy.settled.first?.1 == true)
    }

    @Test func occludedPocketAsksAndCheckMeansDropped() {
        let spy = Spy(), m = model(spy)
        m.drive(result(3, shot: slowMake()))
        let others = Set(Pocket.allCases).subtracting([.footLeft])
        play(m, from: 3, seconds: 1.5, inView: others)
        #expect(spy.settled.isEmpty)
        let ask = try? #require(m.pocketConfirm)
        #expect(ask?.pocket == .footLeft && ask?.ball == BallID(3)!)
        #expect(m.showsPocketConfirm)
        // Never a guess: nobody answers, it stays pending.
        play(m, from: 4.5, seconds: 10, inView: others)
        #expect(spy.settled.isEmpty && m.pocketConfirm != nil)
        // Hidden while anyone aims.
        m.drive(result(15, inView: others, liveAim: true))
        #expect(!m.showsPocketConfirm)
        m.answerPocket(dropped: true)
        #expect(spy.settled.count == 1 && spy.settled.first?.1 == false)
        #expect(spy.advanced?.onTable.contains(BallID(3)!) == false)
        #expect(m.pocketConfirm == nil)
    }

    @Test func occludedPocketCrossMeansItStayed() {
        let spy = Spy(), m = model(spy)
        m.drive(result(3, shot: slowMake()))
        play(m, from: 3, seconds: 1.5, inView: Set(Pocket.allCases).subtracting([.footLeft]))
        m.answerPocket(dropped: false)
        #expect(spy.settled.count == 1 && spy.settled.first?.1 == true)
        #expect(spy.advanced?.onTable.contains(BallID(3)!) == true)
    }

    /// The confirm is icon-only: its view source has no text (the aiming-path lint covers Live; this pins it).
    @Test func confirmHasNoText() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let src = try String(contentsOf: root.appendingPathComponent("CueCoach/Live/PocketConfirmView.swift"), encoding: .utf8)
        for token in ["Text(", "Label(", ".alert("] { #expect(!src.contains(token), "\(token)") }
        #expect(src.contains("checkmark") && src.contains("xmark"))
        #expect(src.contains("minWidth: 56") || src.contains("width: 56"))
    }
}

/// The pipeline reports which pockets it can see (in frame, no hand over them) and which hold a ball.
struct D30PipelineTests {
    @Test func pocketsInViewAndOccupied() async throws {
        let scene = SyntheticTableScene.demo()
        let cg = try #require(scene.render())
        let px = try #require(PixelImage(cgImage: cg))
        let p = PerceptionPipeline()
        await p.setTable(scene.frame)
        let r = try #require(await p.process(PerceptionFrame(image: px, camera: scene.camera, timestamp: 0)))
        #expect(r.pocketsInView == Set(Pocket.allCases))
        // A hand over the foot-left pocket hides it.
        let geo = FrameGeometry(frame: scene.frame, camera: scene.camera)
        let pk = try #require(geo.cloth.apply(scene.frame.spec.pocketCenter(.footLeft)))
        let r2 = try #require(await p.process(PerceptionFrame(image: px, camera: scene.camera, timestamp: 0.1, wristsByPerson: [[pk]])))
        #expect(!r2.pocketsInView.contains(.footLeft))
        // A tracked ball 5 cm from a pocket occupies it.
        let near = PerceptionPipeline.occupiedPockets([TrackedBall(id: 3, position: scene.frame.spec.pocketCenter(.headRight) + Vec2(0.05, -0.03),
                                                                   velocity: .zero, kind: .solid, tentativeNumber: 3, confirmed: true)],
                                                      spec: scene.frame.spec)
        #expect(near == [.headRight])
    }
}

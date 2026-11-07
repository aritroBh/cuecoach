import Foundation
import Geometry
import Rules
import Testing
@testable import CueCoach

struct LiveStatusTests {
    @Test func flowThroughStates() {
        #expect(LiveStatus.derive(planeFound: false, corners: 0, calibrated: false, trackingOK: true, bumped: false) == .searching)
        #expect(LiveStatus.derive(planeFound: true, corners: 0, calibrated: false, trackingOK: true, bumped: false) == .placing)
        #expect(LiveStatus.derive(planeFound: true, corners: 4, calibrated: false, trackingOK: true, bumped: false) == .confirming)
        #expect(LiveStatus.derive(planeFound: true, corners: 4, calibrated: true, trackingOK: true, bumped: false) == .calibrated)
        #expect(LiveStatus.derive(planeFound: true, corners: 4, calibrated: true, trackingOK: false, bumped: true) == .trackingLost)
        #expect(LiveStatus.derive(planeFound: true, corners: 4, calibrated: true, trackingOK: true, bumped: true) == .phoneMoved)
        #expect(LiveStatus.trackingLost.showsRecalibratePulse && !LiveStatus.calibrated.showsRecalibratePulse)
    }

    @Test func bumpHoldsThenClears() {
        var b = BumpDetector()
        let r0 = b.update(userAcceleration: 0.02, rotationRate: 0.1, at: 0)
        let r1 = b.update(userAcceleration: 0.6, rotationRate: 0.1, at: 1)
        let r2 = b.update(userAcceleration: 0.02, rotationRate: 0.1, at: 2.5)
        let r3 = b.update(userAcceleration: 0.02, rotationRate: 0.1, at: 3.2)
        let r4 = b.update(userAcceleration: 0.0, rotationRate: 2.0, at: 4)
        #expect(!r0 && r1 && r2 && !r3 && r4)
    }
}

struct LegalityTests {
    @Test func openBarEightTable() {
        let (engine, g) = TargetLegality.defaultGame()
        let legal = engine.legalTargets(g)
        #expect(TargetLegality.mark(kind: .cue, number: 0, legal: legal) == .cue)
        #expect(TargetLegality.mark(kind: .eight, number: 8, legal: legal) == .illegal)
        #expect(TargetLegality.mark(kind: .solid, number: 3, legal: legal) == .legal)
        #expect(TargetLegality.mark(kind: .stripe, number: nil, legal: legal) == .legal)
        #expect(TargetLegality.mark(kind: .unknown, number: nil, legal: legal) == .unknown)
    }

    @Test func groupsAssignedMakeOtherGroupIllegal() {
        let (engine, base) = TargetLegality.defaultGame()
        var g = base
        g.groups = [0: .solids, 1: .stripes]
        g.phase = .inPlay
        let legal = engine.legalTargets(g)
        #expect(TargetLegality.mark(kind: .stripe, number: 11, legal: legal) == .illegal)
        #expect(TargetLegality.mark(kind: .solid, number: nil, legal: legal) == .legal)
    }
}

struct ShotPredictorTests {
    let p = GeometricShotPredictor()
    let spec = TableSpec(size: .sevenFoot)

    @Test func stunLeavesOnTheTangentLine() {
        let phi = 0.5
        #expect(abs(p.cueDeflection(cut: phi, spin: .stun) - (.pi / 2 - phi)) < 1e-12)
    }

    @Test func naturalRollIsAboutThirtyDegreesNearHalfBall() {
        let half = 30.0 * .pi / 180
        let d = p.cueDeflection(cut: half, spin: .follow) * 180 / .pi
        #expect(d > 25 && d < 36, "got \(d)")
        #expect(p.cueDeflection(cut: half, spin: .draw) > p.cueDeflection(cut: half, spin: .stun))
    }

    @Test func throwPeaksMidCutAndVanishesStraight() {
        #expect(p.throwAngle(cut: 0, spin: .stun) == 0)
        #expect(p.throwAngle(cut: .pi / 4, spin: .stun) > p.throwAngle(cut: 0.1, spin: .stun))
        #expect(p.throwAngle(cut: .pi / 4, spin: .stun) < 0.09)
    }

    @Test func throwCompensationShiftsGhostAgainstTheCut() throws {
        // A 30° cut into the foot-left corner.
        let pocket = spec.pocketCenter(.footLeft)
        let obj = Vec2(spec.length - 0.4, 0.35)
        let u = (AimPlanner.aimPoint(.footLeft, spec: spec) - obj).normalized
        let cue = obj - u.rotated(by: 0.5) * 0.7
        let s = try #require(AimPlanner.suggest(cue: cue, objects: [obj], spec: spec))
        #expect(s.pocket == .footLeft)
        #expect(s.throwAngle > 0)
        let plain = AimPlanner.ghostBall(object: obj, pocket: AimPlanner.aimPoint(.footLeft, spec: spec))
        #expect(s.ghost.distance(to: plain) > 0.001 && s.ghost.distance(to: plain) < 0.01)
        _ = pocket
    }

    @Test func straightShotSuggestsDrawToAvoidScratch() throws {
        let obj = Vec2(spec.length - 0.35, 0.35)
        let u = (AimPlanner.aimPoint(.footLeft, spec: spec) - obj).normalized
        let s = try #require(AimPlanner.suggest(cue: obj - u * 0.8, objects: [obj], spec: spec))
        #expect(s.cut < 0.05)
        #expect(s.spin == .stun || s.spin == .draw)
        #expect(!AimPlanner.scratches(s.cuePath, spec: spec))
    }

    @Test func cuePathStaysOnTheTable() throws {
        let obj = Vec2(1.2, 0.6)
        let s = try #require(AimPlanner.suggest(cue: Vec2(0.4, 0.3), objects: [obj], spec: spec))
        for q in s.cuePath { #expect(q.x >= 0 && q.x <= spec.length && q.y >= 0 && q.y <= spec.width) }
        #expect((1...5).contains(s.power))
    }

    @Test func longerHarderShotsGetMorePower() {
        #expect(AimPlanner.power(distance: 2.5, cut: 0.9, spin: .draw) > AimPlanner.power(distance: 0.4, cut: 0.1, spin: .stun))
    }
}

import Foundation
import Geometry
import Testing
@testable import CueCoach

struct KalmanTrackerTests {
    func det(_ p: Vec2, _ k: BallKind = .solid) -> BallDetection {
        BallDetection(imagePoint: .zero, tablePoint: p, radiusPx: 10, confidence: 1, kind: k, tentativeNumber: nil)
    }
    let R = TableSpec.ballRadius
    let dt = 1.0 / 30

    @Test func filterLearnsConstantVelocity() {
        var k = CVKalman1D(position: 0, positionVar: 1e-5, velocityVar: 0.25)
        var rng = SplitMix(seed: 2)
        for i in 1...40 {
            k.predict(dt: dt, q: 6)
            k.update(0.8 * Double(i) * dt + rng.gauss() * 0.003, r: 1.6e-5)
        }
        #expect(abs(k.v - 0.8) < 0.08, "v \(k.v)")
    }

    @Test func jitterAtRestStaysBelowRestSpeed() {
        var tr = KalmanBallTracker()
        var rng = SplitMix(seed: 4)
        var rested = false
        for f in 0..<45 {
            _ = tr.update([det(Vec2(1, 0.5) + Vec2(rng.gauss() * 0.003, rng.gauss() * 0.003))], at: Double(f) * dt)
            if tr.isAtRest { rested = true }
        }
        #expect(rested)
    }

    /// Equal-mass head-on collision: A stops at contact, B leaves at A's speed. No ID swap.
    @Test func headOnCollisionKeepsIdentities() {
        var tr = KalmanBallTracker()
        var t = 0.0
        var a = Vec2(0.6, 0.5)
        let b0 = Vec2(1.2, 0.5)
        var b = b0
        var ids: (Int, Int)?
        let v = 1.2
        for f in 0..<60 {
            let contact = b0.x - 2 * R
            if a.x < contact && b == b0 { a.x = min(contact, a.x + v * dt) }
            else { b.x += v * dt }   // after contact A rests, B rolls on
            let out = tr.update([det(b), det(a)], at: t); t += dt
            let ia = out.min { $0.position.distance(to: a) < $1.position.distance(to: a) }!.id
            let ib = out.min { $0.position.distance(to: b) < $1.position.distance(to: b) }!.id
            if f == 8 { ids = (ia, ib) }
            if f > 8, let ids { #expect(ia == ids.0 && ib == ids.1, "swap at frame \(f)") }
        }
    }

    /// Two balls on crossing diagonals pass the same point at different times.
    @Test func crossingPathsKeepIdentities() {
        var tr = KalmanBallTracker()
        var t = 0.0
        var ids: (Int, Int)?
        for f in 0..<50 {
            let s = Double(f) * dt
            let a = Vec2(0.5 + 1.0 * s, 0.3 + 0.6 * s)
            let b = Vec2(0.5 + 1.0 * s, 0.9 - 0.6 * (s - 0.08))
            let out = tr.update([det(a), det(b)], at: t); t += dt
            let ia = out.min { $0.position.distance(to: a) < $1.position.distance(to: a) }!.id
            let ib = out.min { $0.position.distance(to: b) < $1.position.distance(to: b) }!.id
            if f == 6 { ids = (ia, ib) }
            if f > 6, let ids { #expect(ia == ids.0 && ib == ids.1, "swap at frame \(f)") }
        }
    }

    @Test func coastsThroughShortOcclusion() {
        var tr = KalmanBallTracker()
        var t = 0.0, x = 0.5
        var id: Int?
        for _ in 0..<15 { x += 0.03; id = tr.update([det(Vec2(x, 0.5))], at: t).first?.id; t += dt }
        for _ in 0..<4 { x += 0.03; _ = tr.update([], at: t); t += dt }
        x += 0.03
        #expect(tr.update([det(Vec2(x, 0.5))], at: t).first { $0.confirmed }?.id == id)
    }
}

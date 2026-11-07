import Testing
import Foundation
@testable import Geometry

@Suite("Vec2")
struct Vec2Tests {
    @Test func arithmetic() {
        let a = Vec2(3, 4)
        #expect(a.length == 5)
        #expect((a + Vec2(1, 1)) == Vec2(4, 5))
        #expect((a * 2) == Vec2(6, 8))
        #expect(a.dot(Vec2(1, 0)) == 3)
        #expect(Vec2(1, 0).cross(Vec2(0, 1)) == 1)
    }

    @Test func normalizedHasUnitLength() {
        #expect(abs(Vec2(3, 4).normalized.length - 1) < 1e-12)
        #expect(Vec2.zero.normalized == .zero)
    }

    @Test func perpendicularIsCounterClockwise() {
        #expect(Vec2(1, 0).perpendicular == Vec2(0, 1))
    }
}

@Suite("TableSpec")
struct TableSpecTests {
    // WPA Recommended Equipment Specs §5: 9 ft = 100" x 50", 8 ft = 92" x 46". 7 ft (not WPA): Diamond 80" x 40".
    @Test(arguments: [
        (TableSize.sevenFoot, 2.032, 1.016),
        (TableSize.eightFoot, 2.337, 1.168),
        (TableSize.nineFoot, 2.540, 1.270),
    ])
    func playingSurface(size: TableSize, length: Double, width: Double) {
        let spec = TableSpec(size: size)
        #expect(abs(spec.length - length) < 0.002)
        #expect(abs(spec.width - width) < 0.002)
    }

    @Test func standardBallRadius() {
        #expect(abs(TableSpec.ballRadius - 0.028575) < 1e-9)
    }

    @Test func sixPocketsAtCornersAndSides() {
        let spec = TableSpec(size: .nineFoot)
        #expect(spec.pockets.count == 6)
        #expect(spec.pocketCenter(.headLeft) == Vec2(0, 0))
        let side = spec.pocketCenter(.sideRight)
        #expect(abs(side.x - spec.length / 2) < 1e-9)
        #expect(Pocket.sideLeft.isSide && !Pocket.headRight.isSide)
    }

    @Test func spotsOnLongAxisCenterline() {
        let spec = TableSpec(size: .sevenFoot)
        #expect(abs(spec.footSpot.x - spec.length * 0.75) < 1e-9)
        #expect(abs(spec.headSpot.x - spec.length * 0.25) < 1e-9)
        #expect(abs(spec.footSpot.y - spec.width / 2) < 1e-9)
    }
}

@Suite("BallID")
struct BallIDTests {
    @Test func groups() {
        #expect(BallID.cue.group == nil)
        #expect(BallID(3)!.group == .solids)
        #expect(BallID(12)!.group == .stripes)
        #expect(BallID.eight.group == nil)
        #expect(BallID(16) == nil)
        #expect(BallID.allObjectBalls.count == 15)
    }
}

@Suite("TableState")
struct TableStateTests {
    @Test func onTableBallsAndCodableRoundTrip() throws {
        var state = TableState(spec: TableSpec(size: .eightFoot))
        state.balls[.cue] = BallState(position: Vec2(0.5, 0.5))
        state.balls[.eight] = BallState(position: Vec2(1.5, 0.5))
        #expect(state.onTable.count == 2)
        let data = try JSONEncoder().encode(state)
        let back = try JSONDecoder().decode(TableState.self, from: data)
        #expect(back == state)
    }
}

// Head end (kitchen, head spot at L/4) and head pockets must be on the same end of the table.
@Test func headPocketsAreAtHeadEnd() {
    let t = TableSpec(size: .sevenFoot)
    for p in [Pocket.headLeft, .headRight] { #expect(t.pocketCenter(p).x < t.headStringX) }
    for p in [Pocket.footLeft, .footRight] { #expect(t.pocketCenter(p).x > t.footSpot.x - 0.001) }
    #expect(t.pocketCenter(.headLeft).y == 0 && t.pocketCenter(.footLeft).y == 0)
}

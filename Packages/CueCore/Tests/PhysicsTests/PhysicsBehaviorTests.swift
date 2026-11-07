import Foundation
import Geometry
import Physics
import Testing

@Test func slidingToRollingUsesTheFiveSeventhsRule() {
    let params = PhysicsParams.standard
    let stroke = Stroke(direction: Vec2(1, 0), speed: 3)
    let initial = TableState(
        spec: TableSpec(size: .sevenFoot),
        balls: [.cue: BallState(position: Vec2(0.5, 0.5))]
    )
    let trace = Simulator(params: params).simulate(initial, stroke: stroke)

    guard let transition = trace.events.first(where: { $0.event.kind == .slideToRoll }) else {
        #expect(Bool(false), "expected a slide-to-roll event")
        return
    }

    #expect(abs(transition.time - 2 * stroke.speed / (7 * params.slidingFriction * params.gravity)) < 1e-8)
    let atTransition = trace.state(at: transition.time)
    #expect(abs(atTransition.balls[.cue]!.velocity.length - 5 * stroke.speed / 7) < 1e-8)
}

@Test func strokeClampsTipOffsetToMiscueLimit() {
    let stroke = Stroke(direction: Vec2(1, 0), speed: 3, tipOffset: Vec2(0.4, 0.4))
    #expect(abs(stroke.tipOffset.length - 0.5) < 1e-12)
    #expect(abs(stroke.tipOffset.x - 0.3535533905932738) < 1e-12)
    #expect(abs(stroke.tipOffset.y - 0.3535533905932738) < 1e-12)
}

@Test func invalidStrokeProducesNoMotionInsteadOfTrapping() {
    let initial = TableState(spec: TableSpec(size: .sevenFoot), balls: [.cue: BallState(position: Vec2(0.5, 0.5))])
    for speed in [-1.0, Double.nan] {
        let trace = Simulator().simulate(initial, stroke: Stroke(direction: Vec2(1, 0), speed: speed))
        let noMotion = trace.events.isEmpty && trace.duration == 0 && trace.final == initial
        #expect(noMotion)
    }
}

@Test func strokeTraceAndTimedEventRoundTripThroughCodable() throws {
    let initial = TableState(spec: TableSpec(size: .sevenFoot), balls: [.cue: BallState(position: Vec2(0.5, 0.5))])
    let stroke = Stroke(direction: Vec2(1, 0), speed: 2, tipOffset: Vec2(0.2, -0.1))
    let trace = Simulator().simulate(initial, stroke: stroke)
    let event = TimedEvent(time: 1, event: .rest(.cue))

    let strokeData = try JSONEncoder().encode(stroke)
    let traceData = try JSONEncoder().encode(trace)
    let eventData = try JSONEncoder().encode(event)
    #expect(try JSONDecoder().decode(Stroke.self, from: strokeData) == stroke)
    #expect(try JSONDecoder().decode(ShotTrace.self, from: traceData) == trace)
    #expect(try JSONDecoder().decode(TimedEvent.self, from: eventData) == event)
}

@Test func sideEnglishProducesOppositeSquirt() {
    let initial = TableState(
        spec: TableSpec(size: .sevenFoot),
        balls: [.cue: BallState(position: Vec2(0.5, 0.5))]
    )
    let stroke = Stroke(direction: Vec2(1, 0), speed: 3, tipOffset: Vec2(0.5, 0))
    let trace = Simulator().simulate(initial, stroke: stroke)

    let angleDegrees = abs(trace.state(at: 0).balls[.cue]!.velocity.angle) * 180 / .pi
    #expect(angleDegrees >= 1 && angleDegrees <= 3)
}

@Test func frictionalCutCollisionProducesSmallThrow() {
    let spec = TableSpec(size: .sevenFoot)
    let initial = TableState(
        spec: spec,
        balls: [
            .cue: BallState(position: Vec2(0.4, 0.5)),
            BallID(1)!: BallState(position: Vec2(0.9, 0.53)),
        ]
    )
    let trace = Simulator().simulate(initial, stroke: Stroke(direction: Vec2(1, 0), speed: 4))
    let contact = trace.events.first(where: { $0.event.kind == .ballBall })!
    let before = trace.state(at: contact.time - 1e-8)
    let after = trace.state(at: contact.time)
    let normal = (before.balls[BallID(1)!]!.position - before.balls[.cue]!.position).normalized
    let rawThrow = after.balls[BallID(1)!]!.velocity.angle - normal.angle
    let throwDegrees = atan2(sin(rawThrow), cos(rawThrow)) * 180 / .pi

    #expect(abs(throwDegrees) >= 1)
    #expect(abs(throwDegrees) <= 4)
}

@Test func followAndDrawChangeCueBallDeparture() {
    let spec = TableSpec(size: .sevenFoot)
    let initial = TableState(
        spec: spec,
        balls: [
            .cue: BallState(position: Vec2(0.4, 0.5)),
            BallID(1)!: BallState(position: Vec2(0.68, 0.5)),
        ]
    )
    let simulator = Simulator()
    let stun = simulator.simulate(initial, stroke: Stroke(direction: Vec2(1, 0), speed: 3, tipOffset: .zero))
    let follow = simulator.simulate(initial, stroke: Stroke(direction: Vec2(1, 0), speed: 3, tipOffset: Vec2(0, 0.45)))
    let draw = simulator.simulate(initial, stroke: Stroke(direction: Vec2(1, 0), speed: 3, tipOffset: Vec2(0, -0.45)))
    let st = stun.events.first(where: { $0.event.kind == .ballBall })!.time
    let ft = follow.events.first(where: { $0.event.kind == .ballBall })!.time
    let dt = draw.events.first(where: { $0.event.kind == .ballBall })!.time
    let stunAfter = stun.state(at: st).balls[.cue]!.velocity
    let followAfter = follow.state(at: ft + 0.1).balls[.cue]!
    let drawAfter = draw.state(at: dt + 0.1).balls[.cue]!
    #expect(stunAfter.x > 0 && stunAfter.x < 0.5)
    #expect(abs(stunAfter.y) < 0.05)
    #expect(followAfter.velocity.x > stunAfter.x)
    #expect(drawAfter.velocity.x < stunAfter.x)
    #expect(followAfter.velocity.x > drawAfter.velocity.x + 0.2)
}

@Test func ballReboundsFromCushionWithLossAndSpinDeflection() {
    let spec = TableSpec(size: .sevenFoot)
    let initial = TableState(
        spec: spec,
        balls: [.cue: BallState(position: Vec2(spec.length / 2 + 0.2, 0.35))]
    )
    let trace = Simulator().simulate(initial, stroke: Stroke(direction: Vec2(0, -1), speed: 4, tipOffset: Vec2(0.4, 0)))
    let incoming = trace.state(at: 0).balls[.cue]!.velocity
    let cushionEvent = trace.events.first(where: { $0.event.kind == .cushion })!
    let outgoing = trace.state(at: cushionEvent.time).balls[.cue]!.velocity

    #expect(trace.events.contains { $0.event.kind == .cushion })
    #expect(outgoing.length > 0 && outgoing.length < incoming.length)
    #expect(outgoing.y > 0)
}

@Test func pocketMouthCapturesAimedBallAndJawsRejectNearMiss() {
    let spec = TableSpec(size: .sevenFoot)
    let captured = TableState(
        spec: spec,
        balls: [.cue: BallState(position: Vec2(0.20, 0.20))]
    )
    let capturedTrace = Simulator().simulate(captured, stroke: Stroke(direction: Vec2(-1, -1), speed: 2))
    #expect(capturedTrace.final.balls[.cue]!.motion == .pocketed)

    let jawMiss = TableState(
        spec: spec,
        balls: [.cue: BallState(position: Vec2(0.20, 0.20))]
    )
    let missedTrace = Simulator().simulate(jawMiss, stroke: Stroke(direction: Vec2(-1, 0), speed: 2))
    #expect(missedTrace.final.balls[.cue]!.motion != .pocketed)
    #expect(missedTrace.events.contains { $0.event.kind == .cushion })
}

@Test func sameInputProducesIdenticalTrace() {
    let spec = TableSpec(size: .sevenFoot)
    let initial = TableState(
        spec: spec,
        balls: [
            .cue: BallState(position: Vec2(0.4, 0.5)),
            BallID(1)!: BallState(position: Vec2(0.8, 0.52)),
        ]
    )
    let stroke = Stroke(direction: Vec2(1, 0), speed: 4, tipOffset: Vec2(0.2, -0.1))

    #expect(Simulator().simulate(initial, stroke: stroke) == Simulator().simulate(initial, stroke: stroke))
}

@Test func pathSamplesIncludeTheInitialAndFinalBallPositions() {
    let initialPosition = Vec2(0.4, 0.5)
    let initial = TableState(spec: TableSpec(size: .sevenFoot), balls: [.cue: BallState(position: initialPosition)])
    let trace = Simulator().simulate(initial, stroke: Stroke(direction: Vec2(1, 0), speed: 2))
    let sampleDT = 0.05
    let path = trace.path(of: .cue, sampleDT: sampleDT)

    #expect(path.first == initialPosition)
    #expect(path.last == trace.final.balls[.cue]!.position)
    let samplesMatch = (1..<max(1, path.count - 1)).allSatisfy { index in
        path[index].distance(to: trace.state(at: Double(index) * sampleDT).balls[.cue]!.position) < 1e-12
    }
    #expect(samplesMatch)
}

@Test func straightStopShotTransfersNearlyAllCueSpeedToObjectBall() {
    let spec = TableSpec(size: .sevenFoot)
    let objectID = BallID(1)!
    let initial = TableState(
        spec: spec,
        balls: [
            .cue: BallState(position: Vec2(0.4, 0.5)),
            objectID: BallState(position: Vec2(0.8, 0.5)),
        ]
    )
    let trace = Simulator().simulate(initial, stroke: Stroke(direction: Vec2(1, 0), speed: 3))
    let impact = trace.events.first(where: { $0.event.kind == .ballBall })!
    let state = trace.state(at: impact.time)

    #expect(state.balls[objectID]!.velocity.x > 2)
    #expect(abs(state.balls[.cue]!.velocity.x) < 0.2)
}

@Test func aimGeometryProvidesGhostBallTangentAndThirtyDegreeLine() {
    let object = Vec2(1, 0.5)
    let pocket = Vec2(2, 0.5)
    let ghost = AimGeometry.ghostBall(object: object, pocket: pocket)
    #expect(abs(ghost.distance(to: object) - 2 * TableSpec.ballRadius) < 1e-12)

    let tangent = AimGeometry.tangentDirection(contactNormal: Vec2(1, 0))
    #expect(abs(tangent.dot(Vec2(1, 0))) < 1e-12)
    let thirty = AimGeometry.thirtyDegreeRuleDirection(shotDirection: Vec2(1, 0), cutAngle: 0.4)
    #expect(abs(thirty.angle + .pi / 6) < 1e-12)
}

@Test func typicalFourBallSimulationPerf() {
    let spec = TableSpec(size: .sevenFoot)
    let balls: [BallID: BallState] = [
        .cue: BallState(position: Vec2(0.45, 0.5)),
        BallID(1)!: BallState(position: Vec2(0.9, 0.5)),
        BallID(2)!: BallState(position: Vec2(1.3, 0.6)),
        BallID(3)!: BallState(position: Vec2(1.5, 0.3)),
        BallID(4)!: BallState(position: Vec2(1.7, 0.7)),
    ]
    let initial = TableState(spec: spec, balls: balls)
    let simulator = Simulator()
    let stroke = Stroke(direction: Vec2(1, 0.03), speed: 4)
    let clock = ContinuousClock()
    _ = simulator.simulate(initial, stroke: stroke)
    var samples: [Double] = []
    for _ in 0..<10 {
        let start = clock.now
        _ = simulator.simulate(initial, stroke: stroke)
        let elapsed = start.duration(to: clock.now).components
        samples.append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
    }
    let average = samples.reduce(0, +) / Double(samples.count)
    let maximum = samples.max() ?? .infinity
    print(String(format: "Physics perf: average %.3f ms, max %.3f ms (10 runs)", average, maximum))
#if !DEBUG
    #expect(maximum < 5)
#endif
}

private func rackBreakState() -> TableState {
    let spec = TableSpec(size: .sevenFoot)
    let diameter = 2 * TableSpec.ballRadius + 1e-6
    var balls: [BallID: BallState] = [
        .cue: BallState(position: Vec2(spec.length * 0.25, spec.width / 2))
    ]
    var number = 1
    let apexX = spec.length * 0.75
    for row in 0..<5 {
        for column in 0...row {
            let y = spec.width / 2 + (Double(column) - Double(row) / 2) * diameter
            let x = apexX + Double(row) * diameter * sqrt(3) / 2
            balls[BallID(number)!] = BallState(position: Vec2(x, y))
            number += 1
        }
    }
    return TableState(spec: spec, balls: balls)
}

@Test func sixteenBallRackBreakPerf() {
    let simulator = Simulator()
    let initial = rackBreakState()
    let stroke = Stroke(direction: Vec2(1, 0), speed: 8)
    let clock = ContinuousClock()
    _ = simulator.simulate(initial, stroke: stroke)
    var samples: [Double] = []
    for _ in 0..<10 {
        let start = clock.now
        _ = simulator.simulate(initial, stroke: stroke)
        let elapsed = start.duration(to: clock.now).components
        samples.append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
    }
    let average = samples.reduce(0, +) / Double(samples.count)
    let maximum = samples.max() ?? .infinity
    print(String(format: "Physics 16-ball rack break perf: average %.3f ms, max %.3f ms (10 runs)", average, maximum))
#if !DEBUG
    #expect(average < 5)
#endif
}

@Test func eventCapMarksTraceTruncated() {
    let spec = TableSpec(size: .sevenFoot)
    let params = PhysicsParams(slidingFriction: 0, rollingFriction: 0, cushionRestitution: 1,
                              cushionFriction: 0, cushionHeight: TableSpec.ballRadius)
    let initial = TableState(spec: spec, balls: [.cue: BallState(position: Vec2(spec.length / 2, spec.width / 2))])
    let trace = Simulator(params: params).simulate(initial, stroke: Stroke(direction: Vec2(1, 0), speed: 2))

    #expect(trace.events.count == 4096)
    let truncated = trace.truncated
    #expect(truncated)
    #expect(trace.final.balls[.cue]!.velocity.length > 0)
}

// Pocket labels must agree with Geometry.TableSpec.pocketCenter (head end at x = 0).
@Test(arguments: Pocket.allCases)
func pocketEventLabelMatchesGeometry(pocket: Pocket) {
    let spec = TableSpec(size: .sevenFoot)
    let target = spec.pocketCenter(pocket)
    let center = Vec2(spec.length / 2, spec.width / 2)
    let direction = (target - center).normalized
    let start = target - direction * 0.25
    let initial = TableState(spec: spec, balls: [.cue: BallState(position: start)])
    let trace = Simulator().simulate(initial, stroke: Stroke(direction: direction, speed: 1.5))
    let pocketed = trace.events.compactMap { e -> Pocket? in
        if case let .pocket(_, p) = e.event { return p } else { return nil }
    }
    #expect(pocketed == [pocket])
}

@Test func railLabelsMatchGeometryEnds() {
    let spec = TableSpec(size: .sevenFoot)
    func firstRail(_ dir: Vec2) -> Rail? {
        let s = TableState(spec: spec, balls: [.cue: BallState(position: Vec2(spec.length / 2 + 0.2, spec.width / 2))])
        return Simulator().simulate(s, stroke: Stroke(direction: dir, speed: 1)).events.compactMap { e -> Rail? in
            if case let .cushion(_, r) = e.event { return r } else { return nil }
        }.first
    }
    #expect(firstRail(Vec2(-1, 0)) == .head)
    #expect(firstRail(Vec2(1, 0)) == .foot)
}

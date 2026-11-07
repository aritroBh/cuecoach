import Foundation
import Geometry
import Physics
import Testing

private struct FixtureFile: Decodable {
    let seed: Int
    let models: [String: String]
    let generatorAudit: FixtureGeneratorAudit?
    let shots: [FixtureShot]
}

private struct FixtureGeneratorAudit: Decodable {
    let randomShotAttempts: Int
    let rejectedRandomShotCount: Int
    let rejectedRandomShots: [FixtureRejection]
    let rejectedShotCount: Int
    let rejectedShots: [FixtureRejection]
}

private struct FixtureRejection: Decodable {
    let id: String
    let tag: String
    let reasons: [String]
}

private struct FixtureShot: Decodable {
    let id: String
    let tag: String
    let table: FixtureTable
    let initial: FixtureInitial
    let stroke: FixtureStroke
    let events: [FixtureEvent]
    let final: FixtureFinal
}

private struct FixtureTable: Decodable { let size: String }
private struct FixtureInitial: Decodable { let balls: [FixtureBall] }
private struct FixtureBall: Decodable { let id: Int; let position: FixturePoint }
private struct FixturePoint: Decodable { let x: Double; let y: Double }
private struct FixtureStroke: Decodable {
    let direction: FixturePoint
    let speed: Double
    let tipOffset: FixturePoint
}
private struct FixtureEvent: Decodable {
    let type: String
    let ballIDs: [Int]
    let time: Double
    let cushionID: String?
    let pocket: String?
}
private struct FixtureFinal: Decodable {
    let balls: [FixtureBall]
    let pocketed: [Int]
}

private func fixture() throws -> FixtureFile {
    let url = Bundle.module.url(forResource: "pooltool_fixtures", withExtension: "json", subdirectory: "Fixtures")!
    return try JSONDecoder().decode(FixtureFile.self, from: Data(contentsOf: url))
}

private func simulate(_ shot: FixtureShot, params: PhysicsParams = .standard) -> ShotTrace {
    let size = TableSize(rawValue: shot.table.size)!
    let balls = Dictionary(uniqueKeysWithValues: shot.initial.balls.map { ball in
        (BallID(ball.id)!, BallState(position: Vec2(ball.position.x, ball.position.y)))
    })
    let initial = TableState(spec: TableSpec(size: size), balls: balls)
    let stroke = Stroke(
        direction: Vec2(shot.stroke.direction.x, shot.stroke.direction.y),
        speed: shot.stroke.speed,
        tipOffset: Vec2(shot.stroke.tipOffset.x, shot.stroke.tipOffset.y)
    )
    return Simulator(params: params).simulate(initial, stroke: stroke)
}

private func eventMatches(_ actual: TimedEvent, _ expected: FixtureEvent) -> Bool {
    guard actual.event.kind.rawValue == expected.type,
          actual.event.ballIDs.map(\.number) == expected.ballIDs else { return false }
    if expected.type == "pocket" {
        guard case let .pocket(_, pocket) = actual.event else { return false }
        return pocket.rawValue == expected.pocket
    }
    return true
}

private func assertNoUnpocketedBallLeavesTable(_ shot: FixtureShot, _ trace: ShotTrace) {
    let spec = trace.final.spec
    let envelope = PhysicsParams.standard.cushionWidth + TableSpec.ballRadius
    for (id, initialBall) in trace.initial.balls {
        let pocketTime = trace.events.first {
            if case let .pocket(ball, _) = $0.event { return ball == id }
            return false
        }?.time
        var time = 0.0
        var escaped: (Double, Vec2)?
        while time < trace.duration && pocketTime.map({ time < $0 }) != false {
            // state(at:) is the raw integrated position. Allow the cushion envelope around mouths.
            let position = trace.state(at: time).balls[id]?.position ?? initialBall.position
            if position.x < -envelope || position.x > spec.length + envelope ||
                position.y < -envelope || position.y > spec.width + envelope {
                escaped = (time, position)
                break
            }
            time += 0.01
        }
        #expect(escaped == nil, "\(shot.id): ball \(id) escaped at \(escaped?.0 ?? 0): \(escaped?.1 ?? .zero)")
        if let ball = trace.final.balls[id], ball.motion != .pocketed {
            #expect(ball.position.x >= -envelope && ball.position.x <= spec.length + envelope,
                    "\(shot.id): unpocketed ball \(id) ended outside length bounds: \(ball.position)")
            #expect(ball.position.y >= -envelope && ball.position.y <= spec.width + envelope,
                    "\(shot.id): unpocketed ball \(id) ended outside width bounds: \(ball.position)")
        }
    }
}

@Test func pooltoolFixturesMeetD10() throws {
    let fixture = try fixture()
    let randomShots = fixture.shots.filter { ["break", "cluster", "sparse"].contains($0.tag) }
    let breakShots = randomShots.filter { $0.tag == "break" }
    let clusterShots = randomShots.filter { $0.tag == "cluster" }
    let sparseShots = randomShots.filter { $0.tag == "sparse" }
    let simpleShots = fixture.shots.filter { $0.tag == "simple" }
    let regressionIDs: Set<String> = ["random_319", "random_193", "random_304", "random_444"]
    let regressionShots = fixture.shots.filter { regressionIDs.contains($0.id) }
    let generatorAudit = try #require(fixture.generatorAudit)
    let rejectedRandomShots = generatorAudit.rejectedRandomShots
    #expect(randomShots.count + rejectedRandomShots.count == 500)
    #expect(breakShots.count + rejectedRandomShots.filter { $0.tag == "break" }.count == 50)
    #expect(clusterShots.count + rejectedRandomShots.filter { $0.tag == "cluster" }.count == 100)
    #expect(sparseShots.count + rejectedRandomShots.filter { $0.tag == "sparse" }.count == 350)
    #expect(breakShots.allSatisfy { $0.initial.balls.count == 16 })
    #expect((clusterShots + sparseShots).allSatisfy { (8...15).contains($0.initial.balls.count) })
    #expect(simpleShots.count >= 20)
    #expect(regressionShots.count == 4)
    #expect(generatorAudit.rejectedRandomShotCount == generatorAudit.rejectedRandomShots.count)
    #expect(generatorAudit.rejectedShotCount == generatorAudit.rejectedShots.count)
    #expect(generatorAudit.rejectedShotCount == generatorAudit.rejectedRandomShotCount)
    #expect(generatorAudit.randomShotAttempts == randomShots.count + generatorAudit.rejectedRandomShotCount)
    #expect(generatorAudit.rejectedShots.allSatisfy { !$0.reasons.isEmpty })

    let highSpinShots = randomShots.filter {
        hypot($0.stroke.tipOffset.x, $0.stroke.tipOffset.y) > 0.4
    }
    #expect(highSpinShots.count >= 10)
    let angledBreaks = breakShots.filter { abs($0.stroke.direction.y) > 0.02 }
    #expect(angledBreaks.count >= 5)
    let offCenterBreaks = breakShots.filter { shot in
        guard let cue = shot.initial.balls.first(where: { $0.id == 0 }) else { return false }
        let spec = TableSpec(size: TableSize(rawValue: shot.table.size)!)
        return abs(cue.position.y - spec.width / 2) > 0.005
    }
    #expect(offCenterBreaks.count >= 5)

    func compare(_ shot: FixtureShot, tolerance: Double, diagnostic: inout String?) -> Bool {
        let trace = simulate(shot)
        let expectedPocketed = Set(shot.final.pocketed)
        let actualPocketed = Set(trace.final.balls.filter { $0.value.motion == .pocketed }.keys.map(\.number))
        let positionsMatch = shot.final.balls.allSatisfy { expected in
            guard let actual = trace.final.balls[BallID(expected.id)!] else { return false }
            return actual.position.distance(to: Vec2(expected.position.x, expected.position.y)) <= tolerance
        }
        let sequenceMatches = shot.events.count == trace.events.count &&
            zip(shot.events, trace.events).allSatisfy { expected, actual in eventMatches(actual, expected) }
        let pass = sequenceMatches && expectedPocketed == actualPocketed && positionsMatch
        if !pass && diagnostic == nil {
            var mismatchIndex: Int?
            for index in 0..<min(shot.events.count, trace.events.count)
                where !eventMatches(trace.events[index], shot.events[index]) {
                mismatchIndex = index
                break
            }
            let expectedEvents = shot.events.prefix(8).map { "\($0.type)\($0.ballIDs)@\($0.time)" }
            let actualEvents = trace.events.prefix(8).map { "\($0.event.kind.rawValue)\($0.event.ballIDs.map { $0.number })@\($0.time)" }
            let maxError = shot.final.balls.compactMap { expected in
                trace.final.balls[BallID(expected.id)!].map {
                    $0.position.distance(to: Vec2(expected.position.x, expected.position.y))
                }
            }.max() ?? .infinity
            let mismatch = mismatchIndex.map { " at \($0): \(shot.events[$0].type)\(shot.events[$0].ballIDs)@\(shot.events[$0].time) vs \(trace.events[$0].event.kind.rawValue)\(trace.events[$0].event.ballIDs.map { $0.number })@\(trace.events[$0].time)" } ?? " after shared prefix"
            let start = max(0, (mismatchIndex ?? 0) - 2)
            let expectedWindow = shot.events.dropFirst(start).prefix(5).map { "\($0.type)\($0.ballIDs)@\($0.time)" }
            let actualWindow = trace.events.dropFirst(start).prefix(5).map { "\($0.event.kind.rawValue)\($0.event.ballIDs.map { $0.number })@\($0.time)" }
            diagnostic = "\(shot.id) speed=\(shot.stroke.speed), balls=\(shot.initial.balls.count), tip=\(shot.stroke.tipOffset): events \(shot.events.count)/\(trace.events.count)\(mismatch), window expected \(expectedWindow), actual \(actualWindow), first expected \(expectedEvents), actual \(actualEvents), pocket \(expectedPocketed)/\(actualPocketed), max position error \(maxError)"
        }
        return pass
    }

    func report(_ name: String, _ shots: [FixtureShot], tolerance: Double, denominator: Int? = nil) -> Int {
        var passed = 0
        var diagnostics: [String] = []
        for shot in shots {
            var diagnostic: String?
            let shotPassed = compare(shot, tolerance: tolerance, diagnostic: &diagnostic)
            if shotPassed { passed += 1 }
            else if diagnostics.count < 3, let diagnostic { diagnostics.append(diagnostic) }
        }
        let total = denominator ?? shots.count
        let rate = 100 * Double(passed) / Double(max(1, total))
        print(String(format: "Pooltool fixture pass rate: %@ %.1f%% (%d/%d)", name, rate, passed, total))
        for diagnostic in diagnostics { print("  \(diagnostic)") }
        return passed
    }

    let breakPassed = report("break", breakShots, tolerance: TableSpec.ballRadius, denominator: 50)
    let clusterPassed = report("cluster", clusterShots, tolerance: TableSpec.ballRadius, denominator: 100)
    let sparsePassed = report("sparse", sparseShots, tolerance: TableSpec.ballRadius, denominator: 350)
    let regressionPassed = report("jaw regressions", regressionShots, tolerance: TableSpec.ballRadius)
    let randomPassed = breakPassed + clusterPassed + sparsePassed
    let simplePassed = report("simple", simpleShots, tolerance: 0.005)
    print(String(format: "Pooltool fixture pass rate: random total %.1f%% (%d/500)",
                 100 * Double(randomPassed) / 500, randomPassed))
    #expect(randomPassed * 100 >= 500 * 95)
    #expect(regressionPassed == regressionShots.count)
    #expect(simplePassed == simpleShots.count)
    #expect(fixture.seed == 20261106)
    #expect(fixture.models["ballBall"] == "frictional_inelastic + alciatore")
}

@Test func random319JawRegressionCannotEscape() throws {
    let shot = try #require(fixture().shots.first { $0.id == "random_319" })
    let trace = simulate(shot)
    assertNoUnpocketedBallLeavesTable(shot, trace)
    #expect(trace.events.contains { $0.event.kind == .cushion })
}

@Test func random193JawRegressionCannotEscape() throws {
    let shot = try #require(fixture().shots.first { $0.id == "random_193" })
    let trace = simulate(shot)
    assertNoUnpocketedBallLeavesTable(shot, trace)
    #expect(trace.events.contains { $0.event.kind == .cushion })
}

@Test func random304JawRegressionCannotEscape() throws {
    let shot = try #require(fixture().shots.first { $0.id == "random_304" })
    let trace = simulate(shot)
    assertNoUnpocketedBallLeavesTable(shot, trace)
    #expect(trace.events.contains { $0.event.kind == .cushion })
}

@Test func random444JawRegressionCannotEscape() throws {
    let shot = try #require(fixture().shots.first { $0.id == "random_444" })
    let trace = simulate(shot)
    assertNoUnpocketedBallLeavesTable(shot, trace)
    #expect(trace.events.contains { $0.event.kind == .cushion })
}

@Test func stress145PathSamplesKeepRawPositionThroughSidePocketMouth() throws {
    let shot = try #require(fixture().shots.first { $0.id == "stress_145" })
    let trace = simulate(shot)
    let expectedPocket = try #require(shot.events.first { $0.type == "pocket" && $0.ballIDs == [0] })
    let sampleDT = 0.01
    let sampleIndex = Int((expectedPocket.time - sampleDT) / sampleDT)
    let sampleTime = Double(sampleIndex) * sampleDT
    let statePosition = try #require(trace.state(at: sampleTime).balls[.cue]).position
    let path = trace.path(of: .cue, sampleDT: sampleDT)
    let pathPosition = path[sampleIndex]
    let spec = trace.final.spec

    #expect(statePosition.y > spec.width || statePosition.y < 0 || statePosition.x < 0 || statePosition.x > spec.length)
    #expect(pathPosition.distance(to: statePosition) < 1e-12)
}

@Test func stress482CueRestingInSidePocketMouthIsNotOffTableOrMoved() throws {
    let shot = try #require(fixture().shots.first { $0.id == "stress_482" })
    let trace = simulate(shot)
    let cue = try #require(trace.final.balls[.cue])

    #expect(!trace.events.contains { $0.event == .offTable(.cue) })
    #expect(cue.position.y < 0)
}

@Test func openPocketMissBecomesOffTableEventAtTheBoundary() {
    let spec = TableSpec(size: .sevenFoot)
    let params = PhysicsParams(cornerPocketRadius: 0, sidePocketRadius: 0)
    let initial = TableState(spec: spec, balls: [.cue: BallState(position: Vec2(spec.length / 2, 0.12))])
    let trace = Simulator(params: params).simulate(initial, stroke: Stroke(direction: Vec2(0, -1), speed: 2))

    #expect(trace.events.contains { $0.event.kind.rawValue == "offTable" })
    #expect(trace.final.balls[.cue]!.position.y >= 0)
}

@Test func initiallyOffTableBallIsRecordedAndClamped() {
    let spec = TableSpec(size: .sevenFoot)
    let objectID = BallID(1)!
    let initial = TableState(spec: spec, balls: [
        .cue: BallState(position: Vec2(0.5, spec.width / 2)),
        objectID: BallState(position: Vec2(-0.1, spec.width / 2)),
    ])
    let trace = Simulator().simulate(initial, stroke: Stroke(direction: Vec2(1, 0), speed: 1))

    #expect(trace.events.contains { $0.event.ballIDs.contains(objectID) && $0.event.kind.rawValue == "offTable" })
    #expect(trace.final.balls[objectID]!.position.x == 0)
    #expect(trace.path(of: objectID, sampleDT: 0.01).first?.x == -0.1)
}

@Test func ballThatStopsInsideCushionEnvelopeIsNotMovedOffTable() {
    let spec = TableSpec(size: .sevenFoot)
    let params = PhysicsParams(rollingFriction: 100)
    let initial = TableState(spec: spec, balls: [.cue: BallState(position: Vec2(0.0001, spec.width / 2))])
    let trace = Simulator(params: params).simulate(initial, stroke: Stroke(direction: Vec2(-1, 0), speed: 0.05))

    #expect(!trace.events.contains { $0.event == .offTable(.cue) })
    #expect(trace.final.balls[.cue]!.position.x < 0)
}

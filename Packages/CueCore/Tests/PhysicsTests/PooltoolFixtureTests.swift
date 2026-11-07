import Foundation
import Geometry
import Physics
import Testing

private struct FixtureFile: Decodable {
    let seed: Int
    let models: [String: String]
    let shots: [FixtureShot]
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
private struct FixtureEvent: Decodable { let type: String; let ballIDs: [Int]; let time: Double }
private struct FixtureFinal: Decodable {
    let balls: [FixtureBall]
    let pocketed: [Int]
}

@Test func pooltoolFixturesMeetD10() throws {
    let url = Bundle.module.url(forResource: "pooltool_fixtures", withExtension: "json", subdirectory: "Fixtures")
    #expect(url != nil, "run tools/physics_fixtures/generate.py to create fixtures")
    guard let url else { return }
    let fixture = try JSONDecoder().decode(FixtureFile.self, from: Data(contentsOf: url))
    let randomShots = fixture.shots.filter { $0.tag == "random" }
    let simpleShots = fixture.shots.filter { $0.tag == "simple" }
    #expect(randomShots.count == 500)
    #expect(simpleShots.count >= 20)

    let simulator = Simulator()
    func compare(_ shot: FixtureShot, tolerance: Double) -> Bool {
        guard let size = TableSize(rawValue: shot.table.size) else { return false }
        let balls = Dictionary(uniqueKeysWithValues: shot.initial.balls.map { ball in
            (BallID(ball.id)!, BallState(position: Vec2(ball.position.x, ball.position.y)))
        })
        let initial = TableState(spec: TableSpec(size: size), balls: balls)
        let stroke = Stroke(
            direction: Vec2(shot.stroke.direction.x, shot.stroke.direction.y),
            speed: shot.stroke.speed,
            tipOffset: Vec2(shot.stroke.tipOffset.x, shot.stroke.tipOffset.y)
        )
        let trace = simulator.simulate(initial, stroke: stroke)
        let expectedTypes = shot.events.map(\.type)
        let actualTypes = trace.events.map { $0.event.kind.rawValue }
        let expectedPocketed = Set(shot.final.pocketed)
        let actualPocketed = Set(trace.final.balls.filter { $0.value.motion == .pocketed }.keys.map(\.number))
        let positionsMatch = shot.final.balls.allSatisfy { expected in
            guard let actual = trace.final.balls[BallID(expected.id)!] else { return false }
            return actual.position.distance(to: Vec2(expected.position.x, expected.position.y)) <= tolerance
        }
        let sequenceMatches = expectedTypes == actualTypes
        let pocketMatches = expectedPocketed == actualPocketed
        let pass = sequenceMatches && pocketMatches && positionsMatch
        return pass
    }

    let randomPassed = randomShots.filter { compare($0, tolerance: TableSpec.ballRadius) }.count
    let simplePassed = simpleShots.filter { compare($0, tolerance: 0.005) }.count
    let randomRate = 100 * Double(randomPassed) / Double(max(1, randomShots.count))
    let simpleRate = 100 * Double(simplePassed) / Double(max(1, simpleShots.count))
    print(String(format: "Pooltool fixture pass rate: random %.1f%% (%d/%d); simple %.1f%% (%d/%d)",
                 randomRate, randomPassed, randomShots.count, simpleRate, simplePassed, simpleShots.count))
    #expect(randomPassed * 100 >= randomShots.count * 95)
    #expect(simplePassed == simpleShots.count)
    #expect(fixture.seed == 20261106)
    #expect(fixture.models["ballBall"] == "frictional_inelastic + alciatore")
}

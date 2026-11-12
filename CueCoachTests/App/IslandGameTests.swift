import Foundation
import Testing
import Geometry
import Rules
@testable import CueCoach

/// Plan 013a over real sessions on one `MemoryHub`: a two-phone game split by a link cut keeps scoring on both
/// phones (D44), and after the heal both fold the same merged shots.
@MainActor
@Suite(.serialized) struct IslandGameTests {
    let a = ShellPlayer(id: UUID(), name: "A1", symbol: "hare.fill", colorName: "teal")
    let b = ShellPlayer(id: UUID(), name: "B1", symbol: "bolt.fill", colorName: "orange")

    func game(on link: MeshGameLink) -> GameSessionModel {
        let g = GameSessionModel(config: GameConfig(ruleSet: .barEight, tableSize: .sevenFoot, teams: [[a], [b]]))
        g.mesh = link
        return g
    }

    /// Ball positions for physical shot `n`, distinct per shot.
    static func before(_ n: Int) -> [BallID: Vec2] {
        [.cue: Vec2(0.3 + 0.1 * Double(n), 0.5), BallID(n + 1)!: Vec2(1.5, 0.3 + 0.05 * Double(n))]
    }

    /// The phones in `gs` see physical shot `n`: each ends the aim, then settles its own view (a miss).
    static func shoot(_ n: Int, on gs: [GameSessionModel]) {
        for g in gs { g.aimStarted(); g.aimEnded() }
        for g in gs {
            g.shotSettled(SettledShot(rating: .okay, turnPasses: true, before: before(n),
                                      outcome: ShotOutcome(firstContact: BallID(n + 1)!)))
        }
    }

    @Test func afterHealBothPhonesFoldTheSameShots() async throws {
        let hub = MemoryHub()
        let (host, joiner) = await MeshGameLinkTests.pair(hub)
        let gA = game(on: host.0), gB = game(on: joiner.0)
        Self.shoot(0, on: [gA, gB])
        #expect(await poll(2) { gA.shots.count == 1 && gB.shots.count == 1 })

        hub.partition([host.2.localPeer], [joiner.2.localPeer])
        #expect(await poll(4) { host.0.isIsland && joiner.0.isIsland }, "both phones are islands")
        Self.shoot(1, on: [gA, gB])                       // both see shot 1
        try await Task.sleep(for: .milliseconds(800))
        Self.shoot(2, on: [gA])                           // only the old host sees shot 2
        try await Task.sleep(for: .milliseconds(800))
        Self.shoot(3, on: [gB])                           // only the joiner sees shot 3
        #expect(gB.badge.current?.isProvisional == true, "D48: an island's own badge is provisional")

        hub.heal()
        let merged = await poll(6) {
            gA.shots.count == 4 && gA.shots.map(\.id) == gB.shots.map(\.id) && !host.0.isIsland && !joiner.0.isIsland
        }
        #expect(merged, "A: \(gA.shots.map(\.before)), B: \(gB.shots.map(\.before))")
        #expect(gA.shots.map(\.before) == (0...3).map { Self.before($0) }, "each physical shot once, in stroke order")
        #expect(gA.shots.allSatisfy { !$0.needsTap })
        host.0.stop(); joiner.0.stop()
    }
}

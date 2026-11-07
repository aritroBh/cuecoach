import Foundation
import Rules
import Testing
@testable import Stats

/// `n` pot attempts with `made` makes, all with the given features.
private func pots(_ who: UUID, _ n: Int, made: Int, _ f: ShotFeatures = feat(), clutch: Bool = false) -> [CompetitiveShot] {
    (0..<n).map { cshot(who, team: 0, made: $0 < made, features: f, clutch: clutch) }
}

/// Splits shots across `games` games won by team 0.
private func games(_ shots: [CompetitiveShot], count: Int, start: Double = 0) -> [CompetitiveGame] {
    let per = Int((Double(shots.count) / Double(count)).rounded(.up))
    return (0..<count).map { i in
        let slice = Array(shots.dropFirst(i * per).prefix(per))
        return cgame(slice, winner: 0, at: start + Double(i))
    }
}

private func vec(_ pairs: [ArchetypeDimension: Double]) -> ArchetypeVector { ArchetypeVector(values: pairs) }

@Suite("Archetypes — unlock (SPEC §7: ≥3 competitive games and ≥50 shots)")
struct UnlockTests {
    @Test func needsBothThresholds() {
        var a = Aggregates(); a.games = 3; a.shots = 50
        #expect(Archetypes.isUnlocked(a))
        a.games = 2
        #expect(!Archetypes.isUnlocked(a))
        a.games = 3; a.shots = 49
        #expect(!Archetypes.isUnlocked(a))
        a.games = 10; a.shots = 500
        #expect(Archetypes.isUnlocked(a))
    }

    @Test func snapshotIsNilBeforeUnlock() {
        let g = games(pots(alice, 49, made: 30), count: 3)
        #expect(Archetypes.snapshot(player: alice, games: g, friends: [], at: Date()) == nil)
        let g2 = games(pots(alice, 60, made: 30), count: 2)
        #expect(Archetypes.snapshot(player: alice, games: g2, friends: [], at: Date()) == nil)
    }

    @Test func snapshotAfterUnlockCarriesCounts() throws {
        let g = games(pots(alice, 60, made: 30), count: 3)
        let s = try #require(Archetypes.snapshot(player: alice, games: g, friends: [], at: Date(timeIntervalSince1970: 5)))
        #expect(s.playerID == alice && s.gamesCount == 3 && s.shotsCount == 60)
        #expect(s.computedAt == Date(timeIntervalSince1970: 5))
        #expect(s.vector["pot"] == 0.5)
    }

    @Test func otherPlayersShotsDoNotCount() {
        var shots = pots(alice, 20, made: 10)
        shots += (0..<40).map { _ in cshot(bob, team: 1, made: true) }
        #expect(Archetypes.snapshot(player: alice, games: games(shots, count: 3), friends: [], at: Date()) == nil)
    }
}

@Suite("Archetypes — feature vector")
struct VectorTests {
    @Test func dimensionsHaveStableKeys() {
        #expect(ArchetypeDimension.allCases.map(\.rawValue) ==
                ["cut", "long", "side", "clutch", "safety", "breakPower", "runOut", "bank", "pot", "position"])
    }

    @Test func eachTagMapsToItsDimension() {
        #expect(ArchetypeTag.cutArtist.dimension == .cut)
        #expect(ArchetypeTag.longGun.dimension == .long)
        #expect(ArchetypeTag.sidePocketSniper.dimension == .side)
        #expect(ArchetypeTag.iceVeins.dimension == .clutch)
        #expect(ArchetypeTag.safetyChess.dimension == .safety)
        #expect(ArchetypeTag.cannonBreak.dimension == .breakPower)
        #expect(ArchetypeTag.runOutMachine.dimension == .runOut)
        #expect(ArchetypeTag.bankWizard.dimension == .bank)
        #expect(ArchetypeTag.allCases.count == 8)
    }

    @Test func tagLabelsAreAtMostTwoWordsAndHaveIcons() {
        for t in ArchetypeTag.allCases {
            #expect(t.label.split(separator: " ").count <= 2, "\(t.label)")
            #expect(!t.symbolName.isEmpty)
        }
        #expect(ArchetypeTag.allCases.map(\.rawValue) ==
                ["cutArtist", "longGun", "sidePocketSniper", "iceVeins", "safetyChess", "cannonBreak", "runOutMachine", "bankWizard"])
    }

    @Test func vectorFromAggregates() {
        var a = Aggregates()
        a.games = 4
        a.pot = Rate(successes: 30, attempts: 60)
        a.potByCut = [.c45to60: Rate(successes: 3, attempts: 6), .c60plus: Rate(successes: 1, attempts: 4), .c0to15: Rate(successes: 9, attempts: 10)]
        a.potByDistance = [.long: Rate(successes: 6, attempts: 10)]
        a.potByPocket = [.side: Rate(successes: 7, attempts: 10)]
        a.potByKind = [.bank: Rate(successes: 2, attempts: 3), .kick: Rate(successes: 1, attempts: 2)]
        a.clutch = Rate(successes: 4, attempts: 5)
        a.safety = Rate(successes: 3, attempts: 5)
        a.breaks.count = 4; a.breaks.ballsPocketed = 6
        a.runOuts = 1; a.breakAndRuns = 1
        a.position = Rate(successes: 5, attempts: 10)
        let v = ArchetypeVector(a)
        #expect(v[.cut] == 0.4)
        #expect(v[.long] == 0.6)
        #expect(v[.side] == 0.7)
        #expect(v[.bank] == 0.6)
        #expect(v[.clutch] == 0.8)
        #expect(v[.safety] == 0.6)
        #expect(v[.breakPower] == 0.5)   // 1.5 balls per break / 3
        #expect(v[.runOut] == 0.5)       // 2 of 4 games
        #expect(v[.pot] == 0.5)
        #expect(v[.position] == 0.5)
    }

    @Test func dimensionsWithTooFewSamplesAreAbsent() {
        var a = Aggregates()
        a.games = 2
        a.potByCut = [.c60plus: Rate(successes: 5, attempts: 9)]
        a.clutch = Rate(successes: 4, attempts: 4)
        a.breaks.count = 2; a.breaks.ballsPocketed = 4
        a.pot = Rate(successes: 10, attempts: 19)
        let v = ArchetypeVector(a)
        #expect(v[.cut] == nil)
        #expect(v[.clutch] == nil)
        #expect(v[.breakPower] == nil)
        #expect(v[.runOut] == nil)
        #expect(v[.pot] == nil)
        #expect(v.values.isEmpty)
    }

    @Test func breakPowerIsClamped() {
        var a = Aggregates(); a.breaks.count = 3; a.breaks.ballsPocketed = 30
        #expect(ArchetypeVector(a)[.breakPower] == 1)
    }

    @Test func stringKeyedRoundTrip() {
        let v = vec([.cut: 0.4, .bank: 0.9])
        #expect(v.stringKeyed == ["cut": 0.4, "bank": 0.9])
        #expect(ArchetypeVector(stringKeyed: ["cut": 0.4, "bank": 0.9, "unknownFutureDim": 1]) == v)
    }

    @Test func radarIsInTagOrderWithNilForUnknown() {
        let r = vec([.cut: 0.4, .bank: 0.9]).radar
        #expect(r.map(\.0) == ArchetypeTag.allCases.map(\.dimension))
        #expect(r.first?.1 == 0.4 && r.last?.1 == 0.9 && r[1].1 == nil)
    }
}

@Suite("Archetypes — tags (z-score vs friends and absolute baseline)")
struct TagTests {
    @Test func absoluteBaselineAloneWhenNoFriendGroup() {
        let tags = Archetypes.tags(for: vec([.cut: 0.6, .long: 0.3, .bank: 0.5]), friends: [])
        #expect(tags.contains(.cutArtist))
        #expect(tags.contains(.bankWizard))
        #expect(!tags.contains(.longGun))
    }

    @Test func belowBaselineNeverTagged_evenIfBestOfFriends() {
        let friends = [vec([.cut: 0.05]), vec([.cut: 0.1]), vec([.cut: 0.08])]
        #expect(!Archetypes.tags(for: vec([.cut: 0.3]), friends: friends).contains(.cutArtist))
    }

    @Test func aboveBaselineButAverageInStrongGroup_notTagged() {
        let friends = [vec([.cut: 0.7]), vec([.cut: 0.6]), vec([.cut: 0.65])]
        #expect(!Archetypes.tags(for: vec([.cut: 0.66]), friends: friends).contains(.cutArtist))
    }

    @Test func standoutInGroup_tagged() {
        let friends = [vec([.cut: 0.5]), vec([.cut: 0.45]), vec([.cut: 0.4])]
        #expect(Archetypes.tags(for: vec([.cut: 0.8]), friends: friends).contains(.cutArtist))
    }

    @Test func tooFewFriendsWithTheDimension_fallsBackToBaseline() {
        let friends = [vec([.cut: 0.9]), vec([.bank: 0.1])]  // only one friend has `cut`
        #expect(Archetypes.tags(for: vec([.cut: 0.5]), friends: friends).contains(.cutArtist))
    }

    @Test func identicalFriends_zeroSpread_requiresStrictlyAbove() {
        let friends = [vec([.cut: 0.5]), vec([.cut: 0.5]), vec([.cut: 0.5])]
        #expect(Archetypes.tags(for: vec([.cut: 0.55]), friends: friends).contains(.cutArtist))
        #expect(!Archetypes.tags(for: vec([.cut: 0.5]), friends: friends).contains(.cutArtist))
    }

    @Test func tagsSortedByStrength() {
        let tags = Archetypes.tags(for: vec([.cut: 0.46, .bank: 0.95, .clutch: 0.7]), friends: [])
        #expect(tags == [.bankWizard, .iceVeins, .cutArtist])
        #expect(Set(tags) == [.bankWizard, .iceVeins, .cutArtist])
    }

    @Test func missingDimensionNeverTagged() {
        #expect(Archetypes.tags(for: vec([:]), friends: []).isEmpty)
    }

    @Test func policyBaselinesAreInUnitRange() {
        for t in ArchetypeTag.allCases {
            let b = ArchetypePolicy.standard.baseline[t]
            #expect(b != nil && b! > 0 && b! < 1, "\(t)")
        }
    }
}

@Suite("Archetypes — append-only history")
struct HistoryTests {
    private func snap(_ t: Double, games: Int = 3, player: UUID = alice) -> ArchetypeSnapshot {
        ArchetypeSnapshot(playerID: player, computedAt: Date(timeIntervalSince1970: t), gamesCount: games,
                          shotsCount: 50, vector: ["cut": 0.5], tags: [.cutArtist])
    }

    @Test func appendsInOrder() throws {
        var h = ArchetypeHistory(playerID: alice)
        try h.append(snap(1))
        try h.append(snap(2, games: 4))
        #expect(h.snapshots.count == 2)
        #expect(h.latest?.gamesCount == 4)
    }

    @Test func rejectsOtherPlayer() {
        var h = ArchetypeHistory(playerID: alice)
        #expect(throws: ArchetypeHistory.AppendError.wrongPlayer) { try h.append(snap(1, player: bob)) }
    }

    @Test func rejectsOlderSnapshot() throws {
        var h = ArchetypeHistory(playerID: alice)
        try h.append(snap(5, games: 5))
        #expect(throws: ArchetypeHistory.AppendError.outOfOrder) { try h.append(snap(4, games: 6)) }
        #expect(throws: ArchetypeHistory.AppendError.outOfOrder) { try h.append(snap(6, games: 4)) }
        #expect(h.snapshots.count == 1)
    }

    @Test func recomputeAfterGameAppends() throws {
        var h = ArchetypeHistory(playerID: alice)
        var all = games(pots(alice, 60, made: 30), count: 3)
        #expect(try h.recompute(games: all, friends: [], at: Date(timeIntervalSince1970: 10)))
        all.append(cgame(pots(alice, 20, made: 20), winner: 0, at: 99))
        #expect(try h.recompute(games: all, friends: [], at: Date(timeIntervalSince1970: 20)))
        #expect(h.snapshots.map(\.gamesCount) == [3, 4])
        #expect(h.snapshots[1].vector["pot"] == 50.0 / 80)
    }

    @Test func recomputeBeforeUnlockAppendsNothing() throws {
        var h = ArchetypeHistory(playerID: alice)
        #expect(try !h.recompute(games: games(pots(alice, 10, made: 5), count: 1), friends: [], at: Date()))
        #expect(h.snapshots.isEmpty)
    }

    @Test func historyIsCodable() throws {
        var h = ArchetypeHistory(playerID: alice)
        try h.append(snap(1))
        #expect(try JSONDecoder().decode(ArchetypeHistory.self, from: JSONEncoder().encode(h)) == h)
    }

    @Test func snapshotTagsEncodeAsAppStrings() throws {
        let data = try JSONEncoder().encode(snap(1).tags)
        #expect(String(decoding: data, as: UTF8.self) == #"["cutArtist"]"#)
    }
}

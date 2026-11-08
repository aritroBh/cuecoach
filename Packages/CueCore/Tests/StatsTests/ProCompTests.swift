import Foundation
import Rules
import Testing
@testable import Stats

private func pro(_ id: String, _ values: [ArchetypeDimension: Double]) -> ProProfile {
    ProProfile(id: id, name: id, nickname: nil, profileSource: nil,
               traits: values.mapValues { ProTrait(value: $0, estimated: true, confidence: .low) })
}
private func vec(_ pairs: [ArchetypeDimension: Double]) -> ArchetypeVector { ArchetypeVector(values: pairs) }

@Suite("ProProfiles.json — sourcing (SPEC §8, Phase 6 acceptance)")
struct ProProfilesDataTests {
    private var pros: [ProProfile] { get throws { try ProProfiles.bundled() } }

    @Test func seedListWithEfrenFirst() throws {
        let p = try pros
        #expect(p.first?.id == "efren-reyes")
        #expect(p.map(\.name) == ["Efren Reyes", "Shane Van Boening", "Joshua Filler", "Fedor Gorst", "Earl Strickland",
                                  "Ko Pin-yi", "Carlo Biado", "Aloysius Yapp", "Jayson Shaw", "Francisco Sánchez Ruiz"])
        #expect(Set(p.map(\.id)).count == p.count)
    }

    @Test func everyProHasEveryArchetypeDimension() throws {
        for p in try pros {
            #expect(Set(p.traits.keys) == Set(ArchetypeDimension.allCases), "\(p.id)")
        }
    }

    @Test func everyTraitIsSourcedOrEstimated() throws {
        for p in try pros {
            for (d, t) in p.traits {
                #expect(t.estimated || t.source != nil, "\(p.id).\(d) claims measured data without a source")
                if let s = t.source { #expect(s.hasPrefix("https://"), "\(p.id).\(d) source \(s)") }
                #expect((0...1).contains(t.value), "\(p.id).\(d) out of range")
            }
        }
    }

    @Test func estimatedTraitsAreNeverHighConfidence() throws {
        for p in try pros { for (d, t) in p.traits where t.estimated { #expect(t.confidence != .high, "\(p.id).\(d)") } }
    }

    @Test func profileSourcesAreHTTPS() throws {
        for p in try pros { #expect(p.profileSource?.hasPrefix("https://") ?? true, "\(p.id)") }
    }

    @Test func profileVectorDropsNothing() throws {
        let efren = try #require(try pros.first)
        #expect(efren.vector.values.count == ArchetypeDimension.allCases.count)
    }

    @Test func decodeFailureIsThrownNotTrapped() {
        #expect(throws: (any Error).self) { try ProProfiles.decode(Data("{".utf8)) }
    }

    @Test func rejectsUnsourcedMeasuredTraitOnDecode() {
        let json = #"{"version":1,"profiles":[{"id":"x","name":"X","traits":{"cut":{"value":0.5,"estimated":false,"confidence":"high"}}}]}"#
        #expect(throws: ProProfiles.ValidationError.self) { try ProProfiles.decode(Data(json.utf8)) }
    }

    @Test func rejectsOutOfRangeValueOnDecode() {
        let json = #"{"version":1,"profiles":[{"id":"x","name":"X","traits":{"cut":{"value":1.5,"estimated":true,"confidence":"low"}}}]}"#
        #expect(throws: ProProfiles.ValidationError.self) { try ProProfiles.decode(Data(json.utf8)) }
    }
}

@Suite("ProComp — similarity and nearest pro")
struct ProCompTests {
    private let shape: [ArchetypeDimension: Double] = [.cut: 0.9, .long: 0.3, .bank: 0.8, .safety: 0.4, .breakPower: 0.2]

    @Test func identicalShapeIsOne() throws {
        let s = try #require(ProComp.similarity(vec(shape), pro("a", shape)))
        #expect(abs(s - 1) < 1e-12)
    }

    @Test func isPlainCosineOfRawVectors_specSection8() throws {
        // SPEC §8: cosine similarity. [1,0,0]·[0,1,0] = 0 (the old mean-centred metric gave 0.25).
        let s = try #require(ProComp.similarity(vec([.cut: 1, .long: 0, .bank: 0]), pro("a", [.cut: 0, .long: 1, .bank: 0])))
        #expect(abs(s) < 1e-12)
        let a: [Double] = [0.9, 0.3, 0.8], c: [Double] = [0.2, 0.7, 0.4]
        let dims: [ArchetypeDimension] = [.cut, .long, .bank]
        let dot: Double = zip(a, c).map(*).reduce(0, +)
        let na: Double = a.map { $0 * $0 }.reduce(0, +).squareRoot()
        let nc: Double = c.map { $0 * $0 }.reduce(0, +).squareRoot()
        let expected = dot / (na * nc)
        let got = try #require(ProComp.similarity(vec(Dictionary(uniqueKeysWithValues: zip(dims, a))),
                                                  pro("b", Dictionary(uniqueKeysWithValues: zip(dims, c)))))
        #expect(abs(got - expected) < 1e-12)
    }

    @Test func scaleInvariant() throws {
        let weaker = shape.mapValues { $0 * 0.5 }
        #expect(abs(try #require(ProComp.similarity(vec(weaker), pro("a", shape))) - 1) < 1e-9)
    }

    @Test func onlySharedDimensionsCount() throws {
        var mine = shape; mine[.clutch] = 1   // pro has no clutch trait
        #expect(abs(try #require(ProComp.similarity(vec(mine), pro("a", shape))) - 1) < 1e-9)
    }

    @Test func tooFewSharedDimensionsIsNil() {
        #expect(ProComp.similarity(vec([.cut: 0.9, .bank: 0.1]), pro("a", shape)) == nil)
    }

    @Test func zeroVectorIsNil() {
        #expect(ProComp.similarity(vec([.cut: 0, .long: 0, .bank: 0]), pro("a", shape)) == nil)
    }

    @Test func nearestPicksMostSimilar() throws {
        let banker = pro("banker", [.cut: 0.3, .long: 0.3, .bank: 0.95, .safety: 0.8, .breakPower: 0.2])
        let breaker = pro("breaker", [.cut: 0.6, .long: 0.8, .bank: 0.2, .safety: 0.3, .breakPower: 0.95])
        let me = vec([.cut: 0.35, .long: 0.25, .bank: 0.7, .safety: 0.6, .breakPower: 0.1])
        let c = try #require(ProComp.nearest(to: me, among: [breaker, banker]))
        #expect(c.proID == "banker")
        #expect(c.similarity > 0.5 && c.similarity <= 1)
    }

    @Test func sharedTraitsAreTopTwoBothAboveTheirOwnMean() throws {
        let banker = pro("banker", [.cut: 0.3, .long: 0.3, .bank: 0.95, .safety: 0.8, .breakPower: 0.2])
        let me = vec([.cut: 0.35, .long: 0.25, .bank: 0.7, .safety: 0.6, .breakPower: 0.1])
        let c = try #require(ProComp.nearest(to: me, among: [banker]))
        #expect(c.sharedTraits == ["bank", "safety"])
    }

    @Test func sharedTraitsCanBeFewerThanTwo() throws {
        let p = pro("p", [.cut: 0.9, .long: 0.1, .bank: 0.1, .safety: 0.1])
        let me = vec([.cut: 0.8, .long: 0.2, .bank: 0.3, .safety: 0.1])
        #expect(try #require(ProComp.nearest(to: me, among: [p])).sharedTraits == ["cut"])
    }

    @Test func tiesBreakByID() throws {
        let c = try #require(ProComp.nearest(to: vec(shape), among: [pro("zed", shape), pro("amy", shape)]))
        #expect(c.proID == "amy")
    }

    @Test func noProsOrNoOverlapIsNil() {
        #expect(ProComp.nearest(to: vec(shape), among: []) == nil)
        #expect(ProComp.nearest(to: vec([:]), among: [pro("a", shape)]) == nil)
    }

    @Test func bundledProsGiveAComp() throws {
        let me = vec([.cut: 0.5, .long: 0.3, .side: 0.4, .clutch: 0.5, .safety: 0.7, .breakPower: 0.2,
                      .runOut: 0.1, .bank: 0.6, .pot: 0.5, .position: 0.55])
        let c = try #require(ProComp.nearest(to: me, among: try ProProfiles.bundled()))
        #expect(c.proID == "efren-reyes")   // bank + safety + weak break is the Efren shape
        #expect(c.sharedTraits.count <= 2)
    }

    @Test func encodesLikeTheAppsStoredProComp() throws {
        let c = ProComp(proID: "efren-reyes", similarity: 0.81, sharedTraits: ["bank", "safety"])
        let e = JSONEncoder(); e.outputFormatting = .sortedKeys
        #expect(String(decoding: try e.encode(c), as: UTF8.self) ==
                #"{"proID":"efren-reyes","sharedTraits":["bank","safety"],"similarity":0.81}"#)
    }
}

@Suite("ProComp — only after unlock (SPEC §8)")
struct ProCompGatingTests {
    private func shots(_ n: Int) -> [CompetitiveShot] {
        (0..<n).map { i in cshot(alice, team: 0, made: i % 2 == 0,
                                 features: feat([.c0to15, .c45to60, .c60plus][i % 3], [.short, .long][i % 2],
                                                i % 4 == 0 ? .side : .corner, i % 5 == 0 ? .bank : .plain),
                                 cue: i % 3 == 0 ? .inZone : .outOfZone) }
    }

    @Test func lockedPlayerGetsNoComp() throws {
        let g = [cgame(shots(40), winner: 0, at: 1), cgame(shots(5), winner: 0, at: 2), cgame(shots(1), winner: 0, at: 3)]
        #expect(Archetypes.snapshot(player: alice, games: g, friends: [], at: Date(), pros: try ProProfiles.bundled()) == nil)
    }

    @Test func unlockedPlayerGetsComp() throws {
        let g = [cgame(shots(40), winner: 0, at: 1), cgame(shots(10), winner: 0, at: 2), cgame(shots(10), winner: 0, at: 3)]
        let s = try #require(Archetypes.snapshot(player: alice, games: g, friends: [], at: Date(), pros: try ProProfiles.bundled()))
        #expect(s.proComp != nil)
    }

    @Test func withoutProsNoComp() throws {
        let g = [cgame(shots(40), winner: 0, at: 1), cgame(shots(10), winner: 0, at: 2), cgame(shots(10), winner: 0, at: 3)]
        #expect(try #require(Archetypes.snapshot(player: alice, games: g, friends: [], at: Date())).proComp == nil)
    }
}

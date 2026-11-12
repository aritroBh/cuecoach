import Foundation
import Testing
import Geometry
import Rules
@testable import Sync

/// mesh-identity.md §9 `IslandMerge`: partition + heal sims, disagreement → needs tap, order independence, flapping.
@Suite struct IslandMergeTests {
    static let r = TableSpec.ballRadius
    static let pot1 = ShotOutcome(firstContact: BallID(1)!, pocketed: [BallID(1)!: .footLeft])
    static let miss1 = ShotOutcome(firstContact: BallID(1)!)

    static func layout(_ seed: Double) -> [BallID: Vec2] {
        [.cue: Vec2(0.5 + seed * 0.01, 0.6), BallID(1)!: Vec2(1.2, 0.4 + seed * 0.01), .eight: Vec2(1.8, 0.7)]
    }

    static func view(_ t: Double, pre: [BallID: Vec2] = layout(0), outcome: ShotOutcome = pot1,
                     confidence: Double = 1, id: UUID = UUID()) -> IslandShot {
        IslandShot(id: id, strokeTime: t, preState: pre, outcome: outcome, confidence: confidence)
    }

    // MARK: alignment

    @Test func sameIdAlwaysAligns() {
        let a = Self.view(10)
        var b = a
        b.strokeTime = 99
        #expect(IslandMerge.aligned(a, b))
    }

    @Test func closeTimeAndSamePreStateAlign() {
        var moved = Self.layout(0)
        moved[.cue] = moved[.cue]! + Vec2(Self.r * 0.6, 0)
        #expect(IslandMerge.aligned(Self.view(10), Self.view(10.4, pre: moved)))
    }

    @Test func farTimeNeverAligns() {
        #expect(!IslandMerge.aligned(Self.view(10), Self.view(10.6)))
    }

    @Test func aBallMovedMoreThanARadiusDoesNotAlign() {
        var moved = Self.layout(0)
        moved[BallID(1)!] = moved[BallID(1)!]! + Vec2(Self.r * 1.5, 0)
        #expect(!IslandMerge.aligned(Self.view(10), Self.view(10.1, pre: moved)))
    }

    @Test func ballsSeenByOneSideOnlyAreIgnoredAndAnEmptyStateMatchesOnTime() {
        var fewer = Self.layout(0)
        fewer[.eight] = nil
        #expect(IslandMerge.aligned(Self.view(10), Self.view(10.1, pre: fewer)))
        #expect(IslandMerge.aligned(Self.view(10), Self.view(10.1, pre: [:])))
        #expect(!IslandMerge.aligned(Self.view(10, pre: [.cue: Vec2(1, 1)]), Self.view(10.1, pre: [.eight: Vec2(1, 1)])),
                "two known states with no common ball are different shots")
    }

    // MARK: merge

    @Test func sameShotOnBothIslandsIsKeptOnce() {
        let a = Self.view(10), b = Self.view(10.2)
        let m = IslandMerge.merge([[a], [b]])
        #expect(m.count == 1)
        #expect(m.first?.needsTap == false)
        #expect(m.first?.members == [a.id, b.id].sorted { $0.uuidString < $1.uuidString })
    }

    @Test func disagreementKeepsTheMoreConfidentViewAndNeedsATap() {
        let a = Self.view(10, outcome: Self.pot1, confidence: 0.5), b = Self.view(10.1, outcome: Self.miss1, confidence: 0.9)
        let m = IslandMerge.merge([[a], [b]])
        #expect(m.count == 1)
        #expect(m.first?.shot == b)
        #expect(m.first?.needsTap == true)
    }

    @Test func confidenceTieGoesToTheSmallerID() {
        let ids = [UUID(), UUID()].sorted { $0.uuidString < $1.uuidString }
        let a = Self.view(10, outcome: Self.pot1, id: ids[1]), b = Self.view(10.1, outcome: Self.miss1, id: ids[0])
        #expect(IslandMerge.merge([[a], [b]]).first?.shot.id == ids[0])
        #expect(IslandMerge.merge([[b], [a]]).first?.shot.id == ids[0])
    }

    @Test func unmatchedShotsAreKeptInStrokeOrder() {
        let a1 = Self.view(10), a2 = Self.view(30, pre: Self.layout(3)), b = Self.view(20, pre: Self.layout(2))
        let m = IslandMerge.merge([[a1, a2], [b]])
        #expect(m.map(\.shot.id) == [a1.id, b.id, a2.id])
        #expect(m.allSatisfy { !$0.needsTap })
    }

    @Test func twoViewsFromOneIslandNeverMerge() {
        let a1 = Self.view(10), a2 = Self.view(10.1)
        #expect(IslandMerge.merge([[a1, a2]]).count == 2)
    }

    // MARK: partition + heal sims (§9: 0.5–60 s partitions, noisy timing and outcomes, one-sided misses)

    struct Physical { var time: Double; var pre: [BallID: Vec2]; var outcome: ShotOutcome }

    static func physicalShots(_ rng: inout SeededRNG, from start: Double, to end: Double) -> [Physical] {
        var t = start + Double.random(in: 0.5...6, using: &rng)
        var out: [Physical] = []
        while t < end {
            var pre: [BallID: Vec2] = [:]
            for n in [0, 1, 2, 3, 8, 9] where Bool.random(using: &rng) || n == 0 {
                pre[BallID(n)!] = Vec2(Double.random(in: 0.1...2.1, using: &rng), Double.random(in: 0.1...1.0, using: &rng))
            }
            let n = Int.random(in: 1...7, using: &rng)
            let o = Bool.random(using: &rng) ? ShotOutcome(firstContact: BallID(n)!, pocketed: [BallID(n)!: .sideLeft])
                                             : ShotOutcome(firstContact: BallID(n)!)
            out.append(Physical(time: t, pre: pre, outcome: o))
            t += Double.random(in: 3...20, using: &rng)
        }
        return out
    }

    /// One phone's view: up to ±0.2 s timing, ±r/3 positions, a chance to drop a ball or misread the outcome.
    static func observe(_ p: Physical, _ rng: inout SeededRNG, misread: Double) -> IslandShot {
        var pre: [BallID: Vec2] = [:]
        for (b, v) in p.pre where b == .cue || Double.random(in: 0..<1, using: &rng) > 0.1 {
            pre[b] = v + Vec2(Double.random(in: -r / 3...r / 3, using: &rng), Double.random(in: -r / 3...r / 3, using: &rng))
        }
        var o = p.outcome
        if Double.random(in: 0..<1, using: &rng) < misread {
            o = o.pocketed.isEmpty ? ShotOutcome(firstContact: o.firstContact, pocketed: [o.firstContact!: .footRight])
                                   : ShotOutcome(firstContact: o.firstContact)
        }
        return IslandShot(id: UUID(), strokeTime: p.time + Double.random(in: -0.2...0.2, using: &rng), preState: pre,
                          outcome: o, confidence: Double.random(in: 0.3...1, using: &rng))
    }

    @Test(arguments: 0..<200)
    func everySeenShotAppearsExactlyOnce(seed: Int) {
        var rng = SeededRNG(seed: UInt64(seed) &+ 11)
        let start = Double.random(in: 0...100, using: &rng)
        let length = Double.random(in: 0.5...60, using: &rng)
        let shots = Self.physicalShots(&rng, from: start, to: start + length)
        var islands: [[IslandShot]] = [[], []]
        var owner: [UUID: Int] = [:]
        var views: [Int: [IslandShot]] = [:]
        for (i, p) in shots.enumerated() {
            for side in 0..<2 where Double.random(in: 0..<1, using: &rng) > 0.25 {
                let v = Self.observe(p, &rng, misread: 0.15)
                islands[side].append(v)
                owner[v.id] = i
                views[i, default: []].append(v)
            }
        }
        let merged = IslandMerge.merge(islands)
        let physical = merged.map { m in Set(m.members.map { owner[$0]! }) }
        #expect(physical.allSatisfy { $0.count == 1 }, "seed \(seed): one merged shot mixes two physical shots")
        #expect(physical.map { $0.first! }.sorted() == views.keys.sorted(), "seed \(seed): a seen shot is lost or doubled")
        for m in merged {
            let vs = views[owner[m.shot.id]!]!
            #expect(m.needsTap == (Set(vs.map(\.outcome)).count > 1), "seed \(seed)")
            #expect(m.shot.confidence == vs.map(\.confidence).max(), "seed \(seed)")
        }
        let all = Dictionary(uniqueKeysWithValues: islands.joined().map { ($0.id, $0.strokeTime) })
        let starts = merged.map { m in m.members.map { all[$0]! }.min()! }
        #expect(starts == starts.sorted(), "seed \(seed): merged shots are in stroke order")
        // Deterministic and order-independent.
        var shuffled = islands.map { $0.shuffled(using: &rng) }
        shuffled.shuffle(using: &rng)
        #expect(IslandMerge.merge(shuffled) == merged, "seed \(seed): order changed the merge")
        #expect(IslandMerge.merge(islands.reversed()) == merged)
    }

    @Test func threeIslandsMergeTheSameWay() {
        let a = Self.view(10), b = Self.view(10.2), c = Self.view(10.3, outcome: Self.miss1, confidence: 0.2)
        let m = IslandMerge.merge([[a], [b], [c]])
        #expect(m.count == 1)
        #expect(m.first?.needsTap == true)
        #expect(m.first?.members.count == 3)
        #expect(IslandMerge.merge([[c], [a], [b]]) == m)
    }

    // MARK: flapping link (§9: toggles every 0.5–3 s for 5 simulated minutes)

    /// Each connected spell heals: the host merges its own uncommitted tail with the other side's. A spell may be too
    /// short for the merged log to reach the other phone, which then re-sends its old tail at the next heal.
    @Test(arguments: 0..<40)
    func flappingLinkNeverDuplicatesAShot(seed: Int) {
        var rng = SeededRNG(seed: UInt64(seed) &* 104_729 &+ 3)
        let shots = Self.physicalShots(&rng, from: 0, to: 300)
        var owner: [UUID: Int] = [:]
        var seen = Set<Int>()
        var committed: [MergedShot] = []
        var hostTail: [IslandShot] = [], otherTail: [IslandShot] = []
        var t = 0.0, connected = true, next = 0
        var heals = 0
        func see(_ i: Int, side: Int) -> IslandShot {
            let v = Self.observe(shots[i], &rng, misread: 0.1)
            owner[v.id] = i
            seen.insert(i)
            return v
        }
        while t < 300 {
            let end = min(300, t + Double.random(in: 0.5...3, using: &rng))
            var stable = true
            if connected, !(hostTail.isEmpty && otherTail.isEmpty) {
                heals += 1
                let merged = IslandMerge.merge([hostTail, otherTail])
                if Bool.random(using: &rng) {       // the heal completes: everyone has the merged log
                    committed += merged
                    hostTail = []; otherTail = []
                } else {                            // cut again first: only the host rewrote its log
                    hostTail = merged.map(\.shot)
                    stable = false
                }
            }
            while next < shots.count, shots[next].time < end {
                if connected && stable {
                    let v = see(next, side: 0)
                    committed.append(MergedShot(shot: v, needsTap: false, members: [v.id]))
                } else {
                    for side in 0..<2 where Double.random(in: 0..<1, using: &rng) > 0.25 {
                        let v = see(next, side: side)
                        if side == 0 { hostTail.append(v) } else { otherTail.append(v) }
                    }
                }
                next += 1
            }
            t = end
            connected.toggle()
        }
        committed += IslandMerge.merge([hostTail, otherTail])
        let physical = committed.map { m in owner[m.shot.id]! }
        #expect(physical.count == Set(physical).count, "seed \(seed): a shot was duplicated")
        #expect(Set(physical) == seen, "seed \(seed): a seen shot was lost")
        #expect(heals > 10)
    }
}

/// SplitMix64, as in the app's mesh sims.
struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

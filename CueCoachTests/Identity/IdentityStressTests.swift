import Foundation
import CoreGraphics
import Testing
@testable import CueCoach

// Adversarial stress suite for player recognition (Phase 5).
// Drives the real pure pipeline (VisionShooterIdentifier → ShooterAttributor → IdentitySession) with a scripted
// PersonAnalyzing fake and synthetic embeddings whose intra/inter-class cosines are controlled exactly.
// Tests named after a STRESS-FINDING S<n> were red against the first implementation; all are enabled now.
// Every scenario prints one "STRESS-METRIC" line with measured rates.

// MARK: - Deterministic randomness

struct StressRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {   // SplitMix64
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func uniform(_ r: ClosedRange<Double> = 0...1) -> Double {
        r.lowerBound + (r.upperBound - r.lowerBound) * Double(next() >> 11) / Double(UInt64(1) << 53)
    }
    mutating func chance(_ p: Double) -> Bool { uniform() < p }
    mutating func gauss() -> Double {
        let u1 = max(1e-12, uniform()), u2 = uniform()
        return (-2 * log(u1)).squareRoot() * cos(2 * Double.pi * u2)
    }
    mutating func pick(_ n: Int) -> Int { Int(next() % UInt64(n)) }
}

// MARK: - Synthetic embedding space

let stressBody = "stress.body.v1"
let stressFace = "stress.face.v1"

enum StressSpace {
    static let dim = 32

    static func dot(_ a: [Double], _ b: [Double]) -> Double { zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } }
    static func normalise(_ v: [Double]) -> [Double] { let n = dot(v, v).squareRoot(); return v.map { $0 / n } }
    static func randomUnit(_ rng: inout StressRNG) -> [Double] { normalise((0..<dim).map { _ in rng.gauss() }) }

    /// Unit vector with cosine exactly `c` to unit `base`; the rest of the mass in a fresh random direction ⟂ base.
    static func around(_ base: [Double], cos c: Double, _ rng: inout StressRNG) -> [Double] {
        rotate(base, toward: randomUnit(&rng), cos: c)
    }

    /// Unit vector with cosine `c` to `base`, rotated toward the part of `toward` that is ⟂ base.
    static func rotate(_ base: [Double], toward: [Double], cos c: Double) -> [Double] {
        let d = dot(toward, base)
        let perp = normalise(zip(toward, base).map { $0 - d * $1 })
        let s = max(0, 1 - c * c).squareRoot()
        return zip(base, perp).map { c * $0 + s * $1 }
    }

    static func body(_ v: [Double]) -> Embedding { Embedding(modelID: stressBody, vector: v.map { Float($0) }) }
    static func face(_ v: [Double]) -> Embedding { Embedding(modelID: stressFace, vector: v.map { Float($0) }) }

    /// Genuine per-observation noise: an observation has cosine U(range) to the person's true look.
    static let observation: ClosedRange<Double> = 0.92...0.98
}

// MARK: - Players, scenes, fake Vision

struct StressPlayer {
    var id = UUID()
    /// Current clothing look (unit). Drift / jacket changes edit this.
    var clothes: [Double]
    var face: [Double]
    var consent: RecognitionConsent = .none
    var isGuest = false
    /// Guest given session-only clothes consent on the host (no stored template).
    var guestClothesConsent = false
}

/// Returns the same scripted people for every frame of the stroke window, honouring `wants` like real Vision.
struct StressAnalyzer: PersonAnalyzing {
    let scene: [ObservedPerson]
    var fails = false
    func people(in image: CGImage, wants: AnalysisWants) async throws -> [ObservedPerson] {
        if fails { throw CancellationError() }
        return scene.map {
            ObservedPerson(box: $0.box, joints: $0.joints,
                           appearance: wants.appearance ? $0.appearance : nil, face: wants.face ? $0.face : nil,
                           faceQuality: wants.face ? $0.faceQuality : nil)
        }
    }
}

enum StressPose {
    static let cue = CGPoint(x: 0.5, y: 0.3)
    static let shooterBox = CGRect(x: 0.2, y: 0.25, width: 0.3, height: 0.25)
    static let shooterJoints = BodyJoints(points: [.neck: CGPoint(x: 0.45, y: 0.42), .root: CGPoint(x: 0.25, y: 0.40),
                                                   .leftWrist: CGPoint(x: 0.49, y: 0.31)])
    /// Standing person in slot k (0..<7), right of the table, wrist ≥ 0.3 from the cue ball.
    static func stander(_ k: Int) -> (CGRect, BodyJoints) {
        let x = 0.60 + 0.055 * Double(k)
        let box = CGRect(x: x, y: 0.45, width: 0.05, height: 0.45)
        let j = BodyJoints(points: [.neck: CGPoint(x: x + 0.025, y: 0.85), .root: CGPoint(x: x + 0.025, y: 0.60),
                                    .leftWrist: CGPoint(x: x + 0.03, y: 0.62)])
        return (box, j)
    }
}

struct StressTally: CustomStringConvertible {
    var shots = 0, wrong = 0, auto = 0, autoWrong = 0, outOfTurn = 0, taps = 0
    var guestShots = 0, guestToRegistered = 0, guestMergedAuto = 0
    var faceVisibleShots = 0, faceVisibleAuto = 0

    static func rate(_ a: Int, _ b: Int) -> Double { b == 0 ? 0 : Double(a) / Double(b) }
    var misattribution: Double { Self.rate(wrong, shots) }
    var turnOrderBaseline: Double { Self.rate(outOfTurn, shots) }
    var autoRate: Double { Self.rate(auto, shots) }
    var autoWrongRate: Double { Self.rate(autoWrong, shots) }
    var guestMergeRate: Double { Self.rate(guestMergedAuto, guestShots) }

    static func + (l: StressTally, r: StressTally) -> StressTally {
        var t = l
        t.shots += r.shots; t.wrong += r.wrong; t.auto += r.auto; t.autoWrong += r.autoWrong
        t.outOfTurn += r.outOfTurn; t.taps += r.taps; t.guestShots += r.guestShots
        t.guestToRegistered += r.guestToRegistered; t.guestMergedAuto += r.guestMergedAuto
        t.faceVisibleShots += r.faceVisibleShots; t.faceVisibleAuto += r.faceVisibleAuto
        return t
    }

    var description: String {
        func p(_ x: Double) -> String { String(format: "%.2f%%", 100 * x) }
        return "shots=\(shots) misattr=\(p(misattribution)) turnOrderOnly=\(p(turnOrderBaseline)) auto=\(p(autoRate)) "
            + "autoWrong=\(p(autoWrongRate)) taps=\(taps) guestShots=\(guestShots) "
            + "guestMergedAuto=\(guestMergedAuto) (\(p(guestMergeRate))) guestToRegisteredAny=\(guestToRegistered) "
            + "faceVisibleAuto=\(faceVisibleAuto)/\(faceVisibleShots)"
    }
}

func stressMetric(_ name: String, _ t: StressTally) { print("STRESS-METRIC \(name): \(t)") }

/// One table: players, a live IdentitySession built from synthetic stored templates, and a tally.
@MainActor
final class StressTable {
    var players: [StressPlayer]
    let session: IdentitySession
    var rng: StressRNG
    var tally = StressTally()
    var teams: [[UUID]]?
    var frames = 2
    var faceMatching = StrokeFaceMatching.off
    /// Shot → true shooter (to check stats after taps).
    var truth: [UUID: UUID] = [:]
    private let image = testImage(width: 4, height: 4)

    /// `registrationClothes` overrides what a player wore when they registered (default: what they wear now).
    init(_ players: [StressPlayer], teams: [[UUID]]? = nil, registrationClothes: [UUID: [Double]] = [:], seed: UInt64) {
        self.players = players
        self.teams = teams
        var rng = StressRNG(seed: seed)
        var profiles: [PlayerProfile] = []
        for p in players where !p.isGuest {
            let profile = PlayerProfile(id: p.id, name: "P", avatarSymbol: "star", avatarColor: "red")
            if p.consent.clothes || p.consent.face {
                let reg = registrationClothes[p.id] ?? p.clothes
                let body = (0..<4).map { _ in StressSpace.body(StressSpace.around(reg, cos: rng.uniform(StressSpace.observation), &rng)) }
                let face = (0..<4).map { _ in StressSpace.face(StressSpace.around(p.face, cos: rng.uniform(StressSpace.observation), &rng)) }
                profile.recognition = RecognitionData(
                    faceEmbedding: p.consent.face ? try! EmbeddingCodec.encode(face) : nil,
                    appearanceEmbedding: p.consent.clothes ? try! EmbeddingCodec.encode(body) : nil,
                    optedInAt: Date(timeIntervalSince1970: 0), version: IdentityConsentTerms.current)
            }
            profiles.append(profile)
        }
        session = IdentitySession(profiles: profiles, guests: players.filter(\.isGuest).map(\.id),
                                  faceModelID: stressFace, bodyModelID: stressBody)
        for p in players where p.isGuest && p.guestClothesConsent { session.grantGuestClothesConsent(p.id) }
        self.rng = rng
    }

    func index(_ id: UUID) -> Int { players.firstIndex { $0.id == id }! }
    func team(of id: UUID) -> Set<UUID>? { teams?.first { $0.contains(id) }.map(Set.init) }

    func observe(_ v: [Double], face: Bool) -> Embedding { face ? StressSpace.face(v) : StressSpace.body(v) }

    func scene(shooter: Int?, bystanders: [Int], faceVisible: Bool, shooterFaceVisible: Bool) -> [ObservedPerson] {
        var out: [ObservedPerson] = []
        func person(_ i: Int, _ box: CGRect, _ j: BodyJoints, face: Bool) -> ObservedPerson {
            let p = players[i]
            return ObservedPerson(
                box: box, joints: j,
                appearance: StressSpace.body(StressSpace.around(p.clothes, cos: rng.uniform(StressSpace.observation), &rng)),
                face: face ? StressSpace.face(StressSpace.around(p.face, cos: rng.uniform(StressSpace.observation), &rng)) : nil,
                faceQuality: face ? 0.9 : nil)
        }
        if let s = shooter { out.append(person(s, StressPose.shooterBox, StressPose.shooterJoints, face: shooterFaceVisible)) }
        for (k, b) in bystanders.prefix(7).enumerated() {
            let (box, j) = StressPose.stander(k)
            out.append(person(b, box, j, face: faceVisible))
        }
        return out
    }

    /// One stroke. `actual` shoots, turn order says `expected`. Taps the post-shot card when wrong with `tapIfWrong`.
    @discardableResult
    func shoot(_ actual: Int, expected: UUID, shooterVisible: Bool = true, bystanderVisibility: Double = 0.7,
               faceVisible: Bool = false, tapIfWrong: Double = 0, analyzerFails: Bool = false) async -> (shot: UUID, att: Attribution) {
        let shot = UUID()
        let bystanders = players.indices.filter { $0 != actual && rng.chance(bystanderVisibility) }
        let people = scene(shooter: shooterVisible ? actual : nil, bystanders: bystanders,
                           faceVisible: faceVisible, shooterFaceVisible: faceVisible)
        let window = StrokeWindow(frames: (0..<frames).map { _ in IdentityFrame(image: image, cueBall: StressPose.cue) })
        let identifier = VisionShooterIdentifier(analyzer: StressAnalyzer(scene: people, fails: analyzerFails),
                                                 faceMatching: faceMatching)
        let att = await session.identifyShot(shot, window: window, expectedShooter: expected,
                                             teamInTurn: team(of: expected), using: identifier)
        let truthID = players[actual].id
        truth[shot] = truthID
        tally.shots += 1
        if expected != truthID { tally.outOfTurn += 1 }
        if att.source == .auto { tally.auto += 1 }
        let wrong = att.playerID != truthID
        if wrong { tally.wrong += 1; if att.source == .auto { tally.autoWrong += 1 } }
        if faceVisible && shooterVisible { tally.faceVisibleShots += 1; if att.source == .auto { tally.faceVisibleAuto += 1 } }
        if players[actual].isGuest {
            tally.guestShots += 1
            if wrong, let other = players.first(where: { $0.id == att.playerID }), !other.isGuest {
                tally.guestToRegistered += 1
                if att.source == .auto { tally.guestMergedAuto += 1 }
            }
        }
        if wrong, tapIfWrong > 0, rng.chance(tapIfWrong) {
            _ = session.correct(shot: shot, to: truthID)
            tally.taps += 1
        }
        return (shot, att)
    }

    /// Plays `shots` strokes in rotation (team-alternating when teams are set). `outOfTurn` = chance someone else shoots.
    func play(_ shots: Int, outOfTurn: Double, shooterVisible: Double = 1, faceVisible: Double = 0, tapIfWrong: Double = 0,
              each: ((Int) -> Void)? = nil) async {
        let order = turnOrder()
        for k in 0..<shots {
            each?(k)
            let expected = order[k % order.count]
            var actual = index(expected)
            if rng.chance(outOfTurn) {
                // Out of turn: a teammate in team play, anyone else otherwise.
                let pool = (team(of: expected).map { t in players.indices.filter { t.contains(players[$0].id) } } ?? Array(players.indices))
                    .filter { $0 != actual }
                if !pool.isEmpty { actual = pool[rng.pick(pool.count)] }
            }
            await shoot(actual, expected: expected, shooterVisible: rng.chance(shooterVisible),
                        faceVisible: rng.chance(faceVisible), tapIfWrong: tapIfWrong)
        }
    }

    func turnOrder() -> [UUID] {
        guard let teams, teams.count > 1 else { return players.map(\.id) }
        let width = teams.map(\.count).max() ?? 0
        var out: [UUID] = []
        for i in 0..<width { for t in teams where i < t.count { out.append(t[i]) } }
        return out
    }

    /// Per-player shot counts as the stats layer would read them (current attribution, taps included).
    func shotsPerPlayer() -> [UUID: Int] {
        var out: [UUID: Int] = [:]
        for shot in truth.keys { if let a = session.attribution(for: shot) { out[a.playerID, default: 0] += 1 } }
        return out
    }
}

// MARK: - Look builders

enum StressLooks {
    static func distinct(_ n: Int, _ rng: inout StressRNG) -> [[Double]] { (0..<n).map { _ in StressSpace.randomUnit(&rng) } }

    /// Groups of size `group` whose members are pairwise ≈ `cos` apart (shared centre at cosine √cos).
    static func lookalikes(_ n: Int, group: Int, cos c: Double, _ rng: inout StressRNG) -> [[Double]] {
        var out: [[Double]] = []
        while out.count < n {
            let centre = StressSpace.randomUnit(&rng)
            for _ in 0..<group where out.count < n { out.append(StressSpace.around(centre, cos: c.squareRoot(), &rng)) }
        }
        return out
    }

    static func players(_ looks: [[Double]], consent: RecognitionConsent, _ rng: inout StressRNG) -> [StressPlayer] {
        looks.map { StressPlayer(clothes: $0, face: StressSpace.randomUnit(&rng), consent: consent) }
    }
}

let clothesOnly = RecognitionConsent(clothes: true, face: false)
let faceOnly = RecognitionConsent(clothes: false, face: true)
let bothConsents = RecognitionConsent(clothes: true, face: true)

// MARK: - Scenarios

@MainActor
@Suite(.serialized) struct IdentityStressTests {

    // 2, 4, 8 players, all clothes-consented, clearly different clothes.
    @Test(arguments: [2, 4, 8])
    func distinctPlayersAreRecognisedAndOutOfTurnShotsCaught(n: Int) async {
        var rng = StressRNG(seed: 100 + UInt64(n))
        let table = StressTable(StressLooks.players(StressLooks.distinct(n, &rng), consent: clothesOnly, &rng), seed: 1 + UInt64(n))
        await table.play(120, outOfTurn: 0.15)
        stressMetric("distinct n=\(n)", table.tally)
        #expect(table.tally.autoWrong == 0)
        #expect(table.tally.misattribution <= table.tally.turnOrderBaseline)
        // Recognition must actually help: most out-of-turn shots are caught.
        #expect(table.tally.misattribution <= 0.5 * table.tally.turnOrderBaseline + 0.01)
    }

    // Lookalikes: pairs (and for 8 players, quads) with inter-class cosine 0.80 / 0.85 / 0.90.
    @Test(arguments: [(2, 0.80), (2, 0.85), (2, 0.90), (4, 0.80), (4, 0.85), (4, 0.90), (8, 0.80), (8, 0.85)])
    func lookalikesNeverProduceConfidentWrongCalls(n: Int, c: Double) async {
        await Self.lookalikes(n: n, c: c)
    }

    @Test
    func lookalikeQuadsAtNinetyNeverProduceConfidentWrongCalls() async {
        await Self.lookalikes(n: 8, c: 0.90)
    }

    static func lookalikes(n: Int, c: Double) async {
        var rng = StressRNG(seed: 200 + UInt64(n) * 10 + UInt64(c * 100))
        let looks = StressLooks.lookalikes(n, group: n == 8 ? 4 : 2, cos: c, &rng)
        let table = StressTable(StressLooks.players(looks, consent: clothesOnly, &rng), seed: 7)
        await table.play(120, outOfTurn: 0.15)
        stressMetric("lookalike n=\(n) cos=\(c)", table.tally)
        #expect(table.tally.autoWrongRate <= 0.02)
        #expect(table.tally.misattribution <= table.tally.turnOrderBaseline)
    }

    // Same-shirt teams (team jerseys, intra-team cosine ≈ 0.94), everyone consented: within-team out-of-turn
    // shots are ambiguous and must fall back to turn order rather than pick the wrong teammate.
    @Test(arguments: [4, 8])
    func sameShirtTeamsAllConsentedDoNotSwapTeammates(n: Int) async {
        var rng = StressRNG(seed: 300 + UInt64(n))
        let looks = StressLooks.lookalikes(n, group: n / 2, cos: 0.94, &rng)
        let ps = StressLooks.players(looks, consent: clothesOnly, &rng)
        let teams = [Array(ps.prefix(n / 2).map(\.id)), Array(ps.suffix(n / 2).map(\.id))]
        let table = StressTable(ps, teams: teams, seed: 9)
        await table.play(160, outOfTurn: 0.15)
        stressMetric("same-shirt teams all consented n=\(n)", table.tally)
        #expect(table.tally.autoWrongRate <= 0.02)
        #expect(table.tally.misattribution <= table.tally.turnOrderBaseline)
    }

    // 2v2, team jerseys. Only A (team 1) consented; teammate B did not. B's shots must stay B's (turn order).
    @Test
    func sameShirtNonConsentedTeammateIsNotStolen() async {
        var rng = StressRNG(seed: 400)
        let shirt1 = StressSpace.randomUnit(&rng), shirt2 = StressSpace.randomUnit(&rng)
        var ps = [shirt1, shirt1, shirt2, shirt2].map { StressPlayer(clothes: StressSpace.around($0, cos: 0.98, &rng), face: StressSpace.randomUnit(&rng)) }
        ps[0].consent = clothesOnly          // A only
        let teams = [[ps[0].id, ps[1].id], [ps[2].id, ps[3].id]]
        let table = StressTable(ps, teams: teams, seed: 11)
        var bShots = StressTally()
        for _ in 0..<60 {
            let before = table.tally
            await table.shoot(1, expected: ps[1].id)      // B on B's own turn
            var d = table.tally; d.shots -= before.shots; d.wrong -= before.wrong; d.autoWrong -= before.autoWrong; d.auto -= before.auto
            bShots = bShots + StressTally(shots: d.shots, wrong: d.wrong, auto: d.auto, autoWrong: d.autoWrong)
        }
        stressMetric("same-shirt non-consented teammate B on own turn", bShots)
        #expect(bShots.autoWrong == 0)
    }

    // 3-hour session: every player's look drifts to cosine 0.75 from their registration look (light, sweat, sleeves).
    // 180 strokes; user taps every wrong card. Recognition should not decay to nothing and never get worse than turn order.
    // Measured: auto rate 100% (h1) -> 100% (h2) -> 51.7% (h3); stays correct only because taps re-teach.
    @Test
    func threeHourDriftKeepsRecognising() async {
        var rng = StressRNG(seed: 500)
        let start = StressLooks.distinct(4, &rng)
        let dirs = StressLooks.distinct(4, &rng)
        let table = StressTable(StressLooks.players(start, consent: clothesOnly, &rng), seed: 13)
        var hours = [StressTally(), StressTally(), StressTally()]
        for hour in 0..<3 {
            let before = table.tally
            await table.play(60, outOfTurn: 0.15, tapIfWrong: 1) { k in
                let t = (Double(hour * 60 + k)) / 180
                let c = 1 - 0.25 * t        // cosine to the registration look
                for i in 0..<4 { table.players[i].clothes = StressSpace.rotate(start[i], toward: dirs[i], cos: c) }
            }
            hours[hour] = StressTally(shots: table.tally.shots - before.shots, wrong: table.tally.wrong - before.wrong,
                                      auto: table.tally.auto - before.auto, autoWrong: table.tally.autoWrong - before.autoWrong,
                                      outOfTurn: table.tally.outOfTurn - before.outOfTurn, taps: table.tally.taps - before.taps)
            stressMetric("drift hour \(hour + 1)", hours[hour])
        }
        stressMetric("drift 3h total", table.tally)
        #expect(table.tally.misattribution <= table.tally.turnOrderBaseline)
        #expect(table.tally.autoWrongRate <= 0.02)
        #expect(hours[2].autoRate >= 0.5 * hours[0].autoRate)
    }

    // A takes off a jacket after 30 strokes; the shirt underneath looks like B's (cos 0.9 to B). User taps every wrong card.
    @Test
    func jacketChangeIsLearnedFromTaps() async {
        var rng = StressRNG(seed: 600)
        let ps = StressLooks.players(StressLooks.distinct(2, &rng), consent: clothesOnly, &rng)
        let table = StressTable(ps, seed: 15)
        await table.play(30, outOfTurn: 0.15, tapIfWrong: 1)
        table.players[0].clothes = StressSpace.around(ps[1].clothes, cos: 0.9, &rng)
        let before = table.tally
        await table.play(60, outOfTurn: 0.15, tapIfWrong: 1)
        let after = StressTally(shots: table.tally.shots - before.shots, wrong: table.tally.wrong - before.wrong,
                                auto: table.tally.auto - before.auto, autoWrong: table.tally.autoWrong - before.autoWrong,
                                outOfTurn: table.tally.outOfTurn - before.outOfTurn, taps: table.tally.taps - before.taps)
        stressMetric("jacket change (after)", after)
        #expect(after.autoWrong <= 2)        // at most a couple of wrong calls before the tap teaches A's new look
        #expect(after.misattribution <= after.turnOrderBaseline)
    }

    // Clothes today differ from registration day (orthogonal look). Taps should make recognition work again this session.
    @Test
    func differentClothesThanAtRegistrationIsRelearned() async {
        var rng = StressRNG(seed: 650)
        let ps = StressLooks.players(StressLooks.distinct(2, &rng), consent: clothesOnly, &rng)
        let reg = [ps[0].id: StressSpace.randomUnit(&rng), ps[1].id: StressSpace.randomUnit(&rng)]
        let table = StressTable(ps, registrationClothes: reg, seed: 17)
        await table.play(20, outOfTurn: 0.2, tapIfWrong: 1)
        let before = table.tally
        await table.play(60, outOfTurn: 0.2, tapIfWrong: 1)
        let late = StressTally(shots: table.tally.shots - before.shots, wrong: table.tally.wrong - before.wrong,
                               auto: table.tally.auto - before.auto, outOfTurn: table.tally.outOfTurn - before.outOfTurn)
        stressMetric("new clothes vs registration (late)", late)
        #expect(late.autoRate >= 0.5)
    }

    // Face-only consent, faces visible on 30% of strokes (missing 70%). Attributor level: face evidence, when
    // present, must identify; when missing, fall back to turn order; never a confident wrong call.
    @Test func attributorUsesFaceWhenPresentAndFallsBackWhenMissing() {
        var rng = StressRNG(seed: 700)
        let ps = StressLooks.players(StressLooks.distinct(4, &rng), consent: faceOnly, &rng)
        let roster = IdentityRoster(entries: ps.map { RosterEntry(playerID: $0.id, consent: faceOnly) })
        let templates = Dictionary(uniqueKeysWithValues: ps.map { p in
            (p.id, (0..<4).map { _ in StressSpace.face(StressSpace.around(p.face, cos: rng.uniform(StressSpace.observation), &rng)) }) })
        let scorer = IdentityMatcher(threshold: 1, margin: 0)
        var t = StressTally()
        for k in 0..<400 {
            let expected = ps[k % 4].id
            let actual = rng.chance(0.15) ? ps[rng.pick(4)] : ps[k % 4]
            let visible = rng.chance(0.3)
            var e = TrackEvidence(trackID: 1, poseScore: 0.95, distanceToCueBall: 0.01)
            if visible {
                let probe = StressSpace.face(StressSpace.around(actual.face, cos: rng.uniform(StressSpace.observation), &rng))
                e.faceSimilarity = scorer.match(probe, against: templates).similarities
            }
            let att = ShooterAttributor().attribute(views: [[e]], context: AttributionContext(roster: roster, expectedShooter: expected))
            t.shots += 1
            if expected != actual.id { t.outOfTurn += 1 }
            if att.source == .auto { t.auto += 1 }
            if att.playerID != actual.id { t.wrong += 1; if att.source == .auto { t.autoWrong += 1 } }
            if visible { t.faceVisibleShots += 1; if att.source == .auto { t.faceVisibleAuto += 1 } }
            if !visible { #expect(att.source == .turnOrder) }
        }
        stressMetric("attributor face 30% visible", t)
        #expect(t.autoWrong == 0)
        #expect(StressTally.rate(t.faceVisibleAuto, t.faceVisibleShots) >= 0.8)
    }

    // Same, end to end through VisionShooterIdentifier + IdentitySession: face-consented players whose face is
    // visible should be identified. Face templates are held but the identifier never compares them.
    @Test
    func pipelineIdentifiesVisibleFaces() async {
        var rng = StressRNG(seed: 750)
        let ps = StressLooks.players(StressLooks.distinct(4, &rng), consent: faceOnly, &rng)
        let table = StressTable(ps, seed: 19)
        table.faceMatching = .shooterOnly
        await table.play(200, outOfTurn: 0.15, faceVisible: 0.3)
        stressMetric("pipeline face-only 30% visible", table.tally)
        #expect(StressTally.rate(table.tally.faceVisibleAuto, table.tally.faceVisibleShots) >= 0.8)
    }

    // An unregistered guest whose clothes resemble registered A shoots on the guest's own turn.
    @Test(arguments: [2, 4], [0.85, 0.90, 0.95])
    func lookalikeGuestIsNeverMergedIntoRegistered(n: Int, c: Double) async {
        var rng = StressRNG(seed: 800 + UInt64(n) * 10 + UInt64(c * 100))
        var ps = StressLooks.players(StressLooks.distinct(n, &rng), consent: clothesOnly, &rng)
        ps[1].isGuest = true; ps[1].consent = .none
        ps[1].clothes = StressSpace.around(ps[0].clothes, cos: c, &rng)
        let table = StressTable(ps, seed: 21)
        for _ in 0..<60 { await table.shoot(1, expected: ps[1].id) }
        stressMetric("guest lookalike n=\(n) cos=\(c)", table.tally)
        #expect(table.tally.guestMergedAuto == 0)
    }

    // Registered A's stored templates are unusable (model upgrade) so A has consent but no session template.
    // On A's first turn the shooter is occluded and a guest stands nearby. The guest's clothes must not seed A.
    @Test
    func occludedFirstTurnDoesNotSeedFromBystander() async {
        var rng = StressRNG(seed: 850)
        var ps = StressLooks.players(StressLooks.distinct(2, &rng), consent: .none, &rng)
        ps[1].isGuest = true
        ps[0].isGuest = true; ps[0].guestClothesConsent = true   // A: clothes consent, empty session template
        let table = StressTable(ps, seed: 23)
        // A's first turn: A occluded, guest G standing in view.
        await table.shoot(0, expected: ps[0].id, shooterVisible: false, bystanderVisibility: 1)
        let g = table.session.snapshot().appearanceGallery[ps[0].id] ?? []
        let seededFromGuest = g.contains { ($0.cosine(StressSpace.body(ps[1].clothes)) ?? 0) > 0.8 }
        // Then G shoots on G's own turns.
        for _ in 0..<30 { await table.shoot(1, expected: ps[1].id) }
        stressMetric("occluded first turn, guest bystander", table.tally)
        #expect(!seededFromGuest)
        #expect(table.tally.autoWrong == 0)
    }

    // Shooter unobservable (occluded / out of frame); another consented player stands in view. Must be turn order.
    @Test(arguments: [2, 4, 8])
    func unobservableShooterFallsBackToTurnOrder(n: Int) async {
        var rng = StressRNG(seed: 900 + UInt64(n))
        let ps = StressLooks.players(StressLooks.distinct(n, &rng), consent: clothesOnly, &rng)
        let table = StressTable(ps, seed: 25)
        var nonTurnOrder = 0
        for k in 0..<60 {
            let (_, att) = await table.shoot(k % n, expected: ps[k % n].id, shooterVisible: false, bystanderVisibility: 0.8)
            if att.source != .turnOrder { nonTurnOrder += 1 }
        }
        stressMetric("unobservable shooter n=\(n) (nonTurnOrder=\(nonTurnOrder))", table.tally)
        #expect(nonTurnOrder == 0)
        #expect(table.tally.wrong == 0)
    }

    // Nobody observable at all, or Vision failing on every frame: pure turn order, nothing learned.
    @Test(arguments: [2, 4, 8])
    func emptyOrFailingVisionIsPureTurnOrder(n: Int) async {
        var rng = StressRNG(seed: 950 + UInt64(n))
        let ps = StressLooks.players(StressLooks.distinct(n, &rng), consent: clothesOnly, &rng)
        let table = StressTable(ps, seed: 27)
        let before = table.session.snapshot().appearanceGallery
        for k in 0..<40 {
            let (_, att) = await table.shoot(k % n, expected: ps[k % n].id, shooterVisible: false, bystanderVisibility: 0,
                                             analyzerFails: k.isMultiple(of: 2))
            #expect(att.source == .turnOrder && att.playerID == ps[k % n].id)
        }
        #expect(table.session.snapshot().appearanceGallery == before)
        #expect(table.session.pendingSampleCount == 0)
    }

    // A wrong call followed by one tap: the stats the profile reads must move from the wrong player to the right one,
    // the tap is counted, the sample teaches only the right player, and a second tap moves them again.
    @Test func oneTapCorrectionMovesStats() async {
        var rng = StressRNG(seed: 1000)
        let looks = StressLooks.lookalikes(3, group: 3, cos: 0.95, &rng)
        let ps = StressLooks.players(looks, consent: clothesOnly, &rng)
        let table = StressTable(ps, seed: 29)
        // Force a wrong auto call: B's shot is recorded as an auto attribution to A.
        let shot = UUID()
        let sample = StressSpace.body(StressSpace.around(ps[1].clothes, cos: 0.97, &rng))
        table.session.record(shot: shot, ShooterIdentification(
            attribution: Attribution(playerID: ps[0].id, source: .auto, confidence: 0.9, shooterTrackID: 1),
            shooterAppearance: sample), expectedShooter: ps[0].id)
        table.truth[shot] = ps[1].id
        #expect(table.shotsPerPlayer()[ps[0].id] == 1)
        let gA = table.session.snapshot().appearanceGallery[ps[0].id]?.count ?? 0

        let fixed = table.session.correct(shot: shot, to: ps[1].id)
        #expect(fixed?.playerID == ps[1].id && fixed?.source == .tap)
        #expect(table.session.attribution(for: shot)?.playerID == ps[1].id)
        #expect(table.shotsPerPlayer()[ps[0].id] == nil)
        #expect(table.shotsPerPlayer()[ps[1].id] == 1)
        #expect(table.session.stats.tapped == 1 && table.session.stats.correctBeforeTap == 0)
        let snap = table.session.snapshot().appearanceGallery
        #expect((snap[ps[0].id]?.count ?? 0) == gA)                      // wrong player learned nothing
        #expect(snap[ps[1].id]?.contains(sample.normalised!) == true)    // right player learned the sample

        // Mis-tap, then fix again: stats follow, the sample moves with the tap.
        _ = table.session.correct(shot: shot, to: ps[2].id)
        #expect(table.shotsPerPlayer()[ps[2].id] == 1 && table.shotsPerPlayer()[ps[1].id] == nil)
        let snap2 = table.session.snapshot().appearanceGallery
        #expect(snap2[ps[1].id]?.contains(sample.normalised!) != true)
        #expect(snap2[ps[2].id]?.contains(sample.normalised!) == true)
    }

    // After a tap, the same mistake should not keep repeating stroke after stroke (non-consented same-shirt teammate).
    @Test
    func correctionStopsTheSameMistakeRepeating() async {
        var rng = StressRNG(seed: 1050)
        let shirt = StressSpace.randomUnit(&rng)
        var ps = [StressPlayer(clothes: StressSpace.around(shirt, cos: 0.99, &rng), face: StressSpace.randomUnit(&rng), consent: clothesOnly),
                  StressPlayer(clothes: StressSpace.around(shirt, cos: 0.99, &rng), face: StressSpace.randomUnit(&rng))]
        ps[1].consent = .none
        let table = StressTable(ps, teams: [[ps[0].id, ps[1].id]], seed: 31)
        for _ in 0..<20 { await table.shoot(1, expected: ps[1].id, tapIfWrong: 1) }
        stressMetric("repeat after correction", table.tally)
        #expect(table.tally.autoWrong <= 1)
    }

    // Consent revoked mid-session: templates and every derived gallery entry gone, nothing re-learned afterwards.
    @Test func consentRevokedMidSessionPurgesAndNeverRelearns() async {
        var rng = StressRNG(seed: 1100)
        let ps = StressLooks.players(StressLooks.distinct(4, &rng), consent: bothConsents, &rng)
        let table = StressTable(ps, seed: 33)
        await table.play(40, outOfTurn: 0.25, tapIfWrong: 1)
        let a = ps[0].id
        #expect(table.session.snapshot().appearanceGallery[a] != nil)
        #expect(table.session.snapshot().faceGallery[a] != nil)
        // Remember a shot A really took, to check its held sample is purged too.
        let aShots = table.truth.filter { $0.value == a }.map(\.key)
        let bGalleryBefore = table.session.snapshot().appearanceGallery[ps[1].id] ?? []

        table.session.revoke(a)
        func assertClean(_ where_: String) {
            let s = table.session.snapshot()
            #expect(s.appearanceGallery[a] == nil, "\(where_): appearance")
            #expect(s.faceGallery[a] == nil, "\(where_): face")
            #expect(s.roster.consent(of: a) == .none, "\(where_): consent")
        }
        assertClean("after revoke")
        // A's held samples are gone: retapping A's old shots to B teaches B nothing from A's body.
        for shot in aShots { _ = table.session.correct(shot: shot, to: ps[1].id) }
        let bGalleryAfter = table.session.snapshot().appearanceGallery[ps[1].id] ?? []
        #expect(bGalleryAfter.count <= bGalleryBefore.count, "A's purged samples must not reappear in B's template")
        for shot in aShots { _ = table.session.correct(shot: shot, to: a) }   // and tapping back to A teaches nothing
        assertClean("after retaps")
        #expect(!table.session.bind(a, appearance: StressSpace.body(ps[0].clothes)))

        // Keep playing with A shooting often and taps on: nothing about A comes back, A never auto-identified.
        var autoA = 0
        for k in 0..<60 {
            let actual = k.isMultiple(of: 2) ? 0 : 1 + rng.pick(3)
            let (_, att) = await table.shoot(actual, expected: ps[k % 4].id, faceVisible: true, tapIfWrong: 1)
            if att.playerID == a, att.source == .auto { autoA += 1 }
            assertClean("stroke \(k)")
        }
        #expect(autoA == 0)
        stressMetric("after revoke", table.tally)
    }

    // MARK: - Property test: 10k random sessions

    struct MonteCarlo {
        var all = StressTally()
        var sessions = 0
    }

    static func monteCarlo(sessions: Int, seed: UInt64) async -> MonteCarlo {
        var rng = StressRNG(seed: seed)
        var mc = MonteCarlo()
        for s in 0..<sessions {
            let n = [2, 4, 8][rng.pick(3)]
            let teamPlay = n >= 4 && rng.chance(0.5)
            var looks = StressLooks.distinct(n, &rng)
            if teamPlay && rng.chance(0.4) {                    // team jerseys
                let j1 = StressSpace.randomUnit(&rng), j2 = StressSpace.randomUnit(&rng)
                looks = (0..<n).map { StressSpace.around($0 < n / 2 ? j1 : j2, cos: rng.uniform(0.93...0.98), &rng) }
            }
            if rng.chance(0.3) {                                 // a lookalike pair
                let i = rng.pick(n), j = (i + 1 + rng.pick(n - 1)) % n
                looks[j] = StressSpace.around(looks[i], cos: rng.uniform(0.80...0.92), &rng)
            }
            var ps: [StressPlayer] = []
            for k in 0..<n {
                var p = StressPlayer(clothes: looks[k], face: StressSpace.randomUnit(&rng))
                if rng.chance(0.2) { p.isGuest = true } else {
                    p.consent = RecognitionConsent(clothes: rng.chance(0.6), face: rng.chance(0.3))
                }
                ps.append(p)
            }
            let teams = teamPlay ? [Array(ps.prefix(n / 2).map(\.id)), Array(ps.suffix(n / 2).map(\.id))] : nil
            let table = StressTable(ps, teams: teams, seed: rng.next())
            table.frames = 1
            await table.play(8, outOfTurn: 0.12, shooterVisible: 0.85, faceVisible: 0.3, tapIfWrong: 0.5)
            mc.all = mc.all + table.tally
            mc.sessions = s + 1
        }
        return mc
    }

    @Test func monteCarloTenThousandSessionsMisattributionNoWorseThanTurnOrder() async {
        let mc = await Self.monteCarlo(sessions: 10_000, seed: 0xC0FFEE)
        stressMetric("monte-carlo 10k sessions", mc.all)
        #expect(mc.sessions == 10_000)
        #expect(mc.all.misattribution <= mc.all.turnOrderBaseline)
    }

    @Test
    func monteCarloTenThousandSessionsNeverMergesGuests() async {
        let mc = await Self.monteCarlo(sessions: 10_000, seed: 0xC0FFEE)
        stressMetric("monte-carlo 10k sessions (guest merge)", mc.all)
        #expect(mc.all.guestMergedAuto == 0)
    }
}

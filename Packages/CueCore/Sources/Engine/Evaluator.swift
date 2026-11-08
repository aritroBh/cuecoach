import Foundation
import Geometry
import Physics
import Rules

/// The Quick + Full search (engine.md §3, §6). A value type: every hot loop is synchronous and runs inside
/// task-group children; reductions run serially in sample-index order, so results never depend on scheduling.
struct Evaluator: Sendable {
    let simulator: Simulator
    let rules: RulesEngine
    let rng: EngineRNG
    let budget: EngineBudget
    let skill: SkillModel
    let opponentSkill: SkillModel
    let state: TableState            // quantised
    let game: GameState
    let stateHash: UInt64
    let win: WinModel
    let generator: CandidateGenerator

    init(simulator: Simulator, rules: RulesEngine, seed: UInt64, budget: EngineBudget, skill: SkillModel,
         opponentSkill: SkillModel, state: TableState, game: GameState) {
        self.simulator = simulator
        self.rules = rules
        self.rng = EngineRNG(seed: seed)
        self.budget = budget.normalized
        self.skill = skill
        self.opponentSkill = opponentSkill
        self.state = Self.quantised(state)
        self.game = game
        self.stateHash = Self.hash(self.state, game)
        var skills = [opponentSkill, opponentSkill]
        skills[min(1, max(0, game.shooter))] = skill
        self.win = WinModel(rules: rules, skills: skills)
        self.generator = CandidateGenerator(rules: rules, skill: skill)
    }

    // MARK: Quantisation and hashing (engine.md §6.3 determinism)

    static let quantum = 0.0005

    static func quantised(_ s: TableState) -> TableState {
        var t = s
        for (id, b) in s.balls {
            let q = Vec2((b.position.x / quantum).rounded() * quantum, (b.position.y / quantum).rounded() * quantum)
            t.balls[id] = BallState(position: q, motion: b.motion == .pocketed ? .pocketed : .stationary)
        }
        return t
    }

    static func hash(_ s: TableState, _ g: GameState) -> UInt64 {
        var h = EngineRNG.mix(UInt64(s.spec.size.hashValueStable))
        for id in s.balls.keys.sorted() {
            let b = s.balls[id]!
            h = EngineRNG.mix(h, UInt64(id.number), UInt64(bitPattern: Int64((b.position.x / quantum).rounded())),
                              UInt64(bitPattern: Int64((b.position.y / quantum).rounded())), b.motion == .pocketed ? 1 : 0)
        }
        var bits: UInt64 = 0
        for id in g.onTable { bits |= 1 << UInt64(id.number) }
        h = EngineRNG.mix(h, UInt64(RuleSetID.allCases.firstIndex(of: g.ruleSet)!), UInt64(g.shooter), bits,
                          UInt64(BallInHand.allCasesStable.firstIndex(of: g.ballInHand)!), g.phase.stableCode,
                          UInt64(g.consecutiveFouls[0, default: 0]), UInt64(g.consecutiveFouls[1, default: 0]),
                          g.groups.map { UInt64($0[0] == .solids ? 1 : 2) } ?? 0)
        return h
    }

    // MARK: Per-sample scoring

    struct Sample: Hashable, Sendable {
        var w: Double
        var intended: Bool
        var staysAtTable: Bool
    }

    func startState(_ c: Candidate) -> TableState {
        var s = state
        if let q = c.cuePlacement { s.balls[.cue] = BallState(position: q) }
        return s
    }

    func score(_ trace: ShotTrace, _ c: Candidate) -> Sample {
        let out = OutcomeBuilder.outcome(from: trace, game: game, candidate: c)
        let r = rules.apply(out, to: game)
        let w = win.value(after: r, state: trace.final, forTeam: game.shooter)
        let lost = (r.winner ?? r.nextState.winner).map { $0 != game.shooter } ?? false
        let stays = r.nextState.shooter == game.shooter && r.nextState.winner == nil
        var intended: Bool
        if c.intendsPot {
            intended = out.pocketed[c.objectBall!] == c.pocket && r.fouls.isEmpty && !lost
        } else if c.kind == .safety {
            intended = r.fouls.isEmpty && !lost
            if intended, !stays, r.nextState.winner == nil {
                let leaf = win.leafState(trace.final, r)
                intended = (win.bestPots(leaf, r.nextState).first ?? 0) <= 0.20
            }
        } else {
            intended = r.fouls.isEmpty && !lost                   // hit-kick, push-out, break: a legal shot
        }
        return Sample(w: w, intended: intended, staysAtTable: stays)
    }

    func sample(_ c: Candidate, start: TableState, index i: Int) -> Sample {
        let z = rng.normals(state: stateHash, stream: 0, sample: i)
        let trace = simulator.simulate(start, stroke: skill.perturbed(c.stroke, noise: z))
        return score(trace, c)
    }

    // MARK: Quick tier: aim refinement + analytic P + one nominal sim

    struct Quick: Sendable {
        var candidate: Candidate
        var pAnalytic: Double
        var pBaseline: Double
        var score: Double
        var sims: Int
    }

    func analyticP(_ c: Candidate, skill k: SkillModel) -> Double {
        let s = startState(c)
        guard let cue = s.balls[.cue]?.position, let t = c.target, let o = s.balls[t]?.position else { return 1 }
        let spec = s.spec
        switch c.kind {
        case .direct: return AnalyticP.direct(cue: cue, object: o, pocket: c.pocket!, spec: spec, skill: k)
        case .bank(let rail): return AnalyticP.bank(cue: cue, object: o, pocket: c.pocket!, rail: rail, spec: spec, skill: k)
        case .kick(let rail):
            if let p = c.pocket { return AnalyticP.kickPot(cue: cue, object: o, pocket: p, rail: rail, spec: spec, skill: k) }
            return AnalyticP.kickHit(cue: cue, object: o, rail: rail, spec: spec, skill: k)
        case .combo(let via):
            guard let o2 = s.balls[via]?.position else { return 0 }
            return AnalyticP.combo(cue: cue, first: o, second: o2, pocket: c.pocket!, spec: spec, skill: k)
        case .safety, .pushOut, .breakShot: return 1
        }
    }

    /// Where the first object ball should head for the pot to work.
    func desiredDeparture(_ c: Candidate, _ s: TableState) -> Vec2? {
        guard let t = c.target, let o = s.balls[t]?.position, let p = c.pocket else { return nil }
        let pc = s.spec.pocketCenter(p)
        switch c.kind {
        case .direct, .kick: return pc - o
        case .bank(let rail): return EngineGeometry.mirror(pc, across: rail, spec: s.spec) - o
        case .combo(let via):
            guard let o2 = s.balls[via]?.position else { return nil }
            return AimGeometry.ghostBall(object: o2, pocket: pc) - o
        default: return nil
        }
    }

    func departure(_ trace: ShotTrace, of t: BallID) -> Vec2? {
        guard let e = trace.events.first(where: {
            if case let .ballBall(a, b) = $0.event { return a.isCue || b.isCue } else { return false }
        }), e.event.ballIDs.contains(t) else { return nil }
        let v = trace.state(at: e.time).balls[t]?.velocity ?? .zero
        return v.length > 1e-9 ? v : nil
    }

    func quick(_ c0: Candidate) -> Quick {
        var c = c0
        let start = startState(c)
        var sims = 0
        var trace = simulator.simulate(start, stroke: c.stroke); sims += 1
        if c.intendsPot, let want = desiredDeparture(c, start), let t = c.target, let dep0 = departure(trace, of: t) {
            let err0 = EngineGeometry.signedAngle(from: want, to: dep0)
            if abs(err0) > 0.1 * AnalyticP.degree {
                let delta = 0.05 * AnalyticP.degree
                let probe = Stroke(direction: c.stroke.direction.rotated(by: delta), speed: c.stroke.speed,
                                   tipOffset: c.stroke.tipOffset)
                let t1 = simulator.simulate(start, stroke: probe); sims += 1
                if let dep1 = departure(t1, of: t) {
                    let j = (EngineGeometry.signedAngle(from: want, to: dep1) - err0) / delta
                    if abs(j) > 1e-3 {
                        let fix = max(-3 * AnalyticP.degree, min(3 * AnalyticP.degree, -err0 / j))
                        c.stroke = Stroke(direction: c.stroke.direction.rotated(by: fix), speed: c.stroke.speed,
                                          tipOffset: c.stroke.tipOffset)
                        trace = simulator.simulate(start, stroke: c.stroke); sims += 1
                    }
                }
            }
        }
        let nominal = score(trace, c)
        let pA = analyticP(c, skill: skill)
        let pB = analyticP(c, skill: .reference)
        var q = nominal.w
        if c.intendsPot {
            var missState = start
            if let cue = trace.final.balls[.cue], cue.motion != .pocketed { missState.balls[.cue] = BallState(position: cue.position) }
            let miss = rules.apply(ShotOutcome(firstContact: c.target, anyRailAfterContact: true), to: game)
            let wMiss = win.value(after: miss, state: missState, forTeam: game.shooter)
            let pEff = nominal.intended ? pA : 0.25 * pA
            q = pEff * max(nominal.w, wMiss) + (1 - pEff) * wMiss
        }
        return Quick(candidate: c, pAnalytic: pA, pBaseline: pB, score: q, sims: sims)
    }

    // MARK: Parallel map with deterministic order

    /// nil when the calling task is cancelled: no new work starts, in-flight items are cancelled and dropped.
    func parallelMap<T: Sendable>(_ count: Int, _ body: @escaping @Sendable (Int) -> T) async -> [T]? {
        var out = [T?](repeating: nil, count: count)
        let finished = await withTaskGroup(of: (Int, T).self) { group -> Bool in
            var next = 0
            while next < min(count, budget.maxParallel), !Task.isCancelled {
                let i = next; group.addTask { (i, body(i)) }; next += 1
            }
            for await (i, v) in group {
                if Task.isCancelled { group.cancelAll(); return false }
                out[i] = v
                if next < count { let j = next; group.addTask { (j, body(j)) }; next += 1 }
            }
            return !Task.isCancelled && next == count
        }
        guard finished else { return nil }
        return out.map { $0! }
    }

    // MARK: Full tier: Sequential Halving with CRN

    func run() async -> Evaluation {
        var stats = EngineStats()
        let wp = win.shooterWP(state, game)
        let candidates = generator.generate(state, game)
        stats.candidates = candidates.count
        func evaluation(_ ranked: [CandidateScore], tier: Evaluation.Tier, paired: [UInt32: [Double]]) -> Evaluation {
            let pots = ranked.filter { $0.candidate.intendsPot }
            let naive = pots.max { ($0.pMakeAnalytic, -Int($0.candidate.id)) < ($1.pMakeAnalytic, -Int($1.candidate.id)) }
            let gap = ranked.count > 1 ? ranked[0].ev - ranked[1].ev : 0
            return Evaluation(tier: tier, stateHash: stateHash, state: state, game: game, shooter: game.shooter,
                              skill: skill, opponentSkill: opponentSkill, winProbability: wp, ranked: ranked,
                              secondBestGap: gap, shooterBestPot: pots.map(\.pMakeAnalytic).max() ?? 0,
                              naivePick: naive?.candidate.id, paired: paired, stats: stats)
        }
        if game.phase == .breakShot {
            // Book (D18 row 1): breaks are not searched live (engine.md §9.2).
            let edge = win.breakerEdge[game.ruleSet] ?? 0.53
            let ranked = candidates.map { CandidateScore(candidate: $0, pMakeAnalytic: 1, pBaseline: 1, pIntended: 1, ev: edge,
                                                          evSE: 0, evMake: nil, evMiss: nil, bestLeaf: nil, samples: 0,
                                                          quickScore: edge) }
            return evaluation(ranked, tier: .full, paired: [:])
        }
        guard !candidates.isEmpty else { return evaluation([], tier: .full, paired: [:]) }

        guard let quicks = await parallelMap(candidates.count, { self.quick(candidates[$0]) }) else {
            return evaluation([], tier: .quick, paired: [:])          // cancelled before the Quick tier finished
        }
        stats.sims += quicks.reduce(0) { $0 + $1.sims }
        func quickOnly(_ q: Quick) -> CandidateScore {
            CandidateScore(candidate: q.candidate, pMakeAnalytic: q.pAnalytic, pBaseline: q.pBaseline,
                           pIntended: q.pAnalytic, ev: q.score, evSE: 0, evMake: nil, evMiss: nil,
                           bestLeaf: nil, samples: 0, quickScore: q.score)
        }

        // Arms: top offence, top defence, top push-outs (engine.md §6.2).
        func top(_ filter: (Candidate) -> Bool, _ n: Int) -> [Int] {
            quicks.indices.filter { filter(quicks[$0].candidate) }
                .sorted { (quicks[$0].score, -$0) > (quicks[$1].score, -$1) }.prefix(n).map { $0 }
        }
        var arms = top({ $0.intendsPot }, budget.topK)
            + top({ !$0.intendsPot && $0.kind != .pushOut }, budget.safeties)
            + top({ $0.kind == .pushOut }, budget.pushOuts)
        arms.sort()
        stats.arms = arms.count

        var samples: [Int: [Sample]] = [:]
        var alive = arms
        var eliminatedAt: [Int: Int] = [:]
        for round in 0..<budget.rounds {
            let target = budget.initialSamples << round
            // Work items: (arm, start index) chunks, extending each alive arm to `target` samples.
            var work: [(Int, Int, Int)] = []
            for a in alive {
                var i = samples[a]?.count ?? 0
                while i < target { let e = min(target, i + budget.chunk); work.append((a, i, e)); i = e }
            }
            let items = work
            let starts = Dictionary(uniqueKeysWithValues: alive.map { ($0, startState(quicks[$0].candidate)) })
            let results = await parallelMap(items.count) { k -> [Sample] in
                let (a, s, e) = items[k]
                let c = quicks[a].candidate
                var out: [Sample] = []
                for i in s..<e {
                    if Task.isCancelled { break }
                    out.append(self.sample(c, start: starts[a]!, index: i))
                }
                return out
            }
            guard let results else {
                // Cancelled mid-search: fall back to the Quick ranking (not deterministic; the caller dropped it).
                let ranked = quicks.sorted { ($0.score, -Int($0.candidate.id)) > ($1.score, -Int($1.candidate.id)) }
                return evaluation(ranked.map(quickOnly), tier: .quick, paired: [:])
            }
            for (k, (a, _, _)) in work.enumerated() { samples[a, default: []] += results[k] }
            stats.sims += work.reduce(0) { $0 + $1.2 - $1.1 }
            guard round < budget.rounds - 1, alive.count > 2 else { continue }
            let ranked = alive.sorted { (mean(samples[$0]!), -$0) > (mean(samples[$1]!), -$1) }
            let keep = max(2, (alive.count + 1) / 2)
            for a in ranked.dropFirst(keep) { eliminatedAt[a] = round }
            alive = Array(ranked.prefix(keep)).sorted()
        }

        var scores: [(CandidateScore, Int)] = []
        var paired: [UInt32: [Double]] = [:]
        for (i, q) in quicks.enumerated() {
            if let ss = samples[i] {
                let s = summarise(q, ss)
                scores.append((s, eliminatedAt[i] ?? budget.rounds))
                paired[q.candidate.id] = ss.map(\.w)
            } else {
                scores.append((quickOnly(q), -1))
            }
        }
        scores.sort { a, b in
            if a.1 != b.1 { return a.1 > b.1 }
            if a.0.ev != b.0.ev { return a.0.ev > b.0.ev }
            return a.0.candidate.id < b.0.candidate.id
        }
        return evaluation(scores.map(\.0), tier: .full, paired: paired)
    }

    func mean(_ s: [Sample]) -> Double { s.reduce(0) { $0 + $1.w } / Double(max(1, s.count)) }

    func summarise(_ q: Quick, _ ss: [Sample]) -> CandidateScore {
        let n = ss.count
        let ev = mean(ss)
        // SE over antithetic pair means (the pairs are not independent draws).
        let pairs = stride(from: 0, to: n - 1, by: 2).map { (ss[$0].w + ss[$0 + 1].w) / 2 }
        let pm = pairs.reduce(0, +) / Double(max(1, pairs.count))
        let v = pairs.reduce(0) { $0 + ($1 - pm) * ($1 - pm) } / Double(max(1, pairs.count - 1))
        let se = pairs.count > 1 ? (v / Double(pairs.count)).squareRoot() : 0
        let made = ss.filter(\.intended), missed = ss.filter { !$0.intended }
        let leaf = q.candidate.intendsPot ? made.filter(\.staysAtTable).map(\.w).max() : nil
        return CandidateScore(candidate: q.candidate, pMakeAnalytic: q.pAnalytic, pBaseline: q.pBaseline,
                              pIntended: Double(made.count) / Double(max(1, n)), ev: ev, evSE: se,
                              evMake: made.isEmpty ? nil : mean(made), evMiss: missed.isEmpty ? nil : mean(missed),
                              bestLeaf: leaf, samples: n, quickScore: q.score)
    }
}

extension TableSize {
    var hashValueStable: Int { TableSize.allCases.firstIndex(of: self)! }
}

extension BallInHand {
    static let allCasesStable: [BallInHand] = [.none, .anywhere, .behindHeadString]
}

extension Phase {
    var stableCode: UInt64 {
        switch self {
        case .breakShot: 1
        case .pushOutAvailable: 2
        case .open: 3
        case .inPlay: 4
        case .awaitingOption(let p): 5 + 16 * UInt64(p.chooser) + 256 * UInt64(p.options.count)
        case .over(let w): 6 + 16 * UInt64(w)
        }
    }
}

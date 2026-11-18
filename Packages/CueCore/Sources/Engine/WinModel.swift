import Foundation
import Geometry
import Physics
import Rules

/// v1 analytic inning model (engine.md §6.4) plus the rule-aware leaf value (§6.1).
///
/// The team at the table runs out with R = p₁′·(p̄κ)^(n−1), where p₁′ is its best analytic shot from the
/// actual position (ball-in-hand placements when in hand) and p̄ a generic make rate for its skill.
/// A generic inning from a typical leave runs out with r = (p̄κ)^n. Then
///   W = max( R + (1−R)(1−r_opp)·W_gen,   safety: (1 − r_opp,tough)·W_gen ),
///   W_gen = r / (1 − (1−r)(1−r_opp)).
/// Constants are sim-calibrated placeholders (engine.md R1); W is always the queried team's rack win chance.
public struct WinModel: Sendable {
    public var rules: RulesEngine
    /// Skill per team index.
    public var skills: [SkillModel]
    /// Position factor κ (engine.md §6.4).
    public var kappa = 0.85
    /// Pre-break win chance of the breaker, per rule set (Book; precomputed offline in v2).
    public var breakerEdge: [RuleSetID: Double] = [.wpaNine: 0.55, .wpaEight: 0.53, .barEight: 0.53]

    public init(rules: RulesEngine, skills: [SkillModel]) {
        self.rules = rules
        self.skills = skills.isEmpty ? [.reference, .reference] : skills
    }

    func skill(_ team: Int) -> SkillModel { skills[min(max(0, team), skills.count - 1)] }

    /// Generic make rate on a typical shot (0.9 m CB–OB, 0.6 m to a corner, 25° cut) for a skill.
    static func genericMake(_ k: SkillModel) -> Double {
        let g = EngineGeometry.throwGain(distance: 0.9, cut: 25 * Double.pi / 180)
        return AnalyticP.window(atan(0.025 / 0.6), sigma: g * k.sigmaAim)
    }

    /// Win chance of the team at the table (`g.shooter`).
    public func shooterWP(_ s: TableState, _ g: GameState) -> Double { wp(s, g, forTeam: g.shooter) }

    public func wp(_ s: TableState, _ g: GameState, forTeam team: Int) -> Double {
        let w = shooterWPRaw(s, g)
        if case .over = g.phase { return g.winner == team ? 1 : 0 }
        if case .awaitingOption(let p) = g.phase {
            // Chooser takes the best option for itself.
            let vals = p.options.map { value(after: rules.choose($0, in: g), state: s, forTeam: p.chooser, depth: 1) }
            let best = vals.max() ?? 0.5
            return p.chooser == team ? best : 1 - best
        }
        return g.shooter == team ? w : 1 - w
    }

    func shooterWPRaw(_ s: TableState, _ g: GameState) -> Double {
        switch g.phase {
        case .over, .awaitingOption: return 0.5            // handled by the caller
        case .breakShot: return breakerEdge[g.ruleSet] ?? 0.53
        default: break
        }
        let a = g.shooter, b = 1 - a
        let nA = ballsNeeded(g, team: a), nB = ballsNeeded(g, team: b)
        let pa = Self.genericMake(skill(a)) * kappa, pb = Self.genericMake(skill(b)) * kappa
        let rA = pow(pa, Double(nA)), rB = pow(pb, Double(nB))
        let wGen = rA / (1 - (1 - rA) * (1 - rB))
        let pots = bestPots(s, g)
        let p1 = pots.first ?? 0, p2 = pots.count > 1 ? pots[1] : 0
        let pFirst = p1 + 0.15 * p2 * (1 - p1)
        var run = pFirst * pow(pa, Double(max(0, nA - 1)))
        // Ball in hand also buys shape on the next ball: no position loss on it (κ → 1 once).
        if g.ballInHand != .none && nA >= 2 { run = min(pFirst, run / kappa) }
        let offence = run + (1 - run) * (1 - rB) * wGen
        let rBTough = 0.35 * pb * pow(pb, Double(max(0, nB - 1)))
        let safety = (1 - rBTough) * wGen
        var w = max(offence, safety)
        if g.ruleSet == .wpaNine {
            if g.consecutiveFouls[b, default: 0] == 2 { w += 0.1 * (1 - w) }   // WPA 5.8 pressure on them
            if g.consecutiveFouls[a, default: 0] == 2 { w -= 0.1 * w }
        }
        return min(0.999, max(0.001, w))
    }

    /// Balls a team must still pocket to win the rack.
    func ballsNeeded(_ g: GameState, team: Int) -> Int {
        let objects = g.onTable.filter { !$0.isCue }
        if g.ruleSet == .wpaNine { return max(1, objects.count) }
        let solids = objects.filter { $0.group == .solids }.count
        let stripes = objects.filter { $0.group == .stripes }.count
        if let groups = g.groups, let mine = groups[team] {
            return (mine == .solids ? solids : stripes) + 1
        }
        return (team == g.shooter ? min(solids, stripes) : max(solids, stripes)) + 1
    }

    /// Best analytic P(make) values (descending, ≤ 3) for the team at the table: directs from the cue ball,
    /// or from ball-in-hand placements; banks and kick-pots only when no direct exists.
    public func bestPots(_ s: TableState, _ g: GameState) -> [Double] {
        let gen = CandidateGenerator(rules: rules, skill: skill(g.shooter))
        let objects = CandidateGenerator.liveObjects(s, g)
        let legal = rules.legalTargets(g).filter { objects[$0] != nil }.sorted()
        let kitchen = g.ballInHand == .behindHeadString
        let targets = kitchen ? legal.filter { objects[$0]!.x >= s.spec.headStringX } : legal
        var ps: [Double] = []
        let cueBall = s.balls[.cue]
        if g.ballInHand != .none || cueBall == nil || cueBall!.motion == .pocketed {
            for q in gen.bihPlacements(objects, targets: targets, spec: s.spec, kitchen: kitchen) {
                guard let q else { continue }
                ps += gen.directs(cue: q, objects: objects, targets: targets, spec: s.spec).map(\.p)
            }
        } else {
            let cue = cueBall!.position
            ps = gen.directs(cue: cue, objects: objects, targets: targets, spec: s.spec).map(\.p)
            if ps.isEmpty {
                ps = gen.banks(cue: cue, objects: objects, targets: targets, spec: s.spec).map(\.p)
                    + gen.kicks(cue: cue, objects: objects, targets: targets, spec: s.spec).filter { $0.pocket != nil }.map(\.p)
            }
        }
        return Array(ps.sorted(by: >).prefix(3))
    }

    /// The table as the next shooter finds it: spotted balls placed (WPA 1.5), nothing else moved.
    func leafState(_ s: TableState, _ r: RuleResult) -> TableState {
        var t = s
        for id in r.spot {
            var q = t.spec.footSpot
            // WPA 1.5: if the spot is occupied, place as close behind it (toward the foot rail) as possible.
            while t.balls.contains(where: { $0.key != id && $0.value.motion != .pocketed
                                            && $0.value.position.distance(to: q) < 2 * EngineGeometry.R }) {
                q.x += 0.002
                if q.x > t.spec.length - EngineGeometry.R { break }
            }
            t.balls[id] = BallState(position: q)
        }
        return t
    }

    /// W for `team` after a rules result on end-state `s` (engine.md §6.1): terminal, option node, or leaf.
    public func value(after r: RuleResult, state s: TableState, forTeam team: Int) -> Double {
        value(after: r, state: s, forTeam: team, depth: 0)
    }

    func value(after r: RuleResult, state s: TableState, forTeam team: Int, depth: Int) -> Double {
        if let w = r.winner ?? r.nextState.winner { return w == team ? 1 : 0 }
        if r.reRack {
            let edge = breakerEdge[r.nextState.ruleSet] ?? 0.53
            return r.nextState.shooter == team ? edge : 1 - edge
        }
        let t = leafState(s, r)
        if case .awaitingOption(let p) = r.nextState.phase {
            guard depth < 2 else { return 0.5 }
            let vals = p.options.map { value(after: rules.choose($0, in: r.nextState), state: t, forTeam: p.chooser,
                                             depth: depth + 1) }
            let best = vals.max() ?? 0.5
            return p.chooser == team ? best : 1 - best
        }
        let w = shooterWPRaw(t, r.nextState)
        return r.nextState.shooter == team ? w : 1 - w
    }
}

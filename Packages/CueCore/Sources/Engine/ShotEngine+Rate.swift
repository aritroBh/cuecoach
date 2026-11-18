import Foundation
import Geometry
import Physics
import Rules

extension ShotEngine {
    /// D18 decision class + execution for the shot actually played. Brilliant candidates come back as
    /// `.great`; run `Ratings.finalize` on the game's records after the rack.
    public func rate(chosen: Candidate, outcome: ShotTrace, eval: Evaluation,
                     offTable: Set<BallID> = []) -> (DecisionRating, ExecutionRating) {
        let r = Ratings.rate(ratingInput(chosen: chosen, outcome: outcome, eval: eval, offTable: offTable))
        return (r.decision, r.execution)
    }

    /// The stored per-shot record (input + live rating) for the post-game Brilliant pass.
    public func record(chosen: Candidate, outcome: ShotTrace, eval: Evaluation, intentConfidence: Double = 1,
                       offTable: Set<BallID> = [], thresholds: RatingThresholds = .default) -> ShotRatingRecord {
        let i = ratingInput(chosen: chosen, outcome: outcome, eval: eval, intentConfidence: intentConfidence,
                            offTable: offTable)
        return ShotRatingRecord(input: i, rating: Ratings.rate(i, thresholds))
    }

    /// Same shot intent, ignoring `id` and the throw-corrected direction (ids depend on the skill the list
    /// was generated for).
    static func same(_ a: Candidate, _ b: Candidate) -> Bool {
        a.kind == b.kind && a.target == b.target && a.objectBall == b.objectBall && a.pocket == b.pocket
            && a.meterStep == b.meterStep && a.stroke.tipOffset == b.stroke.tipOffset && a.cuePlacement == b.cuePlacement
    }

    /// The evaluation's entry for `c`: among same-intent entries, the one whose stroke direction is nearest
    /// (an exact id match within the ±3° throw-correction window wins).
    static func match(_ c: Candidate, in e: Evaluation) -> CandidateScore? {
        let hits = e.ranked.filter { same(c, $0.candidate) }
        func angle(_ s: CandidateScore) -> Double { abs(EngineGeometry.signedAngle(from: c.stroke.direction, to: s.candidate.stroke.direction)) }
        if let exact = hits.first(where: { $0.candidate.id == c.id && angle($0) <= 3.5 * AnalyticP.degree }) { return exact }
        return hits.min { (angle($0), $0.candidate.id) < (angle($1), $1.candidate.id) }
    }

    /// Builds every D18 signal for one shot (RATINGS §2). Synchronous: the chosen arm is topped up with paired
    /// CRN samples (same indices as the best arm) when the pre-shot search sampled it less.
    public func ratingInput(chosen c0: Candidate, outcome trace: ShotTrace, eval e: Evaluation,
                            intentConfidence: Double = 1, offTable: Set<BallID> = []) -> RatingInput {
        let ev = Evaluator(simulator: simulator, rules: rules(for: e.game), seed: seed, budget: budget,
                           skill: e.skill, opponentSkill: e.opponentSkill, state: e.state, game: e.game)
        let g = e.game, me = g.shooter
        let out = OutcomeBuilder.outcome(from: trace, game: g, candidate: c0, offTable: offTable)
        let r = ev.rules.apply(out, to: g)
        let w1 = ev.win.value(after: r, state: trace.final, forTeam: me)
        let winner = r.winner ?? r.nextState.winner
        let lost = winner.map { $0 != me } ?? false
        let won = winner == me
        let fouled = !r.fouls.isEmpty
        let isBook = c0.kind.isBook || g.phase == .breakShot

        // Chosen vs best on paired samples.
        let best = e.ranked.first
        let bestW = best.flatMap { e.paired[$0.candidate.id] } ?? []
        var chosen = Self.match(c0, in: e)
        let isBest = chosen != nil && chosen?.candidate.id == best?.candidate.id
        var chosenW = chosen.flatMap { e.paired[$0.candidate.id] } ?? []
        let target = max(chosenW.count, min(bestW.count, max(budget.ratingSamples, chosenW.count)))
        if !isBest && !isBook && chosenW.count < target {
            let cand = chosen?.candidate ?? c0
            let start = ev.startState(cand)
            let extra = (chosenW.count..<target).map { ev.sample(cand, start: start, index: $0) }
            chosenW += extra.map(\.w)
            // Every chosen-arm signal below (difficulty, safety baseline, v̂) reads the topped-up estimate.
            if let c = chosen, c.samples > 0, c.samples + extra.count == chosenW.count {
                chosen = ev.extend(c, with: extra, allW: chosenW)
            } else {
                let pA = ev.analyticP(cand, skill: e.skill), pB = ev.analyticP(cand, skill: .reference)
                chosen = ev.summarise(Evaluator.Quick(candidate: cand, pAnalytic: pA, pBaseline: pB,
                                                      score: chosen?.quickScore ?? 0, sims: 0), extra)
            }
        }
        var loss = 0.0, lossSE = 0.0
        if !isBest, let best {
            let n = min(chosenW.count, bestW.count)
            if n >= 4 {
                let pairs = stride(from: 0, to: n - 1, by: 2).map { k in
                    ((bestW[k] - chosenW[k]) + (bestW[k + 1] - chosenW[k + 1])) / 2
                }
                let m = pairs.reduce(0, +) / Double(pairs.count)
                let v = pairs.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(max(1, pairs.count - 1))
                loss = max(0, m)
                lossSE = (v / Double(pairs.count)).squareRoot()
            } else {
                loss = max(0, best.ev - (chosen?.ev ?? 0))
            }
        }

        // Opponent's best make after the actual result (Rₒ), from their perspective and skill.
        var opp = 0.0
        if winner == nil {
            let leaf = ev.win.leafState(trace.final, r)
            var go = r.nextState
            if case .awaitingOption = go.phase {
                go.phase = go.ruleSet == .wpaNine ? .inPlay : (go.groups == nil ? .open : .inPlay)
            }
            go.shooter = 1 - me
            opp = ev.win.bestPots(leaf, go).first ?? 0
        }

        let isSafety = !isBook && !c0.intendsPot
        let potted = c0.intendsPot && out.pocketed[c0.objectBall!] == c0.pocket
        let executed: Bool
        if c0.intendsPot { executed = potted && !fouled && !lost }
        else if c0.kind == .safety { executed = !fouled && !lost && opp <= 0.20 }
        else { executed = !fouled && !lost }

        // Execution rating (RATINGS §6).
        var result: ExecutionResult
        if fouled || lost { result = .miss }
        else if c0.kind == .breakShot { result = out.pocketed.keys.contains { !$0.isCue } ? .made : .nearMiss }
        else if c0.intendsPot { result = executed ? .made : (Self.nearMiss(trace, c0) ? .nearMiss : .miss) }
        else if c0.kind == .safety { result = opp <= 0.20 ? .made : (opp <= 0.40 ? .nearMiss : .miss) }
        else { result = .made }
        var position = PositionResult.notApplicable
        if c0.intendsPot && executed && winner == nil && r.nextState.shooter == me {
            let vhat = max(chosen?.bestLeaf ?? w1, w1)
            if vhat >= 0.20 { position = w1 / vhat >= 0.8 ? .inZone : .outOfZone }
        }

        let chosenScore = chosen
        let difficulty = chosenScore.map { $0.samples > 0 ? $0.pIntended : $0.pMakeAnalytic } ?? ev.analyticP(c0, skill: e.skill)
        // SotG weight (RATINGS §10, UD-8): a defensive shot has no P(make), so its baseline is the player's own D.
        let baseline = isSafety ? difficulty : (chosenScore?.pBaseline ?? ev.analyticP(c0, skill: .reference))
        return RatingInput(isBook: isBook, wpBefore: e.winProbability, wpAfter: w1, loss: loss, lossSE: lossSE,
                           chosenIsBest: isBest, onlyMoveGap: isBest ? e.secondBestGap : 0,
                           difficulty: difficulty,
                           bestDifficulty: best?.pIntended ?? 0, isSafety: isSafety, opponentBestMake: opp,
                           shooterBestPotBefore: e.shooterBestPot, fouled: fouled, lostRack: lost, wonRack: won,
                           executed: executed, execution: ExecutionRating(result: result, position: position),
                           intentConfidence: intentConfidence,
                           baselineP: baseline)
    }

    /// RATINGS §6 near miss: the object ball rattled a jaw or passed within ~1.5 window half-widths of the pocket.
    static func nearMiss(_ trace: ShotTrace, _ c: Candidate) -> Bool {
        guard let ball = c.objectBall, let pocket = c.pocket else { return false }
        if trace.events.contains(where: {
            if case let .cushion(b, rail) = $0.event { return b == ball && (rail == .cornerJaw || rail == .sideJaw) }
            return false
        }) { return true }
        let pc = trace.initial.spec.pocketCenter(pocket)
        let closest = trace.path(of: ball, sampleDT: 0.02).map { $0.distance(to: pc) }.min() ?? .infinity
        return closest < 0.075
    }
}

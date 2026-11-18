import Foundation
import Geometry
import Physics
import Rules
import Engine

struct ShotEngineEnrichment: Hashable, Sendable {
    var shotID: UUID
    var rating: DecisionRating
    var executionRating: ExecutionRating
    var wpaDelta: Double
    var isClutch: Bool
    var alternative: EngineAlternative?
    var sotgScore: Double
}

struct SessionEngineSummary: Hashable, Sendable {
    var byShotID: [UUID: ShotEngineEnrichment]
    /// Team 0 win probability (`shots.count + 1` points: opening + after each shot).
    var winProbSeries: [Double]
    var shotOfGame: RecordedHighlight?
}

/// Evaluates settled competitive shots off the main actor via `CueCore/Engine.ShotEngine` (SPEC §5.5, §5.9, §9, D18, D23, D55).
/// Produces 10-class `DecisionRating`s (including post-rack `.brilliant` finalize), `wpaDelta`, `winProbSeries`,
/// `EngineAlternative` ghost replays on suboptimal choices, and the `Shot of the Game` highlight.
actor SessionEngineEvaluator {
    let shotEngine: ShotEngine
    let budget: EngineBudget
    let skillsByPlayerID: [UUID: SkillModel]
    let labeller: any HighlightLabelling

    static let interactiveBudget = EngineBudget(
        topK: 6, safeties: 2, pushOuts: 2, initialSamples: 8, rounds: 2, chunk: 4, ratingSamples: 16)

    init(seed: UInt64 = 0,
         budget: EngineBudget = SessionEngineEvaluator.interactiveBudget,
         skillsByPlayerID: [UUID: SkillModel] = [:],
         labeller: any HighlightLabelling = SystemFoundationModelLabeller()) {
        self.budget = budget
        self.shotEngine = ShotEngine(seed: seed, budget: budget)
        self.skillsByPlayerID = skillsByPlayerID
        self.labeller = labeller
    }

    private func teamSkill(team: Int, teams: [[ShellPlayer]], shots: [SessionShot]) -> SkillModel {
        let rosterIDs: [UUID]
        if team >= 0, team < teams.count, !teams[team].isEmpty {
            rosterIDs = teams[team].map(\.id)
        } else {
            var seen = Set<UUID>()
            rosterIDs = shots.filter { $0.team == team }.compactMap { seen.insert($0.shooter.id).inserted ? $0.shooter.id : nil }
        }
        guard !rosterIDs.isEmpty else { return .reference }
        return SkillModel.averaged(rosterIDs.map { skillsByPlayerID[$0] ?? .reference })
    }

    func evaluateRack(ruleSet: RuleSetID, tableSize: TableSize, teamsCount: Int,
                      teams: [[ShellPlayer]] = [], shots: [SessionShot]) async -> SessionEngineSummary {
        guard !shots.isEmpty else {
            return SessionEngineSummary(byShotID: [:], winProbSeries: [], shotOfGame: nil)
        }
        let spec = TableSpec(size: tableSize)
        let effectiveTeams = max(2, teamsCount)
        let (rulesEngine, startGame) = TargetLegality.startingGame(ruleSet, teams: effectiveTeams)
        var gameState = startGame
        let simulator = Simulator()

        func makeTable(_ positions: [BallID: Vec2], pocketed: Set<BallID> = []) -> TableState? {
            var balls: [BallID: BallState] = [:]
            for (id, pos) in positions where !pocketed.contains(id) {
                balls[id] = BallState(position: pos, motion: .stationary)
            }
            return balls.isEmpty ? nil : TableState(spec: spec, balls: balls)
        }

        let openingPre = makeTable(shots[0].before)
        var currentTeamZeroWP: Double
        if let openingPre, openingPre.balls[.cue] != nil, openingPre.balls.count >= 2 {
            let sSkill = teamSkill(team: gameState.shooter, teams: teams, shots: shots)
            let oSkill = teamSkill(team: (gameState.shooter + 1) % effectiveTeams, teams: teams, shots: shots)
            let shooterWP = shotEngine.winProbability(openingPre, gameState, skill: sSkill, opponentSkill: oSkill)
            currentTeamZeroWP = gameState.shooter == 0 ? shooterWP : (1.0 - shooterWP)
        } else {
            currentTeamZeroWP = 0.5
        }
        var winProbSeries: [Double] = [Self.clamp01(currentTeamZeroWP)]

        var byID: [UUID: ShotEngineEnrichment] = [:]
        var indexedRecords: [(shotID: UUID, wonRack: Bool, isSafety: Bool, record: ShotRatingRecord)] = []
        var sawRackWinner = false

        for s in shots {
            // D38 `.shotLost` gap (`s.rating == nil`): `GameSessionModel.fold()` leaves `rulesState` untouched,
            // so we must NOT apply an empty `ShotOutcome()` here either.
            guard s.rating != nil else {
                winProbSeries.append(Self.clamp01(currentTeamZeroWP))
                continue
            }
            gameState.shooter = s.team
            let res = rulesEngine.apply(s.outcome, to: gameState)
            let rackWinner = res.winner ?? res.nextState.winner
            if rackWinner != nil { sawRackWinner = true }

            let shooterSkill = skillsByPlayerID[s.shooter.id] ?? .reference
            let opponentTeam = (s.team + 1) % effectiveTeams
            let opponentSkill = teamSkill(team: opponentTeam, teams: teams, shots: shots)

            if !s.isGuess, let pre = makeTable(s.before),
               pre.balls[.cue] != nil, pre.balls.count >= 2 {
                let eval = await shotEngine.evaluate(pre, gameState, skill: shooterSkill, opponentSkill: opponentSkill, budget: budget)
                let wpBefore = eval.winProbability

                let wpAfter: Double
                if let w = rackWinner {
                    wpAfter = (w == s.team) ? 1.0 : 0.0
                } else {
                    var postPositions = s.after
                    if postPositions[.cue] == nil, res.nextState.ballInHand != .none {
                        postPositions[.cue] = Vec2(spec.length * 0.25, spec.width * 0.5)
                    }
                    if let post = makeTable(postPositions, pocketed: Set(s.pocketed.keys)),
                       post.balls[.cue] != nil, post.balls.count >= 2 {
                        let nextShooterSkill = teamSkill(team: res.nextState.shooter, teams: teams, shots: shots)
                        let nextOppSkill = teamSkill(team: (res.nextState.shooter + 1) % effectiveTeams, teams: teams, shots: shots)
                        let nextWP = shotEngine.winProbability(post, res.nextState, skill: nextShooterSkill, opponentSkill: nextOppSkill)
                        wpAfter = res.nextState.shooter == s.team ? nextWP : (1.0 - nextWP)
                    } else if !res.fouls.isEmpty {
                        wpAfter = max(0.05, wpBefore - 0.25)
                    } else if s.pocketed.keys.contains(where: { !$0.isCue }) {
                        wpAfter = min(0.95, wpBefore + 0.12)
                    } else {
                        wpAfter = max(0.15, wpBefore - 0.08)
                    }
                }

                let best = eval.ranked.first
                let chosenScore = Self.matchCandidate(shot: s, game: gameState, ranked: eval.ranked)
                let isBook = s.rating == .book || gameState.phase == .breakShot
                    || (chosenScore?.candidate.kind.isBook == true)
                    || (s.index == 0 && s.before.count >= 9)
                let isBest = chosenScore != nil && chosenScore?.candidate.id == best?.candidate.id
                let loss = isBest ? 0 : max(0, (best?.ev ?? wpBefore) - (chosenScore?.ev ?? wpAfter))
                let lossSE = chosenScore?.evSE ?? best?.evSE ?? 0
                let fouled = !res.fouls.isEmpty
                let madeObject = s.pocketed.keys.contains { !$0.isCue }
                let lostRack = rackWinner.map { $0 != s.team } ?? false
                let wonRack = rackWinner == s.team
                let isSafety = !isBook && !(chosenScore?.candidate.intendsPot ?? (madeObject || s.firstContact != nil))
                let executed = !fouled && !lostRack && (isSafety ? wpAfter >= wpBefore - 0.05 : madeObject)
                let position: PositionResult = (executed && rackWinner == nil && res.nextState.shooter == s.team) ? .inZone : .notApplicable
                let execRating = ExecutionRating(result: fouled || lostRack ? .miss : (madeObject ? .made : .miss),
                                                 position: position)
                let difficulty = chosenScore?.pMakeAnalytic ?? (madeObject ? 0.45 : 0.50)
                let baseline = chosenScore?.pBaseline ?? difficulty

                let input = RatingInput(
                    isBook: isBook, wpBefore: wpBefore, wpAfter: wpAfter, loss: loss, lossSE: lossSE,
                    chosenIsBest: isBest, onlyMoveGap: isBest ? eval.secondBestGap : 0,
                    difficulty: difficulty, bestDifficulty: best?.pIntended ?? 0,
                    isSafety: isSafety, opponentBestMake: max(0, 1.0 - wpAfter),
                    shooterBestPotBefore: eval.shooterBestPot, fouled: fouled,
                    lostRack: lostRack, wonRack: wonRack, executed: executed,
                    execution: execRating, intentConfidence: chosenScore != nil ? 0.9 : 0.75,
                    baselineP: baseline)
                let rated = Ratings.rate(input)
                let record = ShotRatingRecord(input: input, rating: rated)
                indexedRecords.append((s.id, wonRack, isSafety, record))

                let alternative: EngineAlternative?
                if !isBest, rated.decision.isNegative || !madeObject,
                   let bestCand = best?.candidate,
                   let alt = Self.buildAlternative(candidate: bestCand, pre: pre, simulator: simulator) {
                    alternative = alt
                } else {
                    alternative = nil
                }

                let wpaDelta = wpAfter - wpBefore
                let isClutch = abs(wpBefore - 0.5) <= 0.25 && (rackWinner != nil || abs(wpaDelta) >= 0.15)
                byID[s.id] = ShotEngineEnrichment(
                    shotID: s.id, rating: rated.decision, executionRating: execRating,
                    wpaDelta: wpaDelta, isClutch: isClutch, alternative: alternative,
                    sotgScore: rated.sotgScore)

                currentTeamZeroWP = s.team == 0 ? wpAfter : (1.0 - wpAfter)
            } else {
                // D31 guess, D38 gap, or shot without pre-state cue ball: step Team-0 WP cleanly from rules.
                let beforeT0 = currentTeamZeroWP
                if let w = rackWinner {
                    currentTeamZeroWP = (w == 0) ? 1.0 : 0.0
                } else {
                    let sign = (s.team == 0) ? 1.0 : -1.0
                    if !res.fouls.isEmpty { currentTeamZeroWP -= 0.15 * sign }
                    else if s.pocketed.keys.contains(where: { !$0.isCue }) { currentTeamZeroWP += 0.10 * sign }
                    else { currentTeamZeroWP -= 0.05 * sign }
                }
                currentTeamZeroWP = Self.clamp01(currentTeamZeroWP)
                if let r = s.rating {
                    let shooterDelta = (s.team == 0 ? 1.0 : -1.0) * (currentTeamZeroWP - beforeT0)
                    let made = s.pocketed.keys.contains { !$0.isCue }
                    byID[s.id] = ShotEngineEnrichment(
                        shotID: s.id, rating: r,
                        executionRating: ExecutionRating(result: made ? .made : .miss, position: .notApplicable),
                        wpaDelta: s.isGuess ? 0 : shooterDelta, isClutch: false,
                        alternative: nil, sotgScore: 0)
                }
            }
            winProbSeries.append(Self.clamp01(currentTeamZeroWP))
            gameState = res.nextState
        }

        // Post-rack Brilliant finalize (D18: decided post-game only once the rack is finished; live it stays `.great`).
        if sawRackWinner, !indexedRecords.isEmpty {
            let rawRecords = indexedRecords.map(\.record)
            if let brilliantIdx = Ratings.selectBrilliant(rawRecords) {
                let promotedID = indexedRecords[brilliantIdx].shotID
                byID[promotedID]?.rating = .brilliant
            }
        }

        var sotg: RecordedHighlight?
        if let bestEntry = indexedRecords
            .filter({ !$0.record.input.isBook && (byID[$0.shotID]?.sotgScore ?? 0) > 0 })
            .max(by: { (byID[$0.shotID]?.sotgScore ?? 0) < (byID[$1.shotID]?.sotgScore ?? 0) }) {
            let enrichment = byID[bestEntry.shotID]
            let finalRating = enrichment?.rating ?? bestEntry.record.rating.decision
            let fallbackLabel = Self.highlightLabel(rating: finalRating, wonRack: bestEntry.wonRack, isSafety: bestEntry.isSafety)
            let label: String
            if sawRackWinner, !Task.isCancelled {
                let context = HighlightLabelContext(
                    ruleSet: ruleSet, rating: finalRating, wonRack: bestEntry.wonRack,
                    isSafety: bestEntry.isSafety, isClutch: enrichment?.isClutch ?? false,
                    wpaDelta: enrichment?.wpaDelta ?? bestEntry.record.input.swing,
                    baselineMakeProbability: bestEntry.record.input.baselineP)
                label = await FoundationModelLabeller.resolve(
                    using: labeller, for: context, fallback: fallbackLabel).value
            } else {
                label = FoundationModelLabeller.validated(nil, fallback: fallbackLabel)
            }
            sotg = RecordedHighlight(shotID: bestEntry.shotID, label: label,
                                     score: enrichment?.sotgScore ?? 0)
        }

        return SessionEngineSummary(byShotID: byID, winProbSeries: winProbSeries, shotOfGame: sotg)
    }

    private static func matchCandidate(shot: SessionShot, game: GameState, ranked: [CandidateScore]) -> CandidateScore? {
        if game.phase == .breakShot {
            return ranked.first { $0.candidate.kind == .breakShot } ?? ranked.first
        }
        if let (obj, pock) = shot.pocketed
            .filter({ !$0.key.isCue })
            .sorted(by: { $0.key < $1.key })
            .first {
            if let exact = ranked.first(where: {
                $0.candidate.objectBall == obj && $0.candidate.pocket == pock
                    && (shot.firstContact == nil || $0.candidate.target == shot.firstContact)
            }) {
                return exact
            }
            return ranked.first { $0.candidate.objectBall == obj && $0.candidate.pocket == pock }
        }
        if let fc = shot.firstContact {
            return ranked.first { $0.candidate.target == fc }
        }
        return nil
    }

    private static func buildAlternative(candidate: Candidate, pre: TableState, simulator: Simulator) -> EngineAlternative? {
        guard let obj = candidate.objectBall, let pocket = candidate.pocket,
              let objState = pre.balls[obj] else { return nil }
        var simStart = pre
        if let placement = candidate.cuePlacement {
            simStart.balls[.cue] = BallState(position: placement, motion: .stationary)
        }
        let trace = simulator.simulate(simStart, stroke: candidate.stroke)
        let cuePath = trace.path(of: .cue, sampleDT: 0.03)
        let objPath = trace.path(of: obj, sampleDT: 0.03)
        guard cuePath.count >= 2 || objPath.count >= 2 else { return nil }
        let ghost = candidate.ghost ?? AimPlanner.ghostBall(object: objState.position,
                                                            pocket: pre.spec.pocketCenter(pocket))
        return EngineAlternative(ghostCue: ghost, cuePath: cuePath, objectBall: obj,
                                 objectPath: objPath, pocket: pocket)
    }

    /// ≤ 2 words, zero numbers (SPEC §2).
    static func highlightLabel(rating: DecisionRating, wonRack: Bool, isSafety: Bool) -> String {
        if rating == .brilliant { return isSafety ? "Brilliant Safety" : "Brilliant Shot" }
        if wonRack { return "Rack Winner" }
        if isSafety { return "Clutch Safety" }
        return "Key Shot"
    }

    private static func clamp01(_ x: Double) -> Double {
        guard x.isFinite else { return 0.5 }
        return min(1.0, max(0.0, x))
    }
}

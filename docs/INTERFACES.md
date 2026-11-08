# Module interfaces (proposal — awaiting user review)

All `CueCore` types are value types, `Sendable`, `Codable` where they cross the mesh or disk.
Units: metres, seconds, radians, m/s, rad/s. Table frame: origin = foot-left cushion nose, +x toward the head.

## Geometry (merged)
`Vec2`, `TableSize` (7/8/9 ft), `TableSpec` (dims, pocket centres + mouths, spots, head string),
`Pocket` (6), `BallID` (0 = cue, 1–15; `.group`), `BallGroup`, `BallState` (pos, vel, ω, `MotionState`),
`TableState` (spec + balls).

## Physics
```swift
public struct Stroke { var direction: Vec2; var speed: Double         // cue-ball launch speed, m/s
                       var tipOffset: Vec2 }                          // (side, top/draw) in ball radii, |·| ≤ 0.5
public struct PhysicsParams { /* μ slide, μ roll, μ spin, ball-ball μ, cushion e(v), squirt factor … */ }
public enum PhysicsEvent { case ballBall(BallID, BallID), cushion(BallID, Rail), pocket(BallID, Pocket), offTable(BallID),
                           slideToRoll(BallID), spinOff(BallID), rest(BallID) }   // each with time t
public struct ShotTrace { var events: [TimedEvent]; var final: TableState
                          func state(at t: Double) -> TableState
                          func path(of: BallID, sampleDT: Double) -> [Vec2] }
public struct Simulator { init(params: PhysicsParams = .standard)
                          func simulate(_ s: TableState, stroke: Stroke) -> ShotTrace }   // deterministic
public enum AimGeometry { static func ghostBall(object: Vec2, pocket: Vec2) -> Vec2 … }   // overlay helpers
```

## Rules
```swift
public enum RuleSetID { case barEight, wpaEight, wpaNine }           // default .barEight
public struct ShotOutcome { var isBreak: Bool; var firstContact: BallID?; var pocketed: [BallID: Pocket]
                            var offTable: Set<BallID>; var anyRailAfterContact: Bool
                            var objectBallsToRailOnBreak: Int; var calledPocket: Pocket?
                            var isPushOut: Bool }                    // built from ShotTrace or tracker
public struct GameState { var ruleSet; var shooter: Int (team index); var groups: [Int: BallGroup]?
                          var ballInHand: BallInHand (.none/.anywhere/.behindHeadString)
                          var consecutiveFouls: [Int: Int]; var phase (.breakShot/.pushOutAvailable/.open/.inPlay/.over(winner))
                          var onTable: Set<BallID> }
public struct RuleResult { var fouls: [Foul]; var nextState: GameState; var turnPasses: Bool
                           var winner: Int?; var spot: [BallID]; var options: [PlayerOption] } // e.g. accept table / re-break / pass after push
public struct RulesEngine { init(ruleSet: RuleSetID, teams: Int)
                            func legalTargets(_ g: GameState) -> Set<BallID>      // drives the red ring
                            func requiresCall(_ g: GameState, target: BallID) -> Bool
                            func apply(_ o: ShotOutcome, to g: GameState) -> RuleResult
                            func choose(_ opt: PlayerOption, in g: GameState) -> GameState }
public enum Vote { static func winner(_ ballots: [RuleSetID]) -> RuleSetID }        // tie/no vote → .barEight
```

## Engine (Phase 2)
```swift
public actor ShotEngine { init(seed: UInt64 = 0, simulator: Simulator = Simulator(), budget: EngineBudget = .standard,
                               defaultSkill: SkillModel = .reference, threeBallRule: Bool = true)
    nonisolated func candidates(_ s: TableState, _ g: GameState) -> [Candidate]                       // defaultSkill
    nonisolated func candidates(_ s: TableState, _ g: GameState, skill: SkillModel) -> [Candidate]    // same ids as evaluate(skill:)
    func evaluate(_ s: TableState, _ g: GameState, skill: SkillModel) async -> Evaluation             // opponent = defaultSkill
    func evaluate(_ s: TableState, _ g: GameState, skill: SkillModel, opponentSkill: SkillModel,
                  budget: EngineBudget? = nil) async -> Evaluation
    nonisolated func winProbability(_ s: TableState, _ g: GameState) -> Double
    nonisolated func winProbability(_ s: TableState, _ g: GameState, skill: SkillModel, opponentSkill: SkillModel) -> Double
    func rate(chosen: Candidate, outcome: ShotTrace, eval: Evaluation,
              offTable: Set<BallID> = []) -> (DecisionRating, ExecutionRating)
    func record(chosen: Candidate, outcome: ShotTrace, eval: Evaluation, intentConfidence: Double = 1,
                offTable: Set<BallID> = [], thresholds: RatingThresholds = .default) -> ShotRatingRecord
    func ratingInput(chosen: Candidate, outcome: ShotTrace, eval: Evaluation, intentConfidence: Double = 1,
                     offTable: Set<BallID> = []) -> RatingInput }
// offTable: balls tracking saw leave the table (the simulator never does); they make the shot a foul.
// Cancelling the evaluate() task stops the search; the result then has tier == .quick (Quick ranking or empty).
// A chosen candidate is matched to the evaluation by intent (kind, target, ball, pocket, meter step, tip, placement),
// not by id, so a candidate from any candidates() list can be rated.
public struct EngineBudget { topK, safeties, pushOuts, initialSamples (even), rounds, chunk, maxParallel, ratingSamples;
                             static let standard; var normalized: EngineBudget }   // the engine always uses .normalized
public struct Candidate { id: UInt32, kind: ShotKind, target: BallID?, objectBall: BallID?, pocket: Pocket?, stroke: Stroke,
                          meterStep: Int, cuePlacement: Vec2?, ghost: Vec2?; var intendsPot: Bool }
public enum ShotKind { direct, bank(Rail), kick(Rail), combo(via: BallID), safety, pushOut, breakShot }
public struct Evaluation { tier (.quick/.full), stateHash, state, game, shooter, skill, opponentSkill, winProbability,
                           ranked: [CandidateScore], secondBestGap, shooterBestPot, naivePick, paired, stats; best }
public struct RatingInput / RatingThresholds / ShotRating / ShotRatingRecord
public enum Ratings { static func rate(_:_:) -> ShotRating; sotgScore; brilliantEligible; selectBrilliant; finalize }
// DecisionRating (D18): brilliant, great, best, good, okay, book, inaccuracy, miss, mistake, blunder — rules in docs/RATING_CLASSES.md.
// Brilliant is assigned post-game (max 1/game, must be Shot of the Game); live it shows as Great.
// SotG baseline P: pots use the reference-skill analytic P(make); defensive shots use the player's own D (RATINGS §10).
```

## Stats (Phase 6 — implemented; depends on Geometry + Rules only)
```swift
// Per shot. Stats never imports Physics/Engine: the caller maps Physics `ShotTrace.events` (or tracker output)
// into TraceEvent — ball–ball contact → .ballBall, ball–cushion → .cushion, drop → .pocket(ball, pocket),
// cue ball leaves the cloth before first contact → .airborne(.cue).
enum TraceEvent { case ballBall(BallID, BallID), cushion(BallID), pocket(BallID, Pocket), airborne(BallID) }
struct ShotTraceSummary { var events: [TraceEvent] }                      // time order
struct ShotIntent { target: BallID?, pocket: Pocket?, isSafety: Bool, isBank: Bool, isCombo: Bool }  // called / engine-chosen
static func ShotFeatures.extract(pre: TableState, post: TableState, trace: ShotTraceSummary,
                                 intent: ShotIntent = .unknown, thresholds: FeatureThresholds = .standard) -> ShotFeatures
// ShotFeatures { cutBucket, distanceBucket, pocketType, kind }; bank/combo follow the attempt, not the outcome.
// With a called target, combo = intent.isCombo (hitting another ball first on a direct call is a miss) and bank =
// intent.isBank or no direct line to the called/dropped pocket; a cushion-then-drop never relabels a called shot.
// No contact events: target = a ball seen dropping, else one missing from `post`, else the nearest.
// Break-and-run needs at least one shot after the break (winning on the break alone is not a run).
// Pass intent whenever known (engine's chosen candidate in 9-ball): without it a missed bank/combo that also
// had a direct pot is classified as the direct attempt.

// Competitive inputs (projection of the app's Shot/Game rows; training data has no path in).
struct CompetitiveShot { shooterID, team, isBreak, features, made, onTarget, cueResult, fouls,
                         objectBallsPocketed, wpaDelta, isClutch, timeOnShot,
                         decisionRating: String? }   // Engine DecisionRating.rawValue, supplied by the app
struct CompetitiveGame { ruleSet, startedAt, teamOf: [UUID: Int], winnerTeam: Int?, shots }

static func Aggregates.game(_:player:policy:) / career(_:player:policy:) / perPlayer(_:policy:) / series(...)
enum Trend { init(series: [Double?], window:tolerance:) }
static func Archetypes.isUnlocked(_:policy:) / tags(for:friends:policy:) / snapshot(player:games:friends:at:...)
struct ArchetypeHistory   // append-only
static func ProProfiles.decode(_ data: Data) throws -> [ProProfile];  ProProfiles.bundled()
static func ProComp.similarity(_ v: ArchetypeVector, _ pro: ProProfile) -> Double?   // cosine (SPEC §8), ≥3 shared dims
static func ProComp.nearest(to:among:) -> ProComp?
```
House thresholds **pending user approval** (not in DECISIONS.md yet): `FeatureThresholds` (mid ≥ 0.4 L,
long ≥ 0.9 L, rail gap R/2), `AggregatePolicy.minRunOutShots = 3`, `ArchetypePolicy` baselines and z = 1.0.
Open spec question: SPEC §8 "source URL + confidence per trait" vs Phase 6 "sourced or `estimated`" — the
validator currently accepts estimated traits without a URL.

## Training (Phase 8 — stubs only now)
`DrillID`, `AssistLevel`, `LevelPolicy`, `BiasDetector`.

## App-side protocols (later phases; declared now so wiring compiles)
`FrameSource` (camera / replay `.mov`), `TableCalibrator`, `BallDetector`, `BallTracker`,
`ShotSegmenter`, `MeshSession`, `ShooterIdentifier`, `OverlayRenderer`, `LabelGenerator`
(Foundation Models + rule fallback).

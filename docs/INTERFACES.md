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
public enum PhysicsEvent { case ballBall(BallID, BallID), cushion(BallID, Rail), pocket(BallID, Pocket),
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

## Engine (Phase 2 — stub only now)
```swift
public actor ShotEngine { func candidates(_ s: TableState, _ g: GameState) -> [Candidate]
                          func evaluate(_ s: TableState, _ g: GameState, skill: SkillModel) async -> Evaluation
                          func winProbability(_ s: TableState, _ g: GameState) -> Double
                          func rate(chosen: Candidate, outcome: ShotTrace, eval: Evaluation) -> (DecisionRating, ExecutionRating) }
// DecisionRating (D18): brilliant, great, best, good, okay, book, inaccuracy, miss, mistake, blunder — rules in docs/RATING_CLASSES.md.
// Brilliant is assigned post-game (max 1/game, must be Shot of the Game); live it shows as Great.
```

## Stats / Training (Phase 6 / 8 — stubs only now)
`ShotFeatures.extract(pre:post:trace:) -> ShotFeatures`, `Aggregates`, `Archetypes`, `ProComp`;
`DrillID`, `AssistLevel`, `LevelPolicy`, `BiasDetector`.

## App-side protocols (later phases; declared now so wiring compiles)
`FrameSource` (camera / replay `.mov`), `TableCalibrator`, `BallDetector`, `BallTracker`,
`ShotSegmenter`, `MeshSession`, `ShooterIdentifier`, `OverlayRenderer`, `LabelGenerator`
(Foundation Models + rule fallback).

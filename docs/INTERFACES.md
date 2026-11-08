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

## Identity (Phase 5, app target `CueCoach/Identity`)
```swift
protocol ShooterIdentifier: Sendable {
  func identify(_ window: StrokeWindow, snapshot: IdentitySnapshot, expectedShooter: UUID,
                teamInTurn: Set<UUID>?) async -> ShooterIdentification }
struct StrokeWindow { frames: [IdentityFrame] }                 // ±0.5 s around stroke start
struct IdentityFrame { image: CGImage; cueBall: CGPoint }       // Vision normalised, origin lower-left
struct IdentitySnapshot { roster: IdentityRoster; appearanceGallery, faceGallery: [UUID: [Embedding]];
                          appearanceClaimCeiling, faceClaimCeiling: [UUID: Double] }   // S9 negative signal
struct ShooterIdentification { attribution: Attribution; shooterAppearance: Embedding?; evidence: [TrackEvidence] }
enum AttributionDecision { case auto, turnOrder, tap, unknown }
struct Attribution { playerID: UUID? /* nil only for .unknown */; source: AttributionDecision; confidence: Double;
                    shooterTrackID: Int?; suggestedPlayerID: UUID?
                    var needsConfirmation: Bool /* == .unknown: card asks, nobody credited */
                    var storedSource: AttributionSource? /* nil = don't credit */ }
protocol PersonAnalyzing: Sendable { func people(in: CGImage, wants: AnalysisWants) async throws -> [ObservedPerson] }
struct AnalysisWants { appearance, face: Bool; cueBall: CGPoint; gate: ShooterGate }  // embed only gate-admitted people
struct ObservedPerson { box; joints; appearance: Embedding?; face: Embedding?; faceQuality: Double? }
struct ShooterGate { minPose = 0.5; maxDistance = 0.15 }        // "someone is shooting here", absolute, per track
struct CueModel { calibration; lookalikeRate; lrRange }         // per cue, per modelID (IdentityCalibrationTable)
enum StrokeFaceMatching { case off /* default, Q10 */, shooterOnly }   // honoured only with a matching FaceShipGateRecord
protocol FaceCropping { func faces(in: CGImage) async -> [AlignedFace] }  // Vision landmarks → 5-pt → gate → 112² warp
struct FaceEmbeddingExtractor: EmbeddingExtracting               // AuraFace Core ML, modelID fal.auraface.v1.fp16
protocol RecognitionTemplateStore { templates(for:) / replaceTemplates(_:for:) / deleteTemplates(for:) / deletionGeneration }
struct StoredRecognitionTemplates { faceEmbedding, appearanceEmbedding: Data?; optedInAt: Date; version: Int }
@MainActor final class IdentitySession {                        // RAM only; owns roster + session templates
  init(players: [(UUID, StoredRecognitionTemplates?)], guests:, faceModelID:, bodyModelID:)
  func snapshot() -> IdentitySnapshot
  func identifyShot(_ shot: UUID, window:, expectedShooter:, teamInTurn:, using:) async -> Attribution
  func correct(shot: UUID, to: UUID) -> Attribution?            // one tap: fix or confirm; the only learning path
  func bind(_ player: UUID, appearance: Embedding) -> Bool      // AppearanceBind (clothes consent only)
  func addPlayer(id:, stored:); func addGuest(_: UUID); func removePlayer(_: UUID)
  var needsReconsent: Set<UUID>                                 // stored consent outdated: nothing loaded
  func grantGuestClothesConsent(_ guest: UUID); func revoke(_ player: UUID); func end() }
IdentityPrivacy.deleteMyRecognitionData(stack:, session:, onRevoke:)   // onRevoke required (Mesh IdentityRevoke)
IdentityPrivacy.deleteRecognitionData(of:, store:, session:, onRevoke:)  // same, through the template store
FaceBenchmarkSession.addSubject(_:, consent: FaceBenchConsent?) -> UUID?   // separate bench consent; RAM; ≤ 7 days
FaceBenchmark.evaluate(subjects:modelID:) -> .pass(FaceShipGateRecord) | .fail | .insufficientData   // F6
```
Rules (round 3): only tracks admitted by `ShooterGate` are evidence. Competitors for `.auto` are *every* roster
member (off-team players and guests too) plus an explicit "someone else" (unmodelled person) whenever a guest or a
non-consenting player is at the table; the pick must beat all of them by `minEvidenceRatio` with positive evidence.
A registered profile is never credited (neither `.auto` nor silent turn order) while a guest is at the table:
`.unknown`, one tap. Face consent enrols only frames with exactly one admissible face. Silent
`.turnOrder` only when no guest is present (or the guest is the expected shooter) and evidence neither contradicts
the expected shooter nor ties them with another recognisable player. Nothing is embedded unless a consented template
exists to compare against (no bootstrap). Nothing is learned from turn order or `.auto`: only registration and a tap.
`shooterAppearance` is held (RAM, `tapWindow` shots) only if it resembles a clothes-consented template, or on a
consented player's turn at an all-clothes-consented table. A correction away from W caps W's claim on that look for
the session (numbers only). Every roster/consent change bumps the epoch; revoke/end cancel in-flight work (checked per
frame and before each embedding); retry exhaustion → `.unknown`. Stored consent for older terms/models → nothing
loaded, `needsReconsent`. Face consent needs an identity-trained model (`isIdentityTrained`); generic feature prints
are never face templates. `.shooterOnly` needs a passed on-device benchmark for that modelID (D28): threshold fitted on one volunteer half,
then TAR ≥ 0.90, open-set FPIR ≤ 0.5 % and zero misidentifications on the other, disjoint half (Wilson bounds and
coverage recorded). With a guest at the table a tap teaches nothing unless every guest has a session template and the
sample beats each of them by `IdentitySession.guestMargin`. A tap teaches only a sample that already resembles the
tapped player's template unless everyone at the table consented to clothes. Backups never carry
recognition data. `RecognitionData.version` = consent-terms version.

## App-side protocols (later phases; declared now so wiring compiles)
`FrameSource` (camera / replay `.mov`), `TableCalibrator`, `BallDetector`, `BallTracker`,
`ShotSegmenter`, `MeshSession`, `ShooterIdentifier`, `OverlayRenderer`, `LabelGenerator`
(Foundation Models + rule fallback).

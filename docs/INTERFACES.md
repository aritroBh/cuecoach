# Module interfaces (proposal — awaiting user review)

All `CueCore` types are value types, `Sendable`, `Codable` where they cross the mesh or disk.
Units: metres, seconds, radians, m/s, rad/s. Table frame: origin = head-left cushion nose, +x toward the foot (head spot at 0.25 L, foot spot at 0.75 L).

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

## Training (Phase 8 — `Packages/CueCore/Sources/Training`, imports Geometry only)
```swift
public enum DrillID { case straightIn, increasingCuts, long, rail, sidePocket, positionPlay, spinControl, banks
                      var hasPositionZone: Bool; var trackedAxes: Set<BiasAxis> }   // trackedAxes: open question
public enum OverlayElement { case liveAimLine, cueToGhostLine, ghostBall, objectToPocketLine,
                             cueAfterContactLine, spinDot, powerMeter, positionZone }
public enum AssistLevel: Int { case full = 1, objectLineOnly, ghostOnly, none     // D1
                               var showsSuggestedShot: Bool; var harder/easier: AssistLevel?
                               func visibleWhileAiming(in: DrillID) -> Set<OverlayElement>
                               func visibleAfterShot(in: DrillID) -> Set<OverlayElement> }
public struct LevelPolicy { init(window:promoteAt:demoteAt:) throws(LevelPolicyError)   // decoding validates too
                            static let standard                                      // 10 attempts, ≥0.8 up, ≤0.4 down; gap > 2·epsilon
                            func record(success:into: inout LevelProgress) -> LevelChange? }
public struct LevelProgress { var level: AssistLevel; var recent: [Bool]; var successRate: Double? }
public struct TrainingProgress { func level(for: DrillID) -> AssistLevel
                                 mutating func record(drill:success:policy:) -> LevelChange? }  // Training store only
public enum BiasAxis { case cut, side, speed, cueBallDistance, spin; var unit: String; var typicalNoise: Double }
public struct BiasDetector { struct Config { deadZone, alternativeP, threshold, cap, minimumAttempts
                                             static let standard /* σ units */; static let calibrated: [BiasAxis: Config]
                                             func scaled(by:) -> Config }           // decoding validates
                             init(config:) /* one unit for all axes */; init(configs: [BiasAxis: Config])
                             mutating func observe(_: BiasAxis, error: Double); func activeBiases() -> [DetectedBias]
                             mutating func reset(_: BiasAxis) }
public struct DetectedBias { var key: BiasKey /* axis + BiasDirection */; var evidence: Double
                             var meanError: Double /* sign == direction */; var attempts: Int; var consistency: Double }
public enum Correction { hitThicker, hitThinner, favorLeft, favorRight, softer, firmer, shorter, longer, lessSpin, moreSpin
                         init(for: BiasKey); var label: String /* ≤2 words, no digits */; var visual: FeedbackVisual }
public enum FeedbackVisual { case averageLineVsCorrect, missHeatmap, arrow(ArrowDirection), spinDotVsIntended }
public enum BiasStrength { case slight, clear, strong }                        // glow / line spread only
public struct Feedback { var bias: BiasKey; var correction: Correction; var strength: BiasStrength }
public struct FeedbackCoach { init(drill:configs: = .calibrated); init(drill:config:)
                              var current: Feedback?                            // one correction at a time
                              mutating func record(_: [BiasAxis: Double]); mutating func dismiss() }
public enum SetupMatcher { static func match(ghosts: [Vec2], detected: [Vec2], tolerance: Double) -> [Bool]
                           static func isReady(_: [Bool]) -> Bool }
```
Error contract for `record`/`observe`: actual − intended, positive = overcut / miss right / too hard /
cue ball long / more spin. Units: cut rad; side m (object-ball lateral miss at the pocket mouth, shooter's
right +); speed ratio (actual/intended − 1); cueBallDistance m (past target +); spin ball radii
(|tip offset| − |intended|). `typicalNoise` per axis is provisional until tuned on real training data.

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

## Live table locking (capture ↔ Calibration/Auto) — lock plan 2026-11-07
```swift
protocol TableLocating: Sendable {                       // CueCoach/Calibration/TableLocating.swift
    func ingest(_ f: LocatorFrame) async -> TableEstimate?
    func reset() async
}
struct LocatorFrame { var image: PixelImage; var camera: CameraModel; var planes: [LocatorPlane]
                      var timestamp: Double; var depth: DepthMap?; var trackingNormal: Bool }
struct TableEstimate { var corners: [SIMD3<Double>]; var confidence: Double; var locked: Bool; var size: TableSize?
                       var failure: LockFailure?        // glyph + dev HUD (never text on screen)
                       var frame: TableFrame?           // exact pose when locked — install it, don't re-fit
                       var generation: Int }            // bumps on (re)lock / held-size change
enum LockFailure { case noPlane, noFelt, partialTable, tooFar, tooClose, badShape, unstable }
```
- **Lock source** = `AutoTableLocating` (adapter over `ClassicalAutoTableLocator`, Calibration/Auto). FeltQuad is a
  ghost seed only (felt boundary at rail-top height, cushion inset from `AutoTableProfile`), never the lock.
- Auto `diag.rejection` → `LockFailure`: cloth touches frame → partialTable; cloth too small / too small → tooFar;
  no plane → noPlane; no cloth colour → noFelt; others → badShape; converging with spread > 2 cm → unstable.
- **Cadence**: `LocatingGate` (~15 Hz, busy flag) shared by FrameTap and the VirtualTable harness; no locator throttle.
- **Planes**: an ARKit anchor is an infinite plane at its height (no extent test); without one, Auto takes a
  provisional LiDAR plane. A level > 1.4 m below the camera is the floor, never the table.
- **History** expires after a > 1 s timestamp gap or 5 consecutive rejections.
- **Keypoints**: `TableKeypointModel.provider()` → `TableKeypointProvider` (nil until the tablekp .mlpackage ships).
- **Live screen (D24)**: `LiveScreen(mode: LiveMode, drill: DrillID?, hooks: LiveHooks, onClose: (() -> Void)?)`
  with `.game` | `.training(level: Int)`; visibility per `OverlayVisibility.of(mode)`.
  `LiveHooks` (closures, all `@MainActor`) is how Live drives the shell's `LiveSession`:
  `aimStarted / aimEnded / aimCancelled / ballsSettled / settled(DecisionRating, turnPasses)`, emitted by the pure
  `AimEvents` state machine. With hooks set, the shell draws the post-shot badge; standalone, Live does (hidden
  the moment the next aim starts or any ball moves). Ratings: `RuleRating` (RulesEngine; any foul ≤ Mistake,
  a game-losing foul = Blunder) until a live ShotEngine evaluation is wired.
- **Measured size**: on lock Live writes `UserDefaults "cc.table.measured"` (TableSize raw value).
- **Lock safety**: a lock needs pocket evidence (≥ 2 keypoint mouths or ≥ 4 dark fitted mouths, 3 frames) and a
  measured length that isn't ambiguous between two presets; keypoints come from `CoreMLTableKeypointProvider`
  (tablekp YOLO26n-pose, ANE, ≤ 10 Hz).
- **Manual fallback**: tap the 2 nearest corner pockets (any order) → `TwoTapTable` fills the table from the plane +
  preset → drag any corner (loupe + snap) → ✓.
- **Acceptance**: `CueCoachTests/VirtualTable` matrix + `LockGate` (0 false locks always; accurate-lock / TTL floors
  ratcheted per step). Baselines in `CueCoachTests/VirtualTable/Results/`.

### AutoTableLocator (Calibration/Auto, zero-tap table pose)
`AutoTableLocator.process(AutoTableFrame) -> AutoTableEstimate` (thread-safe; calls are serialised,
`latest` / `flipHeadFoot()` / `reset()` never wait for a detection; a detection in flight during `reset()`
is dropped). `AutoTableEstimate.state` is `.locked` after ≥ 6 agreeing frames at ≤ 1 cm robust corner
spread, or 15 at ≤ 2 cm; `generation` bumps on every new lock and on an adopted size change (size changes
need 10 consistent frames plus a ±15 % vote-share band). `frame.rejection` strings start with one of:
"tracking", "duplicate frame", "no plane", "no cloth colour", "cloth too small", "cloth touches frame",
"no quad", "edge refine", "reprojection", "view too shallow", "reset" (a failed partial fit appends "(partial: …)"). Keypoint plug-in: `TableKeypointProvider` returns
`AutoTableKeypoint`s of kind `.cornerMouth` / `.sideMouth` / `.noseCorner`, the tablekp model's three
groups; `AutoTableKeypointModel` adapts its 10 rows (model-input pixels, Ultralytics letterbox).

## App shell (CueCoach/App, docs/design/app-shell.md)
```swift
enum ShellLiveMode { case game; case training(level: Int) }       // mirrors Live's LiveMode (D24); LiveScreenAdapter is the one call site
struct GameConfig: Codable { var ruleSet; var tableSize; var teams: [[ShellPlayer]]; var sessionTag: UInt16?
                             var rotation: [ShellPlayer] }          // D17 A1, B1, A2, B2, …
@MainActor protocol GameLobbyMesh { var onEvent: ((LobbyEvent) -> Void)?
    func browse(); func stopBrowsing(); func join(gameID:); func leave()
    func host(_: NearbyGame); func stopHosting(); func publish(lineup: LobbyLineup); func announceStart(_: GameConfig) }
enum LobbyEvent { gamesChanged, joined, rejectedFull, hostLeft, started(GameConfig), lineupChanged(LobbyLineup), unavailable, phonesChanged }
```
`MPCGameLobby` implements it on its own MPC service `cuecoach-lb` (adverts in discovery info, JSON messages,
encryption required). On Start every phone opens `MultipeerMeshSession.multipeer(sessionTag:)` with the
host's random tag (`MeshGameLink`). `FakeGameLobbyMesh` drives tests; `OfflineGameLobby` = one phone.
Guests are `ShellPlayer(isGuest: true)` in memory only, never written to SwiftData.
Measured table size: Live writes `UserDefaults "cc.table.measured"` (TableSize raw value); setup preselects it.

## Recognition persistence (privacy round; docs/SCHEMA.md "Recognition store")
`PersistenceStack`: `recognition(for:)`, `storeRecognition(profileID:faceEmbedding:appearanceEmbedding:optedInAt:version:)`
(throws `RecognitionError.revoked`), `beginRecognitionDeletion() -> RecognitionUndo`, `undoRecognitionDeletion(_:)`,
`deleteMyRecognitionData(now:)` (commit, empties the store), `purgeSessionGuests()`,
`promoteSessionGuest(_:keepRecognition:)`, `deleteProfile(_:)`, `importBackup(_:keepingRecognitionOf:)`,
`exportBackup(exportedAt:)` (never includes templates), `register(_: RecognitionGallery)`.
`@MainActor protocol RecognitionGallery: AnyObject { func recognitionDidChange(_: RecognitionChange) }`,
`RecognitionChange = .purgedAll | .purged(Set<UUID>) | .restored(Set<UUID>)`. Identity's in-memory galleries
(`IdentitySession` face/appearance) register so a delete, purge or promotion clears them synchronously.

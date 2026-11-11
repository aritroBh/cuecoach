# Plan 004: A broken or re-exported ball model fails tests instead of silently running classical-only

> **Executor instructions**: Follow this plan step by step. Run every verification command and confirm the
> expected result before the next step. If a STOP condition occurs, stop and report; do not improvise. When
> done, update this plan's row in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat b21f994..HEAD -- CueCoach/Perception/CoreMLBallDetector.swift CueCoachTests/Perception/CoreMLBallDetectorTests.swift CueCoachTests/Perception/ReplayRegressionTests.swift CueCoach/Resources`
> If anything changed, compare the excerpts below with the live code. A mismatch is a STOP condition.

## Status
- **Priority**: P2 · **Effort**: S · **Risk**: LOW · **Depends on**: none · **Category**: tests
- **Planned at**: commit `b21f994`, 2026-11-10

## Why this matters
The default detector is "hybrid" (decision D32): it runs the bundled Core ML model and falls back to the classical
detector whenever inference returns nil. Inference returns nil, with no error, if the model's input/output
feature names or shapes change. That would happen after a re-export, or if the NMS stage is dropped. The current
tests still pass in that case:
- `appDetectorReplaySeesAllSixBalls` passes on classical alone.
- `bundledModelRunsAndEveryDetectionIsOnTheTable` accepts zero detections.

So a broken model could ship as "hybrid" while really being classical, and the D32 accuracy win would be lost
without anyone noticing. This plan pins the contract.

## Current state
- `CueCoach/Perception/CoreMLBallDetector.swift`:
  - `:12-13`: `BallDetectorOutput.classCount = 16`, `inputSize = 640.0`.
  - `:112-118`: hard-coded feature names. Inputs are `"image"` (640×640 pixel buffer), `"iouThreshold"` and `"confidenceThreshold"`; outputs are `"confidence"` and `"coordinates"`. Any mismatch gives `return nil`.
  - `:124-135`: `copyRows` requires 2-D outputs, `coords.shape[1] >= 4` and `conf.shape[1] >= 16`.
  - `:158`: `HybridBallDetector.needsShadingCheck` is true when the last frame used classical.
  - `:174-181`: the hybrid's `detect`, which falls back to classical when `model.infer` returns nil.
- `CueCoachTests/Perception/CoreMLBallDetectorTests.swift:163-173`: `bundledModelRunsAndEveryDetectionIsOnTheTable` uses `SyntheticTableScene.demo()` and `#require(model.infer(img))`, but never checks the count.
- `CueCoachTests/Perception/ReplayRegressionTests.swift:25-29`: `appDetectorReplaySeesAllSixBalls`.
- `MLModel.modelDescription.inputDescriptionsByName` / `outputDescriptionsByName` give names and `MLFeatureDescription` (`.type`, `.imageConstraint?.pixelsWide`). The keypoint model already reads its names this way (`CueCoach/Calibration/CoreMLTableKeypoints.swift:29-31`). The model property is `private let model: MLModel` on `CoreMLBallInference`; use `@testable` access or add an `internal var modelDescription`.
- Tests are Swift Testing (`@Test`, `#expect`, `#require`).

## Commands you will need
| Purpose | Command | Expected |
|---|---|---|
| Targeted | `xcodebuild test -project CueCoach.xcodeproj -scheme CueCoach -destination 'platform=iOS Simulator,name=CueCoach iPhone 15 Pro' -only-testing:CueCoachTests/CoreMLBallDetectorTests -only-testing:CueCoachTests/ReplayRegressionTests` | `** TEST SUCCEEDED **` |
| Full unit | same with `-only-testing:CueCoachTests` | `** TEST SUCCEEDED **` |

## Scope
**In scope:** `CueCoachTests/Perception/CoreMLBallDetectorTests.swift`, `CueCoachTests/Perception/ReplayRegressionTests.swift`, and (only if needed for access) one `var modelDescription: MLModelDescription { model.modelDescription }` line in `CoreMLBallDetector.swift`.

**Out of scope:**
- Changing the feature-name lookup in production.
- The classical detector.
- The model file.
- The keypoint model.

## Git workflow
Branch `wt/plan-004` from `phase/1-core`. Style: `test(perception): pin the ball model's I/O contract and prove the hybrid ran the model`, ending with the co-author trailer.

## Steps
### Step 1: Contract test
Add `bundledModelMatchesTheDecoderContract`. It requires `CoreMLBallInference.shared` and checks that:
- the inputs contain `"image"` (type `.image`, 640×640), `"iouThreshold"` and `"confidenceThreshold"`;
- the outputs contain `"confidence"` and `"coordinates"` (type `.multiArray`).

**Verify**: targeted → passes.

### Step 2: The model really detects
In `bundledModelRunsAndEveryDetectionIsOnTheTable`, add `#expect(raws.count >= 5)`. The demo has 6 balls.

**Verify**: targeted → passes. If it fails, that's a STOP condition.

### Step 3: The hybrid used the model in the replay
In `appDetectorReplaySeesAllSixBalls`, keep a reference to the detector. After the run, `#expect(!detector.needsShadingCheck, "the hybrid's last frame fell back to classical")`. The detector type is `PerceptionPipeline.defaultDetector()`; check its concrete type before calling `needsShadingCheck`. It's on the `BallDetector` protocol (`BallDetection.swift:38`).

**Verify**: targeted → passes.

### Step 4: Prove the guard bites
Temporarily change the string `"confidence"` in `CoreMLBallDetector.swift:116` to `"confidenceX"`, then run the targeted tests. Expect them to **fail** in steps 2 and 3. Revert the change, then confirm `git diff CueCoach/Perception/CoreMLBallDetector.swift` shows only the optional accessor.

**Verify**: failure seen, then reverted, then targeted passes.

## Done criteria
- [ ] Three strengthened or new tests pass; the full `CueCoachTests` passes
- [ ] Step 4's mutation was observed to fail the tests (note it in the commit body)
- [ ] `git diff --name-only phase/1-core` ⊆ the in-scope list plus `plans/README.md`

## STOP conditions
- Step 2 gives fewer than 5 raws on the simulator. The model may already be degraded; report the count.
- `needsShadingCheck` is true at the end of the replay even with the model working. The hybrid's due-time pacing may make the last frame classical by design (it runs the model at ≤ 30 Hz and the replay is 15 Hz, so it should be due). Report it instead of weakening the check.

## Maintenance notes
- Any model re-export must keep these names, or update the decoder and these tests together.

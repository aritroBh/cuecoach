# Plan 003: Ball-model latency is measurable on a real iPhone (Neural Engine) and visible in the dev HUD

> **Executor instructions**: Follow this plan step by step. Run every verification command and confirm the
> expected result before the next step. If a STOP condition occurs, stop and report; do not improvise. When
> done, update this plan's row in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat b21f994..HEAD -- CueCoach/Perception/CoreMLBallDetector.swift CueCoach/Live/LiveModel.swift CueCoach/Live/LiveScreen.swift CueCoachTests/Perception`
> If anything changed, compare the excerpts below with the live code. A mismatch is a STOP condition.

## Status
- **Priority**: P1 · **Effort**: M · **Risk**: LOW · **Depends on**: none · **Category**: perf + tests
- **Planned at**: commit `b21f994`, 2026-11-10

## Why this matters
The app's default ball detector (decision D32: "hybrid", a Core ML model with a classical fallback) was chosen
from simulator-CPU timings only. The checklist's open item "D32 phone latency on the Neural Engine" can't be
closed with today's tools:
- The benchmark test reads its frames from the Mac's source tree, so it can't run on a phone.
- The model timer the app records is never shown anywhere.
- The first measured frame includes model compile time.

The budget is 30 fps on an iPhone 15 Pro (`docs/SPEC.md` §perf: 33 ms/frame), and never below 24 fps when hot.
This plan adds a self-contained latency test that runs on device and shows model time in the dev HUD. Plan 005
(latency fallback) depends on the number this produces, which is why 005 isn't written yet.

## Current state
- `CueCoach/Perception/CoreMLBallDetector.swift:85-99`: `CoreMLBallInference`. It loads `BallDetector.mlmodelc` from a bundle with `cfg.computeUnits = .all`, and is a `static let shared` singleton. `init(bundle: Bundle = .main)` has **no** compute-units parameter.
- `CoreMLBallDetector.swift:103-119`: `lastInferenceMs` (written at line ~119) times only `model.prediction`. It does not cover letterboxing (`CoreMLTableKeypointProvider.letterboxed`, line ~109).
- `CueCoachTests/Perception/DetectorBenchTests.swift:18,105-108`: opt-in through the env var `CUECOACH_BENCH`. It loads frames from `#filePath`-relative `tools/detector/data/bench/` (gitignored, Mac-only).
- `CueCoachTests/Perception/ReplayRegressionTests.swift:9-17`: the pattern to copy for an **in-repo** frame: `SyntheticTableScene.demo()`, `scene.render()` → `CGImage`, then `PixelImage(cgImage:)`. It works on simulator and device with no files.
- The dev HUD, `CueCoach/Live/LiveScreen.swift:369-378` (`DebugHUD`), shows `det` = a smoothed whole-`detect()` time from `LiveModel.detectMs` (`LiveModel.swift:401`).
- Tests are Swift Testing. Device-vs-simulator branching already exists: `#if targetEnvironment(simulator)` (`DetectorBenchTests.swift` `platform`).
- Devices: iPhone 15 Pro Max (the perf gate) and iPhone 17 Pro Max. The user may not have a phone connected. **On simulator the test must record, not gate.**

## Commands you will need
| Purpose | Command | Expected |
|---|---|---|
| New test on sim | `xcodebuild test -project CueCoach.xcodeproj -scheme CueCoach -destination 'platform=iOS Simulator,name=CueCoach iPhone 15 Pro' -only-testing:CueCoachTests/BallModelLatencyTests` | `** TEST SUCCEEDED **`, log line `[latency]` |
| New test on device (if connected) | same with `-destination 'platform=iOS,name=<phone name>'` (list with `xcrun xctrace list devices`) | `** TEST SUCCEEDED **` |
| Full unit suite | sim, `-only-testing:CueCoachTests` | `** TEST SUCCEEDED **` |

## Scope
**In scope:**
- `CueCoach/Perception/CoreMLBallDetector.swift`: add a `computeUnits` init parameter (default `.all`) and a `lastLetterboxMs` timing.
- `CueCoach/Live/LiveModel.swift` and `CueCoach/Live/LiveScreen.swift`: HUD fields only.
- `CueCoachTests/Perception/BallModelLatencyTests.swift` (create).
- `docs/research/detector-benchmark.md`: append a results section.

**Out of scope:**
- Changing the default compute units or detector choice. D32 is settled; this plan only measures.
- `DetectorBenchTests` and the Python scorer.
- The letterbox speed-up: record the number only.
- Any frame-drop or fallback logic (plan 005).

## Git workflow
Branch `wt/plan-003` from `phase/1-core`. Style: `test(perception): device-runnable ball-model latency (warm, split letterbox/predict)`, ending with the co-author trailer.

## Steps
### Step 1: Let the model be built with chosen compute units
Add `init(bundle: Bundle = .main, computeUnits: MLComputeUnits = .all) throws`. The `shared` singleton is unchanged. Record `lastLetterboxMs` the same way as `lastInferenceMs`, using its own `Mutex`, around the `letterboxed` call.

**Verify**: full unit suite → `** TEST SUCCEEDED **`, with no behaviour change.

### Step 2: Latency test
Create `BallModelLatencyTests.swift` with `@Suite(.serialized)`. For each of `[.all, .cpuAndNeuralEngine, .cpuOnly]`:
1. Build `CoreMLBallInference(bundle: Bundle(for: <a class in the app>) or .main, computeUnits:)`. Check how other tests reach the app bundle; `@testable import CueCoach` runs hosted, so `.main` is the app.
2. Render `SyntheticTableScene.demo()` once.
3. Run **10 warm-up** `infer` calls (discarded).
4. Run **60 timed** calls, collecting `lastLetterboxMs` and `lastInferenceMs` per call.
5. Compute p50 and p95 of each, and of their sum.
6. `print("[latency] \(units) letterbox p50/p95 … predict p50/p95 … total p50/p95 … platform \(platform)")`.
7. Expect `infer` to return non-nil with at least 5 detections. The demo has 6 balls, so this proves the model really ran.
8. **Gate only on device**: on device, `#expect(totalP95 < 33)` for `.all`. On the simulator, there is no latency expectation.

**Verify**: the sim command → passes and prints three `[latency]` lines.

### Step 3: HUD
Add `model <ms>` (smoothed `lastInferenceMs`) and `lb <ms>` (smoothed `lastLetterboxMs`) to the first `DebugHUD` line. Read them where `detectMs` is updated (`LiveModel.swift:~401`), from `CoreMLBallInference.shared`. The HUD is dev-only (decision D9: shown only behind the debug flag). Don't add any user-visible text.

**Verify**: full unit suite passes; `grep -n "model \\\\(" CueCoach/Live/LiveScreen.swift` → 1 match.

### Step 4: Record results
Append a section "Device latency (Neural Engine)" to `docs/research/detector-benchmark.md` with the simulator numbers from step 2. Add a device row too if a phone was connected; otherwise write "device: not yet run". Do not invent device numbers.

**Verify**: `grep -n "Device latency" docs/research/detector-benchmark.md` → 1 match.

## Done criteria
- [ ] `BallModelLatencyTests` passes on `CueCoach iPhone 15 Pro` and prints 3 `[latency]` lines
- [ ] Full `CueCoachTests` passes
- [ ] `docs/research/detector-benchmark.md` has the new section with real numbers only
- [ ] `git diff --name-only phase/1-core` ⊆ the in-scope list plus `plans/README.md`

## STOP conditions
- `SyntheticTableScene.demo()` gives fewer than 5 model detections with `.all` on the simulator. That means the model isn't really running (see plan 004). Report it; don't lower the threshold.
- `.cpuAndNeuralEngine` throws, or returns nil on the device. That is a model-export issue. Report it with the error.
- The device p95 for `.all` is over 33 ms. **Don't fix it here.** Report the numbers; they decide plan 005.

## Maintenance notes
- Re-run on both phones after any model re-export. The `[latency]` line is the number to put in the checklist.
- The `.cpuOnly` row is a sanity floor. If `.all` isn't clearly faster than `.cpuOnly` on device, Core ML is likely running the model mostly on CPU.

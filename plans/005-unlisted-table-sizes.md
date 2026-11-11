# Plan 005: Tables that aren't 7, 8 or 9 ft either lock at their true size or say why they can't

> **Executor instructions**: This plan has a **product decision gate** (Step 0). Do not start Step 1 until
> `plans/README.md` records the user's answer for plan 005. Then follow the steps, run every verification, honor
> the STOP conditions, and update this plan's row in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat b21f994..HEAD -- CueCoach/Calibration CueCoach/Live/LiveLogic.swift CueCoach/App/GameSetupModel.swift CueCoachTests/Calibration/Auto`
> If anything changed, compare the excerpts below with the live code. A mismatch is a STOP condition.

## Status
- **Priority**: P2 · **Effort**: M · **Risk**: MED · **Depends on**: user decision (Step 0) · **Category**: bug
- **Planned at**: commit `b21f994`, 2026-11-10

## Why this matters
Auto table-locking knows three presets: 7 ft (80″ = 2.032 m), 8 ft (92″ = 2.337 m) and 9 ft (100″ = 2.540 m). Real
bar and home tables come in other sizes too. Two failure modes follow from the constants (computed, not yet run):
1. **Wrong scale, no warning.** A "Pro-8" (88″ × 44″, playing length 2.235 m) is 4.4 % from 8 ft. That is inside the
   6 % snap and inside the 35 %-of-gap ambiguity guard (0.102 m < 0.35 × 0.305 m), so it locks as 8 ft. Every
   length is then about 4 % too long, and ball positions are off by up to ~5 cm.
2. **Never locks, wrong hint.** A measured length of about 2.154–2.197 m is "measured" (not a preset) but lies inside the
   preset span. The size then never settles, and the user is told `.partialTable` ("step back / tilt"). The table
   is in full view; the real problem is its size.

The game-setup screen already knows a table size (`GameSetupModel.tableSize`, from a measurement or the Settings
manual size `cc.table.manual`), but the locator never sees it.

## Step 0: decision needed from the user (do not guess; project rule)
Ask the user which behaviour they want. Recommended: **A + C**.
- **A.** Snap to a preset only within ±2 % (a measuring tolerance). Anything else locks at its **measured size**. This is what
  decision D12 allows: "the measured size snaps to a preset or is used directly". A Pro-8 would then lock at 88″.
- **B.** Keep the 6 % snap (Pro-8 stays "8 ft"). Only fix the hint (Step 3).
- **C.** (Can combine with A or B.) A size chosen in game setup or Settings is a **prior**. The locator snaps to it when the
  measurement is within 6 % of it, and never locks a different preset without measured evidence.

Record the answer in `plans/README.md` under "Decisions", then continue.

## Current state
- `Packages/CueCore/Sources/Geometry/Table.swift:7-14`: `TableSize { sevenFoot, eightFoot, nineFoot }` and `playingLength`.
- `CueCoach/Calibration/Auto/AutoTableFitter.swift:136-145`: `sizeVerdict(length:width:)`:
  - `est = (L + 2W)/2`
  - if the nearest preset error is > 0.06, the verdict is `.measured` (when `plausibleLength` contains it) or `.implausibleSize`
  - if two presets are within 0.02 of each other, `.ambiguous`
  - otherwise `.preset(nearest)`
- `CueCoach/Live/LiveLogic.swift:531-539`: `SizeAmbiguity.isAmbiguous(measuredLength:snapped:fraction: 0.35)`.
- `CueCoach/Calibration/Auto/AutoTableFusion.swift`:
  - `:81-84`: `presetSpan` = min...max preset length.
  - `:172-180`: when no preset wins, `spec.length = (mL + 2mW)/2` and `sizeDecided = snapped != nil || !presetSpan.contains(spec.length)`. A measured in-span size is never decided. This was deliberate: it fixed a wrong-size false lock (the matrix gate is 0 false locks).
  - `:282`: `votesOnSize`.
- `CueCoach/Calibration/AutoLocatorAdapter.swift:170-176`: while converging, the failure is `.unstable` if the corners spread, else `.partialTable` if `awaitingSize`.
- `CueCoach/Calibration/FeltQuadProposer.swift:5-13`: `enum LockFailure: String { noPlane, noFelt, partialTable, tooFar, tooClose, badShape, unstable }`.
- `CueCoach/App/GameSetupModel.swift:87`: `tableSize = measuredTable ?? defaults.manualTable ?? .sevenFoot`.
- Tests to model on: `CueCoachTests/Calibration/Auto/AutoTableBetweenPresetsTests.swift` (e.g. `betweenPresetFitsAloneNeverLock`, `aLoneBorderlineSnapWhileLockedNeverPoisonsTheMeasuredSize`). It uses synthetic fits from `AutoSyntheticScene.swift`.
- UI copy rule: lock hints are icon + ≤2 words. No text while aiming. A new hint needs a short string and an SF Symbol that match the existing `LockFailure` hints. Find where those are rendered by grepping `partialTable` under `CueCoach/Live`.

## Commands you will need
| Purpose | Command | Expected |
|---|---|---|
| Targeted | `xcodebuild test -project CueCoach.xcodeproj -scheme CueCoach -destination 'platform=iOS Simulator,name=CueCoach iPhone 15 Pro' -only-testing:CueCoachTests/AutoTableBetweenPresetsTests -only-testing:CueCoachTests/AutoTableSizeEvidenceTests` | `** TEST SUCCEEDED **` |
| Full unit | same with `-only-testing:CueCoachTests` | `** TEST SUCCEEDED **` |
| Lock matrix (regression gate) | find the matrix test's invocation in `docs/CHECKLIST.md` ("Lock matrix (27×20, app, -O build)") and run it the same way | **0 false locks**; in-scope accuracy ≥ 92.0 % |

## Scope
**In scope:**
- `AutoTableFitter.swift` (`sizeVerdict`), `AutoTableFusion.swift` (size settling), `LiveLogic.swift` (`SizeAmbiguity`)
- `AutoLocatorAdapter.swift` (hint)
- `FeltQuadProposer.swift` (a new `LockFailure` case)
- the view that renders hints
- the size prior plumbing from `GameSetupModel` to the locator (only if C is chosen)
- tests in `CueCoachTests/Calibration/Auto/`

**Out of scope:**
- Adding new `TableSize` presets. It's a CueCore enum used by Rules, Stats and persistence.
- The keypoint model.
- LiDAR depth code.

## Steps
### Step 1: Red tests
In `AutoTableBetweenPresetsTests.swift`:
- `aPro8LocksAtItsMeasuredLength` (under A): steady four-rail fits at 2.235 × 1.118 m lock at length 2.235 ± 0.02 m, `snapped == nil`. Under B, assert it locks as 8 ft and skip the rest of A.
- `anInSpanUnlistedSizeTellsTheUserItsTheSize`: steady fits at 2.18 m don't lock, and the failure is the new case (e.g. `.unusualSize`), not `.partialTable`.
- Under C: `aChosenSizeIsThePrior`: a manual 8 ft with fits at 2.30 m locks as 8 ft; a manual 7 ft with fits at 2.34 m does not lock as 7 ft.

**Verify**: targeted → the new tests FAIL.

### Step 2: Implement the chosen behaviour
- A: tighten the snap tolerance to 0.02 in `sizeVerdict`. A steady measured size, with the same vote count as a preset, sets `sizeDecided = true` even inside `presetSpan`.
- C: pass `prior: TableSize?` into the fusion config.

Keep every existing `AutoTableBetweenPresetsTests` test green. They guard the false-lock fix.

**Verify**: targeted → passes.

### Step 3: Honest hint
Add the `LockFailure` case. The adapter returns it instead of `.partialTable` when the cloth is fully in view but the size is undecided. Use a short hint and an SF Symbol (e.g. `ruler`) matching the other hints.

**Verify**: full unit suite → passes.

### Step 4: Lock matrix
Run the -O lock matrix.

**Verify**: 0 false locks, in-scope ≥ 92.0 %. Record before → after in `docs/CHECKLIST.md`.

## Done criteria
- [ ] Step 0 answer recorded in `plans/README.md`
- [ ] New tests pass; the full `CueCoachTests` passes
- [ ] Lock matrix: 0 false locks, in-scope ≥ 92.0 %
- [ ] `git diff --name-only phase/1-core` ⊆ the in-scope list plus `docs/CHECKLIST.md` and `plans/README.md`

## STOP conditions
- The matrix shows any false lock after the change. Revert to B and report.
- Under A, a synthetic 7 ft or 9 ft scene now locks at a measured non-preset length (the snap became too tight for real measuring noise). Report the measured spread.
- The prior (C) would need `GameSetupModel` to reach the locator through more than one new parameter on the Live entry point. Report the wiring before building it.

## Maintenance notes
- A measured (non-preset) spec flows into `TableSpec.length/width`, and Rules/Engine already use the spec's numbers. A reviewer should check that nothing downstream switches on `snapped` alone.
- If presets are ever extended (e.g. a 6 ft table, about 1.83 m playing length), `presetSpan` widens. Re-check which measured sizes count as "in span".

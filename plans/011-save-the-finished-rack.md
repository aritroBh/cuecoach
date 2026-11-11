# Plan 011: Save a finished rack to the competitive store (D37, D40)

> **Executor instructions**: Follow this plan step by step. Run every verification and confirm the expected result
> before the next step. Honor the STOP conditions; do not improvise. When done, update this plan's row in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 5cd3fcf..HEAD -- CueCoach/App/AppRouter.swift CueCoach/App/GameSessionModel.swift CueCoach/App/ShellEnvironment.swift CueCoach/App/AppShellRoot.swift CueCoach/Live/LiveModel.swift CueCoach/Persistence docs/INTERFACES.md CueCoachTests/App CueCoachTests/Persistence`
> Plans 002, 007, 008 and 009 change `GameSessionModel.swift`, `AppRouter.swift` and `LiveModel.swift`. Re-read them
> after they merge and compare with the excerpts below. A changed shape is a STOP condition.

## Status
- **Priority**: P1 · **Effort**: M · **Risk**: MED · **Depends on**: plan 009 merged; plan 007 merged (D37 settle-before-end); plan 010 if mesh games should save · **Category**: feature
- **Planned at**: commit `5cd3fcf`, 2026-11-10. Design: `docs/research/game-log-and-saving.md` §3–§5, follow-up 3.

## Why this matters
Nothing in the app writes a `Game` or `Shot` on the live path. Every camera game vanishes when review closes, so
profiles, archetypes and history never grow. **D40:** only finished racks are saved; a quit or kill mid-rack is
discarded. **D37:** the recorder runs after the last open shot settles. One writer: the host or the solo phone.

## Current state (verified at `5cd3fcf`)
- `CueCoach/App/AppRouter.swift:104-109`: `endGame()` stops the mesh, sets `mesh = nil`, then
  `stage = .review(game.reviewData())`. `:112-115` `liveClosed()` calls it for a game. Plan 007 makes ✕ call it only
  after `LiveModel.requestEnd` drains the shot FIFO.
- `CueCoach/App/GameSessionModel.swift:150-164`: `reviewData()`; `winner` comes from `rulesState.winner` (`:159`).
- `CueCoach/Persistence/CompetitiveModels.swift`: `Session.init(startedAt:endedAt:ruleSet:format:tableSize:…)` (`:91`);
  `Game.init(id:index:ruleSet:teams:winnerTeam:winProbSeries:startedAt:endedAt:)` (`:142`); `Shot.init(…)` (`:241-246`)
  takes every column in the design's field table. **`Game` has no table size** (it lives on `Session`) and **`Shot` has no
  team column** (saved review derives team from `StoredTeam.memberIDs`, `Screens/Review/ReviewData.swift:117`).
- `CueCoach/Persistence/SchemaVersions.swift:69-73`: Competitive V2 is current. No schema change here.
- `CueCoach/Persistence/StoredValues.swift:18-28`: `StoredTeam { memberIDs, shootingOrder, orderChanges }`,
  `AttributionSource { auto, turnOrder, tap }`. `StoredShotFeatures` at `:34`.
- `Packages/CueCore/Sources/Stats/ShotFeatures.swift:130` `neutral`; `:164` `extract(pre:post:trace:…)`.
- `CueCoach/App/ShellEnvironment.swift:23` injects `meshFactory`; `AppShellRoot.swift:68` copies it onto the router. Copy that for a recorder.
- `CueCoach/Persistence/PersistenceStack.swift:41` `init(inMemory:)` for tests; `competitiveContext` / `trainingContext`.
- No app code projects `Shot` rows into `CompetitiveShot` for `Aggregates` yet (`grep -rn "CompetitiveShot(" CueCoach` → nothing).

## Commands you will need
| Purpose | Command | Expected |
|---|---|---|
| Unit (targeted) | `xcodebuild test -project CueCoach.xcodeproj -scheme CueCoach -destination 'platform=iOS Simulator,name=CueCoach iPhone 15 Pro' -only-testing:CueCoachTests/GameRecorderTests -only-testing:CueCoachTests/AppRouterTests -only-testing:CueCoachTests/StoreIsolationTests` | `** TEST SUCCEEDED **` |
| Full unit | same with `-only-testing:CueCoachTests` | `** TEST SUCCEEDED **` |
| UI | same with `-only-testing:CueCoachUITests/AppShellUITests` | `** TEST SUCCEEDED **` |

## Scope
**In scope:** `docs/INTERFACES.md` (move `GameRecorder`, `FinishedGame`, `RecordedShot` out of "Proposed");
a new `CueCoach/Persistence/GameRecorder.swift` (protocol + `StackGameRecorder`); `GameSessionModel.swift`
(`finishedGame() -> FinishedGame?`); `AppRouter.swift` (`recorder` property, call in `endGame`); `ShellEnvironment.swift`
and `AppShellRoot.swift` (injection only); a new `CueCoachTests/Persistence/GameRecorderTests.swift`; `AppRouterTests.swift`.

**Out of scope:** schema changes (`Shot.isGuess` is plan 012), unfinished or resumable racks, clips/highlights,
the stats projection, partition handling (plan 013), any UI.

## Steps
### Step 1: Contract
Move the three types into a "Game saving (plan 011)" section. Record the rules: one writer (host or solo); write
only when `winnerTeam != nil` (D40); after the last settle (D37); skip `isGuess` shots and D38 gap shots (`rating == nil`)
and keep the others' original `index`; `Game.id` = first committed shot id; one `Session` per saved game, carrying
`tableSize` and `format`. **Verify**: `grep -n "GameRecorder" docs/INTERFACES.md` → in the new section, not under Proposed.

### Step 2: Red tests (`GameRecorderTests`, `PersistenceStack(inMemory: true)`)
- `finishedSoloRackWritesOneGameWithItsShots` (counts, `winnerTeam`, `endedAt != nil`, shot order).
- `fieldTableIsFollowed`: `.turnOrder`, `calledPocket == nil`, `railsAfterContact == 0`, `cueResult == .notApplicable`,
  `wpaDelta == 0`, `isClutch == false`, `timeOnShot == -1`, `clipRef == nil`, `executionRating` `.made`/`.miss` from `made`,
  `onTarget == made`, empty `winProbSeries`.
- `featuresComeFromPositionsWhenTheCueIsInPre`; `neutralFeaturesWhenNoCueInPre`.
- `guessedAndGapShotsAreNotSaved`.
- `midRackEndSavesNothing` (D40).
- `joinerNeverWrites`; `hostWithoutMajorityNeverWrites` (fake link from plan 009).
- `endingTwiceWritesOnce` (same `Game.id`: update, not a second row).
- `trainingNeverWritesACompetitiveGame` (design §5): training `LiveSession`, settle a shot, `liveClosed`, `endGame`;
  `Game` and `Shot` counts in `competitiveContext` stay 0.
**Verify**: they FAIL.

### Step 3: Implement
- `GameSessionModel.finishedGame()` builds a `FinishedGame` from the folded shots, or nil when there's no winner.
  Shooter ids are `ShellPlayer.id` (guests included as plain ids, design §6).
- `StackGameRecorder(stack:)` inserts `Session` + `Game` + `Shot`s into `competitiveContext` only, upserting by id, and saves once.
- `AppRouter.endGame()`: before `mesh?.stop()`, if `mesh == nil || (mesh.isHost && majority && commitSeq covers the rack)`,
  call `recorder?.record(game.finishedGame())`. A thrown error is logged with `os.Logger` and never blocks review.
**Verify**: targeted → passes; full unit → passes; `AppShellUITests` → passes.

## Done criteria
- [ ] New tests pass; full unit and `AppShellUITests` pass
- [ ] `grep -rn "trainingContext" CueCoach/Persistence/GameRecorder.swift` → nothing
- [ ] `git diff --name-only` ⊆ the in-scope list plus `plans/README.md`

## STOP conditions
- Plan 007 isn't merged, so `endGame` can still run with an open shot in the FIFO (D37 not guaranteed).
- `Shot.init` or `Game.init` would need a new column for any field above (that is a migration; ask).
- A team has more than four players or teams differ in size so `GameFormat` can't be chosen. Report, don't guess.
- Upserting by `@Attribute(.unique) id` doesn't update in place on the simulator.

## Maintenance notes
- Kill after the winning shot but before ✕: nothing is saved, because the recorder runs in `endGame` (design §4).
  Saving on the winning commit instead is a product question; ask before changing it.
- `features` written as `neutral` must be skipped by whoever builds the `Shot → CompetitiveShot` projection (design §3).
  Mark it in that plan; there is no column that says so.
- Plan 012 lets guessed shots be saved. Plan 013 forbids writes while partitioned.

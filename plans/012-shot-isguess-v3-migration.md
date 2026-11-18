# Plan 012: Saved shots remember a D31 best guess (Competitive schema V3)

> **Executor instructions**: Follow this plan step by step. Run every verification and confirm the expected result
> before the next step. Honor the STOP conditions; do not improvise. When done, update this plan's row in `plans/README.md`.
>
> **Approved 2026-11-10 as D43** (user). Still: start only after plan 011 merges.
> (Original note:) This is a SwiftData schema migration on the user's competitive store. Do not start until the user has
> approved it in writing (a new D-number in `docs/DECISIONS.md`). Do not fold any part of it into plan 011.
>
> **Drift check (run first)**: `git diff --stat 5cd3fcf..HEAD -- CueCoach/Persistence CueCoach/Screens/Review/ReviewData.swift CueCoach/App/GameSessionModel.swift docs/SCHEMA.md docs/INTERFACES.md CueCoachTests/Persistence CueCoachTests/Screens`
> Plans 002, 008, 009 and 011 touch `GameSessionModel.swift` and add `CueCoach/Persistence/GameRecorder.swift`.
> Re-read them after they merge. A changed `Shot` shape or a schema version other than V2 is a STOP condition.

## Status
- **Priority**: P2 · **Effort**: M · **Risk**: HIGH (user data migration) · **Depends on**: plan 011 merged; user approval · **Category**: migration
- **Planned at**: commit `5cd3fcf`, 2026-11-10. Design: `docs/research/game-log-and-saving.md` "Migration stop", follow-up 4.

## Why this matters
A D31 lost shot closes with a best-guess result. Plan 011 can't store that honestly: `Shot` has no guess flag, so
a guessed pot would count as a real make in pot % and archetypes. Plan 011 therefore drops guessed shots from the
save, and a saved game's review has holes where those shots were. A `Shot.isGuess` column lets them be saved,
shown dashed in review (as live review already does), and kept out of stats.

## Current state (verified at `5cd3fcf`)
- `CueCoach/Persistence/SchemaVersions.swift:8-14`: `CompetitiveSchemaV1` lists the shared top-level models and keeps
  a **frozen nested copy** only of a model whose shape changed (`CompetitiveSchemaV1.PlayerProfile`, `:16-…`).
- `:69-73`: `CompetitiveSchemaV2` (version 2.0.0) lists the live top-level `Shot`.
- `:88-118`: `CompetitiveMigrationPlan { schemas: [V1, V2]; stages: [v1ToV2] }` (a custom stage).
- `CueCoach/Persistence/PersistenceStack.swift:11`: `competitiveModels = CompetitiveSchemaV2.models`.
- `CueCoach/Persistence/CompetitiveModels.swift:158-272`: `@Model final class Shot` with private stored values and
  public accessors; `init` at `:241-246` has no guess parameter.
- `CueCoach/Persistence/Backup/BackupV1.swift:6-12, 85-97`: backup JSON version 1 has a `Shot` record without
  `isGuess`; `:217-218` rejects any other version. `PersistenceStack+Backup.swift:47, 260-273` maps shots both ways.
- `CueCoach/Screens/Review/ReviewData.swift:119-129`: `GameReviewData.init(game:…)` never sets `ReviewShot.isGuess`.
  Live review already draws a guess dashed (`ReplayDiagram.swift:112`) and labels it (`GameReviewModel.swift:242`).
- `docs/SCHEMA.md:27`: the `Shot` row.
- Migration test precedent: `CueCoachTests/Persistence/RecognitionStoreTests.swift:98-…` builds a V1 store on disk and opens it.

## Commands you will need
| Purpose | Command | Expected |
|---|---|---|
| Unit (targeted) | `xcodebuild test -project CueCoach.xcodeproj -scheme CueCoach -destination 'platform=iOS Simulator,name=CueCoach iPhone 15 Pro' -only-testing:CueCoachTests/CompetitiveStoreTests -only-testing:CueCoachTests/RecognitionStoreTests -only-testing:CueCoachTests/BackupTests -only-testing:CueCoachTests/GameRecorderTests` | `** TEST SUCCEEDED **` |
| Full unit | same with `-only-testing:CueCoachTests` | `** TEST SUCCEEDED **` |
| Core | `cd Packages/CueCore && swift test` | all pass |

## Scope
**In scope:** `SchemaVersions.swift` (frozen `CompetitiveSchemaV2.Shot`, new `CompetitiveSchemaV3`, a lightweight
V2→V3 stage); `CompetitiveModels.swift` (`Shot.isGuess`, default false); `PersistenceStack.swift` (V3 models);
`GameRecorder.swift` (stop skipping guesses); `ReviewData.swift` (read the flag); backup mapping (see step 4);
`docs/SCHEMA.md`, `docs/INTERFACES.md`; tests in `CueCoachTests/Persistence` and `CueCoachTests/Screens`.

**Out of scope:** the stats projection (it doesn't exist in the app yet; record the rule for it), gap shots
(`rating == nil` stay unsaved), any other column, Training or Recognition stores.

## Steps
### Step 1: Contract
`docs/SCHEMA.md`: add `isGuess: Bool` (V3, default false; "pocketed is a D31 best guess; never counted in pot %").
`docs/INTERFACES.md`: `RecordedShot.isGuess`, and drop "isGuess shots omitted until V3".
**Verify**: `grep -n "isGuess" docs/SCHEMA.md` → 1+ match.

### Step 2: Red tests
- `v2StoreOpensAsV3WithEveryShotNotAGuess`: write a V2 store on disk with two games, reopen with the V3 stack, all rows
  present, `isGuess == false`, other columns equal.
- `v3RoundTripsIsGuess`.
- `recorderSavesAGuessedShotFlagged` (replaces plan 011's `guessedAndGapShotsAreNotSaved` for guesses only).
- `savedReviewShowsAGuessDashed` (`ReviewShot.isGuess` from the row).
- `backupRoundTripKeepsIsGuess`; `oldBackupWithoutIsGuessStillImports`.
**Verify**: they FAIL.

### Step 3: Schema
Freeze today's `Shot` as `CompetitiveSchemaV2.Shot` (same pattern as `CompetitiveSchemaV1.PlayerProfile`); V2 lists
it; V3 (3.0.0) lists the live `Shot`. Add `isGuess` with a default so a **lightweight** stage is enough. Point
`PersistenceStack.competitiveModels` at V3. **Verify**: migration tests pass.

### Step 4: Recorder, review, backup
Recorder writes guessed shots with `isGuess = true`. `GameReviewData.init(game:)` sets `isGuess`. Backup: add
`isGuess` to the shot record as an optional field decoded with `decodeIfPresent` (missing → false) and keep
`version: 1`. If the head prefers a version 2 backup instead, STOP and ask.
**Verify**: targeted → passes; full unit → passes; core → passes.

## Done criteria
- [ ] All new tests pass; full unit and core suites pass
- [ ] A V2 store made at `5cd3fcf`'s schema opens without data loss (the migration test)
- [ ] `git diff --name-only` ⊆ the in-scope list plus `plans/README.md`

## STOP conditions
- No written user approval for the migration.
- SwiftData demands a custom stage (lightweight refuses the added column) or the frozen V2 copy changes V2's hash.
- The `Shot` relationship to `Game` can't be frozen without also freezing `Game` (then the change is bigger; report).
- Backup compatibility needs a version bump.

## Maintenance notes
- Whoever builds the `Shot → CompetitiveShot` projection must skip `isGuess` shots for pot %, cut, distance and
  pocket buckets.
- Every later `Shot` change needs its own frozen copy and stage. Keep the stages in order.

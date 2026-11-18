# Plan 015: Fix a recorded shot's shooter from Game Review (D49)

> Executor: read every step before starting. Follow TDD (red → green). Honor the STOP conditions; do not improvise.
> When done, update this plan's row in `plans/README.md`. Read `docs/AGENTS.md` › "Build hygiene" first: one
> `xcodebuild` owner at a time, `-parallel-testing-enabled NO`, the shared `-derivedDataPath` the head gives you.

## Status
- **Planned at**: commit `cfe0a90`, 2026-11-11. Depends on **009** (fold + `.shooterCorrection` replay) and
  **011** (saved games upsert by id). Code excerpts below are from `cfe0a90`; re-check them after 009/011 merge.

## Why this matters
D41: a turn-disc tap only says who shoots next; it never edits a recorded shot. D38 gaps and wrong attributions then
stay wrong forever. **D49 (user, 2026-11-11):** long-press a shot on the Game Review timeline → pick its shooter.
Never during aiming (the no-text-while-aiming rule holds: Review is post-game). The game replays from that shot.

## Current state (verified at `cfe0a90`)
- `CueCoach/Screens/Review/GameReviewView.swift:228-250` `timeline`: one `Button { model.select(s.id) }` per
  `model.shots` (`RatingBadgeCircle` + `TeamArc`), `.buttonStyle(.plain)`, `.accessibilityLabel(model.accessibilityLabel(s))`.
- `CueCoach/Screens/Review/GameReviewModel.swift`: `init(data:)` and `init(source:)`; `private(set) var data`;
  `private func apply(_:)`; hooks are `@ObservationIgnored var onDone`, `onPlayClip`. Copy that hook style.
- `CueCoach/App/AppRouter.swift:114` `stage = .review(game.reviewData())`; `AppShellRoot.swift:113` builds
  `GameReviewModel(data:)` from it.
- After plan 009: `GameEvent.shooterCorrection(shotID: UUID, team: Int)` exists and the fold replays the rotation
  (`shooterCorrectionMovesThatShotAndReplaysTheRotation`). It carries a **team**, not a player.

## Design
1. `GameReviewModel` gets `@ObservationIgnored var onCorrectShooter: ((UUID, ReviewPlayer) -> GameReviewData?)?`
   and `func correctShooter(_ shotID: UUID, to player: ReviewPlayer)`: calls the hook; a non-nil result goes through
   `apply(_:)` and keeps the selection on that shot. No hook (debug/sample screens) → the menu is not shown.
2. Timeline: `.contextMenu` on each shot button (system long-press) listing every player (`Label(name, systemImage:
   "person")`, the current shooter checked). This is the only text added, and it is post-game.
3. `AppRouter` wires the hook: `game.correctShooter(shotID:player:)` → appends `.shooterCorrection` (solo: local log;
   mesh host: `append`; joiner: hook is nil, D39) → re-fold → if the rack is saved, `recorder.record(finishedGame())`
   upserts by id (011) → returns `game.reviewData()`.
4. Team games: the event carries a team. If the picked player is on the same team as the recorded shooter, only the
   `SessionShot.shooter` changes (add `shooter: String?` to `.shooterCorrection`, `decodeIfPresent`, inside protocol
   major 2 — legal only while major 2 is unreleased).

## Scope
**In:** `GameReviewModel.swift`, `GameReviewView.swift` (context menu only), `GameSessionModel.swift`
(`correctShooter`), `MeshMessage.swift` (optional `shooter` key), `AppRouter.swift`/`AppShellRoot.swift` (wiring),
`docs/INTERFACES.md`, tests in `CueCoachTests/Screens`, `CueCoachTests/App`, `CueCoachTests/Mesh`, one UI test.
**Out:** editing outcome/pocketed/fouls, editing during Live, joiner-side editing, stats projection.

## Steps
1. **Contract:** add `correctShooter` + the hook + the optional `shooter` key to `docs/INTERFACES.md`.
   Verify: `grep -n "correctShooter" docs/INTERFACES.md`.
2. **Red:** `GameReviewModelTests`: `correctingAShooterAppliesTheNewDataAndKeepsSelection`, `noHookNoMenu`
   (`canCorrect == false`). `GameSessionModelTests`: `correctShooterAppendsACorrectionAndReplays`,
   `correctingAGapClearsNothingElse` (D38 gap keeps `rating == nil`), `joinerCannotCorrect`.
   `MeshCodecTests`: `shooterCorrectionWithoutShooterDecodes`. `GameRecorderTests` (011): `correctionAfterSaveUpdatesTheSavedShot`.
   Verify: targeted run fails.
3. **Green:** implement design 1–4. Verify: targeted passes; full `CueCoachTests` passes.
4. **UI:** `AppShellUITests.testLongPressFixesShooter`: finish a scripted game, long-press a shot, pick the other
   player, the timeline arc changes team. Verify: `AppShellUITests` passes; `ScreensBUITests` passes (sample screens show no menu).

## Done criteria
- [ ] New tests pass; full `CueCoachTests`, `AppShellUITests`, `ScreensBUITests` pass
- [ ] `grep -rn "contextMenu" CueCoach/Live` → nothing (no editing while aiming)
- [ ] `git diff --name-only` ⊆ in-scope list + `plans/README.md`

## STOP conditions
- 009 or 011 not merged, or `.shooterCorrection` doesn't replay the rotation.
- The correction changes the winner of a saved rack (stats would flip): report, don't decide.
- Protocol major 2 has shipped to a device build already (the optional key would then need a minor-version rule).

## Maintenance notes
- Plan 013 (island merge) shares the replay-from-a-shot path; keep one replay function.

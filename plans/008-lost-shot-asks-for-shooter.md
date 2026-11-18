# Plan 008: A lost shot with no guess pulses the turn discs and leaves a gap in review (D38)

> **Executor instructions**: Follow this plan step by step. Run every verification and confirm the expected result
> before the next step. Honor the STOP conditions; do not improvise. When done, update this plan's row in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat daf120a..HEAD -- CueCoach/Live/LiveModel.swift CueCoach/Live/LiveLogic.swift CueCoach/App/AppRouter.swift CueCoach/App/GameSessionModel.swift CueCoach/App/InGameChrome.swift CueCoachTests/App`
> Plans 001, 002 and 007 touch these files. Re-read them and compare with the excerpts below; a real mismatch is a STOP condition.

## Status
- **Priority**: P1 · **Effort**: M · **Risk**: MED · **Depends on**: plans 001, 002, 007 merged · **Category**: bug
- **Planned at**: commit `daf120a`, 2026-11-10

## Why this matters
When tracking loses a shot and has no best guess (decision D31), Live closes it "unrated" through `hooks.ballsSettled()`.
In a game, the shell then records nothing and keeps the same shooter. If the shooter actually missed, every later shot
is credited to the wrong player and team, and rated against the wrong legal targets, until someone notices.
**Decision D38 (user):** after a lost shot with no guess, the turn discs pulse until someone taps the shooter (one tap),
and the review shows the shot as an unknown gap. **D41:** a disc tap changes only who shoots next, never a recorded shot.

## Current state
- `CueCoach/Live/LiveModel.swift:~205-212`, in `drain()`, the `.lost` case:
  ```swift
  if let (rec, ids) = head.guess?.record() {
      onCloseForTesting?(head.id, rec, true)
      shotSettled(rec, ids: ids, guessed: true)
  } else {
      onCloseForTesting?(head.id, nil, false)
      shotSettledNoAim = true
      hooks.ballsSettled()
  }
  ```
- `CueCoach/Live/LiveLogic.swift:~471-485`: `struct LiveHooks`, which has `settledShot`, `ballsSettled` and others. Defaults do nothing.
- `CueCoach/App/AppRouter.swift:46`: `func ballsSettled() { isAiming = false }`.
- `CueCoach/App/AppRouter.swift:51-54`: `handTurn(toTeam:)` is ignored while aiming. `GameSessionModel.handTurn` (`GameSessionModel.swift:102-107`) passes the turn only if `team != shootingTeam`.
- `CueCoach/App/GameSessionModel.swift:7-17`: `SessionShot.rating` is a non-optional `DecisionRating`. `ReviewShot.rating` is already optional ("nil = unrated").
- `CueCoach/App/InGameChrome.swift:~145-175`: `TurnDiscs`. The active disc is lit, the waiting one dimmed, and tapping the dim one calls `handTurn`. Animation is gated by `reduceMotion`.
- UI: Astryx (D34). Load the `astryx` skill for any new motion or colour token. CLAUDE.md: no text while aiming; feedback is glows and colour. The pulse is a glow or scale on **both** discs, with no text. With Reduce Motion on, use a steady highlight ring instead of a pulse.

## Behaviour to build
1. Live, game mode, lost shot with no guess: call a new hook `shotLost()`, not `ballsSettled()`. Training keeps calling `ballsSettled()`.
2. The shell's `GameSessionModel.shotLost()`:
   - Appends a gap `SessionShot` with `rating == nil` (make `rating` optional), the current shooter and team, and no pocketed balls or fouls.
   - Sets `needsShooter = true`.
   - Clears aiming (like `ballsSettled`).
3. While `needsShooter`:
   - Both discs pulse.
   - Tapping **either** disc sets that team as shooting (D41: only the next shooter changes; the gap shot keeps its recorded shooter) and clears `needsShooter`. Tapping the already-active team's disc confirms "same team" and clears it. Today that tap is a no-op, so add the case.
   - Legal targets are pushed for the chosen team, as `handTurn` does.
4. A new shot that starts while `needsShooter` is set (nobody tapped) clears it and keeps the current shooter. Don't block play.
5. Review: `reviewData()` maps a gap shot to a `ReviewShot` with `rating: nil`. The timeline already draws nil as the dashed unrated style.

## Commands you will need
| Purpose | Command | Expected |
|---|---|---|
| Unit | `xcodebuild test -project CueCoach.xcodeproj -scheme CueCoach -destination 'platform=iOS Simulator,name=CueCoach iPhone 15 Pro' -only-testing:CueCoachTests/LiveAdapterTests -only-testing:CueCoachTests/GameSessionModelTests` | `** TEST SUCCEEDED **` |
| Full unit | `-only-testing:CueCoachTests` | `** TEST SUCCEEDED **` |
| UI | `-only-testing:CueCoachUITests/AppShellUITests` | `** TEST SUCCEEDED **` |

## Scope
**In scope:**
- `LiveLogic.swift` (`LiveHooks.shotLost`)
- `LiveModel.swift` (the `.lost` no-guess branch only)
- `AppRouter.swift` / `InGameChrome.swift` (hook wiring and the disc pulse)
- `GameSessionModel.swift` (`SessionShot.rating` optional, `shotLost`, `needsShooter`, the same-team confirm)
- `docs/INTERFACES.md` (the settled-shot contract: add `shotLost`)
- tests in `CueCoachTests/App/`

**Out of scope:**
- mesh propagation (plan 006 follow-ups)
- saving
- MVP and stats (gap shots have no rating, so plan 001's rules already skip them; verify, don't change)

## Steps
1. Contract: add `shotLost` to the `LiveHooks` block in `docs/INTERFACES.md`, plus one line on the gap shot and `needsShooter`.
2. Red tests (in `LiveAdapterTests` / `GameSessionModelTests`):
   - `aLostShotWithNoGuessRecordsAGapAndAsksForTheShooter`
   - `tappingTheOtherDiscAfterALostShotHandsTheTurnAndKeepsTheGap`
   - `tappingTheActiveDiscConfirmsTheSameShooter`
   - `aNewShotClearsTheAsk`
   - `trainingLostShotStillJustSettles`
   - `gapShotsNeverBecomeMVP`
   **Verify**: they FAIL.
3. Implement 1–5 above. **Verify**: unit → passes; the full suite passes (the `SessionShot.rating` optional change may need small fixes in existing tests. Fix them minimally and list them in the commit body).
4. UI: the disc pulse with a Reduce-Motion fallback. Add a UI assertion if there's a hook for lost shots in the replay; otherwise give a unit-level view-model check and say so. **Verify**: the UI command → passes.

## Done criteria
- [ ] The new tests pass; the full unit suite and `AppShellUITests` pass
- [ ] `grep -n "shotLost" docs/INTERFACES.md` → at least 1 match
- [ ] `git diff --name-only` ⊆ the in-scope list plus `plans/README.md`

## STOP conditions
- Making `SessionShot.rating` optional ripples into more than ~5 files outside scope. Report the list.
- The replay simulator can't produce a lost shot, and there's no unit seam to test the disc state. Report it rather than skipping the test.
- Anything would need text on screen while aiming.

## Maintenance notes
- Plan 006 follow-up 1 (fold the shot log) must carry the gap shot and the "next shooter" choice as log events. D41 needs a "next shooter" event, separate from `.shooterCorrection`.

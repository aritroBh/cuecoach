# Plan 007: ✕ in a game asks "End game?", and an open shot settles before review (D37)

> **Executor instructions**: Follow this plan step by step. Run every verification and confirm the expected result
> before the next step. Honor the STOP conditions; do not improvise. When done, update this plan's row in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat daf120a..HEAD -- CueCoach/Live/LiveScreen.swift CueCoach/Live/LiveModel.swift CueCoach/App/AppRouter.swift CueCoach/App/AppShellRoot.swift CueCoachTests/App CueCoachUITests`
> Plans 001 and 002 touch `LiveModel.swift`/`GameSessionModel.swift`. If they merged after `daf120a`, re-read those files and compare them with the excerpts below. A real mismatch is a STOP condition.

## Status
- **Priority**: P1 · **Effort**: M · **Risk**: MED · **Depends on**: plans 001, 002 merged · **Category**: bug
- **Planned at**: commit `daf120a`, 2026-11-10

## Why this matters
In a game, the Live screen's ✕ ends the game at once. The shot pipeline keeps a FIFO of shots that haven't closed
yet: a pocket question waiting for a tap, the D31 lost-shot look, or waiting for a quiet table. The FIFO only drains
from the frame loop, and the loop is cancelled when the view disappears. So a shot that's still settling is silently
dropped, even the game-winning ball. The review then shows an unfinished, locked game. **Decision D37 (user):** ✕
during a game asks "End game?" first. On confirm, an open shot finishes settling before review opens.

## Current state
- `CueCoach/Live/LiveScreen.swift:66`: `CircleButton(symbol: "xmark", id: "live.close") { if let onClose { onClose() } else { dismiss() } }`. It's shown in every state, including while aiming.
- `CueCoach/Live/LiveScreen.swift:~420`: `.onDisappear { loop?.cancel() }`, which stops the frame loop that drives `drain()`.
- `CueCoach/App/AppShellRoot.swift:53-56`: the Live cover's `onDismiss` calls `router.liveClosed()`.
- `CueCoach/App/AppRouter.swift:104-116`: `endGame()` turns `game.reviewData()` into the review stage. `liveClosed()` calls `endGame()` for a game and clears the stage for Training.
- `CueCoach/Live/LiveModel.swift`:
  - `:100-105`: `private var shots: [ShotEntry]` (the FIFO).
  - `:~198-232`: `drain()` closes entries from the front only while the table is `quiet`. A `.decided` entry with an `openAsk` sets `pocketConfirm` (the one-tap ✓/✗ question) and returns. A `.lost` entry closes as a guess or as unrated.
  - `answerPocket(dropped:)`: the one-tap answer.
- Training mode: ✕ must keep working instantly. D37 covers games only. In Training, `LiveSession.game == nil` (`AppRouter.swift:99-103`).
- UI: Astryx design system (decision D34). Load the `astryx` skill and use its dialog or confirmation pattern. If it has none, use SwiftUI's `.confirmationDialog`. There's an existing `.alert` precedent at `CueCoach/Screens/Settings/SettingsView.swift:48`. Copy, kept short (≤2 words where possible):
  - title: "End game?"
  - actions: "End game" (destructive) and "Keep playing" (cancel)
- Tests:
  - Swift Testing unit tests in `CueCoachTests/App/LiveAdapterTests.swift`. The pattern is a `GameSessionModel` + `LiveSession` + `LiveModel` with `LiveScreenAdapter.hooks(for:)`.
  - XCUITest in `CueCoachUITests/AppShell/` (see the existing AppShell tests for how a game is started in the replay simulator).

## Commands you will need
| Purpose | Command | Expected |
|---|---|---|
| Unit | `xcodebuild test -project CueCoach.xcodeproj -scheme CueCoach -destination 'platform=iOS Simulator,name=CueCoach iPhone 15 Pro' -only-testing:CueCoachTests/LiveAdapterTests -only-testing:CueCoachTests/AppRouterTests` | `** TEST SUCCEEDED **` |
| UI | same with `-only-testing:CueCoachUITests/AppShellUITests` | `** TEST SUCCEEDED **` |
| Full unit | `-only-testing:CueCoachTests` | `** TEST SUCCEEDED **` |

## Scope
**In scope:**
- `LiveScreen.swift` (✕ and the dialog)
- `LiveModel.swift`: a read-only `hasOpenShot: Bool` and a `finishing` mode
- `AppRouter.swift` / `AppShellRoot.swift`: only if the end-of-game hand-off needs it
- `LiveAdapterTests.swift`, `AppRouterTests.swift`, one AppShell UI test

**Out of scope:**
- Training ✕ behaviour
- the menu's "End game" action: make it share the same confirm-then-settle path only if that's a one-line reuse; otherwise leave it
- mesh
- saving games

## Steps
### Step 1: Red unit tests
1. `closingAGameWithAnOpenShotWaitsForItToSettle`: put a shot in the FIFO (follow how existing tests drive `LiveModel` frames, or use `onCloseForTesting`). Request close (the new `LiveModel.requestEnd()` or equivalent). The shot then closes when the table goes quiet, its `SettledShot` reaches the shell, and only then does the end signal fire.
2. `closingWithNoOpenShotEndsAtOnce`.
3. `trainingCloseNeverAsks`.

**Verify**: unit → the new tests FAIL.

### Step 2: Model
- Add `var hasOpenShot: Bool { !shots.isEmpty }`.
- Add `requestEnd(_ done: @escaping @MainActor () -> Void)`:
  - If there is no open shot, call `done` now.
  - Otherwise set `isFinishing = true` and call `done` the moment `drain()` empties the FIFO.
- While finishing, the frame loop keeps running and the pocket question stays answerable. Shots don't get a time cap here: a lost entry already closes through its own D31 rules.

**Verify**: unit → passes.

### Step 3: View
- In a game, ✕ shows the dialog.
- On "End game", call `model.requestEnd { onClose/dismiss }`. While `isFinishing`, hide ✕ and show nothing new apart from the existing pocket question, if any.
- In Training, ✕ dismisses immediately, as today.

**Verify**: full unit → passes.

### Step 4: UI test
Add `testCloseAsksBeforeEndingAGame`: start a game in the replay, tap `live.close`, expect the dialog. "Keep playing" stays in Live; "End game" reaches the review.

**Verify**: the UI command → passes.

## Done criteria
- [ ] The new unit and UI tests pass; the full `CueCoachTests` and `AppShellUITests` pass
- [ ] Training ✕ unchanged (an existing training test still passes)
- [ ] `git diff --name-only` ⊆ the in-scope list plus `plans/README.md`

## STOP conditions
- The FIFO can stay non-empty forever, for example a `.looking` entry on a frozen camera with no frames. Report it with the case; don't add a timeout on your own. A timeout is a product choice.
- Astryx has no dialog, and `.confirmationDialog` clashes with the Live overlay's layering (it doesn't appear in the UI test).
- The menu's "End game" path diverges in a way that needs a refactor.

## Maintenance notes
- Plan 006's recorder (D40: save only finished racks) must run after `requestEnd`'s completion, never on raw `liveClosed`.
- A reviewer should check that ✕ can't double-fire `endGame`, for example on a second tap while finishing.

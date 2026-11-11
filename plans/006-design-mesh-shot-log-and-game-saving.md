# Plan 006 (design spike): One authoritative shot log per game, then save finished games

> **Executor instructions**: This is a **design plan**. The deliverable is a design document and contract stubs,
> not a working feature. Write `docs/research/game-log-and-saving.md`, propose the `docs/INTERFACES.md`
> changes, and list the product questions. Do not change app behaviour. Honor the STOP conditions and update
> this plan's row in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat b21f994..HEAD -- CueCoach/Mesh CueCoach/App CueCoach/Persistence docs/research/mesh-identity.md docs/INTERFACES.md`

## Status
- **Priority**: P1 (product gap) · **Effort**: L overall; this spike is M · **Risk**: HIGH (implementation) / LOW (spike)
- **Depends on**: plans 001 and 002 (live review data shape) · **Category**: direction
- **Planned at**: commit `b21f994`, 2026-11-10

## Why this matters
Two gaps, found by reading the code at `b21f994`:
1. **Finished games are never saved.**
   - `AppRouter.endGame()` builds review data in memory, and `finishReview()` drops it (`CueCoach/App/AppRouter.swift:104-126`).
   - The SwiftData models `Game`, `Shot` and `Session` exist (`CueCoach/Persistence/CompetitiveModels.swift:109,159`), but nothing in the app creates them outside backup import.
   - So profiles, stats, archetypes and pro comparisons never get data from real play.
2. **On two phones, each phone runs its own game.**
   - The mesh link only applies roster changes (`CueCoach/App/MeshGameLink.swift:29-36`). Its comment says Live will consume the session "once it is wired".
   - The replicated log already exists: `GameEvent.shot(MeshShotRecord)` and `.shooterCorrection` (`CueCoach/Mesh/MeshMessage.swift:93-97`), with `LogEntry{seq, term}` and acks. But nothing outside `CueCoach/Mesh/` sends or reads them.
   - Each phone's `GameSessionModel` rates, rotates turns and records shots locally, so the two reviews can disagree.

   Gap 1 can't ship before gap 2 is designed: if each phone saved its own game, every mesh game would be saved twice, with different contents.

## Current state (inline facts)
- Research spec: `docs/research/mesh-identity.md` §2.5 says "GameState = fold(log) on any phone". There is a host election and migration design (Phase 5, merged).
- Decisions:
  - D3: the best-angle clip goes to the host over MPC after the balls settle, never while anyone is aiming.
  - D17: team rotation (whole turn per player, teams alternate, set order).
  - D31: a lost shot is a best guess, flagged.
  - "Training stats never touch competitive stats (separate SwiftData store)." This is a non-negotiable.
- `GameSessionModel` (`CueCoach/App/GameSessionModel.swift`) holds `shots: [SessionShot]`, the rotation cursors (`currentSlot`) and `rulesState`. `handTurn` is the one-tap shooter correction.
- `Shot` (SwiftData) needs:
  - `shooterID`, `attributionSource`
  - `preState` and `postState` (encoded `TableState`)
  - `calledPocket`, `firstContactNumber`, `railsAfterContact`
  - `pocketed`, `fouls`, `features`
  - `made`, `onTarget`, decision/execution ratings, `wpaDelta`

  Live produces only some of these today. After plan 002 it has rating, pocketed, fouls, guess flag and before/after positions.
- `PersistenceGameReviewSource` already reads a saved `Game` into review (`ReviewData.swift:107-135`).

## Questions the design must answer
1. **Who rates a shot in a mesh game?** Options:
   - (a) only the host, and joiners apply `.shot` entries from the log;
   - (b) every phone rates, and the host's log entry wins on conflict;
   - (c) the phone with the best view proposes, and the host commits.

   Recommend one, with failure cases (host leaves mid-shot, split-brain, a late joiner).
2. **How do corrections travel?** `handTurn` becomes a `.shooterCorrection` proposal to the host, and every phone folds the log.
3. **Which fields must a saved `Shot` have now, and which can be optional or derived later?** Map each `Shot` field to its source (Live, Rules, Engine, or "not available, so store a default"). Flag any field whose absence would corrupt stats, e.g. `features` feeding archetypes.
4. **Who writes, and when?** Single writer = host (or the solo phone). Write at rack end, or append per shot? Cover crash and kill mid-game: is a partial game saved, discarded, or resumable?
5. **Training isolation.** Show that the writer is reachable only from `GameSessionModel`, never from training `LiveSession`. Name the test that proves it.
6. **Privacy.** Saved data is ball positions and ratings only, with no frames or embeddings. Recognition data stays in its own store (existing rule). Confirm that one-tap delete covers saved games, or that it doesn't need to.

## Product questions to put to the user (do not decide)
- In a mesh game, should a joiner's phone show its own post-shot badge immediately, or wait for the host's rating?
- When the app is closed mid-game, should the game be saved as unfinished, discarded, or offered for resume?
- Related open items (from the 2026-11-10 audit):
  - Should ✕ in a game ask before ending it? Today a shot still settling, even the game-winning ball, is dropped silently (`LiveScreen.swift:66` → `AppRouter.liveClosed()` → `endGame()`).
  - After a lost-tracking shot with no guess, should the turn pass, stay, or should the app ask? Today it stays, so later shots are credited to the wrong player until someone corrects it (`AppRouter.swift:46`, `GameSessionModel.swift:139`).

## Deliverables
1. `docs/research/game-log-and-saving.md`: the answers to questions 1–6, a sequence diagram (text) for one shot on two phones, and failure cases.
2. Proposed `docs/INTERFACES.md` diff (contracts first), for example:
   - `protocol GameRecorder { func record(_ game: FinishedGame) throws }`
   - the `GameSessionModel` ↔ `MeshGameLink` event flow

   Mark it "proposed" until the user approves.
3. A list of follow-up implementation plans (worker-sized, each TDD), in dependency order.

## Commands you will need
None that build. Read-only exploration: `grep`, and reading `CueCoach/Mesh/*`, `CueCoach/App/*`, `CueCoach/Persistence/*`, `docs/research/mesh-identity.md`.

## Scope
**In scope:** `docs/research/game-log-and-saving.md` (create); `docs/INTERFACES.md` (a "Proposed" section only).

**Out of scope:** any Swift source change.

## Done criteria
- [ ] The design doc answers questions 1–6 with code references
- [ ] The product questions are listed verbatim for the user, with a recommended answer each
- [ ] The INTERFACES diff is marked "Proposed"
- [ ] `git diff --name-only phase/1-core` contains only the two docs plus `plans/README.md`

## STOP conditions
- `docs/research/mesh-identity.md` already decides question 1 differently from the recommendation. Follow the doc and note the conflict.
- Saving requires a SwiftData schema change to `Shot` or `Game`. Note the migration need and stop at design; don't write a migration.

## Maintenance notes
- This gap isn't in `docs/CHECKLIST.md` yet. Add "Game saving + mesh shot log (design: plans/006)" as an open item when this plan starts.

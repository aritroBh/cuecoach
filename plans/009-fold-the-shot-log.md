# Plan 009: Every phone folds one shot log into the game (D39, D41, D38 gap)

> **Executor instructions**: Follow this plan step by step. Run every verification and confirm the expected result
> before the next step. Honor the STOP conditions; do not improvise. When done, update this plan's row in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 5cd3fcf..HEAD -- CueCoach/App/GameSessionModel.swift CueCoach/App/AppRouter.swift CueCoach/App/InGameChrome.swift CueCoach/App/MeshGameLink.swift CueCoach/Live/LiveLogic.swift CueCoach/Live/LiveModel.swift CueCoach/Mesh/MeshMessage.swift CueCoach/Mesh/MeshTypes.swift docs/INTERFACES.md CueCoachTests/App CueCoachTests/Mesh`
> Plans 002, 007 and 008 change `GameSessionModel.swift`, `LiveModel.swift`, `LiveLogic.swift` and `AppRouter.swift`.
> After they merge, re-read those files and compare them with the excerpts below. Line numbers will have moved; a
> changed **shape** (not just a moved line) is a STOP condition.

## Status
- **Priority**: P1 · **Effort**: L · **Risk**: HIGH · **Depends on**: plans 002 and 008 merged (007 recommended) · **Category**: feature
- **Planned at**: commit `5cd3fcf`, 2026-11-10. Design: `docs/research/game-log-and-saving.md` (plan 006), follow-up 1.

## Why this matters
Today each phone rates and records its own shots. Nothing about a shot goes on the mesh, so two phones in one game
can show different shooters, badges and reviews. **D39:** the host rates every shot and a joiner shows the badge only
after the host's committed rating. **D41:** a turn-disc tap changes only who shoots next. **D38:** a lost shot with no
guess is a gap in review. This plan makes one replicated log the source of truth: the host (or the solo phone) appends,
and every phone builds `shots`, the badge, the turn and the rules state by folding the committed prefix. No SwiftData.

## Current state (verified at `5cd3fcf`)
- `CueCoach/Mesh/MeshMessage.swift:86-91`: `MeshShotRecord { shotID, shooterTeam, outcome: ShotOutcome, postState: TableState? }`.
- `CueCoach/Mesh/MeshMessage.swift:94-98`: `enum GameEvent { case ruleSetChosen(RuleSetID); case shot(MeshShotRecord); case shooterCorrection(shotID: UUID, team: Int) }`. Synthesized `Codable`, so an older build fails to decode a whole `logEntries` batch that holds an unknown case.
- `CueCoach/Mesh/MeshTypes.swift:29-30`: `ProtocolVersion.current = (major: 1, minor: 0)`, `supportedMajors = [1]`. The frame header carries the major (`CueCoachTests/Mesh/MeshCodecTests.swift:79-85`, `incompatibleMajor`), and `MeshNode.onHello` rejects a peer with no common major (`MeshNode.swift:603-605`).
- `CueCoach/App/MeshGameLink.swift:7-13`: `protocol GameMeshLink { peerCount; isStopped; start(); stop() }`. No log access.
- `CueCoach/App/GameSessionModel.swift`:
  - `:7-17` `SessionShot { id, index, shooter, team, rating, pocketed, fouls, isGuess }` (002 adds `before`/`after`; 008 makes `rating` optional).
  - `:64` `rulesAdvanced(_:)` stores Live's next state; bound at `InGameChrome.swift:19` (`h.gameAdvanced`).
  - `:102-107` `handTurn(toTeam:)` calls `passTurn()` locally; `:111-117` `swap` is local only.
  - `:121-141` `record` / `shotSettled(_:)` append a shot with a fresh `UUID()`, show the badge and pass the turn.
- `CueCoach/Live/LiveLogic.swift:458-467`: `SettledShot` has no `ShotOutcome`. `LiveModel.swift:255-272` builds it from
  `RuleRating.outcome(record, ids:)` (`LiveLogic.swift:296-311`) but passes only `pocketed`.
- `docs/INTERFACES.md:382-468`: "Proposed (plan 006 — not approved)". It says no new `GameEvent` case; D41 needs one (below).

## Design choices this plan fixes (from D38/D41; confirm in step 1)
1. Two new events: `.nextShooter(team: Int)` (D41 disc tap; works before the first shot too) and
   `.shotLost(shotID: UUID, shooterTeam: Int)` (D38 gap: rating nil, no rules change, sets `needsShooter`).
   `.shooterCorrection` stays for fixing a recorded shot (no UI yet).
2. Adding cases is a wire break, so bump `ProtocolVersion` to major 2 (`current = (2, 0)`, `supportedMajors = [2]`).
   An old build then gets a clean `Reject` at Hello instead of silently undecodable logs.
3. `MeshShotRecord` gains `preState: TableState?`, `decisionRating: DecisionRating?`, `isGuess: Bool`, decoded with
   `decodeIfPresent` (missing key → nil / false). `SettledShot` gains `outcome: ShotOutcome`.
4. Solo (`mesh == nil`) uses the same fold over an in-memory local log that commits at once. One code path.
5. Fold is a pure function over the committed events plus local swaps (kept as `(afterEvent, team, a, b)` so solo
   swap behaviour is unchanged). Re-fold from scratch on every change; the badge fires only for a newly committed `.shot`.
6. Live's `gameAdvanced` no longer writes `rulesState`; the fold owns it.

## Commands you will need
| Purpose | Command | Expected |
|---|---|---|
| Unit (targeted) | `xcodebuild test -project CueCoach.xcodeproj -scheme CueCoach -destination 'platform=iOS Simulator,name=CueCoach iPhone 15 Pro' -only-testing:CueCoachTests/GameSessionModelTests -only-testing:CueCoachTests/LiveAdapterTests -only-testing:CueCoachTests/MeshCodecTests -only-testing:CueCoachTests/MeshNodeTests` | `** TEST SUCCEEDED **` |
| Full unit | same with `-only-testing:CueCoachTests` | `** TEST SUCCEEDED **` |
| UI | same with `-only-testing:CueCoachUITests/AppShellUITests` | `** TEST SUCCEEDED **` |

## Scope
**In scope:** `docs/INTERFACES.md`; `MeshMessage.swift` (`MeshShotRecord`, `GameEvent`); `MeshTypes.swift` (version);
`LiveLogic.swift` (`SettledShot.outcome`); `LiveModel.swift` (`shotSettled` fills `outcome` only); `GameSessionModel.swift`;
`MeshGameLink.swift` (protocol members only; `MeshGameLink` gets stub conformance: `isHost = true`, `append` no-op,
callback never fires); `InGameChrome.swift` (drop the `gameAdvanced` write); tests in `CueCoachTests/App` and `CueCoachTests/Mesh`.

**Out of scope:** real mesh wiring (plan 010), SwiftData (plan 011), island mode and re-run (plan 013), logging swaps
on the mesh, any UI change.

## Steps
### Step 1: Contract first
Move into the real contract (`docs/INTERFACES.md`, a new "Shot log (plan 009)" section): the widened `MeshShotRecord`,
the two new `GameEvent` cases, the major-2 bump, the `GameMeshLink` additions (`isHost`, `commitSeq`,
`onCommittedLog`, `append`), `SettledShot.outcome`, and the four `GameSessionModel` rules from the Proposed block
(`shotSettled`, `ingest(log:commitSeq:)`, `handTurn`, plus `shotLost` per D38). Leave `GameRecorder`/`FinishedGame`/
`RecordedShot` in "Proposed" for plan 011. Replace the "No new GameEvent case" sentence with design choice 2.
**Verify**: `grep -n "nextShooter\|shotLost\|decodeIfPresent" docs/INTERFACES.md` → matches in the new section.

### Step 2: Red wire tests (`MeshCodecTests`)
- `shotRecordWithoutNewKeysDecodesWithDefaults` (golden JSON with only the four old keys).
- `widenedShotRecordRoundTrips`; `nextShooterAndShotLostRoundTrip`; `frameHeaderIsMajorTwo`.
**Verify**: targeted → the new tests FAIL to compile or fail.

### Step 3: Wire types
Implement design choices 1–3. Update `goldenV1HeartbeatStillDecodes` only as far as the major bump forces (add a
V2 golden; say why in the commit body). **Verify**: targeted → passes, `MeshNodeTests` unchanged and green.

### Step 4: Red fold tests (`GameSessionModelTests`, with a `FakeGameMeshLink` test double)
The design calls this a "fake `MeshSession`"; the seam `GameSessionModel` sees is `GameMeshLink`, so fake that.
- `soloSettleFoldsAtOnceAndShowsTheBadge` (same results as today's tests).
- `hostSettleAppendsAShotAndShowsNothingUntilCommitted`, then `…badgeAndTurnFollowTheCommit`.
- `clientSettleAppendsNothing` (D39) and `clientShowsTheHostsCommittedRating`.
- `foldCarriesBeforeAfterIntoSessionShots` (plan 002 fields via `preState`/`postState` on `config.tableSize`).
- `discTapAppendsNextShooterAndChangesNoRecordedShot` (D41); `discTapBeforeTheFirstShotWorks`.
- `shooterCorrectionMovesThatShotAndReplaysTheRotation` (attribution `.tap`).
- `lostShotFoldsToAGapAndAsksForTheShooter`; `nextShooterClearsTheAsk` (D38 via the log).
- `refoldIsIdempotentAndBadgeFiresOncePerShot`; `uncommittedTailNeverShows`.
- `soloSwapKeepsTodaysBehaviour` (existing swap tests stay green).
**Verify**: they FAIL.

### Step 5: Fold
Implement design choices 4–6 in `GameSessionModel`. Keep `passTurn`, `rules`, `reviewData` signatures. `rulesState`
after each `.shot` = `engine.apply(outcome, to: state with shooter = folded team)`; rating = `decisionRating` if
present, otherwise the same classification `RuleRating.rate` uses (extract it to a helper that takes a `RuleResult`).
**Verify**: targeted → passes; full unit → passes.

### Step 6: UI smoke
**Verify**: `AppShellUITests` → passes (solo play must look exactly as before).

## Done criteria
- [ ] Every new test passes; full `CueCoachTests` and `AppShellUITests` pass
- [ ] `grep -n "rulesAdvanced" CueCoach/App/InGameChrome.swift` → no write to `rulesState` from Live
- [ ] `grep -rn "SwiftData\|ModelContext" CueCoach/App/GameSessionModel.swift` → nothing
- [ ] `git diff --name-only` ⊆ the in-scope list plus `plans/README.md`

## STOP conditions
- The head or user rejects the major-2 bump (design choice 2). Do not invent a workaround inside major 1.
- The fold's rules state differs from Live's own `result.nextState` for the same shot (add a test that compares them).
  That means the host's Live and the fold disagree; report the case.
- Keeping solo swap behaviour needs more than the local-swap list (design choice 5).
- 002/008 merged with a different `SessionShot` shape (no `before`/`after`, or `rating` not optional).

## Maintenance notes
- On a mesh host the next shot is rated against the committed state. If a second shot settles before the first
  commits (a silent joiner), Live rates against stale state. That is the no-majority case; plan 013 owns it.
- Mid-game `swap` still diverges between phones until a later plan logs `StoredTeam.orderChanges`.
- Reviewer: check the badge never fires twice for one `shotID` across re-folds and host changes.

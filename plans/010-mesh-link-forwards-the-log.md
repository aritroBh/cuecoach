# Plan 010: The real mesh link forwards the committed log to the game

> **Executor instructions**: Follow this plan step by step. Run every verification and confirm the expected result
> before the next step. Honor the STOP conditions; do not improvise. When done, update this plan's row in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 5cd3fcf..HEAD -- CueCoach/App/MeshGameLink.swift CueCoach/App/GameSessionModel.swift CueCoach/App/AppRouter.swift CueCoach/App/ShellEnvironment.swift CueCoach/Mesh/MeshSession.swift CueCoach/Mesh/MeshNode.swift docs/INTERFACES.md CueCoachTests/App CueCoachTests/Mesh`
> Plan 009 rewrites the `GameMeshLink` protocol and `GameSessionModel`; plans 002, 007 and 008 also touch
> `GameSessionModel.swift` and `AppRouter.swift`. Re-read those files after they merge and compare with the excerpts
> below. A changed shape (not just moved lines) is a STOP condition.

## Status
- **Priority**: P1 · **Effort**: M · **Risk**: MED · **Depends on**: plan 009 merged · **Category**: feature
- **Planned at**: commit `5cd3fcf`, 2026-11-10. Design: `docs/research/game-log-and-saving.md`, follow-up 2.

## Why this matters
Plan 009 makes `GameSessionModel` fold a committed log, but it tests against a fake link: the shipping
`MeshGameLink` still only counts peers. Until this lands, a two-phone game never appends a shot to the mesh and the
joiner never sees one, so D39 (joiner badge after the host's committed rating) can't happen on real phones.

## Current state (verified at `5cd3fcf`; re-check after 009)
- `CueCoach/App/MeshGameLink.swift:15-48`: `MeshGameLink` holds a concrete `MultipeerMeshSession` (`:18`), built in
  `init(sessionTag:)` from battery state (`:21-27`). `start()` (`:29-38`) reads `s.updates` and handles **only**
  `.rosterChanged` (`:35`). `stop()` (`:40-47`) cancels the task and stops the session.
- `CueCoach/Mesh/MeshNode.swift:46-60`: `MeshUpdate` has `.roleChanged(MeshRole, term:)` and
  `.logChanged(lastSeq:commitSeq:)`. It carries sequence numbers only, not entries. `flush()` (`:856-862`) emits
  `logChanged` whenever `(lastSeq, commitSeq)` changes.
- `CueCoach/Mesh/MeshSession.swift:5-16`: `MeshSnapshot { role, term, roster, log, commitSeq, … }`; `:20-38` the
  `MeshSession` protocol has `append(_:)` and `snapshot()`. `MultipeerMeshSession.init(transport:status:config:)`
  (`:53-58`) accepts any `MeshTransport`.
- `CueCoachTests/Mesh/MeshSessionTests.swift:7-40`: `MemoryHub` and `MemoryTransport` give an in-process mesh for
  `MultipeerMeshSession` tests. Reuse them.
- `CueCoach/App/ShellEnvironment.swift:23`: `meshFactory = { MeshGameLink(sessionTag: $0) }`.
- `CueCoach/App/AppRouter.swift:89-97` attaches the link at `startGame`; `:104-109` `endGame()` stops it and sets `mesh = nil`
  **before** building review. Plan 011 needs `isHost` and `commitSeq` at that moment: keep the link readable until after
  the recorder runs (see Maintenance).
- After plan 009 the `GameMeshLink` protocol has `isHost`, `commitSeq`, `onCommittedLog`, `append(_:)` and
  `MeshGameLink` conforms with stubs.

## Commands you will need
| Purpose | Command | Expected |
|---|---|---|
| Unit (targeted) | `xcodebuild test -project CueCoach.xcodeproj -scheme CueCoach -destination 'platform=iOS Simulator,name=CueCoach iPhone 15 Pro' -only-testing:CueCoachTests/MeshGameLinkTests -only-testing:CueCoachTests/MeshSessionTests -only-testing:CueCoachTests/AppRouterTests` | `** TEST SUCCEEDED **` |
| Full unit | same with `-only-testing:CueCoachTests` | `** TEST SUCCEEDED **` |
| UI | same with `-only-testing:CueCoachUITests/AppShellUITests` | `** TEST SUCCEEDED **` |

## Scope
**In scope:** `MeshGameLink.swift`; `ShellEnvironment.swift` (only if the factory signature changes);
`docs/INTERFACES.md` (one line under the plan 009 section); a new `CueCoachTests/App/MeshGameLinkTests.swift`.

**Out of scope:** `MeshNode` protocol logic, fusion of joiner detections (`MeshUpdate.tableState`), clip transfer,
saving, island mode, any UI.

## Steps
### Step 1: Contract
Add to the plan 009 section of `docs/INTERFACES.md`: "`MeshGameLink` turns each `logChanged` into one
`onCommittedLog(log.prefix(through: commitSeq), commitSeq)` call from a fresh `snapshot()`, on the main actor, in
order; `roleChanged` sets `isHost`." **Verify**: `grep -n "onCommittedLog" docs/INTERFACES.md` → the new line.

### Step 2: Red tests (`MeshGameLinkTests`, two links on one `MemoryHub`)
Add an `init(session: any MeshSession)` seam on `MeshGameLink` (keep `init(sessionTag:)` for production).
- `hostAppendReachesTheJoinersCallbackOnceCommitted`: host link `append(.shot(…))`; the joiner's `onCommittedLog`
  gets a log whose last entry is that shot, and `commitSeq` covers it.
- `uncommittedEntriesAreNeverForwarded`: a lone host of a two-member roster with the joiner cut off forwards nothing new.
- `clientAppendBecomesAProposalTheHostCommits` (D41 disc tap from the joiner).
- `isHostFollowsRoleChanges`.
- `callbacksArriveInCommitOrder` (no older `commitSeq` after a newer one).
- `stopEndsForwarding`.
Wait on async delivery with a bounded poll (≤ 2 s), as `MeshSessionTests` does.
**Verify**: targeted → the new tests FAIL.

### Step 3: Implement
- Store `any MeshSession`. In the update loop: `.rosterChanged` as today; `.roleChanged` sets `isHost`;
  `.logChanged` awaits `snapshot()`, drops it if its `commitSeq` is older than the last one forwarded, then calls
  `onCommittedLog` with entries `seq <= commitSeq`.
- `append(_:)` forwards to `session.append` in a `Task` (the session already turns a client append into a proposal).
- `commitSeq` is the last forwarded value.
**Verify**: targeted → passes; full unit → passes.

### Step 4: End-to-end check
Add `twoGameSessionsAgreeOnShotsAndTurn` in `MeshGameLinkTests`: two `GameSessionModel`s, each with a link on one hub.
Settle a shot on the host's model; both models end with the same `shots` ids, ratings and `shootingTeam`.
**Verify**: targeted → passes; `AppShellUITests` → passes.

## Done criteria
- [ ] New tests pass; full `CueCoachTests` and `AppShellUITests` pass
- [ ] `grep -n "logChanged\|roleChanged" CueCoach/App/MeshGameLink.swift` → both handled
- [ ] `git diff --name-only` ⊆ the in-scope list plus `plans/README.md`

## STOP conditions
- A `snapshot()` per `logChanged` measurably lags on the simulator (the forwarded `commitSeq` trails the node by more
  than one update under a 30-shot burst). Report numbers; don't add a new `MeshUpdate` case without the head.
- `MemoryHub` can't run two `MultipeerMeshSession`s to a committed state in-process.
- Making the link testable needs a `MeshSession` protocol change.

## Maintenance notes
- Plan 011 must read `isHost` / `commitSeq` / roster majority **before** `endGame()` stops the link. Either 011 moves
  the recorder ahead of `mesh?.stop()` or this plan keeps the last values readable after stop. Coordinate; do not do both.
- Joiner detections (`MeshUpdate.tableState`) still go nowhere. The host rates from its own camera until fusion exists.

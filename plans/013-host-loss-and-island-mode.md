# Plan 013: Losing the host keeps the game: mid-shot re-run and island merge (§2.5)

> **Executor instructions**: Follow this plan step by step. Run every verification and confirm the expected result
> before the next step. Honor the STOP conditions; do not improvise. When done, update this plan's row in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 5cd3fcf..HEAD -- CueCoach/Mesh CueCoach/App/MeshGameLink.swift CueCoach/App/GameSessionModel.swift CueCoach/App/AppRouter.swift CueCoach/Live/LiveLogic.swift CueCoach/Live/LiveModel.swift Packages/CueCore/Package.swift docs/INTERFACES.md CueCoachTests/Mesh CueCoachTests/App`
> Plans 009, 010 and 011 change the mesh link, the fold and the save path; plans 002, 007 and 008 also touch
> `GameSessionModel.swift`, `LiveModel.swift`, `LiveLogic.swift` and `AppRouter.swift`. Re-read them after they merge
> and compare with the excerpts below. A changed shape is a STOP condition.

## Status
- **Priority**: P2 · **Effort**: L · **Risk**: HIGH · **Depends on**: plan 009 merged (010 and 011 recommended) · **Category**: feature
- **Planned at**: commit `5cd3fcf`, 2026-11-10. Design: `docs/research/game-log-and-saving.md` §1 failure cases, follow-up 5;
  `docs/research/mesh-identity.md` §2.5.

## Why this matters
The Phase 5 gate is "killing the host keeps the game". With plan 009 in, a two-phone game commits a shot only when
both phones have it. Today, after a host loss or a link blip: the shot in flight is never re-run, so it is missing
and the turn stays with the previous shooter; and in a two-phone split both sides keep playing, but every shot
appended during the split is thrown away when they heal. Players lose real shots in every Wi-Fi blip.

## Split (head, 2026-11-12)
This plan runs as **013a** = steps 1–4 below, unchanged: island state, per-phone settle buffer, `IslandMerge`, heal,
and the recorder refusing while `isIsland`. `needsTap` stays a flag only; no new screens; no schema change.
**013b** (after plan 015, which builds replay-from-a-shot) adds the D47 side-by-side pick (reusing 015's replay) and
the D51 unconfirmed island save (schema change). 013b gets its own plan file. Q12 and the "needs tap" display are
answered (D44, D47), so the STOP condition on them is cleared for 013a.

**Drift since `5cd3fcf` is expected:** plans 009–012 and 014 merged (fold, mesh link forwarding, save on finished
rack with `hasGameQuorum`, `Shot.isGuess` V3, five table sizes). Re-read the current code; STOP only if a shape this
plan needs is missing (`MeshShotRecord.preState`, committed-prefix fold in `GameSessionModel`, the recorder's quorum gate).

## Decision gate (before step 2)
**Update 2026-11-10: the user answered Q12 = island + merge (D44).** The "needs tap" display below is still open: mock it (Astryx, icon-only, never while aiming) and get the head's OK before step 2.

`docs/research/mesh-identity.md:649` lists **Q12** (island + merge, or freeze and tap) as an open user question with
"Island + merge" only recommended; no D-number records an answer. Also undecided: how a merged shot marked
**"needs tap"** is shown (§2.5 says "on the next post-shot card"; no such card UI exists). Ask the user both. This
plan assumes "island + merge" and leaves the "needs tap" UI out (it only sets a flag).

## Current state (verified at `5cd3fcf`)
- `CueCoach/Mesh/MeshNode.swift:459-468` `hostLost`: drops the host and calls `claimIfTop`. `:470-498` `claimIfTop`:
  `term += 1`; "a claim by a minority island keeps the old roster as its commit denominator" (`:483-484`
  `quorumBase = max(roster.count, priorMembers)`), so a two-phone split commits nothing on either side.
- `:643-662` `finishCollecting` takes the best survivor tail **only while collecting**. After a heal, the old host
  adopts the winner (`:501-530` `adopt`, sends its whole log) and the new host ignores it (`:680-692`,
  `ignoredMessages += 1`). The stepped-down phone then truncates its own log to the host's (`:699`).
- `CueCoachTests/Mesh/MeshNodeTests.swift:233-252` `partitionedOldHostStepsDownOnHeal` **asserts** the island shot
  is dropped: `#expect(net.node(newHost).log.count == 2)`. This plan changes that expectation on purpose.
- `CueCoach/Mesh/MeshMessage.swift:220-230`: an unknown message `type` decodes as `.unknown` and is ignored, so a new
  `MeshMessage` kind is a minor (additive) change. A new `GameEvent` case is not (see plan 009).
- No `IslandShot`, `IslandLog` or `IslandMerge` exists anywhere (`grep -rln Island CueCoach Packages` → nothing).
- `Packages/CueCore/Package.swift:8-16`: targets Geometry, Physics, Rules, Engine, Stats, Training. `project.yml:16-27`
  links the `CueCore` product.
- `CueCoachTests/Mesh/SimNetwork.swift:102-105`: `partition(_:_:)` and `heal()` for seeded sims.
- After plan 009: client settles are dropped, `MeshShotRecord` has `preState`, and `GameSessionModel` folds the committed prefix.

## Behaviour to build
1. **Island state.** A phone with no host, or a host without a majority, is an island. `MeshNode` reports it
   (`MeshUpdate.island(Bool)`, additive). While an island: tracking and overlay continue; shots are kept as a
   provisional island tail; `GameSessionModel` may show a provisional badge (§2.5 item 2); **no SwiftData write**
   (plan 011's recorder refuses while `isIsland`).
2. **Every phone keeps its own settles.** A client stores its local `SettledShot`s (with `strokeHostTime`, from
   `ClockSync`, and `preState`) until a committed `.shot` matches them. A new host appends the unmatched ones: that is
   the §2.5 "re-run" of the shot in flight. No confident record → a D38 gap (`.shotLost`).
3. **`IslandMerge`** (pure, new CueCore target `Sync`, depends on Geometry and Rules): input = the common committed
   prefix plus each island's tail; align shots by `|Δt| ≤ 0.5 s` **and** pre-state (every ball within one ball radius);
   same outcome → one shot; different outcome → keep the higher-confidence one and set `needsTap`; unmatched → keep.
   Deterministic and independent of island order.
4. **Heal.** The stepped-down side sends its island tail in a new `IslandLog` message; the winning host merges and
   appends the result; everyone re-folds.

## Commands you will need
| Purpose | Command | Expected |
|---|---|---|
| Core | `cd Packages/CueCore && swift test --filter SyncTests` | all pass |
| Unit (targeted) | `xcodebuild test -project CueCoach.xcodeproj -scheme CueCoach -destination 'platform=iOS Simulator,name=CueCoach iPhone 15 Pro' -only-testing:CueCoachTests/MeshNodeTests -only-testing:CueCoachTests/MeshCodecTests -only-testing:CueCoachTests/GameSessionModelTests -only-testing:CueCoachTests/GameRecorderTests` | `** TEST SUCCEEDED **` |
| Full unit | same with `-only-testing:CueCoachTests`; then `xcodegen generate` if `project.yml` changed | `** TEST SUCCEEDED **` |

## Scope
**In scope:** `docs/INTERFACES.md`; `Packages/CueCore/Package.swift` + `Sources/Sync/IslandMerge.swift` + `Tests/SyncTests`;
`MeshNode.swift`, `MeshMessage.swift` (`IslandLog`, `MeshShotRecord.strokeHostTime` optional); `MeshGameLink.swift`
(forward island state); `GameSessionModel.swift` (local settle buffer, provisional badge); the recorder guard;
`MeshNodeTests` (`partitionedOldHostStepsDownOnHeal` expectation), new Mesh/App tests.

**Out of scope:** the "needs tap" UI, resuming a killed game, election changes, ≥3-phone tuning beyond §2.5 item 4.

## Steps
1. **Contract.** Add a "Host loss and islands (plan 013)" section with the four behaviours and the new types.
   **Verify**: `grep -n "IslandMerge" docs/INTERFACES.md` → the new section.
2. **Red core tests (`SyncTests`)**, from `mesh-identity.md` §9 `IslandMerge` row: seeded partition sims (0.5–60 s)
   where every physical shot appears exactly once if any side saw it; disagreement flagged `needsTap`; merge order-independent;
   flap test (link toggles every 0.5–3 s for 5 simulated minutes) with no duplicates. **Verify**: they FAIL; then implement; pass.
3. **Red mesh tests (`MeshNodeTests`)**: `twoPhoneSplitKeepsBothIslandsShotsOnHeal` (replaces the old expectation; say so
   in the commit body); `hostKilledMidShotTheNewHostAppendsItsOwnSettle`; `noConfidentSettleBecomesAGap`;
   `islandStateIsReported`; plus the existing kill-host sims stay green. **Verify**: FAIL, implement, pass.
4. **Red app tests**: `islandShowsAProvisionalBadgeAndWritesNothing` (`GameRecorderTests`: zero rows while island);
   `afterHealBothPhonesFoldTheSameShots`. **Verify**: FAIL, implement, full unit passes.

## Done criteria
- [ ] Core, targeted and full unit suites pass
- [ ] `grep -rn "IslandMerge" Packages/CueCore/Sources/Sync` → the implementation
- [ ] No SwiftData call reachable while `isIsland` (test-proven)
- [ ] `git diff --name-only` ⊆ the in-scope list plus `plans/README.md` (and `project.yml` if the new target needs it)

## STOP conditions
- Q12 or the "needs tap" display is unanswered when step 2 starts.
- Stroke times can't be put on one host clock (no `ClockSync` estimate at settle time) on the simulator.
- Making a split side commit would need changing the majority rule. Don't; report.
- The kill-host sims regress (`killingHostKeepsGame`, `randomKillHostNeverLosesCommittedEvents` at `MeshNodeTests.swift:125-230`).

## Maintenance notes
- Resume after a kill (design question 2's third option) builds on this; it is not planned.
- `preStateDigest` in §2.5 is replaced by the full `preState`, because alignment needs positions within one ball radius.
- **2026-11-11 user answers:** D47 — a disagreement shows both versions side by side (ball glyphs), one tap picks, the game replays from that shot. D48 — while cut off the joiner shows its own badge as provisional; the merged result replaces it. Share the replay-from-a-shot path with plan 015 (D49).
- **From the plan 011 review (2026-11-12):** saving needs `hasGameQuorum` (a strict majority of the game's original members), so an island never saves on its own. This plan owns saving island games: merge on reconnect (D47), then save once. If the phones never reconnect: **D51** — the island saves its finished rack flagged unconfirmed; shown in history with a small marker, excluded from competitive stats until confirmed (how: undecided — ask the user in 013b).

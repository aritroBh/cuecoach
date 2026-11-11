# Plan 001: Live-game data is tested through Game Review, and MVP is never a coin flip

> **Executor instructions**: Follow this plan step by step. Run every verification command and confirm the
> expected result before the next step. If a STOP condition occurs, stop and report; do not improvise. When
> done, update this plan's row in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat b21f994..HEAD -- CueCoach/Screens/Review/GameReviewModel.swift CueCoach/App/GameSessionModel.swift CueCoachTests/App/GameSessionModelTests.swift CueCoachTests/Screens/GameReviewModelTests.swift`
> If anything changed, compare the excerpts below with the live code. A mismatch is a STOP condition.

## Status
- **Priority**: P1 · **Effort**: S · **Risk**: LOW · **Depends on**: none · **Category**: bug + tests
- **Planned at**: commit `b21f994`, 2026-11-10

## Why this matters
In a live (camera) game, the in-game model `GameSessionModel` builds the review data with `wpaDelta: 0` for every
shot and an empty `winProb`. In a team game, Game Review then picks the MVP as the max of per-player WPA sums,
which are all 0. That is a tie, decided by `Dictionary` iteration order, which Swift randomizes per process. So
the "MVP" shown after every live 2v2 game is arbitrary, and it can differ between launches. No test feeds live
`GameSessionModel.reviewData()` into `GameReviewModel`, so neither this nor plan 002's bug is caught. This plan
adds that test seam and makes the MVP honest: **no MVP when there is no WPA signal**.

## Current state
- `CueCoach/App/GameSessionModel.swift:150-163`: `reviewData()`. Every `ReviewShot` gets `pre: nil, post: nil, paths: [:], wpaDelta: 0`, and `GameReviewData` gets `winProb: []`.
- `CueCoach/Screens/Review/GameReviewModel.swift:130-144`: `mvp`:
  ```swift
  var mvp: ReviewMVP? {
      guard !isLocked, let d = data else { return nil }
      let rated = d.shots.filter { $0.shooter != nil }
      let isTeamGame = d.teams.contains { $0.count > 1 }
      let player: ReviewPlayer?
      if isTeamGame {
          let totals = Dictionary(grouping: rated, by: { $0.shooter!.id }).mapValues { $0.reduce(0) { $0 + $1.wpaDelta } }
          player = totals.max { $0.value < $1.value }.flatMap { best in rated.first { $0.shooter?.id == best.key }?.shooter }
      } else {
          guard let w = d.winnerTeam, d.teams.indices.contains(w) else { return nil }
          player = d.teams[w].first
      }
      guard let player,
            let best = rated.filter({ $0.shooter?.id == player.id }).max(by: { $0.wpaDelta < $1.wpaDelta }) else { return nil }
      return ReviewMVP(player: player, team: best.team, bestShot: best)
  }
  ```
- Tests use **Swift Testing** (`import Testing`, `@Suite`, `@Test`, `#expect`), not XCTest. Use as the pattern:
  - `CueCoachTests/App/GameSessionModelTests.swift`: helper `teams()` at line 15 builds a 2v2 session on an 8 ft table, and `reviewDataHasTeamsShotsAndTable` (line ~79) shows `s.shotSettled(rating:turnPasses:)`, then `s.reviewData()`.
  - `CueCoachTests/Screens/GameReviewModelTests.swift`: `GameReviewModel(data:)` and its `mvp`, `isLocked` and `timelineStyle` checks.
- Project rule: TDD. Write the failing test first, then the code. Comments are short and plain.

## Commands you will need
| Purpose | Command | Expected |
|---|---|---|
| Regenerate project (after adding files) | `xcodegen generate` | exit 0 |
| Targeted tests | `xcodebuild test -project CueCoach.xcodeproj -scheme CueCoach -destination 'platform=iOS Simulator,name=CueCoach iPhone 15 Pro' -only-testing:CueCoachTests/GameSessionModelTests -only-testing:CueCoachTests/GameReviewModelTests` | `** TEST SUCCEEDED **` |
| Full unit suite | same, with `-only-testing:CueCoachTests` | `** TEST SUCCEEDED **` |

## Scope
**In scope:** `CueCoach/Screens/Review/GameReviewModel.swift` (only the `mvp` property), `CueCoachTests/App/GameSessionModelTests.swift`, `CueCoachTests/Screens/GameReviewModelTests.swift`.

**Out of scope:**
- `GameSessionModel.reviewData()` state fields (`pre`/`post`): that is plan 002.
- Computing real WPA for live shots: that needs the engine's win model per shot. It is a separate feature.
- The single-player (1v1) MVP path: it uses the winner, which is deterministic.
- Any UI or view file.

## Git workflow
Branch `wt/plan-001` from `phase/1-core`, in a worktree under `.worktrees/`. One commit for the red test, one for the fix. Message style from `git log`: `fix(review): <what is now true>`, ending with the repo's co-author trailer. Do not push.

## Steps
### Step 1: Red test. A live 2v2 review has no MVP when WPA is all zero
In `GameSessionModelTests.swift`, add:
```swift
@Test func liveTeamReviewHasNoMVPWithoutWinProbability() {
    let s = teams()
    s.shotSettled(rating: .best, turnPasses: true)
    s.shotSettled(rating: .good, turnPasses: true)
    var g = s.rules.1; g.phase = .over(winner: 0); s.rulesAdvanced(g)   // finished, so review isn't locked
    let m = GameReviewModel(data: s.reviewData())
    #expect(!m.isLocked)
    #expect(m.mvp == nil)
}
```
(Check `reviewHeaderFollowsTheRulesWinner` in the same file for the exact way to finish a rack. Copy it if the lines above differ.)

**Verify**: targeted tests → this test FAILS (`m.mvp` is non-nil).

### Step 2: Fix `mvp`
In the team branch, return nil when no rated shot has a non-zero `wpaDelta`. When values tie, choose
deterministically: the higher total wins, and on a tie the player whose first shot has the lower `index` wins. Shape:
```swift
if isTeamGame {
    guard rated.contains(where: { $0.wpaDelta != 0 }) else { return nil }   // no WPA signal: no MVP
    var totals: [(id: UUID, total: Double, first: Int)] = []
    for s in rated.sorted(by: { $0.index < $1.index }) { ... accumulate per shooter id, keeping first-seen order ... }
    player = totals.max { ($0.total, -$0.first) < ($1.total, -$1.first) }.flatMap { b in rated.first { $0.shooter?.id == b.id }?.shooter }
}
```
**Verify**: targeted tests → `** TEST SUCCEEDED **`, including every existing `GameReviewModelTests` MVP test.

### Step 3: Tie-break test
In `GameReviewModelTests.swift`, add a test: two players on one team with equal non-zero WPA totals. The one who shot first is MVP. Run it 3 times (`-test-iterations 3`).

**Verify**: targeted tests → pass on all iterations.

### Step 4: Full unit suite
**Verify**: full unit suite → `** TEST SUCCEEDED **`.

## Done criteria
- [ ] New tests `liveTeamReviewHasNoMVPWithoutWinProbability` and the tie-break test exist and pass
- [ ] Full `CueCoachTests` passes on `CueCoach iPhone 15 Pro`
- [ ] `git diff --name-only phase/1-core` lists only the three in-scope files (plus `plans/README.md`)
- [ ] `plans/README.md` row updated

## STOP conditions
- An existing `GameReviewModelTests` MVP test expects an MVP for a team game with all-zero WPA. That would mean the "no MVP" behaviour is a product decision against an existing test. Report it and don't change the test.
- The fix seems to need a UI change. For example, the review view crashes or shows an empty card when `mvp` is nil in a finished team game. Report it.

## Maintenance notes
- When live shots get real WPA, the MVP will appear again on its own. Re-check the tie-break test then.
- A reviewer should check that nothing else iterates a `Dictionary` to pick a "best" item in review (`shotOfGame`).

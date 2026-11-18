# Plan 001: Live-game data is tested through Game Review, and team MVP follows D35 (never a coin flip)

> **Executor instructions**: Follow this plan step by step. Run every verification command and confirm the
> expected result before the next step. If a STOP condition occurs, stop and report; do not improvise. When
> done, update this plan's row in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat b21f994..HEAD -- CueCoach/Screens/Review/GameReviewModel.swift CueCoach/App/GameSessionModel.swift CueCoachTests/App/GameSessionModelTests.swift CueCoachTests/Screens/GameReviewModelTests.swift`
> If anything changed, compare the excerpts below with the live code. A mismatch is a STOP condition.

## Status
- **Priority**: P1 · **Effort**: S · **Risk**: LOW · **Depends on**: none · **Category**: bug + tests
- **Planned at**: commit `b21f994`, 2026-11-10 (revised the same day for decision D35)

## Why this matters
In a live (camera) game, `GameSessionModel` builds review data with `wpaDelta: 0` for every shot. In a team
game, Game Review picks the MVP as the max of per-player WPA sums. All sums are 0, so it is a tie decided by
`Dictionary` iteration order, which Swift randomizes per process. The "MVP" after every live 2v2 game is arbitrary.
No test feeds live `GameSessionModel.reviewData()` into `GameReviewModel`, so the tests don't catch this.

**Decision D35 (user, 2026-11-10):** when no rated shot has a non-zero `wpaDelta`, the team-game MVP is **the winning
team's player with the best shot ratings**. The rules:
- Rank each `DecisionRating` by its position in `DecisionRating.allCases`. The order is `brilliant, great, best, good, okay, book, inaccuracy, miss, mistake, blunder`; earlier is better.
- Take each winning-team player's mean rank over their rated shots. The lowest mean wins.
- Ties go to the player with more rated shots, then to the earlier first-shot `index`.
- When WPA data exists, keep the highest-WPA rule, but with a deterministic tie-break.

## Current state
- `CueCoach/App/GameSessionModel.swift:150-163`: `reviewData()`. Every `ReviewShot` has `wpaDelta: 0`, and `winProb: []`.
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
- `CueCoach/Screens/Review/GameReviewView.swift:426-458`: `mvpCard` always draws an "MVP" title, then the MVP if there is one. With D35 a finished team game always has an MVP whenever the winning team has a rated shot, so no view change is needed.
- `DecisionRating` is in `Packages/CueCore/Sources/Engine/Contracts.swift:5-6` (`CaseIterable`). `ReviewShot.rating` is `DecisionRating?`.
- Tests are **Swift Testing** (`import Testing`, `@Suite`, `@Test`, `#expect`). Patterns:
  - `CueCoachTests/App/GameSessionModelTests.swift`: the helper `teams()` (line ~15) gives a 2v2 on 8 ft. `reviewHeaderFollowsTheRulesWinner` shows how to finish a rack (`var g = s.rules.1; g.phase = .over(winner: 1); s.rulesAdvanced(g)`).
  - `CueCoachTests/Screens/GameReviewModelTests.swift`: `mvpTeamGameIsHighestTotalWPA` (non-zero WPA) and `emptyAndLockedStates`.
- Project rule: TDD. Red test first.

## Commands you will need
| Purpose | Command | Expected |
|---|---|---|
| Regenerate project | `xcodegen generate` | exit 0 |
| Targeted tests | `xcodebuild test -project CueCoach.xcodeproj -scheme CueCoach -destination 'platform=iOS Simulator,name=CueCoach iPhone 15 Pro' -only-testing:CueCoachTests/GameSessionModelTests -only-testing:CueCoachTests/GameReviewModelTests` | `** TEST SUCCEEDED **` |
| Full unit suite | same with `-only-testing:CueCoachTests` | `** TEST SUCCEEDED **` |

## Scope
**In scope:** `CueCoach/Screens/Review/GameReviewModel.swift` (only `mvp`, plus a private helper if needed), `CueCoachTests/App/GameSessionModelTests.swift`, `CueCoachTests/Screens/GameReviewModelTests.swift`.

**Out of scope:**
- `reviewData()` state fields (plan 002)
- real WPA for live shots
- the 1v1 MVP path
- any view file

## Git workflow
Branch `wt/plan-001`. One commit for the red test(s), one for the fix. Style: `fix(review): <what is now true>`, ending with the co-author trailer. Do not push.

## Steps
### Step 1: Red test. A live 2v2 MVP is the winning team's best-rated shooter
In `GameSessionModelTests.swift`:
```swift
@Test func liveTeamMVPIsTheWinningTeamsBestRatedShooter() {
    let s = teams()
    // Rotation A1, B1, A2, B2 (D17). Team A (0) wins. A2 rates better than A1; B1 rates best but loses.
    s.shotSettled(rating: .okay, turnPasses: true)       // A1
    s.shotSettled(rating: .brilliant, turnPasses: true)  // B1 (losing team: never MVP)
    s.shotSettled(rating: .great, turnPasses: true)      // A2
    var g = s.rules.1; g.phase = .over(winner: 0); s.rulesAdvanced(g)
    let data = s.reviewData()
    #expect(!GameReviewModel(data: data).isLocked)
    for _ in 0..<20 { #expect(GameReviewModel(data: data).mvp?.player.name == "A2") }
}
```
Check the rotation in `teams()` first. If the shooters differ, reorder the ratings so the intent holds.

**Verify**: targeted tests → this test FAILS.

### Step 2: Fix `mvp` (team branch only)
- If any rated shot has `wpaDelta != 0`, keep the highest-total-WPA rule. Build the totals in first-shot order and break ties by the earlier first shot, not with `Dictionary.max`.
- Otherwise (D35):
  - If `d.winnerTeam` is nil, return nil.
  - Among shots with `team == winnerTeam` and a non-nil `rating`, group by shooter in first-shot order.
  - Pick the lowest mean `DecisionRating.allCases.firstIndex(of:)`. Ties go to more rated shots, then the earlier first shot.
- `bestShot`: with WPA data, the player's highest `wpaDelta` shot (unchanged). Without it, the player's best-rated shot (lowest rank, earliest on a tie).

**Verify**: targeted tests → `** TEST SUCCEEDED **`, including every existing MVP test.

### Step 3: Tie-break tests
In `GameReviewModelTests.swift`, add:
- Two winning-team players with the same mean rank and the same shot count: the one who shot first is MVP.
- Equal non-zero WPA totals: the one who shot first is MVP.

**Verify**: targeted → passes.

### Step 4: Full unit suite
**Verify**: `** TEST SUCCEEDED **`.

## Done criteria
- [ ] The new tests exist and pass; the full `CueCoachTests` passes
- [ ] `grep -n "Dictionary(grouping" CueCoach/Screens/Review/GameReviewModel.swift` shows no `max` over a `Dictionary` in `mvp`
- [ ] `git diff --name-only` vs the base lists only the three in-scope files
- [ ] `plans/README.md` row updated

## STOP conditions
- An existing `GameReviewModelTests` MVP test contradicts D35.
- The fix seems to need a view change.

## Maintenance notes
- When live shots get real WPA, the WPA rule takes over on its own. D35 is only the no-WPA fallback.
- A reviewer should check `shotOfGame` for the same `Dictionary`-order problem.

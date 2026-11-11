# Plan 002: A live game's review shows each shot's rating and its before/after replay

> **Executor instructions**: Follow this plan step by step. Run every verification command and confirm the
> expected result before the next step. If a STOP condition occurs, stop and report; do not improvise. When
> done, update this plan's row in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat b21f994..HEAD -- CueCoach/Live/LiveLogic.swift CueCoach/Live/LiveModel.swift CueCoach/App/GameSessionModel.swift CueCoach/Screens/Review/GameReviewModel.swift docs/INTERFACES.md CueCoachTests/App/LiveAdapterTests.swift`
> If anything changed, compare the excerpts below with the live code. A mismatch is a STOP condition.

## Status
- **Priority**: P1 · **Effort**: M · **Risk**: MED · **Depends on**: plans/001-live-review-tests-and-mvp.md · **Category**: bug
- **Planned at**: commit `b21f994`, 2026-11-10

## Why this matters
Game Review is the main screen after a game. For a live (camera) game, every shot in its timeline shows as a
dashed "Unrated" circle, VoiceOver says "Unrated", and the replay diagram always says unavailable. The ratings
are recorded correctly. They are hidden because the timeline shows a rating only when the shot has a pre- and
post-shot `TableState`, and the live path never passes one. Live already has those ball positions in its
`ShotRecord` and throws them away. This plan carries them through to review.

## Current state
- `CueCoach/Screens/Review/GameReviewModel.swift:100-104`: the timeline gate (**do not change it**: it is also the "state failed to decode" signal for saved games, tested by `GameReviewModelTests.undecodableShotIsUnavailable`):
  ```swift
  func timelineStyle(_ s: ReviewShot) -> RatingBadgeStyle {
      isReplayAvailable(s) ? .of(s.rating) : .of(nil)
  }
  func isReplayAvailable(_ s: ReviewShot) -> Bool { s.pre != nil && s.post != nil }
  ```
- `CueCoach/Perception/ShotSegmenter.swift:5-9`: `ShotRecord` has `preState: [Int: Vec2]` and `finalState: [Int: Vec2]`. Keys are **tracker ids**, values are table-plane positions in metres. It also has `pocketed: [Int: Pocket]`.
- `CueCoach/Live/LiveModel.swift:255-271`: `shotSettled(_ record: ShotRecord, ids: [Int: BallID], guessed: Bool = false)`. `ids` maps tracker id to rule `BallID`. It builds the hand-off:
  ```swift
  hooks.settledShot(SettledShot(rating: rating, turnPasses: result.turnPasses,
                                pocketed: RuleRating.outcome(record, ids: ids).pocketed,
                                fouls: result.fouls, isGuess: guessed))
  ```
  `RuleRating.outcome` (`LiveLogic.swift:296`) maps ids the same way you need to: `if let id = ids[tid] { ... }`. A track without an identity is **dropped**. That is decision D29: unsettled identities never reach Rules. Follow it here too.
- `CueCoach/Live/LiveLogic.swift:457-467`: `struct SettledShot { rating, turnPasses, pocketed, fouls, isGuess }`.
- `CueCoach/App/GameSessionModel.swift`:
  - `:7-17`: `struct SessionShot { id, index, shooter, team, rating, pocketed, fouls, isGuess }`.
  - `:121-124`: `record(_ r: SettledShot)` appends a `SessionShot`.
  - `:150-163`: `reviewData()` builds `ReviewShot(... pre: nil, post: nil, ... paths: [:] ...)`. The game's table size is `config.tableSize`.
- `CueCoach/Screens/Review/ReviewData.swift:93`: `ReviewPaths.straight(pre: TableState, post: TableState, pocketed: [BallID: Pocket]) -> [BallID: [Vec2]]` builds straight before→after segments. The saved-game adapter (`ReviewData.swift:117-129`) uses it with `pathsAreTraced: false`. Copy that.
- `Packages/CueCore/Sources/Geometry/Ball.swift`:
  - `BallState(position:velocity:angularVelocity:motion:)`, where `motion` is `.stationary` or `.pocketed`.
  - `TableState(spec: TableSpec, balls: [BallID: BallState])`.
  - `TableSpec(size:)` takes a `TableSize`.
- Test pattern to copy: `CueCoachTests/App/LiveAdapterTests.swift:285-298`, `aSettledShotsPocketedBallsAndFoulsShowInReview`. It builds a `GameSessionModel`, `LiveSession`, `LiveModel` and `LiveScreenAdapter.hooks(for:)`, calls `m.shotSettled(rec, ids:)`, then reads `game.reviewData()`. Swift Testing (`@Test`, `#expect`, `#require`).
- Contract doc: `docs/INTERFACES.md` lines ~359-374 ("Settled shot result"). The project rule is **contracts first**: update this doc in the same change. Line ~374 currently says "Live-game review shots still have `pre/post` nil and no paths".
- Privacy: carry **ball positions only**. Never carry pixels, embeddings or track metadata. Nothing here is persisted. It lives in memory until review closes.

## Commands you will need
| Purpose | Command | Expected |
|---|---|---|
| Targeted tests | `xcodebuild test -project CueCoach.xcodeproj -scheme CueCoach -destination 'platform=iOS Simulator,name=CueCoach iPhone 15 Pro' -only-testing:CueCoachTests/LiveAdapterTests -only-testing:CueCoachTests/GameSessionModelTests -only-testing:CueCoachTests/GameReviewModelTests` | `** TEST SUCCEEDED **` |
| Full unit suite | same with `-only-testing:CueCoachTests` | `** TEST SUCCEEDED **` |
| UI review smoke | same with `-only-testing:CueCoachUITests/AppShellUITests` | `** TEST SUCCEEDED **` |

## Scope
**In scope:** `CueCoach/Live/LiveLogic.swift` (`SettledShot` only), `CueCoach/Live/LiveModel.swift` (`shotSettled` only), `CueCoach/App/GameSessionModel.swift` (`SessionShot`, `record`, `reviewData`), `docs/INTERFACES.md` (the settled-shot contract), `CueCoachTests/App/LiveAdapterTests.swift`, `CueCoachTests/App/GameSessionModelTests.swift`.

**Out of scope:**
- `GameReviewModel.timelineStyle` and `isReplayAvailable`: keep the gate.
- Persisting games (a separate design plan, 006).
- Mesh messages (`TableStateFrame`).
- Physics-traced paths.
- Review UI files.
- `RuleRating`.

## Git workflow
Branch `wt/plan-002` from `phase/1-core` after plan 001 is merged. Commits: (1) contract doc, (2) red tests, (3) implementation. Style: `feat(review): live shots carry before/after ball positions to Game Review`, ending with the co-author trailer.

## Steps
### Step 1: Contract
In `docs/INTERFACES.md`'s settled-shot block:
- Add `var before: [BallID: Vec2] = [:]` and `var after: [BallID: Vec2] = [:]` to `SettledShot`. These are identified balls only (D29), in table metres; balls that left the table are absent from `after`.
- Replace the sentence "Live-game review shots still have `pre/post` nil and no paths" with: "`reviewData()` builds `pre`/`post` `TableState`s on `config.tableSize` from them (pocketed balls `.pocketed` in `post`), and straight `paths` (`pathsAreTraced = false`). A shot with an empty `before` stays without states."

**Verify**: `grep -n "before: \[BallID: Vec2\]" docs/INTERFACES.md` → 1 match.

### Step 2: Red tests
In `LiveAdapterTests.swift`, next to the test at line 285, add `aSettledShotsBallPositionsReachReview`. Use the same setup with `preState: [1: Vec2(0.5,0.5), 2: Vec2(1,0.5), 9: Vec2(1.5,0.6)]` and `finalState: [1: Vec2(0.7,0.5)]`, `pocketed: [2: .footLeft]`, and `ids: [1: .cue, 2: BallID(3)!]`. Track 9 has **no** identity. Expect:
- `shot.pre?.balls.keys` == `{.cue, 3}` (track 9 dropped)
- `shot.post?.balls[BallID(3)!]?.motion == .pocketed`
- `shot.post?.balls[.cue]?.position == Vec2(0.7, 0.5)`
- `shot.pre?.spec == TableSpec(size: .eightFoot)`
- `!shot.paths.isEmpty`, `!shot.pathsAreTraced`
- `GameReviewModel(data: game.reviewData()).timelineStyle(shot)` equals `.of(shot.rating)`, i.e. not dashed

Add `aShotWithNoKnownPositionsStaysWithoutStates`: a `ShotRecord` with empty `preState` gives `shot.pre == nil`.

**Verify**: targeted tests → both new tests FAIL; all others pass.

### Step 3: Implement
1. In `SettledShot`, add `var before: [BallID: Vec2] = [:]` and `var after: [BallID: Vec2] = [:]`.
2. In `LiveModel.shotSettled`, fill them by mapping `record.preState` and `record.finalState` through `ids`, dropping unknown tracks (same pattern as `RuleRating.outcome`). Use the same `record` for a D31 guess.
3. In `SessionShot`, add the same two fields. `record(_:)` copies them.
4. In `reviewData()`, for each shot with a non-empty `before`:
   - `pre` = `TableState(spec: TableSpec(size: config.tableSize), balls:)` with every `before` ball `.stationary`.
   - `post` = every `after` ball `.stationary`, plus every key of `pocketed` set to `BallState(position: before[id] ?? .zero, motion: .pocketed)`.
   - `paths` = `ReviewPaths.straight(pre:post:pocketed:)`.
   - `pathsAreTraced: false`.

   With an empty `before`, keep today's nil/empty values.

**Verify**: targeted tests → `** TEST SUCCEEDED **`.

### Step 4: Full suite + UI smoke
**Verify**: full unit suite and `AppShellUITests` → `** TEST SUCCEEDED **`.

## Test plan
- The two new tests in `LiveAdapterTests.swift`, described above.
- Existing ones that must keep passing:
  - `aSettledShotsPocketedBallsAndFoulsShowInReview`
  - `anUnratedCloseRecordsNoShot`
  - `GameReviewModelTests.undecodableShotIsUnavailable`
  - every `GameSessionModelTests` test

## Done criteria
- [ ] Both new tests exist and pass, and the full `CueCoachTests` passes
- [ ] `AppShellUITests` passes
- [ ] `grep -n "pre: nil, post: nil" CueCoach/App/GameSessionModel.swift` → no match, or only inside the empty-`before` branch
- [ ] `git diff --name-only phase/1-core` ⊆ the in-scope list plus `plans/README.md`
- [ ] `plans/README.md` row updated

## STOP conditions
- `ShotRecord.preState` turns out not to be table metres (e.g. image pixels). Check `ShotSegmenter`'s callers: positions should come from the homography-projected tracker. Report it if not.
- A guessed shot (D31) reaches `shotSettled` with a `record` whose `preState` is empty while `pocketed` is not. Report it; don't invent positions.
- Any change to `timelineStyle`/`isReplayAvailable` seems necessary.
- The review UI test fails on the replay diagram (e.g. drawing straight paths for live shots looks wrong). Report it with a screenshot; that is a design question.

## Maintenance notes
- When games get saved (plan 006), `SessionShot.before`/`after` are what gets written to `Shot.preState`/`postState`.
- If identity is still settling when a shot ends, those balls are missing from the replay. That is by design (D29), not a bug.
- A reviewer should check that no pixel or identity data rides along with the positions.

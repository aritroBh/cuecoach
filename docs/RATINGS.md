# Shot ratings and "Brilliant" (D2) — proposal for review

Status: **draft, awaiting user review.** Every product choice is tagged **NEEDS USER DECISION** (written as `[UD-n]`).
The full list is in §8. Thresholds are starting ranges to tune on the Phase 2 gate set (20 hand-built positions)
plus the real-case recreations in §4. They are not final numbers.

---

## 1. What chess.com does, and what we borrow

### 1.1 Chess.com's model (sourced)

Chess.com rates a move by **expected points lost**. Expected points are the mover's winning chances, computed
from the engine eval *and the player's rating*. 1.00 is a certain win, 0.00 is a certain loss.[^cc]

| Class | Expected points lost | How it is decided |
|---|---|---|
| **Brilliant !!** | ≈ 0 | Best or nearly best move **plus a good piece sacrifice**. The move must not leave you in a bad position, and it does not count if you were already completely winning. Judged more generously for new players.[^cc] |
| **Great !** | ≈ 0 | "Critical to the outcome": turns losing into equal, or equal into winning, or is **the only good move**.[^cc] |
| Best | 0.00 | Engine top move |
| Excellent | 0.00–0.02 | |
| Good | 0.02–0.05 | |
| Inaccuracy ?! | 0.05–0.10 | |
| Mistake ? | 0.10–0.20 | |
| Blunder ?? | 0.20–1.00 | |
| Miss | — | Failed to punish the opponent's error[^cc] |

Lichess uses the same idea on a winning-chances scale: drops of 0.1 / 0.2 / 0.3 are Inaccuracy / Mistake / Blunder.[^li]
Lichess derives winning chances from an empirical regression on real games.[^liacc]

### 1.2 Mapping to pool

| Chess idea | Pool equivalent in CueCoach |
|---|---|
| Expected points (rating-aware) | **Rack win probability** `W` from `ShotEngine.winProbability`, using the shooter's **skill model** (spec §5.5.2) |
| Expected points lost | **Decision loss** `L = EV(best) − EV(chosen)`, *ex-ante*: averaged over Monte Carlo outcomes, before we know what happened |
| Piece sacrifice | **Giving something up on purpose**: the turn (safety, deliberate miss), ball in hand (intentional foul), a ball (dumping or tying up your own), or a sure pot traded for a harder but better shot |
| "Not already winning" | `W_before ≤ W_max` (the shot had to matter) |
| "Only good move" | Gap from the best to the second-best candidate is large |
| Rating-generosity | Thresholds scale with the skill model (§6.3) |

**Key principle:** the Decision rating judges the *choice* from EV, never the luck of the result. The Execution
rating judges *what happened*. Brilliant and Great are the only Decision classes that also need the result
(D2: "executed successfully = the intended outcome happened").

---

## 2. What the engine produces per shot (inputs to rating)

| Symbol | Meaning | Source |
|---|---|---|
| `W₀` | Shooter's rack win probability before the shot | `winProbability(pre)` |
| `W₁` | Shooter's rack win probability after the shot settles (actual result; turn passing handled) | `winProbability(post)` |
| `ΔW = W₁ − W₀` | Realized **WPA** of the shot | — |
| `EV(c)` | Expected `W` after candidate `c`, from Monte Carlo with the shooter's noise | `evaluate` |
| `c*`, `c₂` | Best and second-best candidates by EV | `evaluate` |
| `ĉ` | **Chosen candidate** (inferred intent, §2.1) | intent matcher |
| `L = EV(c*) − EV(ĉ)` | Decision loss | — |
| `G = EV(c*) − EV(c₂)` | "Only move" gap | — |
| `Pb(ĉ)` | **Baseline P(intended outcome)** for a *reference* player (pot made, or safety reached its target leave) | MC with reference skill |
| `Ps(ĉ)` | Same, for this shooter's skill | MC with shooter skill |
| `Rₒ` | Opponent's best reply P(make or legal hit and keep control) after the actual result | `evaluate(post)` for the opponent |
| `class(ĉ)` | direct / bank / combo / kick / carom / safety / intentional foul / push-out / break | candidate generator |
| `obvious(ĉ)` | Is this what a naive policy picks? (§3.2) | heuristic |
| `foul`, `intended` | Did a foul occur, and was it the plan (`ĉ.class == intentionalFoul`)? | `RulesEngine.apply` |

### 2.1 Inferring intent (the hardest part)

Ratings mean nothing if we guess the wrong intent. Proposal:

1. **Stroke likelihood.** For each candidate, compute the likelihood of the observed stroke (cue direction, speed
   bucket, tip offset) under the shooter's noise model. Pick the most likely candidate.
2. **Called pocket** (WPA modes) overrides the pocket of a pot candidate (spec §3).
3. **Safety vs. missed pot.** If no pot candidate explains the stroke better than a safety candidate does, the intent
   is safety. Otherwise it is a missed pot.
4. **Low confidence → no Brilliant / Great.** If the top intent's posterior is below `κ`, the shot can still get a
   loss-based rating (computed against the expected intent), but it is never promoted. `κ ∈ [0.6, 0.8]`.
5. **One-tap correction** in the post-game review ("I meant safe"). `[UD-1]`

Fluke rule: if the actual result matches a *different* candidate than `ĉ` (slop, accidental pot), the
execution is a **Miss** (or "Lucky", see `[UD-9]`) and the shot is never Brilliant.

---

## 3. Brilliant-shot catalogue

Every class below comes from real pro play or from a cited instructor. "Signals" are what our engine can check.
"v1" says whether the 2D engine (spec §5.4: no ball elevation) can **generate** the candidate. Shots it can't
generate it can still **observe** through the tracker, but it can't score them against alternatives.

### 3.1 Catalogue

| # | Class | Definition | Real cases | Detectable signals | v1 |
|---|---|---|---|---|---|
| **B1** | **Lockdown safety** | Safety that leaves the opponent no makeable shot and no good return safety: CB hidden or frozen, object ball far away near a rail | Josh Filler lock-up vs Shane Van Boening (Mosconi Cup); Han Yu lock-up vs Van Boening (World Pool Masters)[^ddshots] | `class=safety`; `Rₒ ≤ 0.10`; opponent's best reply EV leaves us `W ≥ 0.65`; `ΔW ≥ +0.15`; `Pb ≤ 0.5` (hard to execute at that quality) | Yes |
| **B2** | **Escape kick that pots** | Shooter is snookered (no direct path to a legal ball), kicks off one or more rails, pockets the ball, keeps position | **Efren Reyes "Z-shot"**, Sands Regency XXI final, hill-hill vs Earl Strickland, 11 Jun 1995: two-rail kick on the 5 into the corner with shape on the 6. A miss would probably have lost the match.[^bd30][^pd] Earl Strickland kicking the 8 in to win; Albin Ouschan long kick (Mosconi Cup)[^ddshots] | `W₀ ≤ 0.35` and no direct pot candidate; `class=kick`; made; `ΔW ≥ +0.30`; `Pb ≤ 0.25` | Yes (kick) |
| **B3** | **Escape kick that plays safe** | Snookered shooter kicks, makes a legal hit, and leaves the opponent hooked or far | Efren Reyes kick-bank safety escape vs Steve Davis; Alain Martel kick-rail-jump safety escape[^ddshots] | `W₀ ≤ 0.35`; `class=kick` + safety intent; legal hit; `Rₒ ≤ 0.20`; `ΔW ≥ +0.20` | Kick yes; jump **no** |
| **B4** | **Two-way shot** | A pot attempt whose miss branch also leaves the opponent in trouble. Chosen over a "safer pot" with higher P(make) but a disastrous miss branch | Shane Van Boening 2-9 two-way combo to win a match (Mosconi Cup)[^ddshots]; Dr. Dave: on a difficult shot (e.g. a bank) "use two-way shots where possible"; three-rail two-way end-game shot[^ddsafe][^ddend] | `EV(make-branch)` high **and** `EV(miss-branch) ≥ 0.45`; `ĉ ≠ argmax P(make)`; `L ≤ ε`; made, **or** missed with `Rₒ ≤ 0.20` | Yes |
| **B5** | **Deliberate miss / "leave nothing"** (the user's example) | Shooter has a pot available but deliberately doesn't pot, playing so the opponent can't make the next shot. This is the pool "sacrifice" of the turn | Dr. Dave: "If you're less than about 70% sure of a shot, look for a safety that is significantly better"; in 9-ball, "bury the next ball and/or the cue ball"[^dd8][^dd9] | A pot candidate existed with `Ps ≥ 0.4`, but `ĉ=safety` and `EV(safety) − EV(best pot) ≥ +0.05`; result `Rₒ ≤ 0.15`; `ΔW ≥ +0.10` | Yes |
| **B6** | **Tactical intentional foul** | Fouling on purpose (gives ball in hand) to tie up the opponent's balls, block a pocket, dump their hanger, or dump their break-out ball. The pool equivalent of a piece sacrifice | Dr. Dave, *Intentional Fouls* (BD Mar 2026): tie up the 2 with the 5; send the 8 between the 1 and 11 to block a pocket; dump an opponent hanger via the 3-11 combo; dump the opponent's break-out ball; end-game 8-ball tie-up when snookered on the 8[^ddfoul] | `class=intentionalFoul`, `intended=true`; `W₁ ≥ W₀ − 0.02` despite ball in hand; opponent's P(run-out with BIH) ≤ 0.35; `L ≤ ε` | Yes (needs foul-intent candidates) |
| **B7** | **Cluster breakout with insurance** | Pot a ball and in the same stroke break a cluster with the cue ball, keeping an insurance ball for position | Dr. Dave 8-ball principles: break out clusters "when an insurance ball is available, using as little speed as necessary"[^dd8] | made; count of "runnable" balls for the shooter rises by ≥ 2; P(run-out) after rises by ≥ 0.20; `Pb ≤ 0.5` | Yes |
| **B8** | **Game-winning combo / carom** | Win the rack with a combo or carom on the money ball (9-ball D13: combos and caroms on the 9 win) instead of running out | Shane Van Boening kick-jump-carom for the win; Corey Deuel rail-first carom for the win[^ddshots] | `class ∈ {combo, carom}`; game ends with a win; `W₀ ≤ 0.70`; `Pb ≤ 0.35`; `L ≤ ε` (it really was better than playing on or safe) | Yes (combo/carom); jump **no** |
| **B9** | **Clutch money-ball bank / kick** | A low-percentage bank or kick on the money ball to win, when it beat the safe option on EV | David Alcaide 9-ball bank to win the World Pool Masters; Chris Melling's 8-ball run-out ending in a four-rail bank; Jayson Shaw two-rail massé kick on the 8 to win[^ddshots][^az25] | Money ball made, win; `class ∈ {bank, kick}`; `Pb ≤ 0.30`; `ΔW ≥ +0.40`; `L ≤ ε` | Bank/kick yes; massé **no** |
| **B10** | **Push-out trap** (9-ball) | A push-out that leaves a shot the shooter can make but the opponent can't. Either the opponent passes and the shooter converts, or the opponent tries and fails | Forum consensus: "leave something you can do, but your opponent can't"; against pros a push to a jump or a kick-safe[^push1][^push2] | `class=pushOut`; `min(EV_opp_shoots, EV_opp_passes)` for the shooter `≥ 0.55`; realized `ΔW ≥ +0.15` after the opponent's choice resolves | Yes |
| **B11** | **Swing safety (safety-battle winner)** | A safety from a losing position that hands the opponent a likely loss, so the rack flips | Dr. Dave: safeties that "force difficult kicks", maximize distance, keep the OB off rails and pockets[^ddsafe] | `W₀ ≤ 0.40`, `W₁ ≥ 0.60`; `class=safety`; `Rₒ ≤ 0.15` | Yes |

Classes the 2D engine can't generate (**jump**, **massé**, scoop-free jump escapes) can be *observed* through the
tracker: the cue ball passes over a blocker's footprint, or its curve departs from the predicted path. Without
alternatives to compare against, they can't be scored. `[UD-2]`: show them as "Great" (impact only), or wait until
the engine models elevation.

### 3.2 "Non-obvious" (the creativity gate)

Brilliant needs a shot an average player would not pick. The test: `obvious(ĉ) = false` if **any** of these hold:

| Test | Rule |
|---|---|
| Naive-policy rank | `ĉ` is **not** the top choice of a naive policy ("pot the highest-P(make) legal ball, ignore position and leave"), *and* the naive pick's EV is ≥ 0.05 below `EV(c*)` |
| Creative class | `class(ĉ) ∈ {kick, bank, combo, carom, safety, intentionalFoul, pushOut}` |
| Sacrifice | `ĉ` gives up the turn, ball in hand, or a ball, while a pot with `Ps ≥ 0.4` was on |

`[UD-3]`: should a plain cut pot ever qualify as Brilliant (e.g. B7 cluster breakout with a straight-in pot)? This
proposal says yes, but only through the naive-policy test.

### 3.3 What is *not* Brilliant (anti-cases)

| Case | Why | Proposed rating |
|---|---|---|
| Fluke / slop pot | Outcome ≠ intent | Decision by `L`; Execution = Miss (or "Lucky" `[UD-9]`) |
| Hard bank made when an easy safety was much better | High risk, `L` large | **Mistake / Blunder + Made**. "Right result, wrong choice" |
| Easy pot while `W₀ ≥ 0.90` | Already winning (chess.com rule) | Best |
| Great lockdown that the opponent escapes anyway | Execution fine; impact comes later | Brilliant still allowed: rate on `Rₒ` at settle, not on the opponent's luck. `[UD-4]` |
| Intentional foul that leaves the opponent an easy run-out | `W₁ ≪ W₀` | Mistake / Blunder by `L` |

---

## 4. Proposed rating algorithm

### 4.1 Decision rating, in priority order

```
input: L, G, W₀, W₁, ΔW, Pb, Rₒ, class(ĉ), obvious(ĉ), intentConfidence, intendedOutcomeHappened, foul, intended

1. if intentConfidence ≥ κ and intendedOutcomeHappened and L ≤ ε_B and not obvious(ĉ)
      and W₀ ≤ W_max and W₁ ≥ W_floor and ΔW ≥ Δ_B
      and (Pb ≤ P_B or class(ĉ) ∈ creative) and matches some B1–B11 signal set
      → BRILLIANT !!
2. if intendedOutcomeHappened and L ≤ ε_G and W₀ ≤ W_max
      and (G ≥ G_only                      // only good move
           or (W₀ < 0.40 and W₁ ≥ 0.50)    // losing → equal
           or (W₀ < 0.60 and W₁ ≥ 0.70))   // equal → winning
      → GREAT !
3. L ≤ ε_best            → BEST
4. L ≤ t_good            → GOOD
5. L ≤ t_inacc           → INACCURACY ?!
6. L ≤ t_mistake         → MISTAKE ?
7. otherwise             → BLUNDER ??
Override: unintended foul with ΔW ≤ −t_foul → at least MISTAKE; ≤ −t_blunder → BLUNDER.
```

### 4.2 Thresholds (ranges to calibrate)

Win probability is in points of `W` (0–1).

| Parameter | Meaning | Chess.com analogue | Proposed start | Calibrate within |
|---|---|---|---|---|
| `ε_best` | Max loss for "Best" | Best + Excellent (0–0.02) | 0.03 | 0.02–0.05 |
| `t_good` | Good upper bound | 0.05 | 0.07 | 0.05–0.10 |
| `t_inacc` | Inaccuracy upper bound | 0.10 | 0.13 | 0.10–0.18 |
| `t_mistake` | Mistake upper bound (above = Blunder) | 0.20 | 0.25 | 0.20–0.35 |
| `ε_B`, `ε_G` | Max loss to stay eligible for Brilliant / Great | "best or nearly best" | 0.03 | 0.02–0.05 |
| `Δ_B` | Min realized WPA for Brilliant | — | +0.15 | +0.10 – +0.25 |
| `P_B` | Max baseline P(intended) for "hard" | — | 0.35 | 0.25–0.50 |
| `W_max` | "Already winning" cutoff | "not already completely winning" | 0.90 | 0.85–0.95 |
| `W_floor` | Brilliant must not leave you worse than this | "must not leave you in a bad position" | 0.50 | 0.40–0.55 |
| `G_only` | "Only move" gap to second best | "only good move" | 0.12 | 0.08–0.20 |
| `κ` | Min intent confidence to promote | — | 0.7 | 0.6–0.8 |
| `t_foul`, `t_blunder` | Foul override bounds | — | 0.10 / 0.25 | 0.08–0.30 |

**Why wider than chess.** One pool shot moves rack win probability far more than one chess move moves expected
points: a miss in 9-ball often hands over a run-out. Chess bands applied as-is would turn ordinary misses into
Blunders. The ranges start wider. Tune them so the class frequencies in §4.4 hold.

**Monte Carlo noise floor.** At N simulations, the standard error of an EV is about `√(p(1−p)/N)`, roughly 0.016 at
N = 1000 and p = 0.5. Any band narrower than about 2 SE is noise. Rule: if the confidence intervals of `EV(ĉ)` and
`EV(c*)` overlap, `L := 0` (Best). This keeps `ε_best ≥ 0.02` and ties the minimum N to the on-device eval budget
(< 3 s, Phase 2 gate).

### 4.3 Worked examples (to become unit fixtures)

| Situation | `W₀` | `ĉ` | `L` | `Pb` | Result | `W₁` | Rating |
|---|---|---|---|---|---|---|---|
| Efren Z-shot analogue: snookered, two-rail kick pots and leaves shape | 0.25 | kick | 0.00 | 0.12 | made | 0.85 | **Brilliant !! / Made** (B2) |
| Pot available (`Ps` 0.45), player buries the CB instead; opponent has nothing | 0.50 | safety | 0.00 | 0.40 | `Rₒ` 0.05 | 0.78 | **Brilliant !! / Made** (B5) |
| 8-ball: tie up the opponent's ball on purpose, BIH given (Dr. Dave Image 1) | 0.30 | int. foul | 0.01 | 0.60 | intended | 0.50 | **Brilliant !! / Made** (B6; creative class, `ΔW` +0.20) |
| Same tie-up, but the opponent keeps a decent break-out | 0.30 | int. foul | 0.02 | 0.60 | intended | 0.40 | **Best / Made** (`ΔW` +0.10 < `Δ_B`; `W₁` < 0.50 so not Great) |
| Only one shot doesn't lose: thin cut, others lose 0.2+ | 0.55 | direct | 0.00 | 0.55 | made | 0.80 | **Great !** (`G` 0.2) |
| Easy stop-shot on the 9 for the win | 0.95 | direct | 0.00 | 0.97 | made | 1.00 | **Best / Made** |
| Slight wrong side on position | 0.70 | direct | 0.05 | 0.80 | made | 0.62 | **Good / Made** (position: OK) |
| Long bank made when an easy safety was much better | 0.50 | bank | 0.22 | 0.20 | made | 0.85 | **Mistake ? / Made** |
| Scratches on an easy 8 | 0.92 | direct | 0.00 | 0.90 | foul, loss | 0.00 | **Blunder ?? / Miss** via the spec's foul override, though the decision was fine `[UD-5]` |
| Shoots the 8 early on an open table in bar rules | 0.50 | — | 0.50 | — | foul loss | 0.00 | **Blunder ??** |

### 4.4 Target class frequencies (calibration targets)

| Class | Target share of competitive shots | Rationale |
|---|---|---|
| Brilliant !! | ≤ 1–2% (about 1 per 2–3 racks of amateur play) | Must feel rare, like chess.com's |
| Great ! | 3–6% | |
| Best | 35–50% | |
| Good | 15–25% | |
| Inaccuracy ?! | 10–15% | |
| Mistake ? | 5–10% | |
| Blunder ?? | 2–6% | |

`[UD-6]`: confirm these targets, especially how rare Brilliant should be.

---

## 5. Execution rating

Execution answers "did the intended thing happen?" It is independent of the Decision rating.

| Intent | **Made** | **Near miss** | **Miss** |
|---|---|---|---|
| Pot (direct, bank, combo, kick-pot, carom) | Intended ball in the intended (called) pocket, no foul | Object ball reached the jaws, or its path came within 1 ball width of the pocket mouth | Otherwise |
| Safety / deliberate miss | Legal hit **and** `Rₒ ≤` target (proposed 0.25) | Legal hit, `Rₒ` 0.25–0.45 | Foul, or `Rₒ > 0.45` |
| Intentional foul | Tie-up / block / dump achieved (the target ball's state matches the candidate) | Partial | Not achieved |
| Push-out | Opponent's best `EV ≤ 0.45` for them | 0.45–0.55 | > 0.55 |
| Break | Legal, ≥ 1 ball down, CB not scratched | Legal, nothing down | Foul / scratch |

**Position-play sub-result** (pots only, and only when the turn continues):
`r = next-shot value achieved / next-shot value planned by ĉ`.

| Position | Rule | Visual (no text while aiming; this is post-shot) |
|---|---|---|
| **Perfect** | `r ≥ 0.9` | Green ring at the CB rest spot |
| **OK** | 0.6 ≤ `r` < 0.9 | Yellow ring |
| **Out of line** | `r` < 0.6 | Red ring + ghost of the planned spot |

Post-shot badge (spec §2: icon + color + ≤ 2 words): **one** word for the decision class, plus an execution icon.
Possible layout: `!! Brilliant` with a check, a dashed check, or a cross for Made / Near miss / Miss. `[UD-7]`
decides which of the two appears as the word.

---

## 6. Open design calls inside the algorithm

### 6.1 Reference skill for `EV` and `Pb`

| Option | `EV` / `L` computed with | `Pb` computed with | Effect |
|---|---|---|---|
| **A (proposed)** | The shooter's own skill model | A fixed "club player" reference | Fair "best for *you*" choices; "hard" means hard for a typical player |
| B | Fixed reference for both | Reference | Comparable across players; harsh on beginners |
| C | Shooter skill for both | Shooter | Brilliant becomes "hard for you". A beginner's routine cut could be Brilliant |

`[UD-8]`

### 6.2 Rack vs match context

The engine's `W` is rack-level. Efren's Z-shot came at hill-hill, where the rack *was* the match. Proposal: rating
uses rack `W` only. A separate **clutch flag** (spec §6) marks shots where the match is on the hill, and Shot of
the Game gets the match bonus. `[UD-10]`: should match state also lower `Δ_B` or `P_B` for Brilliant?

### 6.3 Skill generosity (chess.com judges new players more generously)

Proposal: with option A, generosity comes for free, since `L` uses the player's own noise. Optionally, scale
`ε_B` and `P_B` up by up to 1.5× for players with fewer than 50 competitive shots. `[UD-11]`

### 6.4 Bar 8-ball etiquette

In bar culture, safeties and intentional fouls can be seen as "dirty pool". Dr. Dave notes that bar rules often
expect every safety to come from an honest attempt to pot a ball.[^ddbar] Our bar rules allow safeties (rules-notes
B22). `[UD-12]`: should B5 / B6 be eligible for Brilliant in bar 8-ball? Proposal: yes, because D2 explicitly names
deliberate misses.

### 6.5 "Miss" (chess.com's failed-to-punish class)

Our 7 classes have no "Miss". Proposal: fold it into the loss ladder. Failing to exploit a big opponent error
already shows up as a large `L`. `[UD-13]`: add an 8th class instead?

---

## 7. Implementation notes (for the Phase 2 worker)

- `rate(chosen:outcome:eval:)` must be a **pure function** of `Evaluation` + `ShotTrace` + thresholds. Keep the
  thresholds in a `RatingThresholds` struct so tests and calibration can sweep them.
- Add fields to `Evaluation`: `bestEV`, `secondEV`, `ev(of:)`, the EV confidence interval, `baselinePMake(of:)`,
  `opponentBestReply(post:)`, `naivePick`, and the miss-branch EV per candidate (needed for B4).
- New `Candidate.class` cases are needed for `intentionalFoul` (target: tie-up / block / dump) and `pushOut`.
  Jump and massé stay out until the physics models elevation.
- Store `L`, `ΔW`, `Pb`, the matched B-class, and the intent confidence per shot in competitive stats (spec §6), so
  calibration can replay real sessions.
- TDD fixtures: every row of §4.3, plus one fixture per B-class (§3.1), built as hand-made `TableState`s.

---

## 8. Decisions needed from the user

| # | Question | Proposal |
|---|---|---|
| UD-1 | Allow a one-tap "I meant safe / I meant this pocket" correction in game review, changing the rating? | Yes, review screen only |
| UD-2 | Jump and massé shots (engine can't simulate them in v1): rate them Great on impact alone, or don't rate them? | Great on impact, never Brilliant until simulated |
| UD-3 | Can a plain direct pot be Brilliant (via the naive-policy test)? | Yes |
| UD-4 | Judge a lockdown at settle (`Rₒ`) even if the opponent escapes with a miracle? | Yes, judge at settle |
| UD-5 | Spec §5.5 says a foul that swings `W` hard is a Blunder. Apply that to pure execution fouls (e.g. scratch on a correct, easy 8), or only to fouls caused by the choice? | Keep spec (Blunder) for v1; revisit after calibration |
| UD-6 | Target class frequencies (§4.4), especially Brilliant ≤ 1–2% | As listed |
| UD-7 | Which word shows on the post-shot badge: the decision class, or the execution result? | Decision word + execution icon |
| UD-8 | Skill reference for `EV` / `Pb` (§6.1) | Option A |
| UD-9 | Show a "Lucky" execution tag for flukes? | Yes, icon only |
| UD-10 | Should match context (hill-hill) affect Brilliant thresholds? | No; clutch flag + SotG bonus only |
| UD-11 | Extra generosity for new players (< 50 shots)? | Yes, up to 1.5× on `ε_B`, `P_B` |
| UD-12 | Safeties and intentional fouls eligible for Brilliant in bar 8-ball? | Yes (per D2) |
| UD-13 | Add a chess.com-style "Miss" class? | No; keep the 7 classes |
| UD-14 | Starting thresholds in §4.2 | As listed; tune on the 20-position gate set |
| UD-15 | Catalogue B1–B11: anything to add or drop? | As listed |

---

## Sources

[^cc]: Chess.com Help, "How are moves classified?": https://support.chess.com/en/articles/8572705-how-are-moves-classified-what-is-a-blunder-or-brilliant-and-etc
[^li]: Lichess source, `Advice.scala` (winning-chance thresholds .1 / .2 / .3): https://github.com/lichess-org/lila/blob/master/modules/tree/src/main/Advice.scala
[^liacc]: Lichess, "Accuracy" (win% from centipawns, empirical): https://lichess.org/page/accuracy
[^bd30]: Billiards Digest, "30 over 30" #18 (Reyes, Sands Regency XXI, 11 Jun 1995): https://www.billiardsdigest.com/new_30over30/18.php
[^pd]: PoolDawg, "The Greatest Pool Shot Ever?" (Reyes vs Earl Strickland, hill-hill): https://www.pooldawg.com/article/the-greatest-pool-shot-ever/
[^ddshots]: Dr. Dave Alciatore, "Great Pool Shots" video index (Filler, Han Yu, Van Boening, Alcaide, Ouschan, Thorpe, Shaw, Deuel, Martel, Reyes): https://drdavepoolinfo.com/videos/pool-shots/
[^az25]: AZBilliards forum, "Top 25 Best Pool Shots of All Time" (Dr. Dave video; Melling four-rail bank, Reyes Z-kick): https://forums.azbilliards.com/threads/top-25-best-pool-shots-of-all-time.531212/
[^ddsafe]: Dr. Dave, "Safety Strategy Advice": https://drdavepoolinfo.com/faq/safety/strategy/
[^ddend]: Dr. Dave, "End-Game Situation Strategy" (three-rail two-way): https://drdavepoolinfo.com/faq/strategy/end-game/
[^dd8]: Dr. Dave, "What are some examples of good 8-ball strategy?": https://drdavepoolinfo.com/?p=2528
[^dd9]: Dr. Dave, "What are some examples of good 9-ball strategy?": https://drdavepoolinfo.com/?p=2530
[^ddfoul]: Dr. Dave, "Intentional Fouls", Billiards Digest, March 2026 (NV L.108): https://drdavepoolinfo.com/bd_articles/2026/march26.pdf
[^ddbar]: Dr. Dave, "Bar Rules and Dirty Pool", Billiards Digest, June 2025: https://drdavepoolinfo.com/bd_articles/2025/june25.pdf
[^push1]: AZBilliards forum, "What is your goal when you push out?": https://forums.azbilliards.com/goto/post?id=5348076
[^push2]: AZBilliards forum, "Push Out Strategies": https://forums.azbilliards.com/threads/push-out-strategies.13958

Background, not cited above: Accu-Stats TPA = balls made ÷ (balls made + errors), with errors = missed shot,
position, kick, break scratch, failed safety (https://drdavepoolinfo.com/?p=2392). This suggests an optional
"accuracy %" per player. FargoRate's game-win odds = 2^(Δrating/100) (https://drdavepoolinfo.com/?p=2404) could
seed default skill models.

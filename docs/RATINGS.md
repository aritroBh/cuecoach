# Shot ratings and "Brilliant": research, numbers, compute and timing (rev 2)

Status: **draft, awaiting user review.** Product choices are tagged `[UD-n]`; the full list is in §12.

**How this relates to `docs/RATING_CLASSES.md` (D18).** D18 is the authority on the **10 classes, their order and
their rules**. This doc does not change them. It supplies what D18 leaves open: exact signal definitions, the
statistics that make a 2-point Loss band measurable, intent inference, the brilliant-shot catalogue, the compute
budget, when the badge appears, calibration, and the interface and schema deltas. Where I think a D18 rule should
change, it is raised as a `[UD]`, not applied.

Rev 2 fixes the 17 reviewer issues. §13 lists what changed and the two points I only partly accepted.

---

## 1. What chess.com and Lichess do

| System | Scale | Inaccuracy / Mistake / Blunder | Brilliant / Great |
|---|---|---|---|
| **Chess.com**[^cc] | Expected points, 0–1, rating-aware | Loss 0.05–0.10 / 0.10–0.20 / > 0.20 (Best 0, Excellent ≤ 0.02, Good ≤ 0.05) | Brilliant: best or nearly best **plus a good sacrifice**, not already winning, judged more generously for new players. Great: "critical", or the only good move |
| **Lichess**[^li][^liacc] | `winningChances` on **−1..1** (`2/(1+e^(−0.00368·cp)) − 1`; Win% = 50 + 50·that) | Δ ≥ 0.1 / 0.2 / 0.3 on −1..1, which is **0.05 / 0.10 / 0.15 on a 0–1 scale** | None |

So on our 0–1 scale, Lichess is *stricter* than chess.com at the Blunder end (0.15 vs 0.20). D18 uses 0–100 pts:
Best ≤ 2, Good 2–5, Okay 5–8, Inaccuracy 8–15, Mistake 15–30, Blunder at a Swing of ≤ −30. That sits between the two
and is wider at the top. That is right for pool: one missed pot often hands over a run-out, which one chess move
rarely does.

**What we borrow.** Rate the *choice* by ex-ante loss of win probability, and the *result* by realized swing.
"Sacrifice" maps to giving something up on purpose: the turn (safety or deliberate miss), ball in hand
(intentional foul), or a sure pot traded for a better plan.

---

## 2. Signals (definitions, perspective, cost)

**Perspective rule:** every W is the **rated shooter's team's** rack win probability (D17 team play), before and
after the turn passes. "Opponent" means the **next opposing shooter in the rotation**, with that player's own
`SkillModel` (engine.md §5.4 `SkillContext`).

**Units:** EV is in W units. The engine's value function (engine.md §6.1) computes the expectation of W over noisy
samples. That generalises spec §5.5.3 (P(make)·value(position) + (1−P)·value(left to opponent)) and is equal to it
when every outcome is "made, turn continues" or "missed, turn passes". It is **a spec amendment** `[UD-19]`, already
flagged by the engine track.

| Symbol | Definition | Computed by | Cost |
|---|---|---|---|
| `W₀` | `winProbability(pre)`, shooter to play | WP model (engine.md §6.4) | cheap (~5 µs) |
| `W₁` | `winProbability(post)` after `RulesEngine.apply`, including turn pass, BIH and the foul count | WP model | cheap |
| **Swing** `ΔW` | `W₁ − W₀` | — | cheap |
| `EV(c)` | Mean W over N noisy samples of candidate c (shooter σ, CRN seeds, §2.2) | Full pass + rating top-up | **expensive** |
| `c*`, `c₂` | Best and second-best generated candidate by EV | Full pass (Sequential Halving) | (already paid) |
| `ĉ` | Chosen candidate, from intent inference (§2.1). If no candidate fits (> 3σ), the **observed-stroke candidate** from `score(stroke:)` | intent matcher | cheap |
| **Loss** `L` | `EV(c*) − EV(ĉ)` on paired CRN samples. Set to 0 if `L < z·SE_L` (§2.2) | rating top-up | **expensive** |
| `SE_L` | Standard error of the **paired difference** `W_i(c*) − W_i(ĉ)` across samples i | rating top-up | free with it |
| `G` | Only-move gap `EV(c*) − EV(c₂)` | top-up at 256 samples | medium |
| **Difficulty** `D` | This player's P(intended outcome) for ĉ: analytic P(make) (engine.md §4.3) for pots; for safeties, the share of ĉ's samples that hit legally and leave `Rₒ ≤ 0.20` | analytic / samples | cheap |
| `Rₒ` | **Opponent's best make chance** after the actual result: max analytic P(make) over the opponent's legal pot candidates (kicks included) under the opponent's σ. One quantity, as D18's Brilliant rule needs | Quick pass on the post state (≤ 150 ms) | cheap |
| `Pbest_pot,pre` | Shooter's best pot P(make) before the shot (D18 Brilliant safety rule) | Quick pass, pre | cheap |
| `EV_miss(c)` | Mean W over ĉ's *missed* samples (two-way test) | same samples, partitioned | free |
| `naiveRank` | Rank of ĉ under "pot the highest-P(make) legal ball" | analytic | cheap |
| `R_run` | Shooter's run-out probability (engine.md §6.4) | WP model | cheap |
| `runnable` | Shooter's legal targets with a clear direct capsule and P(make) ≥ 0.5 under the shooter's σ | Quick pass | cheap |
| `trackerOK` | Every ball's position SD ≤ 1.5 cm and ID confidence ≥ the tracker's threshold, for the pre and post states | Tracking | cheap |

The expensive signals are only `EV`, `L`, `SE_L` and `G`. Everything else comes from the analytic WP model or a
Quick pass. That is what makes the budget in §8 work.

### 2.1 Intent inference

Every Great or Brilliant rests on this, so it is specified fully.

**Observable features only.** From the tracker: cue-ball **launch direction** and **launch speed** (first ~5
frames), **first contact**, **object-ball departure direction**, and the called pocket (WPA modes, spec §3). Tip
offset is **not** observable from a tripod camera, so it is not a feature. The spin implied by the CB's post-contact
curve is too confounded with speed and throw to use for intent (it is used only for the skill model's weak speed
residual, engine.md §5.2).

**Likelihood.** `ℓ(c) = N(launchDir; φ_c, σ_φ) · N(log launchSpeed; log V_c, σ_V) · 1[firstContact consistent with c]`.
It uses the shooter's σ, and a Student-t (ν = 4) instead of the Gaussian for robustness, matching engine.md §5.3.
The "consistent" factor is soft (0.05, not 0) because a thin miss can change the first contact.

**Prior: uniform over plans, not over variants, and with no EV term.** A plan is (target, pocket, kind), or
"safety" as one plan. Each plan gets equal mass, split evenly over its deduplicated stroke variants.
- *Why not EV-weighted:* it would pull intent toward `c*` and bias L down, which is the very thing we are measuring.
- *Why plans, not variants:* the safety grid produces up to 432 variants, and a uniform-over-variants prior would
  make "safety" win every ambiguous stroke.
- A per-player frequency prior (how often this player plays safe) is a v2 option once there is data.

**Posterior** `π(c) ∝ prior(c)·ℓ(c)`. `intentConfidence = π(ĉ)`. **κ = 0.7** (range 0.6–0.8).

**Safety needs a margin.** ĉ is a safety only if `ℓ(best safety) / ℓ(best pot) ≥ λ`, with **λ = 4** (range 3–10).
Otherwise ĉ is the best-matching pot, i.e. a *missed pot*. A missed pot is **never** promoted, however good the
leave. This stops "badly missed pot that happened to hook the opponent" from becoming a B5/B11 Brilliant.

**Called pocket** overrides the pocket of a pot plan (WPA modes). In bar 8-ball only the 8 is called (RULES B1).

**Fluke rule** (blocks Great and Brilliant). The result is a fluke if (a) a pot plan's ball went in a different
pocket, or a different ball went in, (b) a safety plan potted a ball (bar slop keeps the turn, RULES B18/B22), or
(c) the realized outcome is more likely under another plan than under ĉ (posterior over plans given the outcome).
A fluke is still rated by Loss. Its Execution is "Miss", with the "Lucky" icon `[UD-9]`.

**Bar slop and safety intent.** If a safety plan slop-pots a group ball, the turn continues (bar rules). The
intended outcome (opponent to shoot, hooked) did **not** happen, so the shot is a fluke. Loss is unaffected
because the samples already include slop outcomes.

**Corrections `[UD-1]`.** A one-tap "I meant safe / I meant this pocket" in the game review re-runs `rate` with
the corrected ĉ. Proposal: a correction **can change Loss-based classes but can never promote to Great or
Brilliant**, and it is logged as `attributionSource = tap`. So it can't be used to farm Brilliants, Safety Chess
archetype points or WPA.

**Adversarial fixtures** (must hold):
1. Missed thin cut whose miss leaves the opponent hooked, and a safety stroke is 2× less likely than the pot:
   intent = pot, class by Loss, no promotion.
2. Same, but the stroke is soft and 6× more likely as a safety: intent = safety, may be Great.
3. Safety stroke that slop-pots a ball in bar 8-ball: fluke, no promotion.
4. Two pocket plans equally likely (π 0.45 / 0.45): confidence < κ, no promotion, Loss uses the π-weighted EV.
5. Correction from pot to safety on a shot that would then qualify as Great: stays at the Loss-based class.

### 2.2 Making a 2-point band measurable

**The old rule was wrong** (reviewer issue 1). Overlapping CIs aren't a test of the difference. The SE of a
difference of independent means is √2× bigger, and at N = 1000 the rule erased everything below ~0.06.

**New rule.**
1. **Common random numbers.** Sample i of every candidate uses the same noise vector (engine.md §6.3:
   counter-based seeds, antithetic pairs). The same seed also draws the **ball-position perturbation** (§2.3), so
   both candidates see the same perceived table.
2. Compute `d_i = W_i(c*) − W_i(ĉ)`, `L = mean(d)`, `SE_L = sd(d)/√N`.
3. If `L < z·SE_L` with **z = 1.645** (one-sided 95%), set `L := 0` (Best). Otherwise use L as measured.
4. Pick N so that `z·SE_L ≤ 0.02` (the Best band).

**Arithmetic.** Per-sample SD of W, `s ≈ 0.30`. That is conservative: a 50% pot with W 0.8 made / 0.3 missed has
SD 0.25. CRN correlation ρ between the two candidates varies: about 0.9 for two variants of the same pot, about 0
for pot vs safety. `SE_L = s·√(2(1−ρ)/N)`, so the N needed for `z·SE_L ≤ 0.02` is `2(1−ρ)(z·s/0.02)²`:

| ρ | 0 (pot vs safety) | 0.5 | 0.7 | 0.9 (same pot, other spin) |
|---|---|---|---|---|
| N needed | 1218 | 609 | 365 | 122 |

**Chosen:** `N_rate = 1024` paired samples for ĉ and c\*, and 256 for c₂ (G only has to clear 10 pts). This is
the probability that a shot whose true Loss sits at a band's midpoint gets that band (normal approximation,
computed in the scratchpad):

| True Loss (band midpoint) | ρ = 0, N = 1024 | ρ = 0.7, N = 1024 | ρ = 0, N = 512 (thermal `.serious`) |
|---|---|---|---|
| 0.035 (Good) | 71% | 96% | 38% |
| 0.065 (Okay) | 74% | 96% | 58% |
| 0.115 (Inaccuracy) | 99% | 100% | 94% |

Pot vs safety at ρ ≈ 0 is the hard case. Good and Okay are reachable but noisy there. Under thermal throttling the
rule degrades gracefully: more Goods become Best, never harsher.
- `[UD-14]`: if the Phase 2 benchmark shows typical ρ < 0.3, accept the noisy Good/Okay bands, or let the rating
  pass run longer (the budget allows ~2×).
- **Unit fixture (band reachability).** A synthetic two-arm bandit with true gaps 0.01 / 0.035 / 0.065 / 0.115 /
  0.20 at ρ ∈ {0, 0.7}, N = 1024, 200 seeds. Assert hit rates ≥ the table above minus 5 points, and that true
  Loss 0.01 is Best in ≥ 95%.

### 2.3 Tracking error

Ball positions from the homography carry ~0.5–1 cm error (engine.md R2), and thin cuts and banks are very
sensitive to it.
- **Propagate it.** Each MC sample also draws a position offset for every ball from the tracker covariance
  (default isotropic 6 mm until Phase 3 measures it). The draw is shared across candidates (CRN), so it widens EV
  but barely widens L.
- **Sensitivity fixture.** For each B-class fixture and each §5 row: perturb all positions 20× by the Phase 3 error
  budget (1 cm SD). The class must be unchanged in ≥ 90% of runs, and otherwise move at most one adjacent band.
- **Low confidence.** If `trackerOK` is false, no promotion (no Great or Brilliant), and the shot is rated by Loss
  only. `[UD-21]`

---

## 3. Brilliant-shot catalogue (B1–B12)

The catalogue **does not gate** Brilliant. D18's five criteria do. A B-tag explains *why* a shot was special. It
is stored per shot and drives the review caption and archetype features (e.g. B1/B11 → Safety Chess).
`[UD-3]` covers whether to add the spec's "non-obvious" test as an extra gate.

**v1 column:** **Gen** means the engine generates the shot and its alternatives, so Loss is meaningful. **Obs**
means it is not generated, but the observed stroke is simulated by `score(stroke:)` with the same seeds, so its EV
is compared against the generated set. **Book** is D18 class 1, never rated. **No** means the 2D physics can't
simulate it (jump, massé).

| # | Class | Definition | Real cases (sourced) | Signals | v1 |
|---|---|---|---|---|---|
| **B1** | Lockdown safety | Leaves no makeable shot and no good return safety | Josh Filler "lock-up safety against Shane VanBoening in Mosconi Cup"; "Han Yu lock-up safety against Shane Van Boening in World Pool Masters"[^ddshots] | safety (by λ margin); `Rₒ ≤ 0.10`; Swing ≥ +15 | Gen |
| **B2** | Escape kick that pots | Snookered, kicks, pockets, keeps shape | **Efren Reyes Z-shot**, Sands Regency XXI, hill-hill vs Earl Strickland, 11 Jun 1995[^bd30][^pd]; Earl Strickland "kicking the 8 in for the win"[^ddshots] | no clear direct pot; kick; made; Swing ≥ +30 | Gen |
| **B3** | Escape kick that plays safe | Snookered, kicks, legal hit, opponent hooked | Efren Reyes "kick bank safety escape against Steve Davis"[^ddshots] | kick + safety intent; legal; `Rₒ ≤ 0.20` | Gen (Martel's "kick-rail-jump" escape: **No**) |
| **B4** | Two-way shot | Pot attempt whose miss branch also leaves the opponent bad | SVB "two-way shot 2-9 combo to win a Mosconi Cup Match"; Earl Strickland "kick-bank 2-way shot"[^ddshots] | `EV_miss(ĉ) ≥ 0.45`; ĉ ≠ naive pick; made, or missed with `Rₒ ≤ 0.20` | Gen (miss branch = same samples, free) |
| **B5** | Deliberate miss / leave nothing (D2) | Pot available, plays safe instead, opponent has nothing | AZB contributor 8onthebreak (quoted on Dr. Dave's page): "If you are less than 70% sure you'll make the shot…start looking for a safety."[^dd8] KellyStick: "you really need to bury the next numbered ball and/or CB in a defense"[^dd9] | safety by margin; `Pbest_pot,pre ≥ 0.4`; `EV(ĉ) − EV(best pot) ≥ +0.05`; `Rₒ ≤ 0.15` | Gen |
| **B6** | Tactical intentional foul | Foul on purpose to tie up, block, or dump a ball | Dr. Dave, *Intentional Fouls* (BD Mar 2026): tie up a ball, block a pocket with the 8, dump a hanger, dump the break-out ball[^ddfoul] | foul; `W₁ ≥ W₀ − 0.02`; `L ≤ 0.02` vs generated options | **Obs**. Under D18 every BIH foul is Mistake, so B6 can't be Great/Brilliant unless `[UD-5]` changes it |
| **B7** | Cluster break-out with insurance | Pot and break a cluster, insurance ball kept | Dr. Dave's 8-ball summary: "Break out clusters when there is an insurance ball available, and use as little speed as necessary"; Robert Byrne (rule 7, quoted on the same page)[^dd8] | made; `runnable` count +2 or more; `R_run` +0.20 or more | Gen |
| **B8** | Money-ball combo / carom (9-ball, D13) | Wins with a combo or carom instead of running out | Earl Strickland "two-rail kick combo for the win"; Efren Reyes "kick carom for the win"; Jayson Shaw "two-way bank carom for the win"[^ddshots] | combo/carom; win; `W₀ ≤ 0.70`; `L ≤ 0.02` | combo **Gen**; carom **Obs** (carom candidates are v2, engine.md §4.1) |
| **B9** | Clutch money-ball bank / kick | Low-percentage bank or kick on the money ball that beat safe play on EV | David Alcaide "9-ball bank to win the World Pool Masters"; Chris Melling 8-ball sequence ending in a four-rail bank[^ddshots] | money ball made; win; bank/kick; `D ≤ 0.30`; `L ≤ 0.02` | Gen (Shaw's massé kick: **No**) |
| **B10** | Push-out trap (9-ball) | Leaves a shot the shooter can make and the opponent can't | AZB forum: "leave something you can do, but your opponent can't"[^push1][^push2] | — | **Book** (D18). Review-only caption once the opponent's choice resolves `[UD-20]` |
| **B11** | Swing safety | Safety from a losing position that flips the rack | Dr. Dave: safeties that force difficult kicks and maximise distance[^ddsafe] | `W₀ ≤ 0.40`, `W₁ ≥ 0.60`; safety by margin; `Rₒ ≤ 0.15` | Gen |
| **B12** | Three-foul trap (WPA 9-ball) | Safety that hooks an opponent already on two fouls (Reg 8: a third foul loses) | Dr. Dave's video index lists three-foul examples, e.g. "Efren Reyes vs. Jose Parica"[^ddshots] | opponent `consecutiveFouls == 2`; safety by margin; `Rₒ ≤ 0.20`; Swing ≥ +25 (the WP model prices the foul count, engine.md §6.4) | Gen |

Shots the engine can't simulate (jump, massé) can only be *seen* by the tracker. `[UD-2]` proposes Execution only,
with Decision shown as "Okay" and no Great/Brilliant, until the physics models elevation.

**Kick and bank confidence.** Cushion restitution is constant in v1 (D16), so Difficulty and EV for B2, B3 and B9
are **low-confidence** until e(v) is calibrated on a real table. They still rate, but the review marks them with a
small "estimate" icon, and calibration (§9) re-checks them first.

### 3.1 Not Brilliant (anti-cases → fixtures)

| Case | Why | D18 outcome |
|---|---|---|
| Fluke / slop pot | Outcome ≠ intent | By Loss; Execution Miss + Lucky icon |
| Hard bank made when an easy safety was much better | Loss large | Mistake (Loss 15–30) or Inaccuracy; Execution Made |
| Easy 9 at W₀ 0.95 | Swing < 25, D > 30% | Best |
| Lockdown the opponent escapes with a miracle | Judged at settle | Still eligible `[UD-4]` |
| Intentional foul leaving an easy run-out | `W₁ ≪ W₀` | Mistake (D18 row 3) or Blunder (Swing ≤ −30) |
| Missed pot that happens to hook the opponent | λ margin fails, so it's a missed pot | By Loss, never promoted |

---

## 4. Applying D18 (numbers, gates, special cases)

D18's table is evaluated top-down as written. This section adds only what D18 leaves open.

**Thresholds (D18 numbers in W units, with the calibration range RATINGS may tune):**

| D18 term | Value | Tune within | Note |
|---|---|---|---|
| Best Loss | ≤ 0.02 | 0.02–0.03 | Measured with the §2.2 rule (`L := 0` when `L < 1.645·SE_L`) |
| Good / Okay / Inaccuracy | 0.02–0.05 / 0.05–0.08 / 0.08–0.15 | ±0.01 per edge | |
| Mistake (Loss/Swing) | 0.15–0.30 | 0.12–0.35 | |
| Blunder Swing | ≤ −0.30 | −0.25 to −0.40 | |
| Miss: Best's Difficulty / gap | ≥ 0.70 / ≥ 0.10 | 0.6–0.8 / 0.08–0.15 | |
| Great: Loss / D / G / Swing | ≤ 0.03 / ≤ 0.50 / ≥ 0.10 / ≥ +0.15 | | |
| Brilliant: Loss / pot D / safety `Rₒ` & `Pbest_pot,pre` / Swing | ≤ 0.02 / ≤ 0.30 / ≤ 0.20 & ≤ 0.40 / ≥ +0.25 | | Plus "decides the rack from W₀ ≤ 0.50" |
| κ / λ | 0.7 / 4 | 0.6–0.8 / 3–10 | §2.1 |

**What "successfully executed" requires** (D18: "the intended outcome happened"), for both Great and Brilliant:
`intentConfidence ≥ κ`, **and** not a fluke, **and** `trackerOK`, **and** the intended outcome happened. For a pot
that means ĉ's ball in ĉ's pocket. For a safety it means a legal hit and `Rₒ ≤ 0.20`. These are interpretations of
D18's wording, not new rules. They are listed in `[UD-21]` so you can see them.

**Special cases D18 doesn't spell out:**

| Case | Rule | Fixture |
|---|---|---|
| Illegal shot with no matching candidate (9-ball non-lowest first; the 8 hit early in bar rules) | ĉ = observed-stroke candidate via `score(stroke:)`. L = EV(c*) − EV(observed). D18 negative rows apply first: game loss → Blunder, BIH foul → Mistake | 9-ball, shooter pots the 7 off a wrong-ball-first hit → Mistake, L recorded |
| 3-foul rule (WPA 9-ball) | The foul count is part of `GameState`, so W prices it (engine.md §6.4). A third foul loses the rack → Blunder (D18). A second foul is Mistake, and its lower W is visible in Swing | Shooter on 1 foul fouls again → Mistake. Opponent on 2 hooked → B12 |
| Team play (D17) | W = team rack win probability. `Rₒ` and opponent plies use the **next opposing shooter's** σ. WPA is credited to the shooter | 2v2 with a strong next opponent: lower W₁ than vs a weak one |
| Break, re-break, push-out | **Book** (D18 row 1). Execution still recorded (break: legal / ball down / scratch) | |
| Player options (accept/pass after a push, accept table / re-break) | **Not rated.** The game review shows the engine's preferred option as a ghost | |
| Bar slop on a safety | Fluke (§2.1) | Fixture 3 in §2.1 |

**Brilliant is post-game (D18).** `Ratings.selectBrilliant(game:)` runs once when the game ends, over the stored
per-shot records. Among shots meeting criteria 2–5 it picks the one with the highest SotG score. Live, those shots
show as Great.

---

## 5. Worked examples (unit fixtures, D18 classes)

| Situation | W₀ | ĉ | L | D | Result | W₁ | Class (Execution) |
|---|---|---|---|---|---|---|---|
| Efren Z-shot analogue: snookered, two-rail kick pots with shape | 0.25 | kick | 0.00 | 0.12 | made | 0.85 | Great live → **Brilliant** post-game if SotG (B2) |
| Pot on (P 0.45); buries the CB instead; `Rₒ` 0.05 | 0.50 | safety (LR 8) | 0.00 | 0.70 | hooked | 0.78 | Great live (Swing +0.28) → Brilliant if SotG (B5) |
| Same stroke, but LR(safety/pot) = 2 | 0.50 | pot (missed) | 0.06 | 0.45 | hooked | 0.78 | **Okay** (never promoted) |
| Only one shot doesn't lose; thin cut; others ≥ 0.20 worse | 0.55 | direct | 0.00 | 0.55 | made | 0.80 | **Great** (G 0.20) |
| Same, but `intentConfidence` 0.55 | 0.55 | direct | 0.00 | 0.55 | made | 0.80 | **Best** (no promotion) |
| Easy 9 for the win | 0.95 | direct | 0.00 | 0.97 | made | 1.00 | **Best** (Made) |
| Slightly wrong side on position | 0.70 | direct | 0.04 | 0.80 | made | 0.62 | **Good** (Made, position OK) |
| Long bank made when an easy safety was much better | 0.50 | bank | 0.22 | 0.20 | made | 0.85 | **Mistake** (Made) |
| Easy pot on, went for a harder ball (−0.12) and made it | 0.60 | direct | 0.12 | 0.40 | made | 0.62 | **Miss** ("Missed chance") |
| Scratch on an easy 8 (correct choice) | 0.92 | direct | 0.00 | 0.90 | loss | 0.00 | **Blunder** (D18 row 2; see `[UD-5]`) |
| Scratch off an object ball mid-rack (correct choice) | 0.60 | direct | 0.01 | 0.75 | BIH | 0.30 | **Mistake** (D18 row 3; see `[UD-5]`) |
| 8 early on an open table, bar rules | 0.50 | observed | 0.50 | — | loss | 0.00 | **Blunder** |
| Intentional tie-up foul, W barely drops | 0.30 | observed foul | 0.01 | — | BIH | 0.29 | **Mistake** under D18; **Best** under `[UD-5]` option c |
| Beginner σ, 20 reference positions | — | — | — | — | — | — | Spread floor: ≥ 30% of rated shots are not Best (§10) |

Every B-class also gets one positive fixture and one near-miss fixture just outside a threshold.

---

## 6. Execution rating

Independent of the class. It follows engine.md §7 so that there is one definition.

| Intent | Made | Near miss | Miss |
|---|---|---|---|
| Pot | ĉ's ball in ĉ's (called) pocket, no foul | OB departure within 1.5× the window half-width outside the window, or a jaw rattle | Otherwise |
| Safety | Legal hit and `Rₒ ≤ 0.20` | Legal hit, `Rₒ` 0.20–0.40 | Foul, or `Rₒ > 0.40` |
| Intentional foul (Obs) | W₁ ≥ W₀ − 0.02 | W₁ within 0.05 | Otherwise |
| Break | Legal, ≥ 1 ball down, no scratch | Legal, nothing down | Foul |

These numbers are new product choices: `[UD-16]`.

**Position** (pots, turn continues). Uses engine.md's **position zone**: the CB rest cells whose leaf value is
≥ 0.8× the best sampled leaf value for ĉ.
- Let `v` = the achieved leaf value and `v̂` = the best sampled leaf value.
- If `v̂ < 0.20` (no good shape existed), the result is "n/a". This avoids dividing by ~0.
- Otherwise `r = clamp(v / v̂, 0, 1)`: **Perfect** if in the zone (r ≥ 0.8), **OK** if 0.5 ≤ r < 0.8, **Out of
  line** if r < 0.5.

Visual, post-shot only: green, yellow or red ring at the CB rest spot. The red ring adds a faint ghost circle at the
best zone cell. That is a new post-shot UI element: `[UD-17]`.

---

## 7. Timing contract (when the badge appears and disappears)

```
t0          stroke detected (CB velocity threshold, spec §5.3)
t0+0.2 s    ĉ inferred from launch direction + speed → rating top-up starts (c*, ĉ to 1024; c₂ to 256)
            runs while the balls are still rolling; ~0.9 s wall (§8)
ts          all balls at rest (typically t0 + 2–4 s)
ts+≤0.2 s   post state → W₁ (5 µs), Quick pass for Rₒ (≤150 ms), rules, fluke check → rate() → badge
ts+3 s      badge auto-dismisses
any time    the badge HIDES at once when any meshed phone sees a shooting stance (pose) near the CB or CB motion
```

- If the top-up hasn't finished at `ts` (thermal), wait up to 0.5 s, then rate with the samples available. The
  `SE_L` rule makes that generous, never harsh. **The class never changes after display** (engine.md R5). The
  review shows the same class.
- **Badge content:** icon + color + ≤ 2 words (D18 labels). Live it is never Brilliant (D18). Push-out and
  player-option outcomes appear only in the game review.
- `[UD-7]`: when someone starts aiming, hide the badge entirely (proposed), or shrink it to icon + color only. The
  spec says no text while aiming, so it must at least lose its words.
- Mesh: only the host runs the engine. The badge is broadcast after settle, in the spirit of D3.

---

## 8. Compute budget (iPhone 15 Pro Max, A17 Pro)

Uses engine.md's measured assumptions: 0.35 ms per sparse sim, about 2.5 effective P-cores with the camera live,
2-ply leaf ≈ 3 nominal sims at a 50% cache-hit rate, so **≈ 0.93 ms CPU per candidate-sample**. The reviewer's
estimate of 10⁸ sims assumed full MC on every candidate. The engine instead uses an analytic Quick pass,
Sequential Halving on 16 arms[^sh], and a top-up only on the 2–3 arms the rating needs.

| Stage | When | Candidates × samples | CPU | Wall | Tag |
|---|---|---|---|---|---|
| Quick pass (analytic P, nominal sims) | while aiming | ~140 variants, 0 MC | ~70–120 ms | ≤ 50 ms | engine.md §9.1 |
| Full pass (Seq. Halving, CRN) | while aiming | 16 arms, 768 total | ~1.1 s | ~0.45 s | engine.md §9.2 |
| **Rating top-up** | stroke → settle | ĉ + c* to 1024, c₂ to 256 (reuses Full-pass samples) | ≈ (2×1024 + 256) × 0.93 ms ≈ **2.1 s** | **≈ 0.86 s** | new, expensive |
| Observed-stroke candidate (if no match) | same | +1024 samples | +0.95 s | +0.38 s | conditional |
| Post state: W₁, `R_run` | settle | analytic | < 1 ms | < 1 ms | cheap |
| Post state: Quick pass for `Rₒ`, `runnable` | settle | analytic | ≤ 120 ms | ≤ 50 ms | cheap |
| Intent posterior, naive rank, D, EV_miss | stroke | analytic + existing samples | < 1 ms | < 1 ms | cheap |
| Opponent BIH value (B6/W₁) | settle | WP model BIH term (engine.md §6.4); **no** placement search | µs | µs | cheap |
| `selectBrilliant` | game end | stored records | µs | µs | cheap |

**Worst case** (no matching candidate): ~1.25 s wall from stroke, which fits inside the 2–4 s settle. At thermal
`.serious` (engine.md §8 halves budgets), N_rate = 512 and §2.2's generous degradation applies. At `.critical`,
classes come from the Full pass alone (≤ 180 samples). Most Good/Okay become Best. Negative rows (fouls, Swing)
are unaffected because they are cheap.

**Benchmark first** (Phase 2, before thresholds are frozen): measure sims/s on the 15 Pro Max with the camera
live, the per-sample leaf cost, and the CRN correlation ρ for pot-vs-pot and pot-vs-safety pairs over the 20
positions. Feed ρ and s back into §2.2. If the rating top-up exceeds 1.5 s wall at p95, reduce c₂ to 128 samples
first, then N_rate.

---

## 9. Calibration plan

The 20 positions can't estimate frequencies (reviewer issue 8). They are now an **ordering and sanity check** that
you review (spec Phase 2 gate).

1. **Synthetic self-play (Phase 2, `tools/` on macOS).** Bots at beginner, amateur and strong σ (engine.md §5.1)
   play each other on the virtual table. Each bot picks by softmax over candidate EVs with a per-tier temperature
   (so they make realistic choice errors), plus a 5% "deliberate safety" rate. Run ≥ 2,000 racks per tier pair ×
   rule set. That is about 25 shots × 1.1 s CPU per rack: ~1.5 h per cell on a 10-core Mac.
2. **Tune thresholds within the §4 ranges** so the class frequencies below hold for the amateur tier, and check the
   other tiers stay plausible. Brilliant is checked as **the share of games with a Brilliant**.
3. **Recalibrate on real data** after ≥ 500 tracked competitive shots exist (Phase 3+ replay mode). Store
   `thresholdsVersion` per shot so old shots can be re-rated in review (never live).
4. **Kick/bank first.** Until e(v) is measured on a real table (D16), B2/B3/B9 are flagged low-confidence (§3).

**Target frequencies** (rated shots, excluding Book) `[UD-6]`:

| Class | Target | | Class | Target |
|---|---|---|---|---|
| Brilliant | 0–1 per game (D18); **15–35% of games** have one | | Okay | 10–15% |
| Great | 5–10% | | Inaccuracy | 5–10% |
| Best | 30–45% | | Miss | 2–5% |
| Good | 15–20% | | Mistake | 5–12% (amateur fouls are common) |
| | | | Blunder | 1–4% |

---

## 10. Skill reference and beginners

D18 fixes Best and Difficulty to **this player's** skill, so Loss uses the shooter's own σ. Reviewer issue 17 is
real: with a very noisy σ, all candidate EVs squash together, L shrinks, and almost everything is Best.
- **Fixture (spread floor).** On the 20 positions and in beginner self-play, at least 30% of rated beginner shots
  must be non-Best, and the Loss quantiles must not collapse (p90 Loss ≥ 0.08).
- **If it fails** `[UD-8]`: below 30 observed shots, compute Loss at the "amateur" default σ instead of the
  learned beginner σ (the "learning" icon is already shown then).
- **Dropped:** the rev-1 idea of 1.5× extra generosity for new players. It would make the collapse worse.
- **No feedback loop:** the skill model learns from raw tracked residuals and made/miss only (engine.md §5.2),
  never from ratings.
- **SotG "baseline P(make)"** (spec §9): proposed as this player's D, for consistency with D18 `[UD-8]`.

---

## 11. Contract deltas (contracts first; for the head orchestrator to apply)

**INTERFACES.md → Engine.** Builds on engine.md §12, replacing `rate(chosen:outcome:eval:)`:

```swift
public struct IntentPosterior: Sendable, Codable { var chosen: Candidate; var confidence: Double
                                                   var safetyLR: Double; var isFluke: Bool }
public struct RatingInput: Sendable, Codable {
    var ruleSet: RuleSetID; var isBook: Bool
    var wpBefore: Double, wpAfter: Double                 // shooter's team perspective
    var best: CandidateScore, chosen: CandidateScore, second: CandidateScore?
    var loss: Double, lossSE: Double                      // paired CRN difference (§2.2)
    var intent: IntentPosterior
    var difficulty: Double, opponentBestMake: Double, shooterBestPotBefore: Double
    var missBranchEV: Double?, naiveRank: Int, runnableDelta: Int, runOutDelta: Double
    var opponentFoulsBefore: Int
    var rules: RuleResult, outcome: ShotOutcome           // tracker-built ShotOutcome, not a ShotTrace
    var execution: ExecutionObservation                   // OB window miss, jaw event, CB rest leaf value v, v̂
    var trackerOK: Bool
}
public struct RatingThresholds: Sendable, Codable { /* every §4 number + κ, λ, z; version */ }
public enum Ratings {                                     // pure, synchronous
    static func rate(_ i: RatingInput, _ t: RatingThresholds) -> ShotRating   // class, execution, tag B1–B12?
    static func selectBrilliant(_ game: [ShotRatingRecord], _ t: RatingThresholds) -> Int?   // post-game
}
// ShotEngine (actor) gains: func ratingTopUp(before: Evaluation, chosen: Candidate,
//                                             budget: EngineBudget) async -> (best, chosen, second, loss, lossSE)
```

All async work (top-up, post Quick pass) happens **before** `rate`. `rate` stays pure and needs no simulator.
`ShotKind` replaces rev 1's `Candidate.class`, which is a Swift keyword.

**SCHEMA.md → `Shot`** `[UD-18]`. Add `loss`, `lossSE`, `difficulty`, `opponentBestMake`, `intentConfidence`,
`catalogueTag: String?` (B1–B12), `sotgScore`, `flags` (fluke, trackerLow, coarse, lowConfidencePhysics),
`engineVersion` and `thresholdsVersion`. `wpaDelta` already exists (= Swing). All stay in the competitive store.

**Spec amendment** `[UD-19]`: EV in W units (§2).

---

## 12. Decisions needed from the user

| # | Question | Proposal |
|---|---|---|
| UD-1 | Review-screen "I meant…" correction: may it promote to Great/Brilliant? Does the opponent have to confirm? | Corrections re-rate by Loss only, never promote. No confirmation needed |
| UD-2 | Jump/massé (not simulatable in v1) | Execution only; class "Okay"; never Great/Brilliant until elevation is modelled |
| UD-3 | Add the spec's "non-obvious" test (naive-policy rank) as an extra Brilliant gate on top of D18? | No. D18's "really hard" covers it. Show naive rank in review only |
| UD-4 | Judge a lockdown at settle even if the opponent escapes with a miracle | Yes |
| UD-5 | D18 makes every BIH foul a Mistake (and a game-losing foul a Blunder), even on a correct choice, and makes B6 intentional fouls never eligible. Options: (a) keep D18; (b) execution fouls → Execution "Miss" + foul icon, class from Loss; (c) keep D18 but exempt **intentional** fouls with Loss ≤ 2 | (c). Fixtures exist for (a), (b) and (c) |
| UD-6 | Target frequencies (§9), incl. "15–35% of games have a Brilliant" | As listed |
| UD-7 | When anyone starts aiming: hide the badge, or shrink it to icon + color? | Hide entirely |
| UD-8 | Beginner fallback (Loss at the amateur σ below 30 shots, if the spread fixture fails); SotG uses the player's own D | Yes to both |
| UD-9 | "Lucky" icon on flukes | Yes, icon only |
| UD-10 | Should match state (hill-hill) lower Brilliant thresholds? | No; clutch flag + SotG bonus only |
| UD-11 | Rev-1 extra generosity for new players | **Drop** (§10) |
| UD-12 | Bar 8-ball etiquette. Dr. Dave's "Bar Rules and Dirty Pool"[^ddbar] lists as dirty pool: "Purposely miss an easy shot to get a break-out and leave your opponent bad" (B5) and "Scratch on purpose to achieve some desirable outcome" (B6), and says defensive safeties "should not be played unless they are the result of an honest effort to pocket a ball". It also lists typical bar rules where a scratch gives BIH "in the kitchen" and no-rail is not a foul. **Our RULES.md differs** (B7/B8: BIH anywhere; no-rail is a foul), and B6 is valued under RULES.md. Allow B5/B6 to be Great/Brilliant in bar 8-ball? | Yes for B5 (D2 names deliberate misses). B6 follows UD-5 |
| UD-14 | Thresholds (§4), the SE rule (z = 1.645), N_rate = 1024; if the benchmark shows ρ < 0.3, accept noisy Good/Okay or spend ~2× compute | As listed; decide after the benchmark |
| UD-15 | Catalogue: B12 added; B6 and carom Obs-only; B10 review-only | As listed |
| UD-16 | Execution thresholds (§6: 1.5× window near miss, safety `Rₒ` 0.20/0.40, foul ±0.02/0.05) | As listed |
| UD-17 | Red position ring adds a ghost of the best spot (new post-shot UI) | Yes, faint ghost circle only |
| UD-18 | New per-shot stored fields (§11) | Yes |
| UD-19 | Spec amendment: EV/Value in rack-win-probability units | Yes (shared with engine.md) |
| UD-20 | Push-outs are Book (D18); show a "trap" caption in review once resolved? | Yes, review only |
| UD-21 | "Executed successfully" also needs intent confidence ≥ κ, no fluke, and good tracker confidence | Yes |

(Rev 1's UD-13, a "Miss" class, is closed by D18.)

---

## 13. Reviewer notes

| Issue | Outcome |
|---|---|
| 1 MC noise floor | **Fixed**: CRN paired SE, one-sided test, N arithmetic, reachability table and fixture (§2.2) |
| 2 Compute budget | **Fixed** (§8). engine.md now exists with a budget and Sequential Halving. Only 2–3 arms get the top-up; the BIH search is replaced by the WP-model term; Pb/D is analytic; signals are tagged cheap/expensive. The benchmark is a Phase 2 prerequisite |
| 3 Timing | **Fixed** (§7). D18 already makes Brilliant post-game and push-outs Book, which removes the late-badge cases |
| 4 Intent | **Fixed** (§2.1): observable features, plan-uniform prior, λ margin, adversarial fixtures, UD-1 |
| 5 Contract | **Fixed** (§11): `RatingInput`, pure `rate`, SCHEMA delta, UD-19 |
| 6 Scope | **Fixed**: B6/carom Obs, B10 Book, B4 free from samples (§3) |
| 7 Missing cases | **Fixed** (§4 table, B12) |
| 8 Calibration | **Fixed** (§9) |
| 9 Tracking error | **Fixed** (§2.3) |
| 10 Foul override | **Partly accepted.** The class order is now D18 (your rule), which puts fouls in Mistake/Blunder by design, so I can't move fouls to Execution on my own. Raised as UD-5 with three options and fixtures for each |
| 11 Great conditions | **Fixed** (§4, "successfully executed") |
| 12 Silent choices | **Fixed**: UD-16, 17, 18, 21, UD-3 for the catalogue gate (the catalogue no longer gates) |
| 13 Citations | **Fixed**: the 70% quote is 8onthebreak and the "bury" quote is KellyStick, both verbatim; Deuel's one-pocket carom removed; Ouschan dropped from B2 |
| 14 Lichess scale | **Fixed** (§1) |
| 15 Bar etiquette | **Fixed** (UD-12, quoted) |
| 16 Vague definitions | **Fixed**: `Rₒ`, position r, `runnable`, perspective rule, `ShotKind`. The rate arithmetic is moot under D18's 1-per-game cap; the target is now a share of games |
| 17 Beginners | **Partly accepted.** The spread fixture, dropped generosity and no-feedback note are in. "Normalize L by EV spread" is rejected: it makes a 2-point Best mean different things per position. The UD-8 fallback is proposed instead |

---

## Sources

[^cc]: Chess.com Help, "How are moves classified?": https://support.chess.com/en/articles/8572705-how-are-moves-classified-what-is-a-blunder-or-brilliant-and-etc
[^li]: Lichess `Advice.scala` (winningChances thresholds .1/.2/.3): https://github.com/lichess-org/lila/blob/master/modules/tree/src/main/Advice.scala
[^liacc]: Lichess "Accuracy" (Win% = 50 + 50·(2/(1+e^(−0.00368208·cp)) − 1)): https://lichess.org/page/accuracy ; winning chances on −1..1: https://rdrr.io/github/dryguy/rbitr/man/winning_chances.html
[^sh]: Karnin, Koren, Somekh, "Almost Optimal Exploration in Multi-Armed Bandits" (Sequential Halving), ICML 2013: https://proceedings.mlr.press/v28/karnin13.html ; common random numbers: https://rossetti.github.io/KSLBook/ch9VRTs.html
[^bd30]: Billiards Digest, "30 over 30" #18 (Reyes, Sands Regency XXI, 11 Jun 1995): https://www.billiardsdigest.com/new_30over30/18.php
[^pd]: PoolDawg, "The Greatest Pool Shot Ever?": https://www.pooldawg.com/article/the-greatest-pool-shot-ever/
[^ddshots]: Dr. Dave Alciatore, "Great Pool Shots" video index (entries quoted verbatim): https://drdavepoolinfo.com/videos/pool-shots/
[^ddsafe]: Dr. Dave, "Safety Strategy Advice": https://drdavepoolinfo.com/faq/safety/strategy/
[^dd8]: Dr. Dave FAQ, 8-ball strategy (summary list; 8onthebreak AZB quote; Robert Byrne): https://drdavepoolinfo.com/?p=2528
[^dd9]: Dr. Dave FAQ, 9-ball strategy (KellyStick quote): https://drdavepoolinfo.com/?p=2530
[^ddfoul]: Dr. Dave, "Intentional Fouls", Billiards Digest, March 2026: https://drdavepoolinfo.com/bd_articles/2026/march26.pdf
[^ddbar]: Dr. Dave, "Bar Rules and Dirty Pool", Billiards Digest, June 2025: https://drdavepoolinfo.com/bd_articles/2025/june25.pdf
[^push1]: AZBilliards forum, "What is your goal when you push out?": https://forums.azbilliards.com/goto/post?id=5348076
[^push2]: AZBilliards forum, "Push Out Strategies": https://forums.azbilliards.com/threads/push-out-strategies.13958

Engine numbers (sim cost, Sequential Halving, CRN seeds, WP model, position zone, `score(stroke:)`):
`docs/research/engine.md` §§4–9, 12.

# Engine research and design proposal

Status: research proposal for Phase 2. It needs head-orchestrator and user review before the `INTERFACES.md` change.
Scope: SPEC §5.5 (candidates, Monte Carlo, value, win probability, ratings hand-off), the INTERFACES Engine stub,
the on-device perf budget, Swift concurrency, and the TDD plan. The brilliant/blunder catalogue is out of scope
here; it lives in `docs/RATINGS.md` (D2). This doc covers only the numbers the Engine hands to that catalogue.

---

## 0. TL;DR

- **Two-tier anytime engine.** A **Quick** pass (≤150 ms wall, p95) generates and ranks candidates with an analytic
  P(make) and one noise-free simulation per variant. A **Full** pass (≤2.5 s wall, p95, inside ball-settling time)
  runs Monte Carlo with execution noise on the top-K, does 2-ply position evaluation and a root-only safety search,
  and produces win probability. Results stream as `Evaluation` snapshots, so the eval bar moves early and then sharpens.
- **Value in win-probability units.** Each sampled outcome goes through `RulesEngine.apply`, which covers fouls,
  scratches, ball-in-hand and turn passing, and is then scored with a win-probability model. Ratings then come from
  expected-win-probability loss, the same way chess.com uses expected-points loss.
- **Skill model.** Gaussian noise on the stroke parameters (aim φ, speed V, tip offset a/b), following the ICGA
  computational-pool tournaments. Defaults ship per skill tier. Each player's σ_aim is learned from tracked
  object-ball departure-angle residuals, which are much stronger evidence than made/missed alone. A Bayesian grid
  posterior shrinks toward the population prior.
- **Budget fits.** At 0.35 ms per sparse sim, the Quick pass needs about 70 ms of CPU and the Full pass about 1.5 s of
  CPU. Spread across the A17 Pro's 2 P-cores and 4 E-cores (about 2.5 effective P-cores after thermal and overlay
  headroom), that is about 30 ms and 0.6 s of wall time, which leaves 2-4x margin.
- **Determinism.** Seeds are counter-based, per (state hash, candidate, sample index), and the same random numbers are
  shared across candidates. This makes evaluations reproducible in tests and stops ratings flickering between runs.

---

## 1. Constraints and inputs

| Constraint | Source | Consequence for the Engine |
|---|---|---|
| All AI on-device, zero network | CLAUDE.md, SPEC §2 | Pure Swift in `Packages/CueCore/Engine`. Precomputed tables ship in the bundle. No cloud self-play. |
| iPhone 15 Pro Max is the perf gate (A17 Pro: 2P @3.78 GHz + 4E @2.11 GHz) | D6, [A17 Pro – Wikipedia](https://en.wikipedia.org/wiki/A17_Pro) | Budget for about 2.5 effective P-cores. The overlay and Vision pipeline need headroom. |
| Physics ≈ 0.35 ms per sparse shot, ≈ 13 ms per 16-ball break (today) | task brief, CHECKLIST (physics fix in progress) | Sim count is the main cost driver. Breaks are budgeted separately. |
| SPEC §5.5.7: background actor, finish within settle time (~2–4 s). Phase-2 gate: "Eval < 3 s on device" | SPEC §5.5, §9 | Full pass target is 2.5 s p95. The Quick pass target (150 ms) is this proposal's own target for live re-ranking (see §11, Q1). |
| No text/audio while aiming. Feedback never numeric-precise | SPEC §2, §5.6 | The Engine outputs Doubles. The **UI must bucket them** (eval-bar fill, green/yellow/red, 5-step power). Exact numbers appear only in the dev HUD (D9). |
| Training stats never touch competitive stats | CLAUDE.md | The skill model learns from competitive shots by default. Using training shots is an open question (§11, Q2). |
| Host owns the engine (mesh) | SPEC §5.7 | `Evaluation` is `Codable` and compact, so the host can broadcast it to peers. |

---

## 2. Prior art (what we borrow)

| System / source | Key idea | What we take |
|---|---|---|
| **PickPocket** (Smith, AAAI 2006; won the 10th and 11th Computer Olympiad 8-ball). [AAAI PDF](https://cdn.aaai.org/AAAI/2006/AAAI06-156.pdf), [mlanthology](https://mlanthology.org/aaai/2006/smith2006aaai-running) | Move generator by shot class in order of difficulty (straight-in → bank/kick/combo only if no straight-in). φ aims at the pocket centre. V comes from a min-speed table and rises in 1 m/s steps; a and b are varied for position. P(make) comes from a 30⁴ lookup over (cut α, OB-pocket d1, CB-OB d2, pocket angle β), filled with 200 samples per cell. Banks, kicks and combos map to an equivalent straight-in with a discount. Evaluation = Σ dᵢpᵢ over the best n distinct ball-pocket shots, with decreasing discounts. **MC search:** 15 samples, 2-ply, chosen to fit 60 s per shot. Safeties are root-only: tried when the best P < t0 = 65%, taken if the opponent's value < t1. MC beat probabilistic expectimax and greedy. | Class-ordered generator, speed/spin variant grid, discounted best-n evaluation, root-only safeties with thresholds, MC 1-ply plus a cheap 2nd ply. |
| **CueCard** (Archibald, Altman, Greenspan, Shoham; won the 2008 ICGA tournament). [AI Magazine paper](https://yoavshoham.net/_files/ugd/a1a3b1_5964a39d807a4fce8768f64cb69d6b25.pdf) | Geometric "interesting directions" (straight-in, multi-collision, cluster-breaking). A noise-free sim filters them, then variants are made by discretising v and randomly varying a, b, θ. Each surviving variant is simulated n times with noise. State value = **1·p1 + 0.33·p2 + 0.15·p3**, with p from a straight-in lookup table. The top-k go to a second ply. A defensive "last resort" shot is used when the score is below a threshold. Ball in hand: candidate placements near object balls in straight-in position. The break is precomputed (92% pot with half the rack spread). 20 CPUs gave only a 55.4% win rate against 1 CPU. | The exact discount weights as the starting point. Noise-free filter before MC. Top-k refinement. BIH placement generator. A precomputed break. **Evidence that more compute has diminishing returns**, which justifies a phone budget. |
| **ICGA noise model.** Same paper as above. Leckie & Greenspan event-based simulator, [Springer](https://www.springerprofessional.de/en/an-event-based-pool-physics-simulator/1276086) | Zero-mean Gaussian on (θ, φ, V, a, b) with σ = (0.1°, 0.125°, 0.075 m/s, 0.5 mm, 0.5 mm). PickPocket's "strong amateur" E_high = σ(φ, θ, V, a, b) = (0.185°, 0.03°, 0.085 m/s, 0.8 mm, 0.8 mm). | The noise-model shape and the order of magnitude of each σ. Human σ_aim is larger; we calibrate it (§5). |
| **Noise vs strategy** (Archibald et al., same paper; [AAMAS 2010 "Success, strategy and skill"](https://ifaamas.csc.liv.ac.uk/Proceedings/aamas2010/pdf/01%20Full%20Papers/22_05_FP_0677.pdf)) | Extra thinking time helped most at about 1.4x tournament noise. At high noise, safeties matter more. | Safety search must be first-class for amateur noise levels, which is our typical user. |
| **Execution-skill estimation** (Archibald & Nieves-Rivera, [AAAI 2019](https://ojs.aaai.org/index.php/AAAI/article/view/4556); [JAIR 2024](https://jair.org/index.php/jair/article/view/15326)) | Bayesian estimation of an agent's execution-noise parameters from observed actions, tested on computational billiards. Joint estimation with decision skill is more robust. | Grid-posterior σ estimation (§5.3). Infer the intended shot before attributing error to execution. |
| **Dr. Dave TP 3.4 / TP A.13** ([TP 3.4](https://drdavepoolinfo.com/technical_proofs/TP_3-4.pdf), [margin-for-error FAQ](https://drdavepoolinfo.com/faq/cut/margin-for-error/), [TP A.13](https://billiards.colostate.edu/technical_proofs/new/TP_A-13.pdf)) | OB direction error from CB aim error Δφ at cut φ and distance d: Δθ = asin((d/2R)·sin Δφ + sin(φ−Δφ)) − φ + Δφ. Linearised, this gives **Δθ ≈ Δφ·(1 + d / (2R cos φ))**. The pocket angular window is 2·atan((p/2)/d_p) for effective target size p. Straight-shot difficulty ∝ d1·d2. | The analytic P(make) prior and test oracle (§4.2). Property tests (monotonic in d, φ). |
| **pooltool** ([GitHub](https://github.com/ekiefl/pooltool), [JOSS 2024](https://theoj.org/joss-papers/joss.07301/10.21105.joss.07301.pdf)) | Reference event-based simulator. We already validate physics against it (D10). | Offline fixture generation for engine reference positions (P(make) ground truth by brute-force MC in Python). |
| **chess.com classification** ([support article](https://support.chess.com/en/articles/8572705-how-are-moves-classified-what-is-a-blunder-or-brilliant-move)) | Expected-points-loss bands: Best 0, Excellent ≤0.02, Good ≤0.05, Inaccuracy ≤0.10, Mistake ≤0.20, Blunder >0.20. Brilliant and Great use extra rules (sacrifice; only-move or swing). | The Engine outputs ΔWP = WP(best) − WP(chosen) with a standard error. Thresholds are owned by RATINGS.md. |
| **FargoRate** ([blog](https://fargorate.com/fargorateblog/archive/behindthecurtain/)) | Game-win odds ratio = 2^(Δrating/100). | Optional: convert per-rack WP into a race/match WP (negative binomial). Optional seed for the default skill tier. Not needed for v1. |
| **Sequential Halving / best-arm identification** ([Karnin, Koren, Somekh, ICML 2013](https://proceedings.mlr.press/v28/karnin13.html)) | A fixed-budget best-arm algorithm that halves the arm set each round. | Allocating the MC budget across candidates (§6.2). |
| **Common random numbers** ([Wikipedia: variance reduction](https://en.wikipedia.org/wiki/Variance_reduction), [KSL book §9.2](https://rossetti.github.io/KSLBook/ch9VRTs.html)) | When comparing alternatives, use synchronised random streams so differences reflect the designs, not the noise. | Per-sample-index seeds shared across candidates (§6.3). |
| **Swift concurrency** ([Swift forums: CPU-bound tasks](https://forums.swift.org/t/concurrency-and-cpu-bound-tasks/49716), [WWDC21 notes, "Behind the scenes"](https://www.donnywals.com/wwdc-notes-swift-concurrency-behind-the-scenes/), [@concurrent thread](https://forums.swift.org/t/is-concurrent-now-the-standard-tool-for-shifting-expensive-synchronous-work-off-the-main-actor/82976)) | The cooperative pool is about core-count wide. Long synchronous work must not block forward progress, so chunk it and check cancellation or yield between chunks. Actor reentrancy is the main logic hazard. | §8 design. |

Note that **no** prior system ran under a phone budget. PickPocket used 60 s per shot and CueCard used 20 CPUs. Our
lever is the analytic P(make) plus noise-free filtering. This pushes the expensive MC onto very few candidates, which
CueCard's 1-vs-20 CPU result says costs little strength.

---

## 3. Architecture

```
            TableState + GameState + skills
                         │
     ┌───────────────────▼────────────────────┐
     │ CandidateGenerator  (pure, nonisolated)│  geometry + RulesEngine.legalTargets
     └───────────────────┬────────────────────┘
                         ▼
 QUICK  ── nominal sim per variant ── analytic P(make) ── leaf eval V0 ──► Evaluation(.quick)  ≤150 ms
                         │ top-K (K≈12) + best safeties
                         ▼
 FULL   ── sequential-halving MC (noisy sims, CRN) ── RulesEngine.apply per sample
        ── 2-ply leaf (next-shot gen, analytic P, nominal sim for top-3) ── WP model ──► Evaluation(.full) ≤2.5 s
```

Three consumers:
1. **Overlay** (60 fps). The overlay does **not** call MC. It uses `AimGeometry` plus one nominal `Simulator.simulate`
   of the live stroke (~0.35 ms) and reads colour (green/yellow/red) from the Quick-pass P(make) of the matching
   candidate. When the aim matches no candidate, it falls back to the analytic P(make) of the live line (3 sims).
2. **Eval bar.** WP from the latest `Evaluation` (Quick and then Full).
3. **Post-shot rating.** The Full evaluation of the *pre-shot* state, plus a re-evaluation of the *chosen* shot (§7).

---

## 4. Candidate generation

### 4.1 Shot classes and geometry

For each `target ∈ RulesEngine.legalTargets(g)` (this also drives the red ring) and each `pocket` (6):

| Class | Geometry | Feasibility filter (cheap, before any sim) | Typical count |
|---|---|---|---|
| **Direct** | Ghost ball G = O + 2R·û(O→aim point). The aim point is the pocket's *effective* centre, offset from the mouth centre toward the far jaw for angled approaches, per [Dr. Dave pocket centre](https://drdavepoolinfo.com/pocket/size-and-center/). | Cut α < 80°. Clear swept capsules C→G and O→pocket (width 2R, against all other balls; uses the jaw/point geometry from `TableSpec`). Side-pocket approach angle < ~55° (the side opening closes fast with angle). | 8-ball: ≤7×6 = 42 raw → ~8–20 after filtering. 9-ball: ≤6. |
| **Bank** (1 rail) | Mirror the pocket across the rail line, offset by R (ball-centre rail), aim O at the mirror image. Then correct the bounce point by the sim (cushion restitution, D16). | Clear path segments. Rail is not the pocket's own rail. | 4 rails × targets × pockets → prune to ≤8. |
| **Kick** (1 rail, cue first) | Mirror the ghost ball across the rail. | Required when the direct cue path to every legal target is blocked (a "snooker"), or as an option when combined with a safety. | ≤8 |
| **Combo** (2-ball) | Chain ghost balls: the secondary S must go to the target's ghost G_T, and the cue goes to S's ghost. | Legal first contact (S must be a legal target, or the target itself in 9-ball when S is the lowest ball). Both cuts < 60°. Distances < 0.6 m. | ≤6 |
| **Carom / kiss** | v2 (not in Phase 2). | | |
| **Safety** | §4.4 | Root only. | 64–144 raw |
| **Break** | Fixed menu: 3 cue placements × 2 speeds, precomputed offline per rule set | Only when `phase == .breakShot` | 6 |
| **Ball in hand** | CueCard-style: for each easy direct shot, place the cue on the extension of O→G behind the ghost at 15/30/45 cm, then filter for legality (`.behindHeadString` restricts the region). | | ≤24 placements × best shot |

**Order of generation** follows PickPocket. Banks, kicks and combos are generated only when fewer than `minDirect`
(default 3) direct shots have P(make) ≥ 0.25, or when the rules force them (snookered). This keeps the 8-ball open
table (15 balls) bounded.

**Complexity.** Generation is O(T·P·B) capsule tests (T targets, P = 6 pockets, B ≤ 15 balls). That is ≤ 15·6·15·2 ≈
2.7k segment-vs-circle tests, about 30 µs.

### 4.2 Stroke variants (speed × spin)

The spec asks for a "grid of speed × spin". Variants are built per (target, pocket, class):

- **Speed.** `V_min` is the minimum CB speed that delivers the OB to the pocket with margin, computed in closed form
  from rolling deceleration (μ_roll·g) and collision energy transfer (cos²α), then checked with one sim. The speed
  set is {V_min·1.15, then the 5 power-meter steps above it}, clipped to [V_min, 6 m/s]. This matches the 5-step
  power meter in the UI, so a suggestion can always be displayed.
- **Spin (tip offset a, b in ball radii, |·| ≤ 0.5):** {centre/stun (0, 0), follow (0, +0.3), draw (0, −0.3),
  left (−0.3, 0), right (+0.3, 0)}. Side spin is generated only when |α| < 45° (the throw and squirt risk is otherwise
  dominated by aim error).
- **Throw-corrected aim.** The nominal φ is solved with one Newton step on the sim: aim, measure the OB departure
  angle, correct. This captures cut-induced and spin-induced throw from our physics (SPEC §5.4).
- Variants count = 6 speeds × (3–5) spins, **deduplicated by end state**. Two variants whose noise-free CB rest
  positions are within 5 cm and that pocket the same balls are merged. That typically leaves 6–12 per
  target-pocket.

### 4.3 Analytic P(make) (the key perf lever)

For a direct candidate with nominal stroke s:
1. Simulate s and s ± δφ (δφ = 0.1°). That is 3 sims, and the ± pair is shared by all variants with the same aim.
   This gives the local Jacobian J = ∂θ_OB/∂φ (it includes throw, so it is better than the TP 3.4 closed form,
   which we keep as the test oracle).
2. The pocket acceptance window [θ⁻, θ⁺] for the OB departure angle is found by bisection on the OB-only sim (or
   cached per (O, pocket) pair). Seed it with 2·atan((p_eff/2)/d1) (TP A.13).
3. Departure-angle noise σ_θ = sqrt((J·σ_φ)² + (∂θ/∂a · σ_a)² + σ_pos²), where σ_pos covers perception error
   in ball positions (default 6 mm, from the tracker covariance).
4. **P(make) = Φ((θ⁺ − θ₀)/σ_θ) − Φ((θ⁻ − θ₀)/σ_θ).** Then multiply by a speed factor P(V ≥ V_min | σ_V) and a
   scratch/foul factor taken from the noise-free trace (0 if the nominal shot scratches).

Banks, kicks and combos chain the Jacobians: J_total is the product of the per-collision ∂out/∂in values, obtained from
the same ±δφ sims. This replaces PickPocket's "map to straight-in plus discount" with a physically grounded number at
the same cost.

The analytic P is used for (a) Quick-pass ranking, (b) the overlay colour, (c) the leaf evaluation, and (d) the
**control variate** for MC in the Full pass (§6.3).

### 4.4 Safeties (root only)

Following PickPocket, safeties are generated only at the root, when `best offensive EV < τ_safety` (default: best
P(make) < 0.65 **or** the best safety's Quick-pass value exceeds the best offensive EV).

- **Sampled grid** (PickPocket/CueCard): φ over a 2.5° grid restricted to directions whose first contact is legal
  (≤ 144 directions after the legality cone filter) × 3 speeds (soft/medium/firm), all centre ball. That is ≤ 432
  nominal sims (~150 ms CPU, done in the **Full** pass only). The Quick pass uses a 10° grid × 2 speeds (≤ 72 sims).
- **Targeted:** (1) "hide": choose CB rest points behind blockers relative to every opponent target (visibility
  polygon from opponent targets). (2) "lag to rail": the legal-hit-plus-rail requirement for BCA/WPA from
  `RuleResult` fouls.
- **Score** = 1 − WP_opponent(state′) from the WP model. With the leaf evaluation, the opponent's options come from
  the generator for the opponent's legal targets, including kicks when snookered. A foul gives the opponent ball in
  hand, which is valued with the BIH generator. This is the spec's "Safety value = 1 − opponent's best P(make)",
  generalised to WP.

---

## 5. Execution noise model (`SkillModel`)

### 5.1 Parameterisation

Our 2D physics has no elevation θ (no jump/massé in v1), so the model has four parameters:

| Param | Meaning | ICGA 2008 | PickPocket E_high | Proposed default (league amateur) | Range |
|---|---|---|---|---|---|
| σ_φ | aim direction (deg) | 0.125 | 0.185 | **0.45** | 0.1–1.5 |
| σ_V | speed, *relative* (%) | 0.075 m/s abs | 0.085 m/s | **8%** | 3–20% |
| σ_a, σ_b | tip offset (mm) | 0.5 | 0.8 | **2.5** | 0.5–6 |

Speed noise is relative because human speed error scales with intended speed. Defaults for "beginner / amateur /
strong" tiers are set so that the analytic make rate on a canonical 1 m, 30° cut matches targets of about
55% / 75% / 90%. They are calibrated offline in `tools/` by sweeping σ_φ. These defaults are placeholders until
real-table data exists. **This is flagged as a calibration risk (§10).**

Sampling: φ, a, b and V are independent Gaussians, with the tip offset clipped to the miscue radius (|tip| ≤ 0.5R;
beyond it, a miscue means CB speed × 0.3 and a random direction ±5°).

### 5.2 What we observe from tracking

For every competitive shot the tracker gives the CB launch direction and speed (from the first ~5 frames), the
first contact, the OB departure direction, the pocketed balls and the rest state (SPEC §5.3).
- **Aim residual (strong signal).** The intended pocket is inferred: the called pocket if it was called, else the
  most likely candidate given the CB launch direction (argmax of the posterior over candidates). The residual is the
  OB departure angle minus the required window centre, which maps back to Δφ via J⁻¹. Each shot gives one
  continuous observation, where a made/missed bit carries about 1 bit.
- **Speed residual (weak).** Only for shots where the candidate with matched spin is unambiguous: the CB travel
  distance against the nominal for the matched variant.
- **Made/missed (fallback).** The likelihood is the analytic P(make | σ), used when the OB direction is not tracked
  (occlusion).

### 5.3 Estimator

- Use a **log-spaced grid posterior** over σ_φ (48 bins, 0.05°–3°), plus 24 bins for σ_V. The posterior is a
  product of per-shot likelihoods. Residuals use a **Student-t (ν = 4)** to be robust to mis-inferred intent
  (Archibald & Nieves-Rivera's point that decision and execution are confounded). The prior is the population
  default tier (weight equivalent to about 20 shots).
- **Cost:** O(bins) per shot update, so microseconds. Stored per player as the 48+24 log-weights (SwiftData,
  competitive store).
- **Point estimate** for simulation: the posterior mean. **Uncertainty:** the posterior SD. Below 30 observed shots,
  the UI shows the skill as "learning" (an icon only).
- **Bucketed context (v2):** separate σ_φ by cut bucket and distance bucket, matching SPEC §6 per-shot features.
  Hierarchical shrinkage goes to the global σ.

### 5.4 Who uses whose skill

- The shooter's σ is used for the root shot and for every "we continue" ply. The **opponent's** σ is used for every
  ply where they shoot. For teams this is per team member in rotation, falling back to the team's mean σ. So
  `evaluate` takes `skills: [PlayerID: SkillModel]` plus the rotation, not one `SkillModel`.
- **Decision ratings** use the shooter's own σ. "Best" is judged relative to what *this* player can execute. A
  pro-level σ is optional, as a second "engine-ideal" line in game review.

---

## 6. Search and value

### 6.1 Value (SPEC §5.5.3, in WP units)

For candidate c from state (s, g) with shooter A:

```
EV(c) = E_noise[ W(s′, g′) ]      where (s′, g′) = (trace.final, RulesEngine.apply(outcome(trace), g).nextState)
W(s′, g′) = 1                      if g′.phase == .over(A)
          = 0                      if g′.phase == .over(B)
          = V_A(s′, g′)            if !turnPasses                (A shoots again)
          = 1 − V_B(s′, g′)        if turnPasses                 (incl. BIH options for B)
```

This is the spec's P(make)·value(resulting) + (1−P)·value(left to opponent), written as an expectation over
samples. It also handles scratches, fouls, the 8 early, the 9 on a combo, and similar outcomes correctly, because
the RulesEngine decides each outcome. The spec's formula would otherwise need special cases.

`V_X(s, g)` (the leaf) = **win probability for X to shoot from (s, g)** (§6.4), estimated from a 2-ply look-ahead:
- ply 2 (cheap): generate X's candidates (directs plus forced kicks). Score each with analytic P(make) and a
  nominal sim for the top 3 by P, then apply the 1-ply leaf below to each nominal end state.
- 1-ply leaf (no sims): the CueCard state score `q = 1·p1 + 0.33·p2 + 0.15·p3` over distinct legal ball-pocket
  shots for X (p from the analytic formula, geometry only, no sim, reusing the TP 3.4 closed form). It is mapped to
  WP via the WP model (§6.4).
- The "position value = best next-shot value, 2-ply" of the spec is ply 2 above.

### 6.2 Budget allocation (Full pass): Sequential Halving

Input: the K = 12 best Quick-pass candidates plus the 4 best safeties (16 arms). The total sample budget is
B = 768 noisy root sims.

```
rounds = ceil(log2(16)) = 4
for r in 0..<rounds:
    n_r = floor(B / (|arms| * rounds))                  // 12, 24, 48, 96 samples per arm
    run n_r more samples per arm (CRN seeds, see 6.3); update mean EV and SE
    keep the better half of arms by EV
```

Use Karnin et al.'s fixed-budget best-arm identification. It concentrates samples on the contenders, which matters
for ratings because the best/second-best gap is what decides "Best" vs "Good". The leaf (2-ply) is evaluated
per sample. Leaf results are **cached** by quantised end state (CB to a 2 cm grid, the set of balls on the table,
and the object balls to a 1 cm grid). Clustered outcomes, such as all the "made, CB within the same patch" samples,
then share one leaf evaluation. Expect a cache-hit rate of 40–70%.

### 6.3 Variance reduction and determinism

- **RNG:** counter-based. `seed = splitmix64(stateHash ^ engineSeed ^ sampleIndex)`, so sample i of *every*
  candidate draws the same standard-normal vector (z_φ, z_V, z_a, z_b) and is scaled by that candidate's σ. This
  gives common random numbers, and the result is independent of task scheduling order. The test harness can assert
  bit-identical `Evaluation`s.
- **Antithetic pairs:** sample i+1 uses −z. This is cheap and cuts the variance of P(make) estimates on symmetric
  windows.
- **Control variate:** EV_cv = mean(W) − β·(mean(1[made]) − P_analytic), with β fitted on the samples. When the
  analytic model is good, the SE on P drops by roughly 2x.
- **Reported SE:** each `CandidateScore` carries `evSE`. RATINGS uses it to avoid labelling within-noise gaps (for
  example, "Best" if ΔWP < max(0.01, 2·SE)).

### 6.4 Win-probability model (eval bar)

The goal is P(A wins this rack | s, g, skills), cheap enough to call for every leaf.

**v1: analytic inning model (ships in Phase 2).**
- From any state, X's **run-out probability** R_X(s) = product over X's remaining balls of the per-ball continuation
  probability, along a greedy plan. The greedy plan picks the next ball with the best q-contribution and takes the
  position-degradation factor κ(skill) = P(good leave | make), with κ fitted offline in `tools/` by virtual-table
  self-play per skill tier.
- After a miss, the opponent gets a "typical" leave. Their run-out probability from a typical leave with n balls
  left is r_X(n) = (p̄_X·κ_X)^n · ρ_X, from a per-tier table fitted by self-play.
- Two-player alternation solves in closed form. With A at the table, run-out R, and generic per-inning run-out
  probabilities r_A, r_B:
  `W_A = R + (1−R)·(1−r_B)·W_A^gen`, where `W_A^gen = r_A / (1 − (1−r_A)(1−r_B))`.
  Partial-progress inning variants (balls per side for 8-ball, lowest ball for 9-ball, BIH and the two-foul state
  for WPA 9-ball) replace the r(n) terms.
- Cost: O(balls), about 5 µs. It is monotone and bounded by construction (property-testable).

**v2: learned table (Phase 2 stretch / Phase 6).** Run engine-vs-engine self-play on the virtual table, offline on
macOS in `tools/`. Fit a small logistic model WP = σ(wᵀf) on features such as (nA, nB, shooter, BIH, best p1 for the
shooter, q-score, cluster count, skill-tier gap, rule set), and ship the weights in the bundle. Validate with
**Brier score and a reliability diagram** against held-out self-play. Accept only if Brier ≤ the v1 model's Brier on
the same data.

**Eval bar.** WP is from the perspective of the team at the table, **or** of team 0 (open question §11, Q3). It is
smoothed with hysteresis so that sample noise does not jiggle the bar (update only if |Δ| > 2·SE).

**Match-level (optional).** Per-rack p plus race length gives P(win race) via the negative binomial, consistent with
FargoRate's 2^(Δ/100) per-game odds.

---

## 7. Rating hand-off

The Engine computes, per shot:
- `WP_before` (Full eval of the pre-shot state, shooter to play) and `WP_after` (Quick + Full of the post-shot state).
- `EV_best`, `EV_chosen`, `ΔWP_decision = EV_best − EV_chosen`, with SEs, under the shooter's σ.
- `P_make_chosen` (baseline difficulty, for "low baseline P(make)" in Brilliant), the `ShotKind` of the chosen shot,
  and `nonObviousness`. The latter is the rank of the chosen shot in a *greedy* ordering by P(make), compared with
  its EV rank. A high-EV shot that a greedy player would not pick is "non-obvious".
- **Chosen-shot inference.** The tracked CB launch (direction, speed, estimated spin from the CB curve) is matched to
  the nearest candidate in stroke space (Mahalanobis distance under σ). If the nearest distance is above 3σ, a new
  candidate is built from the observed stroke and evaluated with the same seeds.
- **Execution:** `made / nearMiss / miss`. A near miss is when the OB departure angle is within 1.5·window
  half-width outside the window, or the OB rattles the jaws (pocket-jaw event in the trace or tracker). `position`
  is `inZone` if the actual CB rest position is in the **position zone**: the set of CB positions whose leaf value ≥
  0.8·the best sampled leaf value for that candidate, rasterised on a 2 cm grid from the MC samples. The same zone
  is reused for the Training "glowing zone" (SPEC §8).
- **Swing:** `WP_after − WP_before` (WPA delta, SPEC §6) feeds Brilliant/Great/Blunder per D2.

The thresholds, classes and the brilliant catalogue live in `docs/RATINGS.md`. **Proposal:** move `rate(...)` off the
actor into a pure `Ratings` function. It is pure given these numbers, which makes it trivially testable.

---

## 8. Swift 6 concurrency design

```swift
public actor ShotEngine {
    // isolated state: config, leaf cache (LRU, ~4k entries), current generation token
    public func evaluations(_ s: TableState, _ g: GameState, skills: SkillContext,
                            budget: EngineBudget = .standard) -> AsyncStream<Evaluation>
}
```

- **The actor holds state only, never runs the hot loop.** Hot code lives in `nonisolated` pure value types
  (`CandidateGenerator`, `ShotSampler`, `LeafEvaluator`, `WinModel`), all `Sendable`. The actor's method creates the
  stream. Inside it, `withTaskGroup` children run the pure functions on the global cooperative pool, so the actor
  serial executor is never blocked.
- **Chunking.** The unit of work is one *chunk* of ~16 sims (about 6 ms), never one sim per task (task overhead and
  allocation). Children = min(chunks, 2 × activeProcessorCount). Each chunk checks `Task.isCancelled` before
  starting. Chunks are short enough that no `Task.yield()` is needed inside them, which respects the forward-progress
  contract on the cooperative pool.
- **Cancellation and supersession.** A new table state (tracker says the balls moved or a new shot started) makes
  the caller cancel the previous stream's task. The actor also bumps `generation`, and results tagged with a stale
  generation are dropped. Target: cancellation is observed in < 10 ms.
- **Anytime.** The stream yields `.quick` (≤150 ms), then a `.full` partial after each Sequential-Halving round, then
  the final `.full`. The eval bar and overlay take the latest one.
- **Priorities.** Quick runs at `.userInitiated` and Full at `.utility`. The live overlay and Vision run on the
  main/GPU/ANE paths. Engine children must not starve the frame callback, so we reserve one P-core by capping
  children at `activeProcessorCount − 1` while the camera is live.
- **Thermal and battery.** Read `ProcessInfo.thermalState`. At `.serious`, halve B and K. At `.critical`, Quick only.
  Also scale with Low Power Mode.
- **Reentrancy.** No mutable actor state is read after an `await` without re-checking `generation`. The leaf cache is
  merged after each round on the actor (children return local caches), not written concurrently.
- **Memory.** `TableState` is a small struct (16 balls). Each sample keeps only (final state hash, W, made, CB rest);
  there are no traces. Peak is well under 5 MB.
- **Mesh.** Only the host runs the engine. `Evaluation` is `Codable` and compact (≤ 20 candidates, no traces, about
  4 KB), broadcast after `.full`, never while aiming (in the spirit of D3 for bandwidth).

---

## 9. Performance budget (iPhone 15 Pro Max)

Assumptions: 0.35 ms per sparse sim on a P-core. E-cores are about 3x slower, giving about 2.5 effective P-cores
after reserving headroom. 8-ball mid-rack with 7 legal targets is the typical worst case. The open table after the
break, with 15 targets, is the hard worst case, handled by the K caps.

### 9.1 Quick pass (target ≤150 ms wall p95; also the "candidate eval" budget)

| Step | Work | CPU (ms) | Wall (ms) @2.5 cores |
|---|---|---|---|
| Legal targets + geometry + capsule pruning | ~3k segment tests | 0.1 | 0.1 |
| Aim solve (Newton) + Jacobian sims (±δφ), per target-pocket | 20 tp × 3 sims | 21 | 8 |
| Nominal sims per variant (after dedup) | 20 tp × 6 = 120 sims | 42 | 17 |
| Banks/kicks/combos (only if needed) | ≤ 22 × 3 sims | 23 | 9 |
| Quick safety grid | 72 sims (only if triggered) | 25 | 10 |
| Leaf eval V0 (no sims) per variant | 140 × ~40 analytic shots × 1 µs | 6 | 2.5 |
| WP model | per leaf, ~5 µs | 1 | 0.4 |
| **Total (typical / worst)** | | **~70 / ~120** | **~30 / ~50** |

Single-threaded worst case on E-cores only (thermal-throttled) is about 360 ms. Mitigations: K caps and dropping the
quick safety grid. This is a **perf-gate test** (§10.3).

### 9.2 Full pass (target ≤2.5 s wall p95; SPEC gate < 3 s)

| Step | Work | CPU (ms) | Wall (ms) |
|---|---|---|---|
| Root MC, Sequential Halving | 768 noisy sims × 0.4 ms (post-shot clustering is denser) | 310 | 125 |
| 2-ply leaf per sample, top-3 nominal sims | 768 × 3 × 0.35 ms × (1 − 0.5 cache hit) | 400 | 160 |
| Ply-2 analytic generation | 768 × 0.5 × 60 µs | 25 | 10 |
| Full safety grid + MC on 4 best safeties | 432 + 4 × 96 sims | 290 | 115 |
| RulesEngine.apply per sample | ~2k × 5 µs | 10 | 4 |
| Chosen-shot re-eval (post-shot) | 96 sims + leaf | 70 | 30 |
| **Total** | | **~1.1 s** | **~0.45 s** |

That leaves headroom for 2x physics regressions, dense racks (sims near 1 ms), or doubling B for better rating
stability. The **break** (13 ms per sim) is not searched live: break candidates and their post-break WP are
precomputed offline. Rating a break uses 32 samples (≈420 ms CPU, background), only to decide whether the outcome
was lucky or good.

### 9.3 Instrumentation
`EngineBudget` counts sims and wall time per stage and exposes them in the Debug HUD (D9) and `os_signpost`
intervals for Instruments. The perf gate reads p50/p95 over the 20 reference positions × 20 runs.

---

## 10. Risks

| # | Risk | Impact | Mitigation |
|---|---|---|---|
| R1 | Sim-to-real gap: physics not yet calibrated to real cloth or cushions (D16 constant e) | P(make) and the position zone are biased, so recommendations are wrong in a consistent direction | The skill calibration absorbs the aim bias. Add a per-table "fudge" σ_pos. Real-table calibration is a Phase-3 item. Never display numeric precision. |
| R2 | Perception noise (±0.5–1 cm ball positions, ID errors) | Blocked/clear and thin-cut decisions flip | σ_pos is part of the analytic P. Capsule tests use R + 3σ_pos margin. Recompute only when the tracker is stable for N frames. |
| R3 | Default skill tiers are guesses | Early ratings are miscalibrated (calls a 55% shot "easy") | Ship conservative defaults. Show a "learning" icon for under 30 shots. The prior weighs about 20 shots. Ask the user to review the tier targets. |
| R4 | Intent inference wrong (bar 8-ball has no called pocket) | Execution error is mis-attributed and ratings are unfair | Student-t residuals, posterior over intended candidates, and a low-confidence flag that suppresses Brilliant/Blunder when intent is ambiguous. |
| R5 | MC noise makes ratings flicker between Best and Good | User distrust | CRN, deterministic seeds, SE-aware thresholds, and a fixed final rating (no re-rating after display). |
| R6 | 2-ply horizon misses pattern-play and safety exchanges | "Best" disagrees with strong players | The WP model encodes rack-level run-out. Add the user's review of 20 positions to the gate. v2 can use a learned leaf from self-play. |
| R7 | Thermal throttling during long sessions with the camera on | Full pass exceeds settle time | Anytime stream (a Quick result always exists), thermal-state scaling, and a core reserved for the camera. |
| R8 | Combinatorial blow-up on the open 8-ball table (15 targets) | Quick pass over 150 ms | Class ordering, P-threshold pruning, and K caps. Worst-case positions are among the 20 reference positions. |
| R9 | Rules and physics coupling: the RulesEngine depends on accurate `ShotOutcome` from the trace (first contact, rail after contact) | Mis-scored fouls in MC | Reuse the one `ShotOutcome.from(trace)` builder that the Rules tests already cover. Golden tests per foul type. |
| R10 | Spec conflict between the 150 ms target and "Eval < 3 s" | Ambiguous gate | Both apply: 150 ms for Quick and 2.5 s/3 s for Full (§11, Q1). |

---

## 11. Open questions for the user (product ambiguity, so ask rather than guess)

1. **Gates.** Confirm two gates: Quick ≤150 ms p95 (live re-rank, overlay colour) and Full ≤2.5 s p95, inside the
   spec's < 3 s.
2. **Skill learning source.** Learn σ from competitive shots only (keeps stats separate), or also from Training shots
   (more data, and only σ is shared, not stats)?
3. **Eval-bar perspective.** Should the bar show the shooter's chances, or a fixed team's side (chess.com style:
   white/black)?
4. **Decision-rating baseline.** Judge against what *this player* can execute (proposed), or against a fixed strong
   player?
5. **Bar 8-ball calling.** When no pocket is called, may the engine infer intent, or should ratings skip shots with
   ambiguous intent?

---

## 12. Interface refinements (proposed delta to `docs/INTERFACES.md` → Engine)

```swift
public enum ShotKind: Hashable, Codable, Sendable {
    case direct, bank(Rail), kick(Rail), combo(via: BallID), safety, breakShot
}
public struct Candidate: Hashable, Codable, Sendable {
    public var kind: ShotKind
    public var target: BallID?          // nil for safety-without-target / break
    public var pocket: Pocket?
    public var stroke: Stroke
    public var cuePlacement: Vec2?      // ball-in-hand placement
    public var ghost: Vec2?             // overlay
}
public struct SkillModel: Hashable, Codable, Sendable {
    public var sigmaAim: Double          // rad
    public var sigmaSpeedRel: Double     // fraction of intended speed
    public var sigmaTip: Double          // ball radii
    public var observations: Int
    public static let beginner, amateur, strong: SkillModel
    public func updated(with obs: SkillObservation) -> SkillModel   // grid-posterior update (pure)
}
public struct SkillContext: Sendable { public var byTeam: [Int: [SkillModel]]; public var rotation: [Int: Int] }
public struct CandidateScore: Hashable, Codable, Sendable {
    public var candidate: Candidate
    public var pMake: Double, ev: Double, evSE: Double, samples: Int
    public var positionZone: ZoneGrid?   // coarse raster, for execution rating + training
}
public struct Evaluation: Hashable, Codable, Sendable {
    public enum Tier: String, Codable, Sendable { case quick, partial, full }
    public var stateHash: UInt64, generation: UInt64, tier: Tier
    public var shooter: Int
    public var winProbability: Double, winProbabilitySE: Double
    public var ranked: [CandidateScore]  // best first, ≤ 20
    public var stats: EngineStats        // sims, ms per stage (debug HUD only)
}
public struct EngineBudget: Sendable { var maxTargetPockets = 24, topK = 12, safeties = 4, rootSamples = 768,
                                       quickDeadline: Duration = .milliseconds(150), fullDeadline: Duration = .seconds(2.5) }
public struct EngineRNG: Sendable { init(seed: UInt64); func normals(sample: Int) -> SIMD4<Double> }  // counter-based

public actor ShotEngine {
    public init(rules: RulesEngine, simulator: Simulator, seed: UInt64 = 0)
    public nonisolated func candidates(_ s: TableState, _ g: GameState) -> [Candidate]          // pure, sync
    public func evaluations(_ s: TableState, _ g: GameState, skills: SkillContext,
                            budget: EngineBudget) -> AsyncStream<Evaluation>                      // anytime
    public func evaluate(_ s: TableState, _ g: GameState, skills: SkillContext,
                         budget: EngineBudget) async -> Evaluation                                // last of stream
    public func score(stroke: Stroke, in s: TableState, _ g: GameState, skills: SkillContext,
                      against e: Evaluation) async -> CandidateScore                              // chosen shot
    public nonisolated func winProbability(_ s: TableState, _ g: GameState, skills: SkillContext) -> Double
}
public enum Ratings {                                                                              // pure, per RATINGS.md
    static func rate(chosen: CandidateScore, before: Evaluation, after: Evaluation,
                     trace: ShotTrace, outcome: RuleResult) -> (DecisionRating, ExecutionRating)
}
```

Deltas from the stub: (1) `skill: SkillModel` becomes `SkillContext` (the opponent's noise is needed). (2) An anytime
stream and a budget are added. (3) `candidates` and `winProbability` are `nonisolated` and pure. (4) `rate` moves to a
pure `Ratings` namespace. (5) A deterministic `EngineRNG` is injected. (6) `score(stroke:)` handles shots that are not
among the candidates.

Dependencies needed from other modules: `ShotOutcome.from(trace:)` (Rules/Physics boundary), `TableSpec` pocket
jaw geometry (Geometry), and a tracker covariance per ball (Tracking, later; default constant until then).

---

## 13. TDD test plan (`Packages/CueCore/Tests/EngineTests`, `swift test`)

Red → green per row. Fast tests (< 1 s each) run in every `swift test`. Tests tagged `.slow` (MC agreement,
self-play calibration) run in CI and on demand.

### 13.1 Unit / property tests

| Area | Tests |
|---|---|
| Geometry helpers | Ghost ball at 2R along the pocket line. Mirror-bank point on each rail. Capsule obstruction: clear, grazing at R+ε, blocked. Pocket effective centre shifts toward the far jaw as the angle grows. |
| Generator | Straight-in present when clear. Absent when blocked, or when the target is illegal (8-ball group, 9-ball non-lowest), matching `RulesEngine.legalTargets` exactly. Banks/kicks appear only when directs are scarce or snookered. Kick generated when snookered. Combos only with a legal first contact. BIH placements respect `.behindHeadString`. Variant dedup merges equivalent end states. Counts never exceed `EngineBudget`. |
| Analytic P(make) | In [0,1]. σ→0 gives 0/1 (window test). Monotone decreasing in d1, d2 and cut angle (property test over random geometry). Symmetric for ± cut. Agrees with the TP 3.4 closed form within 10% for no-throw configurations. **Agrees with 2,000-sample MC within 3 SE on 50 seeded random shots (`.slow`).** Hanging-ball case > 0.95 even at a 60° cut. |
| Noise model / RNG | Same seed gives identical normals. Antithetic pair sums to 0. 10k-sample mean and SD within 2% of the specification. Tip offset clipped to the miscue radius. |
| Skill estimator | Synthetic shooters with known σ_φ ∈ {0.2°, 0.5°, 1.0°}: the posterior mean is within 15% after 200 residual observations and within 30% after 200 made/missed-only observations. 0 observations returns the prior. Outliers (5% mis-inferred intent) do not move the estimate by more than 10% (Student-t). Updates are order-independent. |
| WP model | Bounded in [0,1]. W_A + W_B = 1 for the same state with the shooter swapped and generic re-entry. `.over` states give 0/1. Monotone: fewer own balls raises WP, BIH raises WP, opponent on two fouls (WPA 9-ball) raises WP. Equal skill on a symmetric state is within 0.5 ± 0.05. Self-play Brier ≤ the baseline (`.slow`). |
| Value / search | EV of a guaranteed-scratch shot is ≤ WP with opponent BIH. Pocketing the 8 early in 8-ball gives EV ≈ 0. A 9 on a combo gives EV ≈ 1. Sequential Halving never drops the arm with the best true EV in a synthetic bandit with a gap of 0.1 (≥ 95% of 200 seeds). **Determinism:** the same inputs give bit-identical `Evaluation` regardless of core count. CRN: the variance of the EV difference is lower than with independent seeds. |
| Concurrency | Cancelling during Full returns within 10 ms (measured with a clock). A stale generation is never yielded. The stream yields `.quick` before `.full`. No data races under TSan (`swift test --sanitize=thread`). |
| Ratings boundary | `Ratings.rate` is pure. A ΔWP inside 2·SE is never below "Good". Ambiguous intent suppresses Brilliant/Blunder. These follow RATINGS.md thresholds once approved. |

### 13.2 The 20 reference positions (SPEC Phase-2 gate)

Stored as JSON fixtures in `Tests/EngineTests/Fixtures/positions/NN-name.json` (TableState + GameState + skills +
expected assertions). Each position is rendered by the virtual table for the user review that the gate requires.
Assertions are **qualitative and robust**: class, ordering, a P bucket and the WP direction. They are never exact
numbers.

| # | Position | Rules | Assertion |
|---|---|---|---|
| 1 | Short straight-in, CB 30 cm behind OB, corner | 9-ball | best = direct, P bucket high, WP > 0.5 |
| 2 | 9-ball last ball, easy | 9-ball | best = direct on the 9, WP ≥ 0.85 |
| 3 | 30° cut mid-table to corner | 8-ball | direct, P medium-high |
| 4 | Long 60° thin cut vs a simple safety | 9-ball | amateur σ: safety EV > pot EV. Strong σ: pot EV > safety EV (skill-dependence test) |
| 5 | Steep-angle side pocket vs corner option | 8-ball | the side candidate is rejected or low. Best = corner |
| 6 | Direct blocked, clean one-rail bank | 9-ball | bank generated and best offensive |
| 7 | OB frozen to the rail, along-the-rail shot | 8-ball | direct P medium. Throw-corrected aim differs from the geometric aim |
| 8 | Snookered (every legal target hidden) | 9-ball | only kicks/safeties generated. Best = kick with a legal hit |
| 9 | Dead 2→9 combo | 9-ball | combo generated. EV > direct on the 2 |
| 10 | Easy pot with no shape vs harder pot with perfect shape (2 balls + 8 left) | 8-ball | 2-ply picks the shape shot (position-play test) |
| 11 | Nothing makeable, good hide available | 8-ball | best = safety. Opponent best P low after the safety |
| 12 | Ball in hand, 3 balls left | 9-ball | placement chosen. WP > 0.7 |
| 13 | On the 8 with a scratch line on the natural angle | 8-ball | best variant avoids the scratch (spin/speed). Scratch EV ≈ 0 |
| 14 | Open table after the break (D11), 15 balls | bar 8-ball | Quick pass ≤150 ms. Candidates for both groups |
| 15 | Easy pot that can break a cluster vs a pot that leaves the cluster | 8-ball | the breakout variant ranks higher |
| 16 | We have 7, opponent has 1 + 8 | 8-ball | WP low. Safety preferred over a low-P pot |
| 17 | Ball hanging in the jaws at a 50° cut | 9-ball | P > 0.95 |
| 18 | Two-way shot (pot or leave safe on a miss) | 9-ball | the two-way variant has a higher miss-branch value than the plain pot |
| 19 | Opponent on two fouls (WPA 9-ball) | WPA 9-ball | safety value raised vs the same position without the two fouls |
| 20 | Racked table, break | each rule set | only break candidates. WP from the precomputed break table. No live break MC |

The gate also requires the user to review the ratings on these positions (SPEC §9), the Quick and Full p95 on the
15 Pro Max (§9), and every rule-set path to be exercised.

### 13.3 Performance tests
- **macOS (`swift test`, `.slow`):** sim-count assertions (budget respected) and a wall-time regression guard of 2x
  the baseline, recorded per machine.
- **Device (XCTest `measure` in the app test target, 15 Pro Max):** all 20 positions × 20 runs. Assert p95 Quick ≤
  150 ms and p95 Full ≤ 2.5 s with the camera pipeline running (replay `.mov` source), plus the thermal-state log.
  Repeat on the 17 Pro Max for information only.

### 13.4 Build order (each step red → green)
1. RNG + SkillModel sampling → 2. geometry helpers + obstruction → 3. direct generator + legality →
4. aim solve + analytic P(make) → 5. leaf evaluation (CueCard q) → 6. WP v1 → 7. Quick pass + budget →
8. MC + CRN + Sequential Halving → 9. 2-ply + cache → 10. safeties + BIH → 11. banks/kicks/combos →
12. actor + stream + cancellation → 13. chosen-shot scoring + Ratings boundary → 14. the 20 positions → 15. device perf.

---

## Sources

- Smith, "Running the Table: An AI for Computer Billiards", AAAI 2006. https://cdn.aaai.org/AAAI/2006/AAAI06-156.pdf · https://mlanthology.org/aaai/2006/smith2006aaai-running
- Smith, "PickPocket: A computer billiards shark", Artificial Intelligence 2007. https://datalearner.com:8443/academic/journal-papers/0004-3702/volumes-and-issues/321/paper-detail/68497
- Archibald, Altman, Greenspan, Shoham, "Computational Pool: A New Challenge for Game Theory Pragmatics", AI Magazine. https://yoavshoham.net/_files/ugd/a1a3b1_5964a39d807a4fce8768f64cb69d6b25.pdf
- Archibald, Altman, Shoham, "Success, strategy and skill: an experimental study", AAMAS 2010. https://ifaamas.csc.liv.ac.uk/Proceedings/aamas2010/pdf/01%20Full%20Papers/22_05_FP_0677.pdf
- Archibald et al., "Analysis of a Winning Computational Billiards Player", IJCAI 2009. https://mlanthology.org/ijcai/2009/archibald2009ijcai-analysis
- Leckie & Greenspan, "An Event-Based Pool Physics Simulator", ACG 2005 / LNCS 4250. https://www.springerprofessional.de/en/an-event-based-pool-physics-simulator/1276086
- Archibald & Nieves-Rivera, "Bayesian Execution Skill Estimation", AAAI 2019. https://ojs.aaai.org/index.php/AAAI/article/view/4556
- "Estimating Agent Skill in Continuous Action Domains", JAIR 2024. https://jair.org/index.php/jair/article/view/15326
- Alciatore, TP 3.4 "Margin of error based on distance and cut angle". https://drdavepoolinfo.com/technical_proofs/TP_3-4.pdf
- Alciatore, margin-for-error FAQ. https://drdavepoolinfo.com/faq/cut/margin-for-error/
- Alciatore, TP A.13 (pocket tolerance). https://billiards.colostate.edu/technical_proofs/new/TP_A-13.pdf
- Alciatore, pocket size and centre. https://drdavepoolinfo.com/pocket/size-and-center/
- Rauser, pool make-probability calculator. https://jrauser.github.io/pool/
- Kiefl, pooltool (GitHub, JOSS 2024). https://github.com/ekiefl/pooltool · https://theoj.org/joss-papers/joss.07301/10.21105.joss.07301.pdf
- chess.com, "How are moves classified?". https://support.chess.com/en/articles/8572705-how-are-moves-classified-what-is-a-blunder-or-brilliant-move
- FargoRate, "Behind the curtain". https://fargorate.com/fargorateblog/archive/behindthecurtain/
- Karnin, Koren, Somekh, "Almost Optimal Exploration in Multi-Armed Bandits", ICML 2013. https://proceedings.mlr.press/v28/karnin13.html
- Variance reduction / common random numbers. https://en.wikipedia.org/wiki/Variance_reduction · https://rossetti.github.io/KSLBook/ch9VRTs.html
- Swift forums, "Concurrency and CPU-bound tasks". https://forums.swift.org/t/concurrency-and-cpu-bound-tasks/49716
- Swift forums, "@concurrent for expensive synchronous work". https://forums.swift.org/t/is-concurrent-now-the-standard-tool-for-shifting-expensive-synchronous-work-off-the-main-actor/82976
- Donny Wals, WWDC21 notes "Swift concurrency: Behind the scenes". https://www.donnywals.com/wwdc-notes-swift-concurrency-behind-the-scenes/
- Apple A17 Pro (core configuration). https://en.wikipedia.org/wiki/A17_Pro

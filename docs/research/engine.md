# Engine research and design proposal (rev 2)

Status: research proposal for Phase 2, revised after a critical review (every item addressed; see the Reviewer notes
at the end). It needs head-orchestrator and user review before the `INTERFACES.md` change.
Scope: SPEC §5.5 (candidates, Monte Carlo, value, win probability, ratings hand-off), the INTERFACES Engine stub,
the on-device perf budget, Swift concurrency, mesh hand-off, and the TDD plan. Class rules live in
`docs/RATING_CLASSES.md` (D18, source of truth) and the brilliant catalogue in `docs/RATINGS.md` (D2). This doc
covers only the numbers the Engine hands to them.

---

## 0. TL;DR

- **Two-tier anytime engine plus a rating pass.** **Quick** ranks candidates with an analytic P(make) and about
  1.5 noise-free sims per variant, about 230-260 sims in all. **Full** runs Monte Carlo (MC) with execution noise on
  the top 16 arms, with a 2-ply leaf. The **rating pass** starts at the stroke and spends paired samples on chosen vs best.
  Results stream as `Evaluation` snapshots.
- **Value is in win-probability (WP) units.** Every sampled outcome goes through `RulesEngine.apply`, which covers
  fouls, ball in hand (BIH), option nodes (push-out, accept-or-pass) and turn passing. A WP model then scores it.
- **Skill model.** Gaussian noise on (aim φ, relative speed V, tip offset a, b in ball radii). σ is learned from tracked
  OB departures, with the tracker's own noise and the shooter's intent window in the likelihood.
- **Perf is not measured yet.** No per-sim number exists for the fixed simulator (CHECKLIST: physics rejected and
  being fixed). Every budget below is a **sim count**, and wall time = sims × t_sim / c. With c = 2 engine threads,
  Quick ≤ 150 ms needs t_sim ≤ ~1.1 ms. Full ≤ 2.5 s needs t_sim ≤ ~1.3 ms in the worst case. **Step 0 of Phase 2 is a
  device microbenchmark (§9.1).** Budgets get frozen only after it runs.
- **Resolution limit (needs a user call).** Paired-difference SE at the affordable sample count is about 0.02 WP.
  D18 bands 2 points wide (Best ≤ 2 vs Good 2-5) can't be resolved reliably when chosen and best are different shots.
  The proposal: call "Best" unless the loss is confidently > 2 points (§7.2).
- **Determinism.** The input state is quantised, seeds come from a proper hash mixer, leaves are cached by canonical
  representative, and reductions run in sample-index order. The result is bit-identical on one platform and build,
  whatever the scheduling.

---

## 1. Constraints and inputs

| Constraint | Source | Consequence for the Engine |
|---|---|---|
| All AI on-device, zero network | CLAUDE.md, SPEC §2 | Pure Swift in `Packages/CueCore/Engine`. Precomputed tables ship in the bundle. |
| iPhone 15 Pro Max is the perf gate (A17 Pro: 2 P-cores @ 3.78 GHz + 4 E-cores @ 2.11 GHz) | D6, [A17 Pro – Wikipedia](https://en.wikipedia.org/wiki/A17_Pro) | Clock speeds only. **P/E throughput ratio and effective core count are unmeasured**, and §9.1 measures them. |
| Physics cost per sim: **unknown**. The only number on record is "16-ball break 13 ms" in the supervisor's rejection note, with no hardware or build stated | CHECKLIST (physics row) | Budgets are sim counts plus a required t_sim (§9). |
| SPEC §5.5.7: background actor, "finish within ball-settling time (~2–4 s)". Phase-2 gate: "Eval < 3 s on device" | SPEC §5.5, §13 | Full ≤ 2.5 s is the proposed target. Quick ≤ 150 ms is **this doc's proposal, not a spec gate** (§11 UD-E1). The settle-time meaning is §11 UD-E2. |
| No text/audio while aiming; feedback never numeric-precise | SPEC §2, §5.6 | The Engine outputs Doubles and the UI buckets them. Exact numbers appear only in the dev HUD (D9). |
| Training stats never touch competitive stats | CLAUDE.md | σ learns from competitive shots by default (§11 UD-E6). |
| Host owns the engine; profiles live on each phone | SPEC §5.7, §2 | σ travels in the profile summary, and updates go back to the owning phone (§8.6). |
| Class bands (D18): Best ≤ 2 pts, Good 2–5, Okay 5–8, Inaccuracy 8–15, Mistake 15–30 | RATING_CLASSES.md | These set the SE the rating pass must reach (§7.2). |

---

## 2. Prior art (what we borrow)

| System / source | Key idea | What we take |
|---|---|---|
| **PickPocket** (Smith, AAAI 2006, which reports winning the 10th Computer Olympiad 8-ball). [AAAI PDF](https://cdn.aaai.org/AAAI/2006/AAAI06-156.pdf). Journal version: [Artif. Intell. 171 (2007) 1069–1091, doi:10.1016/j.artint.2007.04.011](https://doi.org/10.1016/j.artint.2007.04.011) | Class-ordered move generator. V from a min-speed table, raised in steps; a, b varied for position. P(make) from a 30⁴ lookup. Evaluation Σ dᵢpᵢ over the best n shots. MC search with 15 samples, 2-ply, 60 s per shot. Root-only safeties when best P < t0 = 65%. | The speed/spin variant grid, discounted best-n evaluation, and MC 1-ply plus a cheap 2nd ply. **Not** its "banks only if no direct" gating (§4.1). t0 = 65% is tuned for a low-noise computer agent, so ours is a tunable default. |
| **CueCard** (Archibald, Altman, Greenspan, Shoham; won the 2008 ICGA tournament). [AI Magazine paper](https://yoavshoham.net/_files/ugd/a1a3b1_5964a39d807a4fce8768f64cb69d6b25.pdf) | Noise-free filter, then noisy MC on variants. State value **1·p1 + 0.33·p2 + 0.15·p3**. Top-k second ply. BIH placements near OBs. A precomputed break (92% pot). 20 CPUs gave a 55.4% win rate against 1 CPU. | The weights, the noise-free filter, top-k refinement, BIH placements and the precomputed break. The 1-CPU agent still had about 10 min per game, so using it to justify a 2.5 s phone budget is **an extrapolation to test on the gate positions**, not evidence. |
| **ICGA noise model** (same paper; Leckie & Greenspan simulator, [Springer](https://www.springerprofessional.de/en/an-event-based-pool-physics-simulator/1276086)) | Gaussian on (θ, φ, V, a, b), σ = (0.1°, 0.125°, 0.075 m/s, 0.5 mm, 0.5 mm). PickPocket "strong amateur" E_high = (0.185°, 0.03°, 0.085 m/s, 0.8 mm, 0.8 mm). | The shape of the noise model. Our σ_φ comes from tier targets (§5.1). |
| **Noise vs strategy** ([AAMAS 2010](https://ifaamas.csc.liv.ac.uk/Proceedings/aamas2010/pdf/01%20Full%20Papers/22_05_FP_0677.pdf)) | Extra thinking time helped most at about 1.4× tournament noise. | **Hypothesis to test** on the gate positions: safety search matters more at amateur noise. That is why safeties are always generated (§4.4). |
| **Execution-skill estimation** (Archibald & Nieves-Rivera, [AAAI 2019](https://ojs.aaai.org/index.php/AAAI/article/view/4556); [JAIR 2024](https://jair.org/index.php/jair/article/view/15326)) | Bayesian estimation of execution noise from observed actions. Decision and execution are confounded. | The grid posterior, with intent marginalised over the acceptance window (§5.3). |
| **Dr. Dave TP 3.4** ([PDF](https://drdavepoolinfo.com/technical_proofs/TP_3-4.pdf)) | d = CB–OB distance (assumes d ≫ R), φ = cut angle, Δφ = CB direction error, Δθ = OB direction error. Exact: **Δθ = asin((d/2R)·sin Δφ + sin(φ − Δφ)) − φ + Δφ** (eq. 1). Differentiating at Δφ = 0 gives **Δθ ≈ Δφ · d / (2R cos φ)**. | The closed-form gain g(d, φ) = d/(2R cos φ) for Quick P(make), and a test oracle (§13.1). Check: at d = 1 m, φ = 30°, Δφ = 0.1° the exact value is 2.040° and the linear value 2.020° (1%). At φ = 60° they are 3.70° vs 3.50° (5%). |
| **TP A.13 / pocket centre** ([TP A.13](https://billiards.colostate.edu/technical_proofs/new/TP_A-13.pdf), [pocket centre](https://drdavepoolinfo.com/pocket/size-and-center/), [margin FAQ](https://drdavepoolinfo.com/faq/cut/margin-for-error/)) | Pocket angular window 2·atan((p/2)/d_p). The effective centre shifts toward the far jaw. | The geometric window used in Quick (§4.3). |
| **pooltool** ([GitHub](https://github.com/ekiefl/pooltool), [JOSS 2024](https://theoj.org/joss-papers/joss.07301/10.21105.joss.07301.pdf)) | Reference simulator (D10). | Offline P(make) ground truth for fixtures. |
| **chess.com classification** ([support](https://support.chess.com/en/articles/8572705-how-are-moves-classified-what-is-a-blunder-or-brilliant-move)) | Expected-points-loss bands. | Background only. D18's bands govern (§1). |
| **FargoRate** ([blog](https://fargorate.com/fargorateblog/archive/behindthecurtain/)) | Game odds 2^(Δ/100). | Optional race-level WP, v2. |
| **Sequential Halving** ([Karnin et al., ICML 2013](https://proceedings.mlr.press/v28/karnin13.html)) | Fixed-budget best-arm identification. | Full-pass allocation (§6.2). |
| **Common random numbers / control variates** ([Wikipedia](https://en.wikipedia.org/wiki/Variance_reduction), [KSL §9.2](https://rossetti.github.io/KSLBook/ch9VRTs.html)) | Synchronised streams for comparisons. A control variate needs a control whose mean is **known exactly**. | CRN plus antithetics, and a linearised control with an exact mean (§6.3). |
| **Swift concurrency** ([SE-0461](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0461-async-function-isolation.md), [SE-0417](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0417-task-executor-preference.md), [forums: CPU-bound tasks](https://forums.swift.org/t/concurrency-and-cpu-bound-tasks/49716)) | SE-0461: with `NonisolatedNonsendingByDefault` on, nonisolated async functions **run on the caller's actor**, and `@concurrent` switches off it. SE-0417: a `TaskExecutor` is a thread source. `withTaskExecutorPreference`, `Task(executorPreference:)` and group children inherit it. | A dedicated engine executor plus `@concurrent` entry points (§8). |

No prior system ran under a phone budget, and whether these levers are enough is something the gate positions test.

---

## 3. Architecture and shot timeline

```
            TableState(quantised) + GameState + SkillContext
                         │
     ┌───────────────────▼────────────────────┐
     │ CandidateGenerator  (pure, sync)       │  geometry + RulesEngine.legalTargets
     └───────────────────┬────────────────────┘
 QUICK  analytic CB-path dedup → ~1.5 nominal sims/variant → analytic P → analytic leaf ─► Evaluation(.quick)
                         │ top-K (12) + 4 safeties (+ push-out/foul arms when applicable)
 FULL   J + sampled window for top-K → Sequential-Halving MC (CRN) → RulesEngine.apply → 2-ply leaf ─► .partial … .full
 RATING (from stroke)   chosen-shot inference → paired chosen-vs-best samples until the band is resolved ─► RatingInputs
```

### 3.1 Timeline of one shot (host phone)

| Phase | Time | Engine work | Live on screen |
|---|---|---|---|
| Balls settle, tracker stable (N frames) | t0 | **Post-shot Quick** on the new state → W₁, Rₒ, zone check. Then the **Full** pass on the same state, which is also the next shot's pre-shot eval | Rating badge at t0 + Quick (≤ ~150 ms, target) |
| Aiming (typically several s, unmeasured) | t0 … ts | Full continues. The eval bar updates on each `.partial`. The overlay uses Quick P for colour | Lines, colour, eval bar |
| Stroke detected, CB launch measured (~5 frames ≈ 170 ms) | ts | Pre-shot Full is **not** cancelled, because its input state is still the pre-shot state. The **rating pass** starts: intent inference, then paired samples | Lines fade (overlay rules) |
| Balls rolling (seconds, unmeasured) | ts … t1 | The rating pass and any unfinished pre-shot Full work run | — |
| Settle | t1 | Post-shot Quick → badge (loss L from the rating pass, swing from Quick W₁) → next Full | Badge |

Consequences:
- **Rating latency after settle ≈ settle detection + one Quick pass.** The expensive work (EV_best, EV_chosen, L)
  runs before the balls stop. This proposal reads "within settle time" as "badge ready when balls stop".
  That reading is §11 UD-E2.
- **W₁ for the live badge comes from the Quick tier.** The post-settle Full refines W₁ later for game review and
  Brilliant (decided post-game per D18). The live badge is never changed after display (R5). Only the post-game
  Brilliant upgrade can change it, and D18 already allows that.
- **Fast shooters.** If the stroke comes before the pre-shot Full finishes, the rating pass uses the latest
  `.partial` and keeps going. When the arms are still unresolved at settle, the rating is marked low-confidence and
  promotions are suppressed.
- **Concurrent load.** While aiming, the Full pass shares the phone with YOLO (30 fps), pose, the tracker and the
  60 fps overlay. That cost is measured, not assumed (§9.4).

Consumers:
1. **Overlay (60 fps).** No MC. One nominal sim of the live stroke when the stick moves enough to matter. Colour
   comes from the matching candidate's Quick P, or else the analytic P of the live line (closed form, no sims).
2. **Eval bar.** WP from the latest `Evaluation`.
3. **Rating.** The `RatingInputs` (§7) for the pure `Ratings.rate`.

---

## 4. Candidate generation

### 4.1 Shot classes (all generated every time, capped)

SPEC §5.5.1 asks for every legal target × pocket with direct, simple banks, simple combos and kicks. D2 and
RATINGS.md make kicks and banks core Brilliant classes. So **banks, kicks and combos are always generated**, pruned
by analytic P and hard caps. They are not gated on whether directs exist.

| Class | Geometry | Cheap filter (before any sim) | Cap (Quick → Full) |
|---|---|---|---|
| **Direct** | Ghost G = O + 2R·û(O→effective pocket centre) ([Dr. Dave](https://drdavepoolinfo.com/pocket/size-and-center/)) | Cut < 80°. Clear capsules C→G and O→pocket against all balls and jaws. Side-pocket approach < ~55° | ≤ 24 target-pockets (typical 8–20) |
| **Bank** (1 rail) | Mirror the pocket across the rail (offset R), then correct with the sim | Clear segments. Not the pocket's own rail. Analytic P > 0.02 | 8 |
| **Kick** (1 rail, cue first) | Mirror the ghost across the rail | Legal first contact reachable. Always included when snookered | 4 (8 when snookered) |
| **Combo** (2-ball) | Chained ghosts | Legal first contact. Both cuts < 60°, distances < 0.6 m | 4 |
| **Carom / kiss** | **Not generated in Phase 2** (observed only). RATINGS B8 wants it | — | §11 UD-E8 |
| **Safety** | §4.4. Always a coarse set, plus the full grid when triggered | Legal first contact | 36 coarse / 432 full |
| **Push-out** (WPA 9-ball, `phase == .pushOutAvailable`) | Direction grid 15° × 2 speeds, plus "roll behind a blocker" targets. Wrong-ball/no-rail fouls suspended (WPA 5.4) | Not a scratch or off-table (nominal) | 48 |
| **Intentional foul** | Tie-up, pocket block, or dump an opponent hanger (RATINGS B6). CB to an illegal or opponent ball at 2 soft speeds, for balls within 40 cm of a pocket or cluster | The resulting state is scored with opponent BIH | 8, **if UD-E8 says Phase 2** |
| **Break** | Fixed menu, 3 placements × 2 speeds, precomputed offline per rule set | `phase == .breakShot` | 6 |
| **Ball in hand** | CueCard-style placements behind the ghost at 15/30/45 cm, filtered by `.behindHeadString` | | ≤ 24 placements, scored analytically first, best 6 simulated |

**Complexity.** Capsule tests are O(T·P·B), about 2.7k segment-vs-circle tests.

### 4.2 Stroke variants

- **Speeds snap to the 5-step power meter.** Each meter step k has a nominal CB speed v_k. These are tunable
  defaults, {0.8, 1.3, 2.0, 3.0, 4.5} m/s, to calibrate with Training data. `V_min` comes from closed-form rolling
  deceleration and cos²α energy transfer. Quick uses the lowest feasible step and the next two (3 speeds), and Full
  may add the rest. Every suggestion is a meter step by construction.
- **Spins (ball radii):** stun (0, 0), follow (0, +0.3), draw (0, −0.3) in Quick. Full adds left/right (±0.3, 0)
  for the top-K target-pockets when |cut| < 45°.
- **Analytic dedup before any sim.** The CB path after contact is predicted in closed form: tangent line for stun,
  the 30° rule near half-ball, and the draw/follow curves (SPEC §5.4; the same helpers the overlay needs in
  `AimGeometry`). The roll distance comes from speed loss. Two raw variants merge when their predicted CB rest
  points are < 10 cm apart with the same predicted first rail. Budget: 9 raw → **5 distinct**.
- **Throw-corrected aim, per variant.** Throw depends on speed and spin (SPEC §5.4), so the aim solve runs per
  variant. The initial aim uses the analytic throw estimate. One sim verifies it. A second (Newton) sim runs only
  when the OB departure error is > 0.25 × window half-width. Budget **1.5 sims per variant**.

### 4.3 Analytic P(make)

For a direct variant with nominal stroke s (aim φ₀, throw-corrected):

1. **Gain.** Quick uses the TP 3.4 closed form g = d/(2R cos φ). Full measures J = ∂θ_OB/∂φ per variant with two
   sims at ±δφ (δφ = 0.05°). That captures throw changes, and it is never shared across variants.
2. **Acceptance set.** Quick uses the geometric window [θ⁻, θ⁺] from the jaw geometry (TP A.13 seed, a single
   interval). Full **samples** the acceptance set for the top-K: 16 OB-only sims on a grid spanning ±4σ_θ around θ₀,
   cached per (quantised O, pocket, speed step). The result is a **union of intervals** {[θᵢ⁻, θᵢ⁺]}, which handles
   jaw rattles and cushion-first entries. No bisection.
3. **Execution noise only:** σ_θ² = (g·σ_φ)² + (∂θ/∂a·σ_a)² + (∂θ/∂b·σ_b)². Throw sensitivity to tip offset comes
   from the same finite differences in Full and is 0 in Quick. All terms are angles.
4. **P(make) = Σᵢ [Φ((θᵢ⁺ − θ₀)/σ_θ) − Φ((θᵢ⁻ − θ₀)/σ_θ)] × P(V ≥ V_min | σ_V) × 1[nominal not a scratch/foul].**

**Perception error is kept out of both P models by default.** The player aims at the real balls. Tracker error
changes *our* state estimate, not their execution. It is handled separately:
- capsule tests use an R + 2σ_pos margin;
- a **sensitivity flag**: P is recomputed with O and C shifted ±σ_pos perpendicular to the lines. In angle terms the
  shift is δ/d_p for the OB-pocket line and g·δ/d for CB-OB, from the TP 3.4 gain. If P moves by more than 0.15,
  the candidate is `perceptionSensitive`, which lowers rating confidence. If we ever want state uncertainty inside
  P, it goes into **both** the analytic and MC models as sampled state perturbations (σ_pos converted to angle as
  above), never into one only.

Banks, kicks and combos chain per-collision gains from the same ±δφ sims (Full), or from the mirrored-geometry
closed form (Quick). Analytic P drives Quick ranking, overlay colour, the leaf, and the MC control (§6.3).

### 4.4 Safeties

- **Always** (Quick and Full): a coarse set of 36 directions (10° grid, legal first contact) at the medium meter
  step, so every evaluation has a safety alternative for RATING_CLASSES "Miss" and RATINGS B5.
- **Full grid** when triggered: 2.5° grid (≤ 144 legal directions) × 3 speeds = ≤ 432 nominal sims, plus targeted
  "hide" points (visibility polygon from the opponent's targets). Trigger: best offensive P < τ_s, **or** the best
  coarse safety's value is within 0.05 of the best offence. τ_s = 0.65 is a **tunable default** (PickPocket's t0),
  tuned on the gate positions.
- **Score** = 1 − V_opp(state′), with the opponent's 2-ply reply including kicks when snookered (§6.1). The 4 best
  enter Sequential Halving as ordinary arms. They are not run as a separate MC (fixes a double count).

---

## 5. Execution noise model (`SkillModel`)

### 5.1 Parameterisation (one unit system: radians, fraction, ball radii)

| Param | Meaning | ICGA 2008 | PickPocket E_high | Default (placeholder) | Range |
|---|---|---|---|---|---|
| σ_φ | CB direction | 0.125° | 0.185° | **derived from the tier target**, see below | 0.02°–1.5° |
| σ_V | speed, relative | 0.075 m/s abs | 0.085 m/s | 8% | 3–20% |
| σ_a, σ_b | tip offset, **ball radii** (R = 28.575 mm) | 0.0175 R (0.5 mm) | 0.028 R (0.8 mm) | 0.0875 R (2.5 mm) | 0.0175–0.21 R |

**Tier targets drive σ_φ, and the targets are a user decision (§11 UD-E4).** Worked numbers with the corrected
TP 3.4 gain: a 1 m CB–OB, 1 m OB–pocket, 30° cut gives g = 20.2. Assume a ±29 mm effective corner half-width at 1 m
(about ±1.66°). Then:

| Make-rate target on that shot | Required σ_θ | Implied σ_φ |
|---|---|---|
| 55% | 2.2° | 0.11° |
| 75% | 1.44° | 0.071° |
| 90% | 1.0° | 0.05° |

The earlier draft's σ_φ = 0.45° "amateur" default would give only about 15% on this shot, so it is withdrawn. The
implied values sit at or below ICGA computer noise. That suggests either the targets are optimistic or the window
assumption is too tight. **Both get calibrated on Phase-3 real shots.** Until then, σ is "sim-calibrated" (R1).

Sampling: independent Gaussians. Tip offset is clipped to the miscue radius (|tip| ≤ 0.5 R). Beyond it, a miscue
means CB speed × 0.3 and direction ± 5°.

### 5.2 What we observe, and its noise

Tracker position noise is ±0.5–1 cm (perception.md). Direction-fit noise from a line fit over n frames with baseline L
is σ_dir ≈ σ_pos·√(12/n)/L. **Back-of-envelope estimates, to be validated on Phase-3 replays:**

| Observation | Typical track | σ_dir (σ_pos = 7 mm) | Usable for |
|---|---|---|---|
| CB launch direction (first 5 frames at 2 m/s ≈ 33 cm) | short | ≈ 1.9° | Intent only (coarse) |
| OB departure direction (≈ 20 frames, 1 m) | long | ≈ 0.3° | σ_φ via the gain (g ≈ 20 means OB error ≈ 20× CB error) |
| CB spin from the post-contact path | — | not shown feasible at 30 fps | **Not used for σ in v1.** Spin is inferred only coarsely (follow / stun / draw) from the post-contact CB path vs the predicted variants |

### 5.3 Estimator

- **Likelihood with intent marginalised over the window.** The player may aim anywhere in the acceptance window
  (cheating the pocket for position), modelled as uniform on [θ⁻, θ⁺]. Observation θ_obs = θ_t + g·e_φ + η, with
  η ~ N(0, σ_obs²) from the tracker covariance. Then
  `L(σ_φ) = [Φ((θ_obs − θ⁻)/s) − Φ((θ_obs − θ⁺)/s)] / (θ⁺ − θ⁻)`, with s² = (g σ_φ)² + σ_obs².
  A Student-t (ν = 4) mixture covers mis-inferred intent.
- **Grid posterior.** 48 log-spaced bins for σ_φ (0.02°–3°) and 24 for σ_V. Prior = the default tier with weight w₀.
  Updates are O(bins) and order-independent.
- **Thresholds are user decisions (§11 UD-E5):** w₀ (proposed 20 shots) and the "learning" icon threshold (proposed
  30 shots).
- **Bucketed context (v2):** σ_φ by cut and distance bucket, with hierarchical shrinkage.

### 5.4 Whose skill

The shooter's σ is used for their own plies and the opponent's σ for theirs, so `evaluate` takes a `SkillContext`.
For teams it is per player in rotation (D17), falling back to the team mean. Decision ratings use the shooter's own
σ (RATING_CLASSES "for this player's skill").

---

## 6. Search and value

### 6.1 Value (WP units) including option nodes

```
EV(c) = E_noise[ W(s′, g′, r) ]   with r = RulesEngine.apply(outcome(trace), g), s′ = trace.final
W = 1 / 0                                   if r.nextState.phase == .over(A / B)
  = OPT(s′, r)                              if !r.options.isEmpty            (option node)
  = V_A(s′, g′)                             if !r.turnPasses
  = 1 − V_B(s′, g′)                         if r.turnPasses   (BIH: V_B uses the BIH leaf)
OPT: the option holder H picks max over options o of W_H(choose(o)).   For A: W = 1 − max_o W_B(o) if H = B.
Push-out by A: B chooses  W = min( V_A(s′) [B passes, A shoots],  1 − V_B(s′) [B shoots] ).
```

That covers push-out (WPA 5.4), illegal-break accept or hand back (WPA 4.3(d), 9-ball Reg 16), break fouls (4.3(g),
(h)) and 8-on-break options (4.3(e), (f)), all through the existing `RuleResult.options` and `RulesEngine.choose`.

**Leaf V_X(s, g)** = X's WP shooting from (s, g):
- *2-ply (default):* generate X's directs plus forced kicks (analytic). Run nominal sims for the top 3 by analytic P,
  then apply the 1-ply score to each end state.
- *1-ply score (no sims):* CueCard q = p1 + 0.33·p2 + 0.15·p3, mapped to WP by §6.4.
- *BIH leaf (no sims):* placements scored analytically (geometry only) for the best p's, then the WP model's BIH
  term. This avoids 24 × sims per foul leaf.
- *Safety arms:* the leaf is the opponent's 2-ply reply, including kicks when snookered, at the same 3-sim cost.

### 6.2 Budget allocation (Full): Sequential Halving

Arms: K = 12 offensive plus 4 safeties (plus push-out or intentional-foul arms when applicable, within the 16 cap).
B = 768 root samples, 4 rounds, n_r = 12, 24, 48, 96 per arm. The two finalists end with 180 samples each.
Ties break by candidate index. Arms knocked out in round 0 have only 12 samples, which is why ratings use a
separate pass (§7.2).

**Leaf cache keyed by canonical representative.** The key is the end state quantised (CB 2 cm, OBs 1 cm, ball set,
GameState). The leaf is **evaluated at the bucket's canonical (quantised) state**, never at whichever sample
arrived first. So the value depends only on the key, and fill order can't change results. The bias is bounded by the
quantum. A property test checks that |V(canonical) − V(exact)| stays small on random states. The hit rate is
unknown, and §9 budgets h = 0 (worst) and h = 0.5.

### 6.3 Variance reduction (unbiased) and determinism

- **CRN.** The root noise for sample i is z_i = Normal4(counter = mix(engineSeed, stateHash, stream = 0, i)), shared
  by every candidate **by design**. `mix` is a proper 64-bit mixer (SplitMix64 finaliser chained per field, or a
  Philox4x32 counter RNG), not XOR. Other random streams (safety jitter, window grids) use stream = candidate id.
- **Antithetics.** Sample 2k+1 uses −z₂ₖ.
- **Linearised control variate (exact mean).** C_i = 1[θ₀ + g·σ_φ·z_φ,i + (∂θ/∂a)σ_a z_a,i + (∂θ/∂b)σ_b z_b,i ∈ window_lin],
  computed from the **same unclipped z** and the same linear model. Since z is exactly Gaussian, E[C] =
  Φ((θ⁺−θ₀)/s) − Φ((θ⁻−θ₀)/s) holds **exactly**, whatever the accuracy of the window or the linearisation. Then
  EV_cv = mean(W) − β·(mean(C) − E[C]). β is fitted on a disjoint half of the samples (split-sample, so no O(1/n)
  bias), then swapped. The analytic P with σ_pos is **never** used as a control. If the gate measurements show CV gains
  < 10%, it is dropped and CRN plus antithetics remain.
- **Stratification (to evaluate):** Latin-hypercube on z_φ, the dominant axis. It is kept only if it measurably
  lowers SE on the gate positions.
- **Determinism.**
  1. The input `TableState` is **quantised to 0.5 mm before hashing**, and the engine runs on the quantised state.
     Same quantised input gives the same output. Sub-mm tracker jitter that crosses a bucket can still change results,
     and the eval-bar hysteresis (§6.4) absorbs it.
  2. Chunks return (startIndex, [W, C, made, …]) into an index-addressed buffer. All means, SEs and β are reduced
     **serially in sample-index order** after each round.
  3. The leaf cache is canonical (§6.2).
  4. The determinism test is scoped to **one platform and build** (macOS arm64 `swift test`, and separately the
     device), across thread counts 1, 2 and 4.

### 6.4 Win-probability model

**v1: analytic inning model.** Run-out probability R_X along a greedy plan, with position factor κ(tier). The
opponent's generic run-out from a typical leave is r_X(n) = (p̄_X κ_X)^n ρ_X. Alternation:
`W_A = R + (1−R)(1−r_B) W_A^gen`, with `W_A^gen = r_A / (1 − (1−r_A)(1−r_B))`. Terms are added for BIH, the WPA
9-ball two-foul state, and 8-ball group progress. Cost about 5 µs.

**Bootstrap, sequenced explicitly (offline, `tools/`, virtual table):**
1. Greedy policy (best analytic P, stun, medium speed) self-play per tier → fit κ, ρ (WP v1.0).
2. Engine with v1.0 self-play → refit κ, ρ (v1.1). Repeat once more if Brier improves by > 2%.
3. **Labelled "sim-calibrated"** until Phase-3 real data, because the sim-to-real gap (D16 constant e) is baked in.

**v2: learned logistic table**, accepted only if its Brier score ≤ v1's on held-out self-play.

**Eval bar.** Perspective is §11 UD-E3. Hysteresis: the bar updates only if |Δ| > 2·SE.

---

## 7. Rating hand-off

### 7.1 What the Engine produces (reconciled with RATINGS §2 and RATING_CLASSES)

| Field | Meaning | Source |
|---|---|---|
| W₀, W₁, swing | WP before (pre Full, else latest partial) and after (post Quick), and W₁ − W₀ | §3.1 |
| EV_best, EV_second, G | Best and second-best arm EVs, and the "only move" gap | Full |
| EV_chosen, L, SE(L) | Chosen EV and paired loss | rating pass §7.2 |
| evMake, evMiss | E[W \| intended outcome], E[W \| not] per candidate (RATINGS B4: miss-branch ≥ 0.45) | split of the MC samples by intended-outcome flag |
| pIntended (Ps) | This player's P(intended outcome): pot made, or safety reached its target leave | MC |
| pBaseline (Pb) | The same with the reference-skill σ (RATINGS UD-8), analytic only (no extra sims) | §4.3 |
| Rₒ | Opponent's best reply after the actual result (max analytic P over their candidates, kicks included) | post Quick |
| intent | Posterior over candidates (top 3 + probability) and confidence κ̂ | §7.3 |
| naivePick | The rank-1 candidate of the naive policy "max P(make), ignore leave" (RATINGS §3.2) | Quick |
| kind | Candidate class, including `pushOut`, `intentionalFoul`, `safety`, `breakShot` | generator |
| execution | made / nearMiss / miss, and position zone | §7.4 |
| flags | `perceptionSensitive`, `lowConfidence` (unresolved at settle) | §4.3, §3.1 |

### 7.2 SE of the loss and what resolution is affordable

With per-sample SD of W about 0.3 (a placeholder until measured on the gate positions), the paired difference
D = W_best − W_chosen under CRN has SD = 0.3·√(2(1−ρ)):

| CRN correlation ρ | When | SD(D) | SE at n = 12 / 96 / 180 / 512 | n for SE = 0.01 / 0.015 / 0.02 |
|---|---|---|---|---|
| 0 | different target or pocket | 0.42 | 0.12 / 0.043 / 0.032 / 0.019 | 1800 / 800 / 450 |
| 0.5 | same target, other pocket | 0.30 | 0.087 / 0.031 / 0.022 / 0.013 | 900 / 400 / 225 |
| 0.8 | same target-pocket, another speed/spin | 0.19 | 0.055 / 0.019 / 0.014 / 0.008 | 360 / 160 / 90 |
| — | chosen == best | 0 | L = 0 exactly, zero cost | — |

D18 bands are 2–3 points wide (§1). Placing L in a band at about 95% confidence needs 2·SE ≲ half a band, so SE ≈
0.01. **That is not affordable for unrelated shots** (1800 pairs ≈ 7k+ sims). Design:
- **Rating pass:** start at the stroke and extend both chosen and best (shared indices, so CRN carries over from SH)
  until the 95% CI of L lies inside one D18 band, or n reaches n_max = 512 per arm.
- **Unresolved at n_max:** round toward the better class (benefit of the doubt, consistent with RATINGS §4.2 "CIs
  overlap → L := 0"). So Best vs Good is only split when the loss is confidently > 2 points. **This makes ratings
  coarser than chess.com's at the top end.** §11 UD-E7 asks whether to accept that or merge Best and Good
  visually.
- **Gate measurement (Phase 2):** measure σ_W, ρ and the resolved-band rate on the 20 positions × the 3 tiers, and
  report the share of shots that end "unresolved".

### 7.3 Chosen-shot inference

- Distance to each candidate in stroke space uses the **combined** covariance Σ = Σ_exec(σ) + Σ_obs (tracker: CB
  launch σ_dir ≈ 2°, speed from the track). For pots, the OB departure (σ ≈ 0.3°) and the pocketed set are matched
  against each candidate's predicted outcome, with intent marginalised over the acceptance window (§5.3).
- Posterior ∝ prior (the engine's own preference, softened) × likelihood. If the best candidate is > 3σ in combined
  Mahalanobis distance, a new candidate is built from the observed stroke and scored with the same seeds.
- **Validation:** synthetic tracks with injected tracker noise (§13.1), not only clean residuals.

### 7.4 Execution
`made / nearMiss / miss` per RATINGS §5. Near miss = OB departure within 1.5× the window half-width outside the
window, or a jaw event. **Position zone** = CB positions whose leaf ≥ 0.8 × the best sampled leaf, rasterised on 2 cm.
It is computed **host-local, and only for the chosen and best candidates**, and never put in a broadcast
`Evaluation`. The 1.5× and 0.8× factors are tunable defaults (gate set).

`Ratings.rate(_ inputs: RatingInputs, thresholds:)` is a pure function, outside the actor.

---

## 8. Swift 6 concurrency design

### 8.1 Executor
- **A dedicated `EngineExecutor: TaskExecutor` (SE-0417)** backed by a fixed pool of c worker threads (default c = 2,
  tuned by §9.4). Each thread has `qualityOfService = .utility`, with Quick and the rating pass submitted to a
  second, 1-thread `.userInitiated` executor. Engine work therefore **never occupies the global cooperative pool**,
  which the tracker, mesh, SwiftData and UI tasks share.
- iOS can't pin threads to P-cores, so placement is the scheduler's choice. The cost under real load is
  **measured** (§9.4), not assumed.

### 8.2 Isolation
- Entry points are `@concurrent nonisolated func` (SE-0461), so they never inherit the caller's actor under
  `NonisolatedNonsendingByDefault` (approachable concurrency). They call
  `withTaskExecutorPreference(engineExecutor) { withTaskGroup { … } }`, and group children inherit the preference.
- **Hot loops are synchronous** (`Simulator.simulate`, sampling, leaf) inside the children. They contain no `await`.
- The `ShotEngine` actor holds config, the generation token and the canonical leaf cache only.

### 8.3 Chunking, cancellation, anytime
- A chunk is ~16 samples (sized after §9.1). It checks `Task.isCancelled` before starting. There are ≤ 2c chunks in
  flight.
- A new quantised state for the live overlay cancels the stale **Quick**. The pre-shot Full and the rating pass are
  **not** cancelled at the stroke (§3.1). The generation token drops stale yields. Cancellation target: < 1 chunk.
- Stream order: `.quick` → `.partial` per SH round → `.full` → `RatingInputs` (from the rating pass).

### 8.4 Thermal / power
`ProcessInfo.thermalState`: at `.serious`, halve B, K and n_max. At `.critical`, Quick only. Low Power Mode halves B.

### 8.5 Memory
Per sample we keep (index, W, C, made, intended, CB rest, leaf key) and no traces. Peak < 5 MB plus zones for 2
candidates.

### 8.6 Mesh and skill models
- **Profile summary (join time)** carries each player's σ posterior log-weights: (48 + 24) Float32 = 288 B per player.
- **Who updates.** After each shot, the host builds a `SkillObservation` (θ_obs, window, g, σ_obs, intent posterior;
  < 100 B) and sends it to the **owning phone**. The owner applies the pure update to its competitive SwiftData
  store and rebroadcasts its summary. The host applies the same pure update to its session copy. The update is
  deterministic, so the two agree. On **host migration**, the new host already holds every broadcast summary, plus
  un-acked observations replayed by the owner.
- Players without a phone in the session use session-only skill (default tier) (§11 UD-E10).
- **Evaluation broadcast:** about 1–2 KB without zones, sent after `.full`. Live eval on peers while aiming is §11
  UD-E9. Option (a) is a ≤ 64 B `EvalLite` (WP bucket, best candidate id, P bucket) at ≤ 2 Hz from the host. Option (b)
  is a local Quick pass on each peer from the fused state. D3 covers clips, not eval, so it is not cited as a reason.

---

## 9. Performance budget (iPhone 15 Pro Max)

### 9.1 Step 0: microbenchmark (before any budget is frozen)
- **Where:** an XCTest in the app test target that links CueCore, **Release** configuration (`-O`, WMO), on the
  15 Pro Max. The same suite also runs on an M-series Mac with `swift test -c release` for the device/Mac ratio.
- **Cases:** fixed simulator (after the physics fix lands), 200 seeded strokes each: **sparse** (3 balls), **mid-rack**
  (9 balls), **open table** (16 balls spread), **break**, and **OB-only** (the window sims).
- **Placement proxies:** the run at `.userInteractive` (likely P-cores) vs `.background` (likely E-cores), and
  throughput with 1, 2, 4 and 6 threads → effective c.
- **Output:** median and p95 t_sim per case, written into this doc. Every wall-time figure below is then recomputed.

### 9.2 Sim counts (formulas; wall = sims × t_sim / c)

**Quick** (target ≤ 150 ms p95, proposed):

| Stage | Count | Typical | Worst (open table) |
|---|---|---|---|
| Directs: TP × 5 distinct variants × 1.5 sims | 20 / 24 TP | 150 | 180 |
| Banks/kicks/combos: 16 × 1 variant × 3 sims | | 48 | 48 |
| Coarse safeties | 36 | 36 | 36 |
| Push-out arms (only in `.pushOutAvailable`, replaces most directs) | ≤ 48 | — | — |
| Leaf (analytic), WP | 0 sims | ~5 ms CPU | ~8 ms |
| **Total** | | **~234 sims** | **~264 sims** |

**Full** (target ≤ 2.5 s p95):

| Stage | Count | h = 0.5 | h = 0 |
|---|---|---|---|
| J (2 sims) + sampled window (16 OB-only sims) for top-K | 12 × 18 | 216 | 216 |
| Full safety grid (only when triggered) | 432 | 432 | 432 |
| SH root samples | 768 | 768 | 768 |
| 2-ply leaf: 3 sims per non-terminal, non-BIH sample, × (1 − h) | ≤ 768 × 3 | 1152 | 2304 |
| BIH and option-node leaves | analytic | 0 | 0 |
| **Total** | | **~2570** | **~3720** |

**Rating pass** (during the roll; worst case = unrelated shots, n_max reached):
(n_chosen,new ≈ 500 + n_best,new ≈ 330) × (1 + 3(1 − h)) = **~2080 (h = 0.5) / ~3320 (h = 0)**. It costs 0 when
chosen == best.

**Required t_sim for each target** (c = 2, worst case):

| Pass | Sims | t_sim = 0.35 ms | 1.0 ms | Max t_sim for target |
|---|---|---|---|---|
| Quick | 264 | 46 ms | 132 ms | **≈ 1.1 ms** for 150 ms |
| Full | 3720 | 0.65 s | 1.86 s | **≈ 1.34 ms** for 2.5 s |
| Rating | 3320 | 0.58 s | 1.66 s | must fit inside roll time (unmeasured) |

If §9.1 comes in over budget, cut in this order: Quick variants 5 → 3. Full leaf top-3 → top-2. B 768 → 512.
n_max 512 → 256, which coarsens ratings (§7.2).

**Break.** Not searched live. The candidates and their post-break WP are precomputed offline, and breaks are "Book"
(D18). Their rating needs no MC.

### 9.3 Instrumentation
`EngineStats` counts sims and per-stage time. `os_signpost` intervals cover each stage. p50/p95 are **computed from
custom `ContinuousClock` samples** (XCTest `measure` reports average and standard deviation, not p95).

### 9.4 Device gates by phase
| Phase | Gate | How |
|---|---|---|
| **2** | Engine-only p95 on the 15 Pro Max: Quick ≤ 150 ms (if UD-E1 says yes), Full ≤ 2.5 s, Eval < 3 s (spec) | 20 positions × 20 runs, with a **synthetic load generator** standing in for perception: a 30 Hz Core ML inference loop on a bundled dummy model (ANE/GPU) plus one CPU thread at 50% duty |
| 3/4 | The same p95 **with the real camera pipeline** (live or replay `.mov`), and overlay frame-time p95 unchanged within 1 ms with the engine running vs not | Capture, detector and replay exist from Phase 3 |
| 9 | **1-hour thermal soak** with the engine on every shot (scripted replay loop): fps never < 24 (spec), log thermalState, and engine p95 per 10-min window | Duty estimate: about 6–10k sims per shot, so a few seconds of CPU per shot. That is unmeasured and is the reason for the soak |

---

## 10. Risks

| # | Risk | Mitigation |
|---|---|---|
| R1 | Sim-to-real gap (D16 constant e). The WP model and σ are sim-calibrated | Label them "sim-calibrated". Real-table recalibration in Phase 3. Never show numeric precision |
| R2 | Perception noise flips blocked/clear and thin-cut decisions | Capsule margin, the `perceptionSensitive` flag, recompute only on a stable tracker |
| R3 | Tier targets and thresholds are guesses | User decisions UD-E4 and UD-E5. Everything else is a tunable default tuned on the gate set |
| R4 | Wrong intent (bar 8-ball has no call) | Combined-covariance likelihood, window-marginalised intent, low-confidence suppresses promotions |
| R5 | MC noise moves ratings across bands | Paired rating pass, benefit-of-the-doubt rounding, no re-rating after display |
| R6 | 2-ply horizon misses patterns and safety exchanges | WP model run-out terms. The user reviews the 20 positions |
| R7 | Thermal throttling | thermalState scaling, a dedicated low-QoS executor, the Phase-9 soak |
| R8 | t_sim above the §9.2 thresholds | The cut order in §9.2. Physics optimisation becomes a Phase-2 task |
| R9 | Rules/physics coupling via `ShotOutcome` | A single `ShotOutcome.from(trace)` builder, golden tests per foul |
| R10 | Unaffordable rating resolution at the top bands | §7.2 design plus UD-E7 |

---

## 11. Decisions for the user

| # | Question | Proposal |
|---|---|---|
| UD-E1 | Add a Quick-pass gate (≤ 150 ms p95) on top of the spec's "Eval < 3 s"? | Yes, for live overlay colour and re-ranking |
| UD-E2 | Does "finish within ball-settling time" mean the badge is ready when the balls stop? | Yes: the heavy work runs during the roll, and the badge uses Quick W₁ |
| UD-E3 | Eval-bar perspective: the shooter, or a fixed team side (chess.com white/black)? | Fixed team side |
| UD-E4 | Skill-tier make-rate targets on a 1 m / 1 m / 30° corner cut (beginner / amateur / strong) | 55% / 75% / 90%, which implies σ_φ ≈ 0.11° / 0.07° / 0.05° (§5.1). Revisit with real data |
| UD-E5 | Skill prior weight and "learning" icon threshold | Prior ≈ 20 shots. Learning icon below 30 shots |
| UD-E6 | Learn σ from Training shots too (only σ shared, no stats)? | Competitive only for v1 |
| UD-E7 | Accept coarser top-end ratings (Best unless the loss is confidently > 2 pts), or merge Best/Good visually? | Accept coarser; Best on ambiguity |
| UD-E8 | Generate **carom** and **intentional-foul** candidates in Phase 2, or v2 (observe only)? | Intentional fouls (basic tie-up/block/dump set) in Phase 2. Caroms v2 |
| UD-E9 | Must peer phones show live eval bar and overlay colour while someone aims? | Yes via `EvalLite` host broadcast at ≤ 2 Hz |
| UD-E10 | Players with no phone in the session: session-only skill at the default tier? | Yes |
| UD-E11 | Bar 8-ball with no call: may the engine infer intent, or skip ambiguous shots? | Infer; suppress promotions when low-confidence |
| UD-E12 | Decision baseline: this player's skill (RATING_CLASSES says so), plus an optional "pro line" in game review? | Player's skill. Pro line optional in review |

---

## 12. Interface refinements (proposed delta to `docs/INTERFACES.md` → Engine)

```swift
public enum ShotKind: Hashable, Codable, Sendable {
    case direct, bank(Rail), kick(Rail), combo(via: BallID), carom(off: BallID) /* generator v2, UD-E8 */
    case safety, pushOut, intentionalFoul(IntentionalFoulGoal), breakShot
}
public enum IntentionalFoulGoal: String, Codable, Sendable { case tieUp, blockPocket, dumpBall }
public struct Candidate: Hashable, Codable, Sendable {
    public var id: UInt32                 // stable index; tie-breaks and RNG streams
    public var kind: ShotKind
    public var target: BallID?, pocket: Pocket?
    public var stroke: Stroke             // tipOffset in ball radii; speed = a power-meter step
    public var meterStep: Int             // 1…5
    public var cuePlacement: Vec2?, ghost: Vec2?
}
public struct SkillModel: Hashable, Codable, Sendable {
    public var sigmaAim: Double           // rad (CB direction)
    public var sigmaSpeedRel: Double      // fraction
    public var sigmaTip: Double           // ball radii
    public var logWeightsAim: [Float]     // 48 bins; travels in the mesh profile summary
    public var logWeightsSpeed: [Float]   // 24 bins
    public var observations: Int
    public static let beginner, amateur, strong: SkillModel   // values pending UD-E4
    public func updated(with obs: SkillObservation) -> SkillModel   // pure, order-independent
}
public struct SkillObservation: Hashable, Codable, Sendable { /* θ_obs, window, gain, σ_obs, intent p */ }
public struct SkillContext: Sendable { public var byPlayer: [PlayerID: SkillModel]; public var rotation: [Int: [PlayerID]] }
public struct CandidateScore: Hashable, Codable, Sendable {
    public var candidate: Candidate
    public var pMakeAnalytic: Double, pIntended: Double, pBaseline: Double
    public var ev: Double, evSE: Double, evMake: Double?, evMiss: Double?, samples: Int
    public var perceptionSensitive: Bool
}
public struct Evaluation: Hashable, Codable, Sendable {
    public enum Tier: String, Codable, Sendable { case quick, partial, full }
    public var stateHash: UInt64, generation: UInt64, tier: Tier, shooter: Int
    public var winProbability: Double, winProbabilitySE: Double
    public var ranked: [CandidateScore]   // best first, ≤ 20; no zones (host-local)
    public var secondBestGap: Double      // G
    public var naivePick: UInt32?         // candidate id
    public var opponentBestReply: Double  // Rₒ, for post-shot states
    public var stats: EngineStats
}
public struct RatingInputs: Hashable, Codable, Sendable {
    public var w0: Double, w1: Double
    public var chosen: CandidateScore, best: CandidateScore
    public var loss: Double, lossSE: Double, resolvedBand: Bool
    public var intent: [(UInt32, Double)] /* top 3 */, intentConfidence: Double
    public var opponentReply: Double, execution: ExecutionRating, lowConfidence: Bool
}
public struct EngineBudget: Sendable { var maxTargetPockets = 24, quickVariants = 5, topK = 12, safeties = 4,
    rootSamples = 768, ratingMaxPerArm = 512, threads = 2 }   // re-set after §9.1
public struct EngineRNG: Sendable { init(seed: UInt64); func normals(state: UInt64, stream: UInt32, sample: Int) -> SIMD4<Double> }

public actor ShotEngine {
    public init(rules: RulesEngine, simulator: Simulator, seed: UInt64 = 0, executor: EngineExecutor)
    public nonisolated func candidates(_ s: TableState, _ g: GameState) -> [Candidate]               // pure, sync
    @concurrent public nonisolated func evaluations(_ s: TableState, _ g: GameState, skills: SkillContext,
                                                    budget: EngineBudget) -> AsyncStream<Evaluation>
    @concurrent public nonisolated func ratingInputs(pre: Evaluation, observed: ObservedShot, post: TableState,
                                                     _ g: GameState, skills: SkillContext) async -> RatingInputs
    public nonisolated func winProbability(_ s: TableState, _ g: GameState, skills: SkillContext) -> Double
}
public enum Ratings { static func rate(_ i: RatingInputs, thresholds: RatingThresholds) -> (DecisionRating, ExecutionRating) }
```

Deltas from the stub: `SkillContext`, an anytime stream, pure `candidates` and `winProbability`, pure
`Ratings.rate` over `RatingInputs`, an injected RNG and executor, new `ShotKind` cases (RATINGS §2/§7), branch EVs,
Rₒ, intent posterior and naivePick. **Reconcile with RATINGS.md before editing INTERFACES.md.**
Dependencies: `ShotOutcome.from(trace:)`, `TableSpec` jaw geometry, a tracker covariance per ball (constant until
Phase 3), and `RulesEngine.choose` for option nodes.

---

## 13. TDD test plan (`Packages/CueCore/Tests/EngineTests`)

### 13.1 Unit / property tests
| Area | Tests |
|---|---|
| TP 3.4 | The exact eq. 1 vs the linear d/(2R cos φ): the relative error is < 2% for φ ≤ 30°, Δφ ≤ 0.1°, d ∈ [0.2, 2] m (numeric sweep). Sign convention fixed in the test. Gain from ±δφ sims agrees with the closed form within 10% on no-throw shots |
| Geometry | Ghost ball, mirror points, capsule obstruction (clear, grazing, blocked), shift of the pocket effective centre |
| Generator | Legal targets match `RulesEngine.legalTargets`. Banks, kicks and combos are present **even when directs exist** (capped). Kicks when snookered. Push-out arms only in `.pushOutAvailable`. BIH respects `.behindHeadString`. Analytic dedup merges equivalent CB paths. Speeds ∈ meter steps. Caps respected |
| Analytic P | In [0, 1]. σ → 0 gives 0/1. Monotone in d1, d2 and cut. Multi-interval window sums correctly (synthetic two-interval case). Agrees with 2,000-sample MC within 3 SE on 50 seeded shots (`.slow`) |
| Control variate | **Unbiased:** across 200 seeds, mean(EV_cv) − EV(20k-sample plain MC) is within 3 SE. E[C] closed form vs 100k-sample empirical mean |
| RNG | A proper mixer: no collisions over 10⁶ (hash, stream, index) tuples. Antithetic pairs. Moment checks |
| Skill estimator | Synthetic shooters σ_φ ∈ {0.05°, 0.1°, 0.3°} with **injected tracker noise** (σ_pos 5–10 mm on simulated tracks at 30 fps) and intent drawn uniformly within the window. Posterior mean within 20% after 200 shots. Ignoring σ_obs is shown to inflate σ (regression guard). Outliers 5% move the estimate < 10%. Order-independent |
| WP model | Bounded. **W_A(s, g) + W_B(s, g) = 1 for the same (s, g).** `.over` gives 0/1. Monotone in own balls, BIH and two-foul. Symmetric state with equal skill gives 0.5 ± 0.05. Brier vs baseline (`.slow`) |
| Option nodes | Push-out: W equals the min over the opponent's {shoot, pass}. Accept-or-pass: the holder picks max own WP. Matches a hand-computed toy |
| Value / search | Guaranteed scratch ≤ WP with opponent BIH. 8 early ≈ 0. 9 on a combo ≈ 1. SH keeps the best arm (≥ 95% of 200 seeds, gap 0.1). CRN lowers Var(difference) |
| Determinism | Bit-identical `Evaluation` and `RatingInputs` for threads ∈ {1, 2, 4}, **same platform and build**. Canonical cache: shuffled fill order gives the same results. A 0.3 mm input jitter inside a quantum gives the same output |
| Concurrency | Engine work runs on `EngineExecutor` threads (asserted via a thread-name probe), never the cooperative pool. Cancellation within one chunk. No stale generation yielded. TSan clean |
| Ratings boundary | `Ratings.rate` is pure. An unresolved band rounds to the better class. Low intent confidence suppresses promotions |

### 13.2 Reference positions
The 20 user-reviewed gate positions (unchanged list, except #6, #8 and #20 are tightened), plus 4 engine fixtures
that are not part of the user review:

| # | Position | Rules | Assertion |
|---|---|---|---|
| 1 | Short straight-in | 9-ball | direct, P high, WP > 0.5 |
| 2 | Easy last ball (9) | 9-ball | direct on the 9, WP ≥ 0.85 |
| 3 | 30° cut mid-table | 8-ball | direct, P medium-high |
| 4 | Long 60° thin cut vs safety | 9-ball | amateur: safety > pot. Strong: pot > safety |
| 5 | Steep side pocket vs corner | 8-ball | best = corner |
| 6 | Direct blocked, clean bank | 9-ball | bank generated and best offensive |
| 7 | OB frozen to the rail | 8-ball | throw-corrected aim ≠ geometric aim |
| 8 | Snookered | 9-ball | kicks and safeties only. Best = kick with a legal hit |
| 9 | Dead 2→9 combo | 9-ball | combo EV > direct on the 2 |
| 10 | Easy pot without shape vs harder pot with shape | 8-ball | 2-ply picks shape |
| 11 | Nothing makeable, good hide | 8-ball | best = safety, Rₒ low |
| 12 | BIH, 3 balls left | 9-ball | placement chosen, WP > 0.7 |
| 13 | On the 8 with a scratch line | 8-ball | best variant avoids the scratch |
| 14 | Open table after the break, 15 balls | bar 8-ball | Quick count ≤ budget. Both groups present |
| 15 | Cluster breakout vs leave | 8-ball | breakout variant higher |
| 16 | 7 vs 1+8 | 8-ball | WP low. Safety over a low-P pot |
| 17 | Hanger at 50° | 9-ball | P > 0.95 |
| 18 | Two-way shot | 9-ball | two-way evMiss > plain pot's evMiss |
| 19 | Opponent on two fouls | WPA 9-ball | safety value raised |
| 20 | Racked table | each rule set | break candidates only, precomputed WP, Book |
| E1 | **Bank beats an available direct** (direct leaves a scratch or a sell-out, the bank is two-way) | 9-ball | bank ranked above the direct |
| E2 | **Push-out** after the break, 1 visible at a hard cut | WPA 9-ball | push-out arms generated. W = min(shoot, pass). Push chosen over a low-P pot |
| E3 | **Accept-or-hand-back** after an illegal break (Reg 16 / 4.3(d)) | WPA 9 / WPA 8 | option node valued as the holder's max |
| E4 | **Intentional foul tie-up** (Dr. Dave BD Mar 2026 Image 1 analogue), if UD-E8 = Phase 2 | 8-ball | the foul arm's EV > the best legal safety |

### 13.3 Performance tests
- macOS `.slow`: sim-count assertions per stage (§9.2 formulas), and a 2× wall regression guard per machine.
- Device: the §9.1 microbenchmark first, then the Phase-2 gate (§9.4) with p95 from `ContinuousClock` samples.
  Pipeline and soak gates are added in Phases 3/4 and 9.

### 13.4 Build order
0. **Microbenchmark** (after the physics fix) → 1. RNG + SkillModel → 2. geometry + obstruction → 3. generator (all
classes, caps) → 4. aim solve + analytic P + window → 5. leaf + WP v1 bootstrap step 1 → 6. Quick + budget →
7. MC + CRN + CV + SH + canonical cache → 8. option nodes + push-out → 9. safeties + BIH → 10. executor + actor +
stream → 11. rating pass + intent + `RatingInputs` → 12. skill estimator with noisy synthetic tracks →
13. reference positions → 14. device gate.

---

## Reviewer notes (rev 2)

All 20 review items were accepted and fixed. Two were partly rejected:
- **Determinism, "hash (stateHash, candidate, index)".** The proper-mixer part is adopted. The *candidate* is
  deliberately **not** in the root-noise seed, because common random numbers require that sample i draws the same z
  for every candidate. Including it would remove the CRN variance reduction the rating pass relies on (§7.2).
  Candidate ids are mixed into the non-root streams only.
- **Perception error in P(make).** Of the two options offered, this doc takes "neither model includes it by
  default", for the reason given in §4.3. The angle conversion is specified for when it gets added to both models.
- **Not changed:** the D18 class bands. RATINGS.md and RATING_CLASSES.md own them, so the resolution problem is
  raised as UD-E7 and the bands are left alone here.

---

## Sources

- Smith, "Running the Table: An AI for Computer Billiards", AAAI 2006. https://cdn.aaai.org/AAAI/2006/AAAI06-156.pdf · https://mlanthology.org/aaai/2006/smith2006aaai-running
- Smith, "PickPocket: A computer billiards shark", Artificial Intelligence 171 (2007) 1069–1091. https://doi.org/10.1016/j.artint.2007.04.011
- Archibald, Altman, Greenspan, Shoham, "Computational Pool: A New Challenge for Game Theory Pragmatics", AI Magazine. https://yoavshoham.net/_files/ugd/a1a3b1_5964a39d807a4fce8768f64cb69d6b25.pdf
- Archibald, Altman, Shoham, "Success, strategy and skill: an experimental study", AAMAS 2010. https://ifaamas.csc.liv.ac.uk/Proceedings/aamas2010/pdf/01%20Full%20Papers/22_05_FP_0677.pdf
- Archibald et al., "Analysis of a Winning Computational Billiards Player", IJCAI 2009. https://mlanthology.org/ijcai/2009/archibald2009ijcai-analysis
- Leckie & Greenspan, "An Event-Based Pool Physics Simulator". https://www.springerprofessional.de/en/an-event-based-pool-physics-simulator/1276086
- Archibald & Nieves-Rivera, "Bayesian Execution Skill Estimation", AAAI 2019. https://ojs.aaai.org/index.php/AAAI/article/view/4556
- "Estimating Agent Skill in Continuous Action Domains", JAIR 2024. https://jair.org/index.php/jair/article/view/15326
- Alciatore, TP 3.4 "Margin of error based on distance and cut angle" (eq. 1; d = CB–OB distance, d ≫ R). https://drdavepoolinfo.com/technical_proofs/TP_3-4.pdf
- Alciatore, margin-for-error FAQ. https://drdavepoolinfo.com/faq/cut/margin-for-error/
- Alciatore, TP A.13. https://billiards.colostate.edu/technical_proofs/new/TP_A-13.pdf
- Alciatore, pocket size and centre. https://drdavepoolinfo.com/pocket/size-and-center/
- Kiefl, pooltool. https://github.com/ekiefl/pooltool · https://theoj.org/joss-papers/joss.07301/10.21105.joss.07301.pdf
- chess.com, "How are moves classified?". https://support.chess.com/en/articles/8572705-how-are-moves-classified-what-is-a-blunder-or-brilliant-move
- FargoRate, "Behind the curtain". https://fargorate.com/fargorateblog/archive/behindthecurtain/
- Karnin, Koren, Somekh, ICML 2013. https://proceedings.mlr.press/v28/karnin13.html
- Variance reduction / CRN / control variates. https://en.wikipedia.org/wiki/Variance_reduction · https://rossetti.github.io/KSLBook/ch9VRTs.html
- SE-0461 "Run nonisolated async functions on the caller's actor by default" (`NonisolatedNonsendingByDefault`, `@concurrent`). https://github.com/swiftlang/swift-evolution/blob/main/proposals/0461-async-function-isolation.md
- SE-0417 "Task Executor Preference". https://github.com/swiftlang/swift-evolution/blob/main/proposals/0417-task-executor-preference.md
- Swift forums, "Concurrency and CPU-bound tasks". https://forums.swift.org/t/concurrency-and-cpu-bound-tasks/49716
- Apple A17 Pro (core configuration). https://en.wikipedia.org/wiki/A17_Pro
- Project docs: `docs/RATING_CLASSES.md` (D18 bands), `docs/RATINGS.md` (§2 inputs, B-classes), `docs/research/rules-notes.md` (WPA 4.3, 5.4, Reg 16), `docs/CHECKLIST.md` (physics status).

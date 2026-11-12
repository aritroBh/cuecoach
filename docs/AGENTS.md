# Agent org & ledger

```
Head orchestrator (main Claude session) — plan, checklist, contracts, merges, phase gates
└─ Phase orchestrator (one Workflow per phase)
   └─ per module: Worker (tests → code, own worktree)  ⇄  Supervisor (different vendor, critical, can reject)
                  + extra review pass via OmniRoute
```

Vendors: Claude subagents · Codex (`codex exec`) · Cursor (`cursor-agent -p`) · Antigravity (`agy`) · OmniRoute.
Rule: **a module is never reviewed by the vendor that wrote it.**

## Build hygiene (every worker, every vendor — paste into worker prompts)

The dev Mac's disk has hit 0 GB free during parallel builds. These rules are mandatory:

- Create worktrees with `tools/new-worktree.sh <name>` (it copies the local build guard hook into the worktree).
- One `xcodebuild` build/test at a time across all agents. Don't start one while another runs (`pgrep -x xcodebuild`).
- Every `xcodebuild test` passes `-parallel-testing-enabled NO` (parallel testing clones the simulator, ~5 GB each).
- Check `df -h /` first; under 40 GB free, stop and report instead of building.
- Use the shared `-derivedDataPath` the head gives you; never the default DerivedData, never one per worktree.
- Don't create simulators. Use `CueCoach iPhone 15 Pro`.
- After merge the head removes the worktree, branch, logs and derived data.

## Phase 1 assignments
| Module | Worker | Supervisor | Extra review |
|---|---|---|---|
| Rules | Claude | Codex | OmniRoute |
| Physics + pooltool fixtures | Codex | Claude | Cursor |
| Persistence (SwiftData, backup JSON) | Claude ✱ | Codex † | — |
| Virtual table UI | Claude | Antigravity (design + code) | Codex |

✱ Cursor was the planned worker, but auto mode blocks `cursor-agent --force` (unattended command execution). Cursor reviews instead until the user allows it.

## Ledger
| Date | Module | Wrote | Reviewed | Result |
|---|---|---|---|---|
| 2026-11-06 | Geometry contracts | Claude (head) | — (contract, reviewed with Phase 1) | merged to bootstrap |
| 2026-11-06 | Engine (candidates, evaluator, win model, ratings) | Claude (worker subagent) | Phase-2 supervisor, with Codex findings | round 1 rejected (4 major, 4 minor); fixes on `wt/engine`, awaiting re-review |
| 2026-11-08 | Tracking + shot segmentation + classical detector fixes (wt/tracker: stress findings A0-A8, B1, B2, C1-C3, E1; Codex r5 M3, M6, M7) | Claude (tracker worker) | Codex (2 adversarial rounds, both REJECT; r1 F1-F8 fixed or narrowed, r2 residuals reported to head) | awaiting head merge decision |
| 2026-11-07 | App shell (Home, Game setup, Join nearby, Training picker, in-game chrome, MPC lobby) | Claude (worker subagent) | Codex (code, 6 rounds) + Codex (UX from screenshots, 4 rounds) ‡ | code APPROVE (r6), UX APPROVE (r5); Live/calibration/Training owner items open |
| 2026-11-08 | Privacy round: recognition store split + migration, one-tap delete/Undo (wt/audit, wt/screens-a) | Claude (privacy worker) | Codex r1 REJECT (3 fixed, 3 rebutted and accepted in r2) · Codex r2 REJECT (3 fixed, not re-reviewed) | awaiting head merge |
| 2026-11-08 | Integration (wt/integration): 8 branches merged, detector/hooks/gallery wiring, D29 in Live | Claude (integration worker) | Codex ×4 areas (capture-r8, autocal-r4, privacy-r3, wiring): all REJECT r1; fixes test-first; r2 REJECT (MAJORs only); fixes; r3 combined: all r2 MAJORs FIXED, 1 new MAJOR fixed; final combined rerun (autocal-r4, tracker-r2, strides, UI-QA fixes) blocked by the Codex usage limit | awaiting head merge decision |
| 2026-11-09 | Integration rounds 2026-11-08/09: D30 look-then-ask, shot-lifecycle FIFO state machine + invariant fuzz, touch targets, relock fixes (8ede140/f046ff8/c43f44b by head) | Claude (integration worker; head for 3 relock commits) | GPT-5.3 Codex, Grok 4.7, Gemini 3.7 (Cursor), Kimi K3 (opencode/Bedrock), GPT-5.6 Sol (Cursor) across 7 rounds; final: GPT-5.6 APPROVE (4e42342), Gemini APPROVE (3590c25 code) | merged to phase/1-core 4e42342 |
| 2026-11-09 | D34 Astryx design system: vendored Packages/Astryx (zero-network), theme bridge, every screen + Live overlays restyled (wt/astryx-ui) | Claude (UI worker) | GLM-5 (Bedrock), Kimi K2.5 (Bedrock) APPROVE; Grok 4.7 (Cursor) REJECT (light contrast) → fixed 552600a → APPROVE | merged to phase/1-core |
| 2026-11-09 | D32 detector benchmark (wt/d32-bench): sim3d renderer, bench harness, scorer, fine-tune, DetectorChoice default | Claude (d32 worker) | Grok 4.7 (Cursor), Kimi K2.5 (Bedrock) APPROVE | merged to phase/1-core |
| 2026-11-09 | D31 lost shot = best guess + D33 stick near the cue ball = aiming (wt/d31-d33) | Claude (d31-d33 worker) | Grok 4.7 r1 REJECT at 7d77e5b (2 BLOCKERs, 1 MAJOR, all fixed test-first) + coordinator D1 MAJOR (fixed); r2 Grok 4.7 + Kimi K2.5 APPROVE | merged to phase/1-core |
| 2026-11-09 | Fix round wt/fix-app: 7 review MAJORs (turn discs, swap, review header, lobby Start, HUD key, store recovery, FaceBenchmark order) + Grok BLOCKERs on fix 1 (legalSink, mounted-model install) | Claude worker | Kimi K2.5 APPROVE 1–7; Grok 4.7 APPROVE 2–7, BLOCKER on 1 fixed in 8eecfc0; Grok re-review BLOCKER on 8eecfc0 fixed in 27ce0d2; Grok 4.7 re-review APPROVE for 27ce0d2 | merged to phase/1-core |
| 2026-11-10 | Review shot results (wt/review-shots): `SettledShot` Live → shell contract, pocketed/fouls/D31 guess in `reviewData()`, review card result row | Claude worker | Grok 4.7 r1–r2 MAJOR (cue-ball outline on white card, fixed 539ca9c) · r3 APPROVE | merged to phase/1-core |
| 2026-11-10 | Size lock (wt/size-lock): guessed partial-fit sizes never vote or lock, sizes between presets never lock, pose only from size-consistent frames (matrix false 1 → 0) | Claude worker | Grok 4.7 REJECT (1 MAJOR, fixed) · GLM-5 REJECT (BLOCKER hardened, MAJOR refuted by tests); Grok 4.7 r2 REJECT (lone borderline snap poisons measured size, fixed b9d0117) · r3 APPROVE | merged to phase/1-core |
| 2026-11-10 | AimStressTests waits for the off-actor physics preview (b21f994, test-only) | Claude (head) | Grok 4.7 APPROVE | merged to phase/1-core |
| 2026-11-10 | Plan 001: team MVP deterministic; no-WPA fallback = winning team's best-rated shooter (D35) | Claude worker | Grok 4.7 APPROVE (MINOR test gaps → 4 tests added, e0af36c) | merged to phase/1-core |
| 2026-11-10 | Plan 004: ball model I/O contract pinned; hybrid proven to run the model (mutation: renamed output fails 2 tests) | Claude worker | Grok 4.7 APPROVE (2 MINOR: type/shape checks are indirect, covered by the ≥5-raws and shading guards) | merged to phase/1-core |
| 2026-11-10 | Plan 003: device-runnable ball-model latency test (warm, letterbox/predict split, 3 compute-units), dev HUD model/lb ms | Claude worker | Grok 4.7 APPROVE (MINOR: doc wording fixed at merge; p50 rank off by one, gate uses p95) | merged to phase/1-core |
| 2026-11-10 | Plan 006 design: authoritative mesh shot log + game saving (docs/research/game-log-and-saving.md, INTERFACES 'Proposed') | Cursor Grok 4.7 (read-only draft) | Claude head (citations spot-checked; D37–D41 folded in) | merged to phase/1-core |
| 2026-11-10 | Plan 002: live shots carry before/after ball positions → Game Review rates + replays live shots; a D31 guess keeps no replay | Claude worker (+ head fix round) | Grok 4.7 REJECT (MAJOR: guessed shot's after table empty) → fixed → APPROVE (MINOR: INTERFACES wording fixed at merge; pocket-path assert loose) | merged to phase/1-core |
| 2026-11-11 | Plan 005: chosen table size is the lock prior (settles the 8/9 ft overlap), between-presets size hint; D36 A dropped (D46) | Claude worker (2 rounds) | Grok 4.7 REJECT (prior never voted on ambiguous fits) → fixed → Codex APPROVE (MINOR: size hint missed on the settled-but-untrusted path; follow-up) | merged to phase/1-core |
| 2026-11-11 | Plan 007: ✕ in a game asks "End game?"; open and in-flight shots settle before review; D42 ~5 s give-up / second ✕ forces, unresolved pockets → guess, late frames ignored | Claude worker + head fix rounds | Grok 4.7 REJECT (2 BLOCKERs) → fixed; Codex REJECT (in-flight shot dropped) → fixed; Codex REJECT (late record closes twice) → fixed → Codex APPROVE | merged to phase/1-core |
| 2026-11-11 | Plan 008: a lost shot with no guess records a review gap; turn discs ring + pulse until the shooter is tapped (D38, D41); gap never MVP; VoiceOver value | Claude worker + head fix | Codex REJECT (gap-only review = "No shots"; a11y MINOR) → fixed → Codex APPROVE | merged to phase/1-core |

† Cursor review attempted 2026-11-06 but its plan hit the monthly usage limit on all models (resets 2026-11-09); Codex reviewed instead.

‡ Antigravity (planned UX reviewer) returned 429 quota exhausted (resets in ~7 days), so Codex did the UX pass from the screenshots too.

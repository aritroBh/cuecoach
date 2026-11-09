# Checklist (live — update as work starts/finishes)

Legend: [ ] todo · [~] in progress · [x] done · [!] blocked on user

## Step 0 — Bootstrap
- [x] git init, directory layout, CLAUDE.md, SPEC/DECISIONS/CHECKLIST
- [x] .gitignore, XcodeGen project, CueCore package skeleton (Geometry contracts TDD, 9 tests green)
- [x] Empty app builds + launches on iOS 27 simulator (unit + UI test pass)
- [x] Signed build installs on iPhone 17 Pro Max (user must Trust developer cert once)
- [x] Public GitHub repo created, bootstrap pushed (github.com/aritroBh/cuecoach)
- [x] Research The Rive (UIUC) table size → D7: table exists, size not found online
- [x] pooltool 0.6.0 env (tools/physics_fixtures, uv)
- [x] External CLIs smoke-tested: codex OK; cursor-agent needs --trust; agy has print mode; omniroute router

## Step 1 — Proposals (gate: user review)
- [x] docs/SCHEMA.md (SwiftData, two stores)
- [~] docs/INTERFACES.md (doc done; Swift stubs after approval)
- [x] docs/RULES.md bar-rule conventions draft (+ docs/research/rules-notes.md, WPA 2026-10-21)
- [x] User approves schema, interfaces, bar conventions (D11–D14)

## Phase 1 — Core (branch phase/1-core; worktrees .worktrees/{rules,physics,persistence})
Parallel now: Physics fix (Codex) · Virtual table review (Antigravity) · Phase 2+ research workflow. Merged: Persistence, Rules, Geometry fix (head pockets at x=0).
- [x] Rules: WPA PDFs + Dr. Dave read, rule numbers cited
- [x] Rules: bar 8-ball tests + impl
- [x] Rules: WPA 8-ball tests + impl
- [x] Rules: WPA 9-ball tests + impl (push-out, 3-foul)
- [x] Rules: Codex review 2 rounds (round-2 scotch-rotation findings overruled by user D17); 207 tests; merged
- [x] Physics: pooltool fixture generator (500 shots) — Codex
- [x] Physics: merged (Codex worker; Claude supervisor APPROVE after 3 rounds): 96.2% pooltool (break 80% — tie-break order only), simple 20/20, jaw 4/4, 16-ball break ~1.6 ms; visual path renders checked
- [x] Physics: fixture suite within tolerance (D10)
- [x] Physics: pocket/rail head-foot labels match Geometry (3aaad2a; found by capture worker; tests per pocket + rail)
- [x] Persistence: SwiftData models + export/import round-trip (45 tests; Codex review 2 rounds; merged 1bcd9f6)
- [x] Persistence: training/competitive isolation test
- [x] Design system (design-system/cuecoach/MASTER.md via ui-ux-pro-max)
- [x] Virtual table REMOVED from the app (D20); code archived locally (archive/vtable-devtool), not shipped
- [ ] Cross-vendor review of every module, findings fixed
- [ ] Device run on iPhone 15 Pro Max, design review
- [ ] Merge, delete branches/worktrees, clean status

## Ahead-of-phase research (workflow wf_b972a7fb, running in parallel)
- [~] docs/RATINGS.md — research (workflow) reconciled with docs/RATING_CLASSES.md (D18, 10 classes — done)
- [~] docs/research/engine.md — candidates, win probability, perf budget
- [~] docs/research/perception.md — calibration (D12), ball detection, dataset licenses
- [~] docs/research/mesh-identity.md — MPC protocol, clock sync, clips (D3), recognition privacy

## Camera track — pulled forward from Phase 3 (user, 2026-11-06), running in parallel
- [~] Capture: camera + LiDAR frame source, replay source (worktree .worktrees/capture, Claude)
- [~] Calibration: tap-4-corners + auto cloth detection, homography + ball-plane offset, LiDAR table size (D12)
- [~] Ball detection v0 (classical, real-time) + tracker v0 — Claude, .worktrees/capture
- [~] Core ML ball detector: pipeline committed (2efd72d, 3,200 synthetic imgs); Codex sandbox had no network → orchestrator training YOLO26n 30 epochs on MPS (slow network: package download in progress)
- [~] Live screen: AR v0 INSTALLED on both phones (5b5558a): plane → tap 4 corners → 3D table + pockets → ball rings → aim line; debug HUD. Next: auto corners, 4K, thermal, tests, Codex+Antigravity review
- [ ] Real-table footage from the user (The Rive) for tuning + held-out test video
- [x] Post-shot VLM benchmark (D22→D23): Apple FM 26–28% / Qwen3.5-2B 39% / Gemma-4-E2B 31–33%, all at chance on vision; Apple FM text-only labels + rule fallback; merged

## All-modules push (workflow wf_4253a676, user: "use all agents", 2026-11-06)
Each module: TDD worker → Codex review + Claude adversarial verification → fix → re-verify.
- [~] Engine (Phase 2): candidates, Monte Carlo, win prob, ratings D18 — .worktrees/engine
- [x] Engine review fixes (Codex GPT-5.3 + Kimi K3; wt/fix-engine, not merged): WPA 3.11 crossing read from the cue-ball path (87433da), kitchen-ball kicks that cross the head string (20efd94), rating top-up refreshes difficulty/baseline (85dfe4a). CueCore 694/694, 0 warnings
- [~] Stats + archetypes + pro comps (Phase 6) — .worktrees/stats. Comparison math done; all 10 pro profiles still `estimated` → sourcing real stats (research agent). No pro videos downloaded (ToS/copyright; detector not trained yet)
- [~] Training logic (Phase 8): drills, assist levels, level policy, bias detector — .worktrees/training
- [~] Mesh (Phase 5): MPC, protocol, host election/migration, clock sync — .worktrees/mesh (Sim C)
- [~] Identity (Phase 5): opt-in embeddings, re-ID, shooter attribution + fallback — .worktrees/identity (Sim D)
- [~] Adversarial QA audit of merged code: rules, persistence, privacy, geometry — .worktrees/audit (Sim E)
Also running: Camera + 3D AR (Claude; UX round: visual coaching, auto corners) · AR v0 reviews: Codex (code) + Antigravity (UX) · YOLO detector (Codex) · Physics fixes (Codex) · VLM A/B: Apple FM vs Qwen3.5-2B vs Gemma-4-E2B (MLX, downloaded)
- [~] Screens A: Settings (privacy delete, backup, rule defaults, table size) + Player profile (stats, radar, pro comp, history, Training tab) — .worktrees/screens-a (Sim F)
- [~] App shell: Home (Game / Training), New game (rules, singles/teams D17, guests, table), Join nearby (real MPC lobby + fake), Training picker, in-game chrome, review → Home — .worktrees/app-shell (Sim G)
- [~] Screens B: Session lobby (lineups D17, rule vote) + Post-shot card (D18) + Game review (timeline, diagram, win-prob, SotG, MVP) — .worktrees/screens-b (Sim G)
- [~] Zero-tap automatic table locating (user at table: manual points mismatched) — AutoTableLocator, .worktrees/autocal (Claude; Codex review; workflow wf_ff3aa1d8)
- [~] Core ML table-keypoint model: pipeline committed (6c16646); paused until the detector's package download finishes (shared cache, slow network)
- [~] AR 9d67bbe INSTALLED on both phones: Codex r3 fixes (relock w/o stale timeout, frame seq/epoch, vanished-ball shot end, LiDAR-verified marks), Kalman tracker, cue-stick live aim + convergence haptic, LiDAR depth balls, buffer reuse, Physics-driven Lines 2/3; 148 unit + 2 UI green. Reviews running: Codex r4 (code) + Antigravity r2 (UX)
- [x] AR 9ad4e32 INSTALLED: zero-tap lock (floor/coffee-table planes rejected), relocalization re-check, shot events, Hungarian tracker, thermal step-down; 117 unit + 2 UI tests green. Codex re-review running; next: cue-stick aim, Kalman, buffer reuse, depth-based ball detection
- [~] On-device test runs: CueCoach unit suite via xcodebuild test on 17 Pro Max + 15 Pro Max
- [x] VLM A/B on BOTH phones (17 Pro Max: OpenSound + OpenCane uninstalled with user OK to free the 3-app slot): Apple FM vs Qwen3.5-2B vs Gemma-4-E2B

## Live product round (2026-11-07, user at the table)
- [x] D24: two modes. Game = no aim lines, rules helpers + post-shot rating; Training = Lines 1+2, Line 3 at higher levels
- [~] Visible table-found state (outline + 6 pockets + ball rings), lock-failure reasons, mode-aware overlay: capture worker
- [~] Codex r4 REJECT (4 MAJOR, 3 MINOR): capture worker
- [~] App shell: Home (Game / Training) → New game / Join nearby → Live → badge → review: app-shell worker (Antigravity + Codex review)
- [~] Recognition hardening workflow: Codex + Antigravity + Claude stress (10k sessions) + face-model licence research → cross-check → fix → re-review
- [~] Merge reviews: stats, training, screens-a, audit (Codex review → Claude verify → fix → reverify)
- [~] AR adversarial stress test (.worktrees/capture-stress)
- [x] Engine merged (APPROVE r2; 103 tests) · Mesh merged (APPROVE r2; 12 findings fixed incl. host-migration log recovery). Phase app tests 147/147
- [ ] Two phones join one real game (mesh merged; needs app shell Join nearby)
- [~] Table-lock virtual QA workflow: synthetic-table simulator matrix (felt colour × lighting × clutter × distance), Codex/Antigravity/OmniRoute root-cause, UI QA on 15/17 Pro Max simulators
- [~] Table-keypoint model training (restarted) · ball detector training epoch 4/30

## Round 2026-11-08 (orchestrator QA while the user is away)
- [x] Stats merged (Codex review → Claude verify → fix → reverify APPROVE) · Training merged (same). CueCore 585 tests green
- [x] Table-keypoint model trained: YOLO26n-pose 25 ep, synthetic test 400/400 detected, median 5.3 px (0.96% diag), Core ML 5.6 MB (wt/tablekp a223399). Real-table accuracy unmeasured
- [~] Ball detector training resumed from checkpoint (epoch ~5/30)
- [x] Virtual table simulator (wt/virtual-qa): 27 conditions × 20 seeds; FeltQuad 0% accurate → Auto 55% accurate, p50 1.0 s, 0 false locks (wt/autocal 44fd4ed)
- [~] Lock: Auto + keypoint model + 2-tap+drag fallback (user) + wait-for-second-look partial (user) + Codex r5 fixes + app-shell hooks — capture worker. Gate ≥95% / <1.5 s / 0 false
- [~] Tracker/shot detection: stress BLOCKERs A0 (≈15.8k phantom shots/h) + A3 (pockets never recorded) + A1–A8, B1–B2, C1–C3, E1, Codex M3/M6/M7 — tracker worker (wt/tracker)
- [x] App shell approved (Codex code 6 rounds + UX 5 rounds): Home → Game/Training → New game / Join nearby → Live → badge → Review. Real phones: join + lineup sync worked; Start→mesh not yet verified
- [~] Recognition: 30 findings real → fixed (open-set "someone else", shooter gate, tap relearning, no recognition in backups, delete beats in-flight registration); Codex re-review r2 running
- [~] Privacy: one-tap delete + Undo; recognition in its own backup-excluded store; guest promotion drops session data — privacy worker
- [ ] User: face model (AuraFace-v1, Apache-2.0) yes/no · clothing templates on disk vs session-only · recognition expiry · pro profiles era/game split

## Integration branch wt/integration (2026-11-08, integration worker; not merged to phase/1-core)
- [x] Merged in order: capture 0f87a45 · autocal-r3 c8be83f · tracker 4f2dbbd · detector 1cbeaf1 · app-shell 61d810a · audit f6b1609 · screens-a 68c703f · identity 6cefa3f → 43a6f2a → 5c59884 → 3b60430 → 4eca63f
- [x] screens-a delete/Undo on audit's staged-delete API; identity templates on the backup-excluded recognition store; IdentitySession galleries registered with the stack
- [x] Trained ball detector behind BallDetector (HybridBallDetector: model ≤ 30 Hz of frame time, classical fallback); keypoint cadence on frame time
- [x] D29 in Live (no red ring/buzz without a settled identity; unsettled ids never reach Rules; impulsive launch / addressing opens the aim)
- [x] No text in the aiming path (shared PostShotRatingBadge); shell LiveScreenAdapter drives LiveSession and injects the game's rules
- [x] Codex reviews: capture-r8, autocal-r4, privacy-r3, wiring (REJECT → fixes → rerun REJECT, MAJORs only → fixes)
- [x] Also merged: autocal-r4 8f08b48 (steep side-pocket fits) · tracker-r2 39079d0; side-pocket pocket-evidence rule (sidePockets fits only)
- [x] App unit suite 1098/1098 at 78f2cbb · CueCore 687 · generic iOS device build OK · lead's fix/coreml-strides (device ANE stride crash) merged
- [x] UI QA regression fixed: LiveReplay (model frames skip the classical shading check; training overlay on the AssistLevel scale, D1/D24). Simulator UI: LiveReplay passes; earlier partial run 27 pass
- [x] Lock matrix (27×20, app, -O build): in-scope 92.3 % accurate, all 72.0 %, p50 TTL 1.33 s; elev-45 25 % / elev-60 40 % (was 5/25)
- [!] Matrix false locks: 1 wrong-size lock (felt-tan seed 10, 16 cm, under the old 20 cm cut-off; now counted). Earlier run: dist-2/3 m wrong size. Size disambiguation needs work before the 0-false gate holds
- [x] Final cross-vendor review done instead via Cursor/opencode (GPT-5.3, Grok, Gemini, Kimi, GPT-5.6): GPT-5.6 APPROVE at 4e42342, Gemini APPROVE
- [x] Merged wt/integration → phase/1-core (4e42342, fast-forward) and pushed 2026-11-09. Simulator UI at 3590c25 (last code change): QA iPhone 15 Pro Max 42/43, QA iPhone 17 Pro Max 42/43 (skip = two-phone test needs both real phones)
- [x] Review round (GPT-5.3): D30 look on every pocketed ball, observed-gone only (≥ 80 %), independent side-pocket evidence. Matrix (app, -O) before/after: in-scope 92.3 → 92.0 %, all 72.0 → 71.1 %, p50 1.33 → 1.27 s, elev-45/60 25/40 → 20/40 %, false 1 → 1 (wrong size, dist-2.0m seed 3, 18.9 cm)
- [x] GPT-5.6 re-review of 3590c25 (all 5 fixed; Gemini approves; 3 test-strength MAJORs, test-only): oracle quiet computed after the expected aim update (aim grace not quiet) + aim flicker; rated == recorded; dropout runs of 1-6 frames on an independent clock + directed multi-frame dropout test (seed 0xC0FFEED33, 360,804 frames, 0 violations; broken variants fail: no aim-phase check close-gate 1,341, recorded closed unrated close-kind 1,304, first-frame-only gate close-gate 356). Unit 1132/1132 on Sim E
- [x] GPT-5.6 re-review of 71b0253 (1 BLOCKER, 4 MAJORs): partial dropout counts as motion (0.3 s window), pipeline keeps raw positions across misses + reacquisition onset; a moving shot-end frame never feeds the new look; invariant oracle with independent aim/look/full-record spec models (seed 0xC0FFEED32, 3000 seq, 380,350 frames, 1,886 records, 0 violations; 71b0253: close-gate 93 / record 32 / aim 362). Unit 1131/1131; UI on Sim E 41/41 (1272a04)
- [x] GPT-5.6 review of dc5f5bd (2 BLOCKERs, 2 MAJORs): raw motion-onset signal as the one motion gate; aim evidence survives relocks, closes wait for a fresh quiet frame; resolved-record close seam; independent invariant oracle (seed 0xC0FFEED31, 3000 seq, 381,855 frames, 0 violations; old logic: B1 83 / B2 2,820). Unit 1128/1128; UI on Sim E 41/41 (bb5a452)
- [x] GPT-5.6 holistic audit (4 MAJORs): Live shot lifecycle restructured into one FIFO state machine (looking/decided/lost), motion gate, shot-end aim opening; ShotLifecycleInvariantTests (seed 0xC0FFEED30: 3000 sequences, 307,073 frames). Unit 1125/1125; UI on Sim E 41/41 (d7c28b3)
- [x] GPT-5.3 K2 BLOCKER: shell sees every aim while a D30 shot is held; held settle lands outside an aim (contract in INTERFACES). Join Leave/Back/Settings and seat Add touch targets now ≥ 44 pt on the tappable label; walkMatrix uses a waiting-only lobby. Unit 1114/1114 (373b312); UI on Sim E 41/41 (AppShell + ScreensA + ScreensB + LiveReplay)
- [x] Review round (Kimi K3): relock drops a held D30 shot (closed unrated), shell aim lifecycle balanced while held, no settle/badge during aim, model cueScore. Unit 1113 (2 fixed/verified: a look-window test updated, soak passes alone 0.0 MB growth); UI on Sim E: LiveReplay + ScreensA + ScreensB 29/29
- [x] D30 "look, then ask" for uncertain pockets (resolver + icon-only post-shot confirm); unit 1106/1106 at d8752e9
- [~] Device UI (iPhone 17 Pro Max): AppShell + Screens 24 pass / 2 fail (both device-timing test issues, fixed in de656b7, not yet re-run: phone went unavailable)
- [ ] Device QA on both physical phones (15 Pro Max perf gate, 17 Pro Max) at 4e42342: phones were unavailable (locked/disconnected); includes checking the 4 mm raw-motion threshold on a real table
- [ ] User: lost-shot adjudication UI · default detector (model vs classical) after real-table footage · stick-visible-but-no-stroke veto (D29 scope)

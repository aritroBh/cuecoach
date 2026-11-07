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
- [~] Physics: supervisor (Claude) REJECTED a9fc236 — jaw cushions one-sided, weak fixtures, 16-ball break 13 ms; Codex fixing
- [ ] Physics: fixture suite within tolerance
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
- [~] Core ML ball detector: synthetic data + YOLO train + .mlpackage export — Codex, .worktrees/detector
- [~] Live screen: camera + table outline + ball rings + aim line, no text while aiming
- [ ] Real-table footage from the user (The Rive) for tuning + held-out test video
- [ ] Post-shot VLM: Apple Foundation Model + benchmark FastVLM / Qwen-VL (MLX) on 15 Pro Max (D22)

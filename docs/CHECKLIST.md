# Checklist (live — update as work starts/finishes)

Legend: [ ] todo · [~] in progress · [x] done · [!] blocked on user

## Step 0 — Bootstrap
- [x] git init, directory layout, CLAUDE.md, SPEC/DECISIONS/CHECKLIST
- [x] .gitignore, XcodeGen project, CueCore package skeleton (Geometry contracts TDD, 9 tests green)
- [x] Empty app builds + launches on iOS 27 simulator (unit + UI test pass)
- [!] Device install: needs Apple ID in Xcode → Settings → Accounts, phone unlocked (17 Pro Max now; 15 Pro Max after iOS 27 update)
- [x] Public GitHub repo created, bootstrap pushed (github.com/aritroBh/cuecoach)
- [x] Research The Rive (UIUC) table size → D7: table exists, size not found online
- [x] pooltool 0.6.0 env (tools/physics_fixtures, uv)
- [x] External CLIs smoke-tested: codex OK; cursor-agent needs --trust; agy has print mode; omniroute router

## Step 1 — Proposals (gate: user review)
- [x] docs/SCHEMA.md (SwiftData, two stores)
- [~] docs/INTERFACES.md (doc done; Swift stubs after approval)
- [x] docs/RULES.md bar-rule conventions draft (+ docs/research/rules-notes.md, WPA 2026-10-21)
- [!] User approves schema, interfaces, bar conventions

## Phase 1 — Core
- [ ] Rules: WPA PDFs + Dr. Dave read, rule numbers cited
- [ ] Rules: bar 8-ball tests + impl
- [ ] Rules: WPA 8-ball tests + impl
- [ ] Rules: WPA 9-ball tests + impl (push-out, 3-foul)
- [ ] Physics: pooltool fixture generator (500 shots)
- [ ] Physics: phenomenon unit tests + impl
- [ ] Physics: fixture suite within tolerance
- [ ] Persistence: SwiftData models + export/import round-trip
- [ ] Persistence: training/competitive isolation test
- [ ] Virtual table: design mock (open-pencil / ui-ux-pro-max)
- [ ] Virtual table: playable 8-ball + 9-ball, XCUITests
- [ ] Cross-vendor review of every module, findings fixed
- [ ] Device run on iPhone 15 Pro Max, design review
- [ ] Merge, delete branches/worktrees, clean status

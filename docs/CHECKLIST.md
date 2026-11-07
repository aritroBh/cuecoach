# Checklist (live — update as work starts/finishes)

Legend: [ ] todo · [~] in progress · [x] done · [!] blocked on user

## Step 0 — Bootstrap
- [x] git init, directory layout, CLAUDE.md, SPEC/DECISIONS/CHECKLIST
- [ ] .gitignore, XcodeGen project, CueCore package skeleton
- [ ] Empty app builds + launches on iOS 27 simulator
- [ ] Empty app installs on iPhone 15 Pro Max (needs Developer Mode on device)
- [ ] Public GitHub repo created, bootstrap pushed
- [ ] Research The Rive (UIUC) table size → D7

## Step 1 — Proposals (gate: user review)
- [ ] docs/SCHEMA.md (SwiftData, two stores)
- [ ] docs/INTERFACES.md + Swift protocol stubs
- [ ] docs/RULES.md bar-rule conventions draft
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

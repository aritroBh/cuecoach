# Agent org & ledger

```
Head orchestrator (main Claude session) — plan, checklist, contracts, merges, phase gates
└─ Phase orchestrator (one Workflow per phase)
   └─ per module: Worker (tests → code, own worktree)  ⇄  Supervisor (different vendor, critical, can reject)
                  + extra review pass via OmniRoute
```

Vendors: Claude subagents · Codex (`codex exec`) · Cursor (`cursor-agent -p`) · Antigravity (`agy`) · OmniRoute.
Rule: **a module is never reviewed by the vendor that wrote it.**

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
| 2026-11-09 | Fix round wt/fix-app: 7 review MAJORs (turn discs, swap, review header, lobby Start, HUD key, store recovery, FaceBenchmark order) + Grok BLOCKER on fix 1 (legalSink) | Claude worker | Kimi K2.5 APPROVE 1–7; Grok 4.7 APPROVE 2–7, BLOCKER on 1 fixed in 8eecfc0; reviewer pending (non-Claude) for 8eecfc0 | awaiting re-review + head merge |

† Cursor review attempted 2026-11-06 but its plan hit the monthly usage limit on all models (resets 2026-11-09); Codex reviewed instead.

‡ Antigravity (planned UX reviewer) returned 429 quota exhausted (resets in ~7 days), so Codex did the UX pass from the screenshots too.

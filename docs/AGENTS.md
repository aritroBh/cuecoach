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
| 2026-11-07 | App shell (Home, Game setup, Join nearby, Training picker, in-game chrome, MPC lobby) | Claude (worker subagent) | Codex (code, 6 rounds) + Codex (UX from screenshots, 4 rounds) ‡ | code APPROVE (r6), UX APPROVE (r5); Live/calibration/Training owner items open |

† Cursor review attempted 2026-11-06 but its plan hit the monthly usage limit on all models (resets 2026-11-09); Codex reviewed instead.

‡ Antigravity (planned UX reviewer) returned 429 quota exhausted (resets in ~7 days), so Codex did the UX pass from the screenshots too.

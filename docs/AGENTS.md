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
| Persistence (SwiftData, backup JSON) | Cursor | Claude | Codex |
| Virtual table UI | Claude | Antigravity (design + code) | Codex |

## Ledger
| Date | Module | Wrote | Reviewed | Result |
|---|---|---|---|---|
| 2026-11-06 | Geometry contracts | Claude (head) | — (contract, reviewed with Phase 1) | merged to bootstrap |

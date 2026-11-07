# CueCoach — project rules

On-device AI pool coach for iOS 27. Full spec: `docs/SPEC.md`. Live progress: `docs/CHECKLIST.md`.

## Non-negotiables (from spec §2)
- Swift 6, SwiftUI, iOS 27 min, iPhone 15 Pro+. Free Personal Team: no iCloud, push, App Groups,
  Associated Domains, or restricted entitlements. Check Apple's "Supported capabilities (iOS)" before adding one.
- **Zero network calls.** No backend, analytics, or SDKs that phone home. Mesh = MultipeerConnectivity only.
- **No text, no audio while aiming.** Post-shot badges: icon + color + ≤2 words. Never numeric-precise advice.
- Recognition data is opt-in, on-device, deletable in one tap.
- Training stats never touch competitive stats (separate SwiftData store).
- Product ambiguity → stop and ask the user. Don't guess.

## How we build
1. **TDD, always.** Red → green → refactor. No production code without a failing test first.
   Pure logic lives in `Packages/CueCore` (`swift test`, seconds, no simulator).
2. **Contracts first.** Change `docs/INTERFACES.md` + protocol stubs before parallel work starts.
3. **Agent hierarchy** (details in `docs/AGENTS.md`):
   - Head orchestrator (main Claude session): plan, checklist, interfaces, merges, phase gates.
   - Phase orchestrator (one Workflow per phase) → per module a **worker** + a **supervisor**.
   - Worker writes tests then code in its own git worktree. Supervisor is critical, checks spec + tests, can reject.
   - Workers/supervisors span vendors: Claude subagents, `codex exec`, `cursor-agent`, `agy` (Antigravity),
     OmniRoute (`omniroute`) for extra review passes. **A module is never reviewed by the vendor that wrote it.**
   - Record who wrote/reviewed each module in `docs/AGENTS.md`.
4. **Skills.** Debugging: `systematic-debugging`. UI: `ui-ux-pro-max`, `open-pencil` mocks, `mobile-design-thinking`,
   `ios-design-review`, `ios-qa`. Before claiming done: `verification-before-completion`.
5. **QA hard.** Unit tests + XCUITest on the iOS 27 simulator (`CueCoach iPhone 15 Pro`), then the real device
   (iPhone 15 Pro Max = perf gate, 17 Pro Max = second mesh phone). Web research/QA via `claude-in-chrome`.
6. **Checklist.** Update `docs/CHECKLIST.md` as items start and finish. It is the source of truth for status.

## UI taste rules
- Big, visual, calm. Camera + lines are the hero. Large touch targets (≥44 pt).
- No pill clutter, no walls of small text, no badge soup, no gradient-text/AI-slop styling.
- Feedback = lines, rings, glows, color, arrows, heatmaps. Labels only where the spec allows.

## Git hygiene
- Branch per phase (`phase/N-name`), short-lived worktree branches per module (`wt/<module>`).
- Never `git push --force`, `git reset --hard` (without a backup branch), or `git clean -fd`. Use stash/branches.
- Merge, then delete merged branches and remove worktrees. Temp files go in a scratch dir, not the repo.
- **Public repo:** no secrets, no personal photos/footage, datasets only if the license allows redistribution.

## Commands
- Core tests: `cd Packages/CueCore && swift test`
- Generate project: `xcodegen generate`
- App tests: `xcodebuild test -project CueCoach.xcodeproj -scheme CueCoach -destination 'platform=iOS Simulator,name=CueCoach iPhone 15 Pro'`
- Physics fixtures: `cd tools/physics_fixtures && uv run generate.py`

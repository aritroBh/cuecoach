# Plan 014: Pro 8 (88″) and 86″ table presets (D46)

> **Executor instructions**: Follow this plan step by step. Run every verification and confirm the expected result
> before the next step. Honor the STOP conditions; do not improvise. When done, update this plan's row in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 8927481..HEAD -- Packages/CueCore/Sources/Geometry/Table.swift CueCoach/Calibration CueCoach/App/GameSetupView.swift CueCoach/Screens/Settings CueCoach/Screens/Lobby CueCoach/Mesh/MeshMessage.swift`
> Plan 005 (D36 C: the chosen size is the lock prior) touches `CueCoach/Calibration/Auto/*`. It must be merged first.

## Status
- **Priority**: P2 · **Effort**: M · **Risk**: MED (a Codable enum shared by persistence and the mesh) · **Depends on**: plan 005 merged · **Category**: feature
- **Planned at**: commit `8927481`, 2026-11-10

## Why this matters
Auto-calibration snaps a measured table to a preset within 6 % (D36). Plan 005 found that a tighter 2 % snap mis-locks
standard tables, because the camera's multi-frame size is off by 2–6 % on normal 7/8/9 ft tables. So a Pro 8
(88″ playing length, 4.4 % short of the 92″ "8 ft") still locks as "8 ft" unless the player picks its size. With plan 005
the size picked in game setup or Settings is the lock **prior**. **Decision D46 (user, "Both"):** keep the 6 % snap, and
add **Pro 8 (88″ × 44″)** and **86″ (86″ × 43″)** as presets the player can pick. Picking one makes it the prior.

## Current state
- `Packages/CueCore/Sources/Geometry/Table.swift:6-17`:
  ```swift
  public enum TableSize: String, CaseIterable, Codable, Sendable {
      case sevenFoot, eightFoot, nineFoot
      public var playingLength: Double {
          switch self {
          case .sevenFoot: 80 * 0.0254
          case .eightFoot: 92 * 0.0254
          case .nineFoot: 100 * 0.0254
          }
      }
  }
  ```
  Width is length / 2 (check `TableSpec(size:)` in the same file; if it isn't, STOP).
- Exhaustive switches that need a case: `CueCoach/Screens/Settings/SettingsViewModel.swift:179` and
  `CueCoach/Screens/Lobby/LobbyView.swift:508` (`feet: Int`). Run
  `grep -rn "sevenFoot\|nineFoot\|TableSize.allCases\|CaseIterable" CueCoach Packages/CueCore/Sources` for the rest
  (pickers that iterate `allCases`, the auto-fit preset list in `CueCoach/Calibration/Auto/AutoTableFusion.swift` and
  `AutoTableFitter.swift`).
- Persistence: `CueCoach/Persistence/CompetitiveModels.swift:82-84` stores `tableSizeRaw` as a String and decodes with
  `TableSize(rawValue:) ?? .sevenFoot`. New cases are added data; old stores still decode. **No schema change.**
- Mesh: `CueCoach/Mesh/MeshMessage.swift:113` sends `tableSize: TableSize` in the game config. An older build cannot
  decode a new case. The wire carries a major version byte (`MeshMessage.swift:319-333`).

## Scope
In: `Table.swift`, every exhaustive switch the compiler flags, the setup/Settings/Lobby pickers, the auto-fit preset
list, the mesh compatibility rule below, tests.
Out: the snap tolerance (stays 6 %), the lock prior logic (plan 005), the D36 between-presets hint, SwiftData schema.

## Steps
1. **Red (CueCore)**: in `Packages/CueCore/Tests`, next to the existing `Table` tests, add
   `proEightAndEightySixInchPresetsHaveTheirPlayingSurface`: `.proEight` length 88 × 0.0254, `.eightySixInch`
   length 86 × 0.0254, width = length / 2; `TableSize.allCases` lists them in length order
   `[.sevenFoot, .eightySixInch, .proEight, .eightFoot, .nineFoot]`. **Verify**: `cd Packages/CueCore && swift test` fails.
2. **Green**: add the cases in that declaration order with raw values `proEight` and `eightySixInch`. Fix every switch
   the compiler flags. In `feet: Int`-style labels, the UI shows "Pro 8" and "86″". If a label can't fit an `Int`,
   change that property to a short `String` label and update its callers. **Verify**: `swift test` passes.
3. **Auto-fit**: check whether the auto-fit snap list is `TableSize.allCases`. If yes, the new presets now snap within
   6 %. Pro 8 and 8 ft are 4.4 % apart, so a measured 2.30 m could snap to either. Precedence (D36 C): if the player chose a size and the
   measurement is within 6 % of it, the chosen size wins; with no prior (or the prior > 6 % off), the nearest preset
   wins. Add a red test in `CueCoachTests/Calibration` (pattern:
   `AutoTableUnlistedSizeTests` from plan 005): with no prior, steady fits at 2.235 m lock as `.proEight` and at 2.337 m as
   `.eightFoot`; with prior `.eightFoot`, a 2.25 m fit locks as `.eightFoot`; with prior `.proEight`, a 2.30 m fit
   locks as `.proEight`. Then make it pass.
4. **Lock matrix**: run the -O lock matrix the way plan 005 did (`scratchpad/matrix.sh`; `TEST_RUNNER_VQA_MATRIX=1`,
   `TEST_RUNNER_VQA_LOCATORS=app`, `SWIFT_OPTIMIZATION_LEVEL=-O`, `VirtualTableTests/lockMatrix()`). Gate: 0 false
   locks, in-scope ≥ 92.0 %. A standard 8 ft scene that now locks as Pro 8 counts as a false lock: **STOP** and report
   the scenes.
5. **Mesh**: a joiner on an older build must not crash or silently lose the game. Add a test in `CueCoachTests/Mesh`:
   a config with `.proEight` encodes, and decoding it under the current major works. Do **not** bump the major for this
   alone. If plan 009 has already bumped it to 2, the new cases ship inside major 2. Otherwise **STOP** and report,
   because the head decides whether this rides on 009's bump.
6. **UI**: setup, Settings and Lobby pickers show five sizes. Run `AppShellUITests` and the Settings/Lobby UI tests,
   with ≥ 44 pt targets, and keep the Astryx styling of the existing picker.
7. Full `CueCoachTests` on a CueCoach sim; record the counts.

## Done criteria
- `swift test` green, full `CueCoachTests` green, the UI tests above green, lock matrix gate met.
- `grep -n "proEight\|eightySixInch" Packages/CueCore/Sources/Geometry/Table.swift` shows both cases.

## STOP conditions
- Width isn't length / 2, or a real Pro 8 / 86″ spec differs from 88 × 44 / 86 × 43: report it, don't guess.
- A standard-table false lock in the matrix (step 4).
- The mesh step (step 5) without a major-2 bump in place.

## Maintenance
Every new exhaustive `switch` on `TableSize` must handle all five. The default for an unknown raw value stays `.sevenFoot`.

# Screens A: Settings + Player Profile (page override)

Overrides `../MASTER.md` only where stated; everything else follows MASTER. Sources: SPEC §2, §6–§8, §10, §11;
SCHEMA; DECISIONS D7, D9, D12–D14, D18, D20. Made with ui-ux-pro-max (SwiftUI stack, chart + UX domains) and
mobile-design-thinking (thumb zone, platform conventions, haptics).

Neither screen is a game screen, so short labels are fine (SPEC §2 bans text and audio only while aiming).
"Short" still means it: a row label is 1–3 words, a helper line is one sentence at most, and no screen has paragraphs.

## Shared rules for both screens
- **Background** `bg`. Grouped cards are `surface`, radius 20, 16 pt gutters, 8-pt grid, 24 pt between sections.
- **Type:** 34 bold for the nav large title, 22 semibold for section headers, 17 regular for rows, 13 semibold
  for chart axis labels and 2-word captions (the floor; nothing smaller). Numbers use SF Pro Rounded with
  `.monospacedDigit()`. Dynamic Type everywhere; at AX sizes, rows stack vertically and charts get taller.
- **Icons:** SF Symbols `.semibold` for controls, `.regular` for row glyphs. Row glyph sits in a 28 pt circle
  tinted `inkMuted`, never a coloured square chip. No emoji.
- **Accent:** one per screen (MASTER rule 4). Settings uses `legal` for "on" toggles only. Profile uses Team A blue
  (#60A5FA) when the profile is on Team A, otherwise the profile's `avatarColor`. `danger` is reserved for delete.
- **Targets:** every row and control is at least 44 pt tall; segmented and silhouette tiles are at least 64 pt.
- **Motion:** `.smooth` for sheets and tab changes, `.snappy` for toggles and selection. Charts draw in once
  (trim 0→1, 0.35 s). With Reduce Motion on, every animation is a crossfade.
- **Haptics:** `.selection` on picker or toggle change; `.success` after export, import, or delete; `.error` on failure.
- **Color is never the only signal.** Heat cells also show a fill-level glyph, locked items show `lock.fill`,
  and selected tiles show `checkmark.circle.fill`.
- **No pills, badge soup, gradient text, or stacked glass.** One `.ultraThinMaterial` layer at most (the sticky header).

---

## 1. Settings

Public API: `SettingsView(model: SettingsViewModel)`. It is pushed from Home (another agent owns Home and the
navigation wiring).

### Wireframe (portrait)
```
┌──────────────────────────────────────┐
│ ‹                                    │
│ Settings                       (34b) │
│                                      │
│ PRIVACY                       (22sb) │
│ ┌──────────────────────────────────┐ │
│ │ (person.crop.circle.badge.check) │ │
│ │ Recognize me             [  ●]   │ │  Toggle, opt-in, default OFF
│ │ Stays on this phone.     (13 mut)│ │  one line of helper text, max
│ ├──────────────────────────────────┤ │
│ │ (trash)  Delete my data      ›   │ │  danger tint, opens confirmation
│ └──────────────────────────────────┘ │
│                                      │
│ BACKUP                               │
│ ┌────────────────┐┌────────────────┐ │
│ │  square.and.   ││  square.and.   │ │  two 88-pt square tiles
│ │  arrow.up      ││  arrow.down    │ │
│ │  Export        ││  Import        │ │
│ └────────────────┘└────────────────┘ │
│   Include face data        [●  ]     │  shown only when recognition data exists
│                                      │
│ RULES                                │
│ ┌──────────────────────────────────┐ │
│ │ ( 8 )      ( 8 )      ( 9 )      │ │  3 rule tiles: ball glyph + 2-word label
│ │  Bar       WPA 8      WPA 9      │ │  selected tile has ring + check
│ ├──────────────────────────────────┤ │
│ │ Three-ball rule          [●  ]   │ │  shown only when WPA 9 is selected; default ON (D13)
│ └──────────────────────────────────┘ │
│                                      │
│ TABLE                                │
│ ┌──────────────────────────────────┐ │
│ │  ▭        ▭▭        ▭▭▭          │ │  felt silhouettes drawn to scale
│ │  7 ft     8 ft      9 ft         │ │  (7 ft default per D14)
│ │ (sensor.fill) Auto-measured      │ │  LiDAR note, only after a measurement
│ └──────────────────────────────────┘ │
│                                      │
│ DEVELOPER                            │
│ │ (gauge) Debug HUD        [●  ]   │ │  D9, the only place HUD text is enabled
└──────────────────────────────────────┘
```
In landscape the screen uses two columns: Privacy and Backup on the left, Rules, Table and Developer on the right,
with 24 pt gutters.

### Hierarchy
1. Privacy comes first because it is the trust contract (SPEC §2).
2. Backup.
3. Rule and table defaults.
4. Developer comes last and looks visually quieter: `inkMuted` glyph and no card fill.

### Components
| Component | Spec | Tokens / symbols |
|---|---|---|
| `SettingsSection` | `Form` with `.formStyle(.grouped)`, `Section` header 22 sb, `listRowBackground(surface)` | `surface`, `ink` |
| Recognition toggle | `Toggle`, tint `legal`; turning it on starts the Identity opt-in flow through a protocol callback (not built here) | `person.crop.circle.badge.checkmark` |
| Delete row | `Button(role: .destructive)`, glyph and label in `danger`; hidden when there is no data (see States) | `trash` |
| Delete confirm | `.confirmationDialog` with one destructive button "Delete" and Cancel. Title: "Delete recognition data?" | `danger` |
| Backup tiles | 2 × 88 pt square buttons, radius 14, `surface`, glyph 28 pt `ink` | `square.and.arrow.up`, `square.and.arrow.down` |
| Export | `ShareLink` (or a `UIActivityViewController` sheet) for a `BackupDocument: Transferable` that wraps `exportBackup(includeRecognition:)` data, filename `CueCoach-YYYY-MM-DD.json` | — |
| Import | `.fileImporter(allowedContentTypes: [.json])` → `importBackup(_:)` | — |
| Include-face toggle | Default OFF (SCHEMA: recognition is never exported unless ticked) | `faceid` |
| Rule tiles | 3 equal tiles, at least 96 × 88 pt: ball glyph circle (SF Pro Rounded "8"/"9" on a black or yellow disc) + label. Selected: 2 pt `ink` ring + `checkmark.circle.fill`. `accessibilityAddTraits(.isSelected)` | `ink`, `inkMuted` |
| Three-ball toggle | Visible only when WPA 9 is selected; slides in with `.snappy`. Helper text: "Soft breaks re-rack." | `3.circle` |
| Table silhouettes | `Canvas` rectangles in `felt` + `rail` frame, widths in true 7:8:9 proportion, 6 pocket dots. Selected tile has a `legal` outline + check | `felt`, `rail`, `legal` |
| Auto-measured note | Appears only when the Calibration protocol reports a LiDAR or ball-scale measurement (D7, D12): `sensor.fill` + "Auto-measured", 13 sb `inkMuted`. Tapping a tile overrides it (the note then reads "Manual") | `sensor.fill` |
| Debug HUD toggle | Plain row, `inkMuted` glyph | `gauge.with.dots.needle.33percent` |

### States
| State | Treatment |
|---|---|
| No recognition data | Toggle OFF. The delete row is still visible but disabled at 40% with the helper "Nothing stored." This keeps the action discoverable without inviting a no-op tap. |
| Deleting | Row glyph becomes a `ProgressView`; the row is disabled. |
| Deleted | `.success` haptic, the glyph morphs to `checkmark` (`.contentTransition(.symbolEffect)`) for 1.5 s, then the row returns to its disabled state. The toggle flips OFF. |
| Delete failed | `.error` haptic, an inline `danger` line under the row ("Couldn't delete. Try again."), and the row stays enabled. |
| Exporting | The Export tile shows a spinner in place of its glyph and is disabled until the share sheet appears. |
| Export failed / cancelled | Cancel: nothing happens. Failure: inline line under the tiles ("Export failed."). |
| Importing | Both tiles are disabled and the Import tile shows a spinner. |
| Import done | `.success` haptic + tile glyph `checkmark` for 1.5 s. No count wall. |
| Import failed (bad JSON / unknown version / orphan parent) | `.alert` titled "Can't import" with one sentence: "This file isn't a CueCoach backup." or "Made by a newer version." OK button. |
| No measurement yet | No auto-measured note; the 7 ft tile is selected. |

### Gestures
Tap for everything, plus the system back swipe. No swipe actions; destructive actions always go through the
confirmation dialog.

### Accessibility
- Rule tiles: label "8-ball bar rules", "8-ball WPA", "9-ball WPA" (spoken in full even though the visible text is short).
- Table tiles: "7 foot table" plus ", measured" when auto-measured.
- The delete row gets the hint "Removes face and look data from this phone."
- Toggles use native semantics. All tiles are `Button`s so Switch Control and VoiceOver work for free.
- At AX5 Dynamic Type, the tiles reflow to a vertical list (`ViewThatFits`).

### View model (local protocols, in-memory previews)
```swift
@MainActor protocol SettingsStore: AnyObject {            // backed by PersistenceStack in the app
    var hasRecognitionData: Bool { get }
    func deleteMyRecognitionData() throws
    func exportBackup(includeRecognition: Bool) throws -> Data
    func importBackup(_ data: Data) throws
}
protocol TableMeasurementSource { var measured: TableSize? { get } }   // Calibration owns the real one
// Defaults (rule set, three-ball, table, debug HUD, recognition opt-in) → @AppStorage keys "cc.rules.default", ...
```

---

## 2. Player profile

Public API: `PlayerProfileView(model: PlayerProfileViewModel)`.

### Wireframe (portrait, Stats tab)
```
┌──────────────────────────────────────┐
│ ‹                               ⋯    │  ⋯ = edit name/avatar (sheet)
│             ╭────────╮               │
│             │  (fig) │  96-pt avatar │  avatarSymbol on avatarColor disc
│             ╰────────╯               │
│              Sam             (34 b)  │
│        ( Cut Artist )  glyph+2 words │  top archetype only (one, not a row of chips)
│                                      │
│   ┌ Stats ┬ History ┬ Training ┐     │  segmented Picker, 44 pt
│                                      │
│  ┌──────── RADAR ─────────────────┐  │  archetype vector, 6–8 axes, 1 dataset
│  │        ╱‾‾‾‾╲                  │  │  fill accent @20%, stroke 2 pt
│  │      ╱  ◆◆   ╲                 │  │  short axis labels (13 sb)
│  │      ╲ ◆◆◆◆  ╱                 │  │
│  │        ╲____╱                  │  │
│  └────────────────────────────────┘  │
│                                      │
│  ┌──── MAKE % ───────────────────┐   │  heat grid: rows = distance (3),
│  │        0  15  30  45  60+     │   │  cols = cut bucket (5) → 15 cells
│  │ Short  ■  ■   ▣   ▢   ▢       │   │  fill = make %, glyph fill-level
│  │ Mid    ■  ▣   ▣   ▢   ·       │   │  "·" = <5 attempts (no data)
│  │ Long   ▣  ▢   ▢   ·   ·       │   │
│  └───────────────────────────────┘   │
│                                      │
│  ┌──── PLAYS LIKE ───────────────┐   │  pro comp card
│  │  ◯ ring 78%  Efren Reyes      │   │  similarity ring, no decimals
│  │  (scope) Cut   (arrow) Banks   │   │  top 2 shared traits, glyph+word
│  └───────────────────────────────┘   │
│                                      │
│  BADGES                              │  earned only, max 8 per row, 56-pt discs
│  ◉ ◉ ◉ ◉                             │  tap → detail sheet
│                                      │
│  3 big numbers row                   │  Make %, Games, Win %, SF Rounded 28
└──────────────────────────────────────┘
```

### History tab
```
│  NOV 2026                       (22) │
│ ┌──────────────────────────────────┐ │
│ │ (8)  Bar · 2v2      ●○  W        │ │  rule glyph, format, result disc
│ │      Thu 6 Nov · 3 games      ›  │ │  one secondary line
│ ├──────────────────────────────────┤ │
│ │ (9)  WPA 9 · 1v1    ○●  L        │ │
```
A `List` of sessions, grouped by month, newest first. Tapping a session expands it into its games; tapping a game
pushes Game Review (owned by another agent, reached through a closure `onOpenGame(UUID)`).
W/L is a filled `legal` `checkmark.circle` or an outlined `danger` `xmark.circle`, never colour alone.

### Training tab (separate store, visually distinct)
```
│ ┌ Training only ───────────────────┐ │  section header carries `graduationcap` glyph
│ │ Straight-ins   ●●●○  Lv 3        │ │  4 dots = assist level 1–4
│ │ Cuts           ●●○○  Lv 2        │ │
│ │ Banks          ●○○○  Lv 1        │ │
│ └──────────────────────────────────┘ │
│  TENDENCY                            │  only when an active BiasRecord exists
│ ┌──────────────────────────────────┐ │  one correction at a time (SPEC §10)
│ │  correct line ── / your line ─ ─ │ │  two-line diagram + arrow
│ │  (arrow.uturn.left) Overcut       │ │  ≤2 words
│ └──────────────────────────────────┘ │
```
The tab never shows a make %, a WPA or win rate, an archetype, or a pro comp. It reads only the Training store's
`DrillProgress` and `BiasRecord`, through a separate `TrainingProfileSource` protocol, so the two stores cannot be
mixed. A thin top band in `brilliant` @ 15% (the only cyan on this tab) marks "training space". Override: this
is the single place `brilliant` is used outside a rating badge, as a mode tint.

### Hierarchy
1. Avatar and name (identity).
2. Radar, the "who you are" shape.
3. Make % heat, the "where you miss" view.
4. Pro comp.
5. Badges.
6. Totals.

Charts are the hero and numbers are secondary.

### Components
| Component | Spec | Tokens / symbols |
|---|---|---|
| Avatar | 96 pt circle, `avatarColor` fill, `avatarSymbol` 44 pt `ink` | Team A/B colors if set |
| Archetype label | Single capsule-free label: symbol + ≤2 words, 17 sb, `inkMuted`. Only the top tag | per-tag symbol table below |
| Tab picker | `Picker(.segmented)`; tab persisted per profile in `@SceneStorage` | — |
| `ArchetypeRadar` | Swift Charts can't draw radar → custom `Canvas`. 6–8 axes from `ArchetypeSnapshot.vector` (ui-ux-pro-max: >8 axes unreadable). 3 grid rings @ `inkMuted` 20%, polygon fill accent @20%, stroke 2 pt accent. Long-press shows a previous snapshot as a dashed `predict`-style outline (evolution) | accent, `predict` dash 6/6 |
| `MakeHeatGrid` | 5 × 3 grid of 52 pt square cells, radius 8, spaced 4. Fill = `legal` at opacity 0.15 + 0.85·make%. Each cell also has a 4-level fill glyph (`circle`, `circle.lefthalf.filled`, `circle.fill`, ring) so it doesn't depend on colour. Cells with fewer than 5 attempts are a `inkMuted` dot. Axis labels 13 sb. No numbers in cells; long-press shows "62% · 40 shots" (aggregate stat, not aiming advice, so it is allowed here) | `legal`, `inkMuted` |
| `ProCompCard` | `surface` card, 120 pt tall: similarity ring (`Gauge(.accessoryCircularCapacity)` style, accent) + pro name 22 sb + 2 trait rows (symbol + word) | accent |
| Pro comp locked | Same card frame with a blurred silhouette ring, `lock.fill`, and a progress ring for games 3 + shots 50 (SPEC §7). Caption: "3 games" or "50 shots", whichever is still missing | `lock.fill`, `inkMuted` |
| `BadgeShelf` | `LazyVGrid` of 56 pt discs, symbol 26 pt, only earned badges. Tapping opens a `.sheet(.medium)` with the big symbol, a 2-word name, and the date earned. Max 8 visible + "All" | per-badge symbol |
| Totals row | 3 columns: SF Rounded 28 number + 13 sb caption | `ink`, `inkMuted` |
| History list | `List(.insetGrouped)`, row ≥ 60 pt, rule glyph disc 36 pt | `legal`/`danger` + shape |
| Drill row | Name 17, 4 level dots (filled `ink` / empty `inkMuted` stroke), "Lv N" 13 sb | — |
| Tendency card | `Canvas`: correct line `aim` 2 pt solid, habitual line `predict` dashed, arrow `caution`. 2-word label | `aim`, `predict`, `caution` |

Archetype symbols (SPEC §7): Cut Artist `scope`, Long Gun `arrow.up.right`, Side-Pocket Sniper `circle.dotted`,
Ice Veins `snowflake`, Safety Chess `shield.lefthalf.filled`, Cannon Break `burst.fill`,
Run-out Machine `repeat`, Bank Wizard `arrow.turn.up.right`.

### States
| State | Treatment |
|---|---|
| Loading (stats computing) | Chart frames render at their final size with a `redacted(.placeholder)` shimmer, so nothing shifts when data arrives. No spinner wall. |
| New player (0 games) | Radar is replaced by an empty outline polygon + `figure.pool` symbol + one line "Play a game to start." The heat grid is all dots. The pro comp shows its locked state. The badge shelf is hidden, not shown empty. |
| Pre-unlock (<3 games or <50 shots) | The radar shows a "draft" dashed outline at 50% opacity with a `lock.fill` corner mark, and no archetype label. Pro comp is locked with a progress ring. |
| Unlocked | Full radar, top archetype label, pro comp card. |
| Pro data missing for a trait | The trait row is omitted; never invent one (SPEC §8). If `ProProfiles.json` fails to load, the card is hidden. |
| Error (store unreadable) | Centred `exclamationmark.triangle` + "Couldn't load stats." + a "Retry" button (44 pt). |
| History empty | `ContentUnavailableView` with `clock` + "No games yet". |
| Training empty | `ContentUnavailableView` with `graduationcap` + "No drills yet". |
| Session guest profile (peer) | Read-only: no ⋯ menu, no Training tab (it lives on the peer's phone). |

### Gestures
- Tap: tabs, badges, history rows, the pro card (opens a detail sheet with the radar overlaid on the pro's radar,
  max 2 datasets).
- Long-press on the radar shows the evolution overlay; long-press on a heat cell shows its value.
- Swipe between tabs is not used. It would conflict with the system back swipe, so the segmented control is the
  only way to switch.
- Pull-to-refresh is not needed (stats are local and recompute on appear).

### Accessibility
- The radar exposes `accessibilityChartDescriptor` (an `AXChartDescriptor` with one series and N categories) and
  an `.accessibilityRepresentation` list such as "Cut accuracy high, Long shots medium".
- Heat cells are each an element: "Mid distance, 30 to 45 degree cut, 62 percent, 40 shots". In the rotor, the
  grid is a table (`.accessibilityElement(children: .contain)`).
- The pro comp ring reads "Plays like Efren Reyes, strong match". Similarity is spoken as a band
  (weak/fair/strong), not a decimal.
- Badges: "Bank Wizard badge, earned 6 November".
- Locked card: "Pro comparison locked, 1 more game needed".
- Every chart keeps its meaning in greyscale (shape + fill glyph). Text contrast is at least 4.5:1 on `surface`.

### View model (local protocols, in-memory sample data)
```swift
protocol ProfileStatsSource {               // Stats agent implements later; computed from Shot rows
    func profile(_ id: UUID) async throws -> ProfileSummary          // name, avatar, totals
    func archetype(_ id: UUID) async throws -> ArchetypeView?        // vector, tags, snapshots, unlocked flag
    func makeGrid(_ id: UUID) async throws -> [HeatCell]             // cut × distance, attempts, makes
    func badges(_ id: UUID) async throws -> [EarnedBadge]            // earned only
    func proComp(_ id: UUID) async throws -> ProCompView?            // nil until unlock
    func history(_ id: UUID) async throws -> [SessionSummary]
}
protocol TrainingProfileSource {            // Training store only, never joined with the above
    func drills(_ playerID: UUID) async throws -> [DrillLevel]
    func activeBias(_ playerID: UUID) async throws -> BiasHint?
}
```
`SamplePlayerData` provides 4 fixtures for previews and tests: `.newPlayer`, `.preUnlock`, `.veteran`, and `.error`.

---

## Open product questions (ask the user, don't guess)
1. **Badges vs archetype tags.** Is a "badge" the same as an earned archetype tag (SPEC §7), or a separate
   achievement set (e.g. first run-out, first Brilliant)? This spec assumes archetype tags plus SotG/MVP awards
   (SCHEMA `Highlight.kind`) until the user decides.
2. **Recognition toggle OFF with data stored.** Should turning the toggle off also delete the data, or only stop
   using it? This spec assumes it only stops using it, with deletion as the separate explicit action.
3. **The Rive (UIUC) default table (D7).** The silhouettes show 7 ft as the default per D14; a "Rive" preset tile
   would be added if that research lands.

## Pre-delivery (on top of the MASTER checklist)
- [ ] Training tab code imports only `TrainingProfileSource` (grep check in tests)
- [ ] Delete flow: confirm → `deleteMyRecognitionData()` → toggle off, verified in XCUITest
- [ ] Export → import round-trip on simulator via Files
- [ ] Heat grid and radar legible in greyscale (Color Filters) and at AX5

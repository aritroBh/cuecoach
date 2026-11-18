# Screens B: Session lobby, Post-shot card, Game review

Page override for `MASTER.md`. Where this file is silent, MASTER rules. Sources: SPEC §3 (vote), §4 (formats),
§5.5 (ratings, alt shot), §9 (SotG, MVP), §11; DECISIONS D17 (order A1,B1,A2,B2), D18 (10 classes),
D20 (no 2D game: the review diagram is static); RATING_CLASSES.md (badge table); SCHEMA (Session, Game, Shot, Highlight).
Made with ui-ux-pro-max (ux, chart, swiftui lookups) and mobile-design-thinking (thumb zone, haptics, platform).

## Shared rules for all three
- Dark only: `bg` behind everything, `surface` (+ `.ultraThinMaterial`) for sheets and docks. One accent glow per screen.
- Thumb zone: the primary action sits in the bottom third, full width minus 16-pt gutters, 56 pt tall, radius 14.
- Avatars are circles (SF Symbol `avatarSymbol` on `avatarColor`) with a 3-pt team ring: Team A #60A5FA, Team B #F59E0B.
  Team is also marked by shape, not just color: Team A ring solid, Team B ring dashed 4/3 (color-blind safe).
- Type: 34 bold title (once per screen), 22 semibold section, 17 body, 13 semibold badge words. Nothing under 13 pt.
- Icons: SF Symbols, `.semibold` for controls, `.regular` for display. No emoji, no pills, no chip rows.
- Every interactive element ≥ 44 pt; in-lobby avatars 64 pt; spacing on the 8-pt grid.
- Each screen is a public `View` with `init(model:)`. Models conform to protocols defined in this folder,
  with in-memory sample data for previews and tests. Reads go through Persistence; nothing here edits it.

---

## 1. Session lobby

### Wireframe (portrait)
```
┌──────────────────────────────────────┐
│  ‹                        ⚙︎ (44pt)   │  nav: back, nothing else
│                                      │
│  Lobby                     (34 bold) │
│                                      │
│  ( ◉ ) ( ◉ ) ( ◉ )   ( + )           │  PEERS row: 56-pt avatars of phones in mesh,
│   you   Sam   Ana    join            │  host has a small crown.fill at 11 o'clock
│                                      │
│  ┌─ Teams ─────────────── 2v2 ▾ ──┐  │  format stepper: 1v1 2v2 3v3 4v4
│  │  A                     B       │  │
│  │ (◉) 1  ≡              (◉) 1  ≡ │  │  lineup columns, drag handle ≡ 44pt
│  │ (◉) 2  ≡              ( ? ) 2  │  │  empty seat = dashed circle + plus
│  │                                │  │
│  │  Order  A1 → B1 → A2 → B2      │  │  order strip = 4 tiny avatars + chevrons, no names
│  └────────────────────────────────┘  │
│                                      │
│  Rules      [8●]   [8◎]   [9◆]       │  three 72-pt vote discs, tally as dots under each
│              ••      •               │
│                                      │
│  Table      ▭7   ▭8   ▭9             │  three table outlines drawn to scale, selected glows
│                                      │
│ ┌──────────────────────────────────┐ │
│ │         ▶  Start                 │ │  56pt primary, host only
│ └──────────────────────────────────┘ │
└──────────────────────────────────────┘
```
Landscape: two columns. Left = peers + teams; right = rules, table, Start. 24-pt gutters.

### Hierarchy
1. Teams (largest block: who plays with whom) 2. Start 3. Rule vote 4. Table size 5. Peers row.

### Components and tokens
| Component | Spec |
|---|---|
| Peer avatar | 56 pt circle, `ink` symbol on `avatarColor`. Host: `crown.fill` 16 pt `ink`. Connecting: ring `inkMuted` rotating (Reduce Motion: static ring at 50%). Lost: avatar at 40% + `wifi.slash` 16 pt. |
| Join / Host | Trailing 56-pt circle `plus` ("Join" 13 pt below). Tap opens a sheet with two 64-pt buttons: `antenna.radiowaves.left.and.right` Host, `person.2.wave.2` Join. Nearby hosts appear as avatars in the sheet; tap to join. |
| Identity | Tap your own avatar or any empty seat: sheet (radius 20) with a 3-column grid of 64-pt local profile avatars + `person.badge.plus` New + `person.fill.questionmark` Guest. Names 13 pt under each, single line, truncated. New = name field (17 pt) + symbol + color picker (8 swatches, 44 pt). Guest gets `person.fill` + next free color, cached as `isSessionGuest`. |
| Format | Segmented control 1v1 / 2v2 / 3v3 / 4v4 (system `Picker(.segmented)`, 44 pt tall). Never more than 8 seats. Lowering format pushes extra players to a "bench" row of dimmed avatars, never deletes them. |
| Lineup | Two columns A/B. Each row: 56-pt avatar, seat number 17 pt SF Pro Rounded, `line.3.horizontal` handle (44×44). Drag within or across columns. |
| Order strip | Derived, read-only: avatars 28 pt in D17 order A1, B1, A2, B2, … joined by `chevron.right` `inkMuted`. Updates live as you drag. With unequal teams (e.g. 2v1 during setup) Start is locked. |
| Rule vote | Three 72-pt discs: Bar 8 = `8.circle.fill`, WPA 8 = `8.circle` + `checkmark.seal` corner, WPA 9 = `9.circle.fill`. Label ≤2 words under each ("Bar 8", "WPA 8", "WPA 9"). Your pick: 3-pt `legal` ring + `checkmark` corner. Tally: one 8-pt dot per vote below each disc (dots, not numbers). Leader (`Vote.winner`) gets the only accent glow; ties → Bar 8 glows (default), matching `Vote.winner`. |
| Table size | Three outlined rectangles drawn to real aspect (2:1) and relative length (7/8/9 ft), `rail` stroke, `felt` fill when selected. "7 ft" etc. 13 pt below. LiDAR-measured preset shows `ruler` 16 pt on its tile (pre-selected per D7/D12). |
| Start | Primary, `legal` fill, `play.fill` + "Start", `bg` text. Host only; peers see the same bar at 40% with `hourglass` + "Waiting". |

### States
- **Empty (solo):** peers row shows just you + Join. Format locked to 1v1; second seat is "Guest" by default. Everything works with one phone (SPEC §5.7).
- **Loading:** discovering peers: Join circle pulses once every 2 s (Reduce Motion: no pulse). Profile list: 3 skeleton circles.
- **Error:** a peer drops: their avatar dims + `wifi.slash`; seat stays filled. Mesh unavailable (Local Network denied): Join circle shows `exclamationmark.triangle` `caution`; tap explains in one sentence with a Settings button.
- **Locked:** Start disabled (40%, no glow) until every seat is filled and teams are equal. The empty seat that blocks it gets a single `caution` ring pulse when Start is tapped. Peers can vote and edit only their own seat; lineup edits are host only (others see no handles).

### Gestures
- Long-press (0.3 s) or handle drag to reorder; lifted avatar scales 1.08 with shadow, others slide `.snappy`. `.selection` haptic per slot crossed, `.impact(.soft)` on drop.
- Swipe left on a row: remove to bench. Tap vote disc: vote (tap again: unvote). Tap table tile: select.
- No hidden-only gestures: every drag has a VoiceOver action.

### Accessibility
- Avatar: label "Sam, team A, seat 2, host". Reorder via `accessibilityActions`: "Move up", "Move down", "Move to team B".
- Vote disc: "WPA 9-ball, 2 votes, leading". Table tile: "8 foot table, selected, measured".
- Largest Dynamic Type: lineup becomes a single column (A then B), labels wrap to 2 lines max.

---

## 2. Post-shot card (badge)

### Wireframe (over the live camera, after balls settle)
```
┌──────────────────────────────────────┐
│ (A◉)                          (B◉)   │  turn avatars stay
│                                      │
│                                      │
│              ╭──────╮                │
│              │  ✦   │  72pt circle   │  symbol 32pt, rating color fill @ 22%,
│              ╰──────╯  3pt ring      │  3pt ring in rating color
│             Brilliant   13 semibold  │
│                                      │
│                              ▮▮▮▯    │  eval bar (owned by live game)
└──────────────────────────────────────┘
```
Placement: centered horizontally, at 38% screen height (above the table center, below the avatars, never
covering the pocketed area). Landscape: same, vertically centered in the top half.

### Badge table (all 10 D18 classes; RATING_CLASSES.md is the source)
| Class | Symbol | Color token | Words |
|---|---|---|---|
| brilliant | `sparkles` | `brilliant` + soft cyan outer glow (the only glow) | Brilliant |
| great | `star.fill` | `legal` | Great |
| best | `checkmark.seal.fill` | `legal` | Best |
| good | `checkmark` | `ink` | Good |
| okay | `circle` | `inkMuted` | Okay |
| book | `book.closed.fill` | `inkMuted` | Book |
| inaccuracy | `exclamationmark` | `caution` | Inaccuracy |
| miss | `scope` | orange (see Open question) | Missed chance |
| mistake | `questionmark` | orange | Mistake |
| blunder | `xmark` | `danger` | Blunder |
Shape carries meaning without color: every class has a distinct symbol. Badge words are ≤2, no numbers, no WPA.

### Optional second line of meaning (no text)
The badge sits on the shooter's team side: a 2-pt arc in the team color under the ring points to the shooting
team's avatar. That is all; the eval bar swing shows the game impact.

### Timing and motion
- Enter after "all balls at rest": scale 0.9 → 1 + fade, 0.25 s `.snappy`. Hold 1.8 s. Exit fade 0.15 s.
- **Hides instantly** (0.15 s fade, no scale) when any phone reports aim start; never re-appears for that shot.
- Haptic: none for the badge itself (make/foul haptics already fired). Brilliant: `.success`.
- **Reduce Motion:** opacity crossfade only (0.2 s in, 0.15 s out); no scale, no glow animation (static glow).
- Tap the badge: it stays (pinned) until tap again or aim starts; opens nothing. Swipe up: dismiss early.

### States
- **Loading (engine still rating, up to ~3 s):** nothing shown. Never a spinner over the table.
- **Error / engine timeout:** no badge for that shot; review shows the shot with `circle.dashed` "Unrated".
- **Locked:** Training level 4 hides badges until reveal (D1); while anyone aims, the badge cannot appear (queued rating is dropped, not delayed).
- **Empty:** n/a.

### Accessibility
- Posted as a VoiceOver announcement ("Brilliant shot by Sam") only after settle, never during aim. Respects "no audio while aiming": announcement is suppressed if aiming has begun.
- Contrast: words in `ink` on a `surface` backdrop disc behind the label (≥ 4.5:1 over any camera frame).
- Bold Text / largest Dynamic Type: words scale to 17 pt max; circle stays 72 pt.

---

## 3. Game review

Scroll view, one column (portrait), sections in this order. Short labels allowed here (SPEC §2), still no paragraphs.

### Wireframe
```
┌──────────────────────────────────────┐
│ ‹  Game 3                            │  title 34 bold; no share button (clips stay in-app)
│    (A◉◉) 8 – 5 (B◉◉)    winner ring  │  score in SF Pro Rounded 34, winner team avatars lit
│                                      │
│ Win chance                    (22)   │
│  100┤          ╭──╮      ✦           │  line chart, A on top half / B bottom (single line =
│   50┼──╮ ╭────╯  ╰──╮ ╭─╯             │  P(Team A wins)); dot markers on badge shots
│    0┤  ╰─╯           ╰╯               │  scrubbing moves the cursor + timeline together
│                                      │
│ Shots                                 │
│  ◯ ✓ ✓ ? ✦ ✓ ✗ ⊙ ✓ …  →  scrolls     │  timeline: 44pt badge circles, team arc under each
│        ▲ selected                     │
│                                      │
│ ┌──── Replay (shot 5) ──────────────┐ │
│ │ ▢▢▢▢▢▢▢▢ felt ▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢ │ │  static top-down diagram, rails + 6 pockets
│ │  ○ before (40%)  ● after (100%)   │ │  path: solid ink actual, dashed `predict` alt
│ │  ━━ actual  ┄┄ engine's shot      │ │  legend = 2 tiny line samples + 1 word each
│ │  [ Before | After ]  (segmented)  │ │
│ └───────────────────────────────────┘ │
│                                      │
│ ┌──── Shot of the Game ─────────────┐ │
│ │  ▶ (clip placeholder 16:9)        │ │  play.circle.fill 64pt center
│ │  ✦ Brilliant   "Bank Escape"      │ │  ≤2-word label (Highlight.label)
│ │  eval swing ▮▮▮▯ → ▮▯▯▯           │ │  mini eval bars before/after
│ └───────────────────────────────────┘ │
│                                      │
│ ┌──── MVP ──────────────────────────┐ │
│ │  (◉ 80pt)  Sam        crown.fill  │ │
│ │  best shot badge + mini diagram   │ │
│ └───────────────────────────────────┘ │
│                                      │
│ ┌──────────────────────────────────┐ │
│ │            Done                  │ │  56pt
│ └──────────────────────────────────┘ │
└──────────────────────────────────────┘
```
Landscape / iPad width: left column = win chart + timeline + replay; right column = SotG + MVP.

### Hierarchy
1. Result (score + winner) 2. Win chance graph (the story) 3. Timeline + replay (drill-down) 4. SotG 5. MVP.

### Components and tokens
| Component | Spec |
|---|---|
| Header | Team avatar clusters (40 pt, overlapping 12 pt), score SF Pro Rounded 34 bold `ink`. Winner side gets a 3-pt `legal` ring + `crown.fill`; loser at `inkMuted`. |
| Win chance | Swift Charts `LineMark` of `Game.winProbSeries` (x = shot index, y = 0…1). Line 2 pt `ink`; area above 50% tinted Team A @ 18%, below 50% Team B @ 18%. A 50% rule dashed `inkMuted`. No y-axis numbers beyond "50%"; x-axis unlabeled. Shot markers: 6-pt dots in badge color only for brilliant/great/mistake/blunder (max 4 kinds, avoids soup). Scrub with one finger: vertical cursor + selected shot highlights in timeline (`.selection` haptic per shot). Fewer than 4 shots: hide chart, show the two eval bars (start / end) instead (chart lookup: line needs ≥ 4 points). |
| Shot timeline | Horizontal `ScrollView` of 44-pt badge circles (same symbol + color table as §2, symbol 20 pt). 2-pt team arc under each. Selected: 56 pt, 3-pt ring. Book and okay drawn at 60% so the eye skips them. Auto-scrolls to the SotG on open. |
| Replay diagram | Static `Canvas`, top-down, `felt` radial + `rail` frame, 6 pockets as `bg` circles. Balls drawn at real scale (57.15 mm) from `Shot.preState` / `postState`. Before = balls at 40% opacity outline; After = solid. Actual paths: 2 pt `ink` (cue) and 2 pt ball color (object). Engine alternative: dashed 6/6 `predict` with ghost cue ball outline (`aim` 2 pt) — only shown when rating is below best. Pocketed balls: small ring inside the pocket. Fouls: `danger` × at the foul point (scratch pocket / first contact). Before/After segmented control (44 pt). Legend: two 24-pt line samples + "Actual" / "Engine" (13 pt). No numbers, ever. This is a still picture, not a playable table (D20). |
| SotG card | `surface`, radius 20. Clip placeholder 16:9 with `play.circle.fill` 64 pt; no clip yet → `film` 40 pt `inkMuted` on `felt` (placeholder). Row: badge 44 pt + label ≤2 words (17 semibold). Eval swing: two horizontal mini eval bars (before → after) with `arrow.right`. The Brilliant glow, if any, lives here only (Brilliant = SotG, D18). |
| MVP card | `surface`, radius 20. 80-pt avatar + name 22 semibold + `crown.fill`. Below: their best shot badge 44 pt + 120-pt-tall mini replay of that shot. Team games: MVP = highest total WPA; 1v1: winner's best shot (SPEC §9). No WPA number shown. |

### States
- **Loading (stats/highlights computing):** header renders immediately from `Game`; chart, SotG and MVP show `surface` skeleton blocks of their final size (no layout jump), subtle shimmer (Reduce Motion: static 50%).
- **Empty:** game with 0 rated shots (e.g. abandoned after break): show header + one centered `circle.dashed` 64 pt + "No shots" and Done. Missing clip → placeholder as above, card still shown.
- **Error:** a shot whose states fail to decode: its timeline circle is `circle.dashed` and the replay shows "Unavailable" with `exclamationmark.triangle` `caution`; the rest of the screen works.
- **Locked:** game in progress → review opens read-only up to the last shot, SotG and MVP cards show `lock.fill` 24 pt + "After game". Unrated shot: `circle.dashed`, no alt path.

### Gestures
- Tap a timeline badge or chart point → selects that shot, replay updates (crossfade 0.2 s).
- Horizontal swipe on the replay card → previous/next shot. Tap play on SotG → full-screen in-app player.
- Pinch on the replay is off (it is a diagram; keep it calm). Swipe-back from the left edge = system back.

### Accessibility
- Chart: `accessibilityChartDescriptor` (audio graph) + per-shot elements "Shot 5, Sam, Brilliant, Team A win chance up" (direction words only, no %). Rotor over timeline badges.
- Replay: one element, label generated from the shot ("Sam banked the 6 into the corner. Engine preferred the 3 in the side.") — the only sentence on the screen and only for VoiceOver.
- Color-independent: badges differ by symbol; actual vs engine differ by solid vs dashed; teams by solid vs dashed ring.
- Largest Dynamic Type: cards stack, timeline circles stay 44 pt, labels wrap to 2 lines.

---

## Haptics (summary)
`.selection`: drag slot cross, chart scrub step, timeline select. `.impact(.soft)`: lineup drop, vote. `.success`: Brilliant badge, Start. `.error`: blocked Start.

## Open questions for the user (do not guess)
1. **Orange token.** RATING_CLASSES uses orange for Miss and Mistake, but MASTER has no orange token. Proposal: add `warn` = #FB923C to MASTER (between `caution` and `danger`). Until then use #FB923C locally, named `warn`.
2. **Miss label** "Missed chance" is 2 words but long for a 72-pt badge; OK at 13 pt (fits ~110 pt). Keep, or shorten to "Missed"?
3. **Who can reorder lineups** mid-lobby: host only (proposed) or any player for their own team?

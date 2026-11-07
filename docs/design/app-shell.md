# App shell — screen spec (Home → Game / Training → Live → Review)

Problem (user at the real table): after the AR scan nothing says what happens next; there is no place to start a
game together or to switch Training ↔ Game. This shell is the answer. Style: `design-system/cuecoach/MASTER.md`
(dark only, SF Symbols, ≥44 pt targets, ≤2-word labels, one accent at a time). D17 order, D18 badges, D20 camera is
the product (no 2D table), D24 the two modes.

## Navigation graph
```
                 ┌──────────── sheet ───────────┐
                 │  Profile (me)   Settings      │
                 └──────────────▲────────────────┘
                                │ small corner buttons
 ┌──────┐  Game   ┌──────────┐  New game  ┌───────────┐  Start  ┌───────────────┐ End game ┌────────┐
 │ Home │───────▶ │ Game hub │──────────▶ │ New game  │───────▶ │ Live (.game)  │────────▶ │ Review │──Done──▶ Home
 │      │         │          │──Join────▶ │ Join near │─host──▶ │ + InGameChrome│          └────────┘
 │      │         └──────────┘            └───────────┘ starts  └───────────────┘
 │      │ Training ┌──────────────┐ Start ┌─────────────────────────┐  close
 │      │────────▶ │ Drill picker │─────▶ │ Live (.training(level)) │──────▶ back to Drill picker
 └──────┘          └──────────────┘       └─────────────────────────┘
```
- Home → Game hub → New game / Join nearby, and Home → Training are pushes on one `NavigationStack`
  (swipe-back works everywhere before Live).
- Live is a full-screen cover (camera owns the whole screen). Review is a full-screen cover after Live.
- `AppRouter` is the single state machine (unit-tested): `path`, `live`, `review`, `sheet`.
- Live's own ✕ (owned by LiveScreen): in Game = same as End game (→ Review); in Training = back to the picker.

## 1. Home
```
┌───────────────────────────────┐
│                     (👤) (⚙)  │  44-pt circles, inkMuted
│                               │
│   ┌─────────────────────────┐ │
│   │      ◎◎  (2 avatars)    │ │  Game: big tile, team A/B discs
│   │         Game            │ │  22 semibold
│   └─────────────────────────┘ │
│   ┌─────────────────────────┐ │
│   │       ◎ target          │ │  Training: big tile, scope glyph
│   │       Training          │ │
│   └─────────────────────────┘ │
└───────────────────────────────┘
```
Two equal tiles (min 160 pt tall, full width minus 16-pt gutters), one word each. No subtitles.
Landscape / AX5: tiles side by side in landscape; stack and grow with Dynamic Type.

## 2. Game hub
```
┌───────────────────────────────┐
│ ‹                             │
│   ┌─────────────────────────┐ │
│   │   ＋  New game           │ │  host on this phone
│   └─────────────────────────┘ │
│   ┌─────────────────────────┐ │
│   │   ((·))  Join nearby     │ │  another phone is hosting
│   └─────────────────────────┘ │
└───────────────────────────────┘
```

## 3. New game (host)
```
┌───────────────────────────────┐
│ ‹  New game                   │
│ Rules   [ 8 bar ][ 8 WPA ][ 9 ]│  ball glyph tiles; selected = legal ring
│ Format  [ ●  vs ● ][ ●● vs ●● ]│  Singles | Teams (2v2…4v4 stepper when Teams)
│ Order   A1 → B1 → A2 → B2      │  avatar discs in D17 shooting order (preview)
│         [＋] empty seat pulses  │  tap seat → roster sheet (roster players + Guest)
│ Table   [7][8][9]  ◉ LiDAR     │  to-scale silhouettes; LiDAR glyph on the measured one
│ Phones  ▢ ▢ ▢  (joiners live)  │  camera glyph per phone that joined
│                               │
│        (  ▶  Start  )          │  64-pt green; caution shake + .error if invalid
└───────────────────────────────┘
```
- Validation (model): every seat filled, no player twice, team sizes equal, 1…4 per team. Start disabled-looking
  (dim) until valid; a tap on dim Start pulses the first empty seat.
- Seat sheet: on-device roster (persisted `PlayerProfile`, never guests) + "New player" (name, persisted) +
  "Guest" (in memory only, never written to SwiftData, gone when the game ends).
- Table preselected from LiDAR when the calibrator knows it; else Settings' manual size; else 7 ft (D14).
- Hosting starts when this screen appears; joiners appear in "Phones" live; leaving stops hosting.

## 4. Join nearby
```
┌───────────────────────────────┐
│ ‹  Join nearby                │
│  ◌ searching sweep            │
│  ┌──────────────────────────┐ │
│  │ (Sam)  8 bar   ●●○○  ›   │ │  host avatar, rules glyph, seats filled
│  └──────────────────────────┘ │
│  states: searching · list · joining (spinner) · joined (camera glyph + waiting pulse)
│          full (✕ lock) · host left (wifi.slash) · no permission (lock glyph)
└───────────────────────────────┘
```
On joined: "Waiting" + camera glyph: this phone becomes another camera angle. When the host starts, Live
opens in `.game` automatically.

## 5. Training picker
```
┌───────────────────────────────┐
│ ‹  Training                   │
│  ┌────┐┌────┐┌────┐┌────┐      │  8 drills, 2-col grid, glyph + ≤2 words
│  └────┘└────┘└────┘└────┘      │
│  Help   ①  ②  ③  ④            │  4 discs; each shows a tiny line sketch of what is drawn
│                               │  (1 all lines, 2 object→pocket, 3 ghost, 4 nothing)
│        (  ▶  Start  )          │
└───────────────────────────────┘
```
Last drill + level are remembered per phone.

## 6. Live + in-game chrome (Game)
```
┌───────────────────────────────┐
│ (✕ Live)       [coach]  (≡)   │  ✕ = LiveScreen's; ≡ = our menu (Resume / End game)
│ (A●)                    (B○)  │  team discs below the top row: active lit + team ring, other dims
│                               │  no text while aiming; tap the dim disc = "their turn" (one-tap correction, §5.8)
│           camera + AR         │
│          [badge 72 pt]        │  PostShotBadgeView after the balls settle (D18)
└───────────────────────────────┘
```
Training: no team discs; menu only (Resume / Stop).

## 7. Review
`GameReviewView` (screens-b) with this game's shots; Done → Home (path cleared).

## Accessibility & motion
Every control ≥44 pt, labelled for VoiceOver. AX5: tiles grow, rows wrap to columns. Reduce Motion: no pulses
or sweeps, crossfades only. Color always paired with a shape (rings, glyphs).

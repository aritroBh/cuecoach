# CueCoach design system (MASTER)

Generated with ui-ux-pro-max (dials: variance 3, motion 4, density 3), then rewritten for a native iOS,
camera-first app. The web-oriented parts of the tool output (Inter font, light background, GSAP) are replaced.
Page overrides go in `pages/<screen>.md`.

## Principles
1. **The table is the hero.** Camera feed or the felt fills the screen; chrome sits at the edges and recedes.
2. **Show, don't tell.** Lines, rings, glows, arrows and color carry meaning. Labels ≤2 words, only where SPEC allows.
3. **Silent while aiming.** No text, no sound, no badges between "aim starts" and "stroke". Haptics are allowed (no audio).
4. **Calm.** One accent at a time, few elements on screen, generous spacing.

## Color tokens (dark only — the app always runs dark so the camera and felt read correctly)
| Token | Value | Use |
|---|---|---|
| `bg` | #0B0F0E | app background |
| `surface` | #151B19 @ 92% + `.ultraThinMaterial` | sheets, control docks |
| `felt` | #0E5A43 → #0A4433 radial | virtual-table cloth |
| `rail` | #2A1D14 with a #3A2A1E top highlight | wood rails |
| `ink` | #F2F5F3 | primary glyphs/text (≥ 7:1 on bg) |
| `inkMuted` | #F2F5F3 @ 60% | secondary (≥ 3:1) |
| `aim` | #FFFFFF @ 90%, 2 pt | aim line / ghost ball outline |
| `predict` | #FFFFFF @ 45%, dashed 6/6 | object-ball and cue-ball predicted paths |
| `legal` | #4ADE80 | legal-target ring, "good" outcomes |
| `caution` | #FACC15 | inaccuracy / near miss |
| `danger` | #F87171 | foul, blunder, illegal target |
| `brilliant` | #22D3EE | brilliant (cyan glow, the only "special" color) |
| Team A / Team B | #60A5FA / #F59E0B | turn indicator, avatars |
Never put meaning in color alone: pair it with a shape (ring, ×, arrow) for color-blind users.

## Type
SF Pro (system). SF Pro Rounded for numbers on balls and score. Sizes: 34 bold (title), 22 semibold (section),
17 regular (body), 13 semibold (≤2-word badge). Use Dynamic Type; no text below 13 pt. No paragraphs on game screens.

## Shape and spacing
8-pt grid; gutters 16 (portrait) / 24 (landscape); corner radius 20 for sheets, 14 for buttons; circles for every in-game control.
Touch targets ≥ 44 pt, primary in-game controls 56–64 pt. Respect safe areas; nothing under the home indicator.

## Icons
SF Symbols only, one weight per level (`.semibold` for controls). No emoji, no custom pill chips.

## Controls (game screens)
- **Aim:** drag anywhere on the table; the cue rotates around the cue ball. Fine-aim: second finger or slow drag near the cue ball.
- **Spin:** a 64-pt cue-ball disc in a corner dock; tap or drag the dot. Shows only a dot, no numbers.
- **Power:** vertical 5-step bar beside the spin disc; pull down and release to shoot (one gesture, like a stroke).
- **Legality:** soft `legal` ring pulses once on legal targets at the start of the turn, then stays faint.
- **Turn / groups:** an avatar disc per team at the top edge with a solid/stripe/9 glyph; active one is lit, the other dims.
- **Options** (accept table, hand back, re-break, push-out): one bottom sheet with 2–3 large icon+word buttons.

## Post-shot badge
Appears after the balls settle, auto-dismisses in ~1.8 s. A 72-pt circle with an SF Symbol + its rating color + ≤2 words.
brilliant `sparkles` cyan, great `star.fill` green, best `checkmark.seal.fill` green, good `checkmark` ink,
inaccuracy `exclamationmark` yellow, mistake `questionmark` orange, blunder `xmark` red.

## Motion
Springs: `.snappy` (0.25 s) for controls, `.smooth` (0.35 s) for sheets. Ball playback uses the physics trace's own timing.
Badge enters with scale 0.9 → 1 + fade (0.25 s), leaves faster (0.15 s). Honor Reduce Motion: no scale/pulse, crossfade only.
Haptics: `.selection` on spin/power step, `.impact(.soft)` on stroke, `.success`/`.error` notification on make/foul.

## Anti-patterns (reject in review)
Pill clusters, badge soup, gradient text, glassmorphism stacks, walls of small text, numeric advice ("aim 2.3° left"),
any text or sound during aiming, more than one accent glow on screen, emoji icons, tiny hit areas.

## Pre-delivery checklist
- [ ] Screenshot of each screen checked against this file and SPEC "no text while aiming"
- [ ] All targets ≥ 44 pt; safe areas respected portrait + landscape
- [ ] Reduce Motion + largest Dynamic Type checked
- [ ] Color never the only signal; contrast ≥ 4.5:1 for text
- [ ] SF Symbols only, consistent weights
- [ ] ios-design-review pass with zero blocking findings

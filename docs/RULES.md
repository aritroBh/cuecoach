# Rules conventions (draft — awaiting user review)

Full research with rule numbers and sources: `docs/research/rules-notes.md`.
WPA text used: **Rules of Play effective 2026-10-21** (wpapool.com/rules-of-play).

## Bar / slop 8-ball (default) — base: APA league rules
| # | Convention | Pick |
|---|---|---|
| B1 | Calling | Slop counts. Only the 8's pocket is called (auto-inferred, tap to override). |
| B2 | Legal break | ≥4 balls to a rail or ≥1 ball pocketed. Otherwise re-rack, same breaker re-breaks. |
| B3 | Groups from the break | **Table is always open after the break**, whatever was made on it. The first ball legally pocketed on a later shot decides the group. (User, D11) |
| B4 | 8 on the break, no foul | **Win.** |
| B5 | 8 on the break + scratch | **Loss.** |
| B6 | Scratch on the break | Opponent gets ball in hand behind the head string. Pocketed balls stay down. |
| B7/B8 | Other cue-ball fouls (scratch, wrong ball first, no contact, no rail) | Ball in hand anywhere. |
| B9 | Scratch while shooting the 8, 8 not pocketed | **Loss.** |
| B10 | Other foul on the 8 shot, 8 not pocketed | Foul only. |
| B12–B14 | 8 in the wrong pocket, 8 early, 8 + last group ball same shot | **Loss.** |
| B15 | 8 off the table | Loss (break included). |
| B16 | 8 by combo or kiss | Allowed if it drops in the called pocket. |
| B17 | 8 hit first on an open table | Foul. |
| B18 | Ball pocketed on a foul | Stays down and counts for its group's owner. |
| B19 | Object ball off the table | Spotted on the foot spot, no foul. |
| B20/B21 | "Two shots" / 3-foul rule | None. |
| B25 | Who breaks next | Winner breaks. |


## WPA 8-ball — implemented as written
- No call on the break. Call ball + pocket on every other shot (obvious shots are inferred).
- 8 on the break is never a win: breaker spots or re-breaks; with a scratch the opponent chooses.
- 8 hit first on an open table is a foul. Loss: 8 early, wrong pocket, on a foul, off the table, with the last group ball.
- Ball in hand anywhere after a foul (behind head string only after a break scratch). No 3-foul rule (3.13).
- Fouls the camera can't see (double hits, foot on floor…) are out of scope. When a foul can't be determined, the shot is legal (Reg 25).

## WPA 9-ball — implemented as written
- Lowest ball first. 9 legally pocketed (incl. on the break) wins. The 9 is the only ball spotted.
- Push-out on the shot right after the break; opponent picks who shoots next.
- 3 consecutive fouls lose; the on-screen foul count is the required warning (Reg 8).
- **House break rule (user, D13): anti-soft-break ON by default.** Break must pocket a ball or send ≥3 object balls
  (pocketed or past the head string) — WPA 5.3(c)/Reg 16. Illegal break → incoming player accepts the table or hands it back.
- **Exception:** a 9 made on the break **wins even on an otherwise "soft" break** (overrides Reg 16(5)) — unless the
  breaker fouls (scratch etc.): then the 9 is spotted and the opponent gets ball in hand anywhere (WPA 5.3/5.7).
- Combos, caroms, kisses that put the 9 in after legally hitting the lowest ball first win (WPA 5, 5.5).

## Interpretations where WPA is silent (my picks)
1. 4.3(e): after a legal 8-on-break and spot, the breaker keeps shooting.
2. 4.3(h)(1): after a break scratch, "accept the table" means ball in hand behind the head string.
3. 4.7 (no spotting in 8-ball) overrides 1.6 (general spot requests).

# Pro profile sourcing pass (SPEC §8)

Research date 2026-11-06. Output: `pro-profiles-sourced.json` (schema-identical to the JSON in
`ProProfilesData.swift`, `version` bumped to 2). It decodes cleanly through the real `ProProfiles.decode` (ProComp.swift),
compiled standalone. The worktree files were not edited.
Generator: `../build_profiles.py`. Every raw number is in it, next to its thread URL.

## Headline

1. **No public per-shot data exists** for cut, long, side, bank, position, clutch or safety success, for any of
   the 10 pros. Matchroom/WNT, CueScore and FargoRate do not publish shot-type stats. Accu-Stats publishes TPA only
   (a single overall accuracy number), and mostly behind PPV. Those 7 dimensions keep their seed values. Only sources, notes and
   (where two independent sources agree) confidence changed.
2. **Break and run-out data does exist.** It comes from AzBilliards user *AtLarge*, who logs every rack of streamed
   Mosconi Cup, Reyes Cup and big challenge matches. Per player he publishes successful-break %, B&R %, and, for
   challenge matches, **balls made per break**. Balls per break is exactly the `breakPower` definition
   (mean balls per break ÷ 3).
3. **The seed's breakPower and runOut values were off-scale for the definitions in `Archetypes.swift`.** Seed SVB
   `breakPower 0.9` would mean 2.7 balls per break. The measured figure is 1.44 (0.48). Seed `runOut 0.85` would mean 0.85
   run-outs per game. The measured figure is about 0.20. Measured pros cluster at breakPower 0.45–0.53 and runOut 0.15–0.28. **All ten
   pros were moved to that scale**, so the vector distances stay consistent. **This is a product decision. Please confirm it
   before merging.** If the comparison should instead use percentile-style values, the seed scale needs a documented
   mapping. Either way, a user's real vector (computed with the Archetypes.swift formulas) will never come near 0.85 runOut,
   so the seed would have pushed every user toward whichever pro had the lowest run-out/break seeds.

## Method

* **Measured (`estimated: false`)**: breakPower for SVB, Gorst and Shaw. It is break-weighted balls per break from the
  challenge-match threads, divided by 3.
* **runOut, measured lower bound**: (run-outs from the first shot after a break, B&Rs included) ÷ games in the match, for
  SVB, Gorst and Shaw. It excludes mid-game run-outs after safeties and misses, so it stays `estimated: true`.
* **Derived for the other pros**: team-event break stats are pooled per player, then shrunk toward the pool mean with k = 20
  pseudo-breaks (pool: 445/586 successful = 0.759, 164/586 B&R = 0.280). The result is mapped onto the measured scale with
  factors calibrated on the three pros that have both kinds of data:
  * breakPower = 1.94 × shrunk successful-break rate ÷ 3 (calibration factors 1.95 / 1.88 / 1.99)
  * runOut = 0.79 × shrunk B&R rate (calibration factors 0.67 / 0.92 / 0.80)

  All derived values are `estimated: true`, `confidence: low`.
* **Confidence** moved to `medium` only where two independent sources agree (qualitative), or where the measurement covers
  several matches by one compiler (SVB and Gorst breakPower/runOut). Nothing is `high`. Every number traces back to one
  volunteer stats compiler, and the TPA figures are second-hand.
* **TPA caveat**: Accu-Stats TPA = balls made / (balls made + errors). Errors include position, kick, safety and
  break-scratch errors ([Dr. Dave](https://drdavepoolinfo.com/?p=2392)), so TPA is a lower bound on pot %, not pot %.
  It is cited in notes; pot values were not replaced with it.

### Raw break data used (AtLarge, AzBilliards forums)

| Pro | Team events pooled (successful / breaks, B&R / breaks) | Challenge-match balls per break |
|---|---|---|
| Van Boening | 87/118, 35/118 (MC 2018, 20–25; RC 2026) | 1.6 (101 br, 2019 v Shaw), 1.5 (120, 2024 v Gorst), 1.3 (78, 2025 v Gorst), 1.0 (30, 2026 9-ball v Gorst) → 1.44 |
| Gorst | 64/83, 24/83 (MC 2020, 23–25; RC 2025–26) | 1.4 (116, 2024), 1.6 (120, 2025), 1.2 (50, 2026) → 1.45 |
| Shaw | 112/139, 49/139 (MC 2018, 20–25; RC 2024–25) | 1.6 (91, 2019 v SVB) |
| Filler | 63/86, 23/86 (MC 2020–23, 25; RC 2026) | — |
| Sánchez Ruiz | 55/73, 14/73 (MC 2022–24; RC 2024–26) | — |
| Yapp | 21/27, 11/27 (RC 2024–25) | — |
| Biado | 26/35, 5/35 (RC 2024–26) | — |
| Ko Pin-yi | 10/13, 2/13 (RC 2024) | — |
| Strickland | 7/12, 1/12 (MC 2022, age 61) | — |
| Reyes | none found | — |

Thread URLs: MC [2018](https://forums.azbilliards.com/threads/break-stats-2018-mosconi-cup-december-2018.485244/),
[2020](https://forums.azbilliards.com/threads/break-stats-2020-mosconi-cup-december-2020.523249/),
[2021](https://forums.azbilliards.com/threads/break-stats-2021-mosconi-cup-december-2021.537949/),
[2022](https://forums.azbilliards.com/threads/break-stats-2022-mosconi-cup-nov-dec-2022.548763/),
[2023](https://forums.azbilliards.com/threads/break-stats-2023-mosconi-cup-december-2023.559698/),
[2024](https://forums.azbilliards.com/threads/break-stats-2024-mosconi-cup-nov-dec-2024.570801/),
[2025](https://forums.azbilliards.com/goto/post?id=8310700); RC
[2024](https://forums.azbilliards.com/threads/break-stats-2024-reyes-cup-october-2024.569410/),
[2025](https://forums.azbilliards.com/threads/break-stats-2025-reyes-cup-october-2025.581001/),
[2026](https://forums.azbilliards.com/threads/break-stats-2026-reyes-cup-october-2026.590880/); challenge
[SVB–Shaw 2019](https://forums.azbilliards.com/threads/stats-van-boening-vs-shaw-10-ball-race-to-100-august-2019.498355/),
[SVB–Gorst 2024](https://forums.azbilliards.com/threads/stats-shane-van-boening-vs-fedor-gorst-10-ball-race-to-120-august-2024.567611/),
[2025](https://forums.azbilliards.com/threads/stats-shane-van-boening-vs-fedor-gorst-10-ball-race-to-120-june-2025.576819/),
[2026](https://forums.azbilliards.com/threads/stats-shane-van-boening-vs-fedor-gorst-9-ball-race-to-50-july-2026.588438/).
Accu-Stats TPA (2020 Mosconi Cup, relayed by forum user patscue):
[thread](https://forums.azbilliards.com/threads/mosconi-cup-accu-stats-stats.523253/). It lists SVB .899, Shaw .905, Gorst .871, Filler .842.

Transcription caveats: the fetch tool reported "Gorst -- 6 of 13 (48%)" for MC 2025, but 6/13 is 46%. The count (6/13) is what the
generator uses. Mosconi Cup samples are 9–23 breaks per player per year, and AtLarge himself warns they are small.

## Summary: what changed from the seed

| Pro | Measured (est. false) | Sourced, still estimated | Unsourced | Seed traits with a source | Traits ≥ medium confidence |
|---|---|---|---|---|---|
| Efren Reyes | 0 | 5 | 5 | 1 | 2 |
| Shane Van Boening | 1 | 4 | 5 | 2 | 2 |
| Joshua Filler | 0 | 3 | 7 | 0 | 0 |
| Fedor Gorst | 1 | 2 | 7 | 0 | 2 |
| Earl Strickland | 0 | 3 | 7 | 2 | 0 |
| Ko Pin-yi | 0 | 2 | 8 | 0 | 0 |
| Carlo Biado | 0 | 2 | 8 | 0 | 0 |
| Aloysius Yapp | 0 | 2 | 8 | 0 | 0 |
| Jayson Shaw | 1 | 3 | 6 | 1 | 1 |
| Francisco Sánchez Ruiz | 0 | 2 | 8 | 0 | 0 |

Totals: 3 measured, 28 sourced-but-estimated, 69 unsourced of 100 trait values. In the seed: 0 measured, 6 with a source, all low.

* **breakPower**, all 10 changed. Measured 0.48 / 0.48 / 0.53 (SVB / Gorst / Shaw). Others derived at 0.45–0.50. Efren is 0.42
  (unsourced placement).
* **runOut**, all 10 changed. The range is now 0.14 (Efren, unsourced) to 0.28 (Shaw, Yapp). Data contradicts two seed rankings:
  Yapp (seed 0.7) ties Shaw for the top runOut (0.28), from a B&R rate of 11/27. Ko (seed 0.8) and Biado (seed 0.7) are among the lowest,
  but on 13 and 35 breaks only.
* **Confidence raised to medium**: Efren bank (Wikipedia + Billiards Digest + Dr. Dave) and Efren clutch (Billiards
  Digest Z-shot at 12-12 hill-hill + Wikipedia comebacks); Shaw pot (AZBilliards profile + TPA .905); SVB and Gorst breakPower and runOut.
* **Sources added without a confidence change**: Efren safety, position and cut (Dr. Dave); SVB pot and safety; Gorst pot;
  Filler pot (TPA .842 conflicts with the 0.9 seed; flagged, not changed); Shaw position; Strickland clutch.
* **Could not be sourced at all, for any pro**: `cut`, `long`, `side` as rates, `safety` success rate, and `position`
  success rate. `clutch` and `bank` have anecdotes only. Ko, Biado, Yapp and Sánchez Ruiz have **no** qualitative
  style source: their Wikipedia pages describe titles only, and searches found no style analysis. Their non-break dimensions are pure seed estimates.

## Open questions for the user

1. Accept the move of breakPower/runOut to the Archetypes.swift scale (recommended), or keep the seed scale with a documented mapping?
2. Should a pro's profile reflect peak form (Efren and Strickland in the 1990s) or the latest data? Strickland's only data is
   from age 61.
3. Most break data is 10-ball challenge matches plus 9-ball team events. If CueCoach targets 8-ball or 9-ball, break numbers are not
   game-comparable. Should profiles be per game type?

## Per-pro tables

Rows marked ** changed versus the seed. The quote column is the JSON `note` verbatim.

### Efren Reyes (The Magician)

| Dim | Seed | New | Estimated | Confidence | Source | Quote / basis |
|---|---|---|---|---|---|---|
| cut ** | 0.75 | 0.75 | true | low | [link](https://forums.azbilliards.com/threads/top-10-efren-reyes-famous-shots-and-how-to-shoot-them.522020/) | Dr. Dave's top-10 Efren shots include 'thin inside cut for shape' and a '3-rail kick back cut'. This is anecdotal: it shows the shots, not a rate. Value itself is estimated. |
| long | 0.65 | 0.65 | true | low | none | Estimated from general reputation; no published per-shot statistic found. |
| side | 0.75 | 0.75 | true | low | none | Estimated from general reputation; no published per-shot statistic found. |
| clutch ** | 0.85 | 0.85 | true | medium | [link](https://billiardsdigest.com/new_strokeofgenius/jan08index.php) | Two independent sources agree. (1) Billiards Digest: the Z-shot came "With the score tied 12-12 in the race-to-13 final against Earl Strickland". (2) Wikipedia: "Reyes won the match 120–117 despite being 17 racks behind"; in 2004 "He trailed 0–4, but won eight straight racks and won the final 11–8." Value itself is estimated. |
| safety ** | 0.85 | 0.85 | true | low | [link](https://forums.azbilliards.com/threads/top-10-greatest-safeties-of-all-time-by-efren-reyes.523581/) | Dr. Dave (dr_dave), 'Top 10 Greatest Safeties of All Time by Efren Reyes', 2020-12-10: "These safeties are quite advanced and really show off Efren's kicking, carom, and CB control skills." Only one source, so confidence stays low. Value itself is estimated. |
| breakPower ** | 0.4 | 0.42 | true | low | none | Unsourced. No break statistics were found for Reyes. The value sits just below the measured/derived pro range (0.45-0.53), which keeps the seed's view that he is not a power breaker. That view itself is unsourced. |
| runOut ** | 0.5 | 0.14 | true | low | none | Unsourced. No run-out statistics were found for Reyes. The seed ranked him lowest (0.5 vs 0.7-0.9 for the others). That rank is kept by putting him just under the measured/derived pro range (0.15-0.28). |
| bank ** | 0.95 | 0.95 | true | medium | [link](https://en.wikipedia.org/wiki/Efren_Reyes) | Two independent sources agree. (1) Wikipedia: "Reyes' ability to play kick shots led to his gaining the nickname 'Magician'." (2) Billiards Digest [https://billiardsdigest.com/new_strokeofgenius/jan08index.php]: his "two-rail kick shot in the case game of the 1995 Sands Regency XXI final" is "often now described as 'the greatest shot in pool history.'" (3) Dr. Dave's top-10 Efren shots [https://forums.azbilliards.com/threads/top-10-efren-reyes-famous-shots-and-how-to-shoot-them.522020/]: 6 of the 10 are kicks or banks. Value itself is estimated. |
| pot | 0.82 | 0.82 | true | low | none | Estimated from general reputation; no published per-shot statistic found. |
| position ** | 0.85 | 0.85 | true | low | [link](https://forums.azbilliards.com/threads/top-10-greatest-safeties-of-all-time-by-efren-reyes.523581/) | Dr. Dave credits "CB control skills" (safeties video), and his top-10 shots list includes 'hook follow shot for shape', 'jump over obstacle ball for shape' and 'thin inside cut for shape' [https://forums.azbilliards.com/threads/top-10-efren-reyes-famous-shots-and-how-to-shoot-them.522020/]. Both come from the same author, which counts as one source. Value itself is estimated. |

### Shane Van Boening (Captain America)

| Dim | Seed | New | Estimated | Confidence | Source | Quote / basis |
|---|---|---|---|---|---|---|
| cut | 0.75 | 0.75 | true | low | none | Estimated from general reputation; no published per-shot statistic found. |
| long | 0.8 | 0.8 | true | low | none | Estimated from general reputation; no published per-shot statistic found. |
| side | 0.75 | 0.75 | true | low | none | Estimated from general reputation; no published per-shot statistic found. |
| clutch | 0.8 | 0.8 | true | low | none | Estimated from general reputation; no published per-shot statistic found. |
| safety ** | 0.75 | 0.75 | true | low | [link](https://forums.azbilliards.com/threads/stats-van-boening-vs-shaw-10-ball-race-to-100-august-2019.498355/) | No safety success rate was found. AtLarge counts only safeties per game ("by Van Boening only -- 16" in the 2019 race to 100), not whether they succeeded. Value itself is estimated. |
| breakPower ** | 0.9 | 0.48 | false | medium | [link](https://forums.azbilliards.com/threads/stats-van-boening-vs-shaw-10-ball-race-to-100-august-2019.498355/) | Measured: 1.44 balls made per break, break-weighted over 329 breaks in SVBvShaw2019 (1.6 on 101 breaks), SVBvGorst2024 (1.5 on 120 breaks), SVBvGorst2025 (1.3 on 78 breaks), SVBvGorst2026 (1.0 on 30 breaks) [https://forums.azbilliards.com/threads/stats-van-boening-vs-shaw-10-ball-race-to-100-august-2019.498355/; https://forums.azbilliards.com/threads/stats-shane-van-boening-vs-fedor-gorst-10-ball-race-to-120-august-2024.567611/; https://forums.azbilliards.com/threads/stats-shane-van-boening-vs-fedor-gorst-10-ball-race-to-120-june-2025.576819/; https://forums.azbilliards.com/threads/stats-shane-van-boening-vs-fedor-gorst-9-ball-race-to-50-july-2026.588438/]. Value = 1.44/3. AtLarge's counts come from streams, by one compiler; mostly 10-ball challenge matches. |
| runOut ** | 0.85 | 0.2 | true | medium | [link](https://forums.azbilliards.com/threads/stats-van-boening-vs-shaw-10-ball-race-to-100-august-2019.498355/) | Lower bound, measured: 140 run-outs from the first shot after a break (B&Rs included) in 706 games: SVBvShaw2019 52/192, SVBvGorst2024 53/236, SVBvGorst2025 27/198, SVBvGorst2026 8/80. This excludes mid-game run-outs after safeties and misses, so it is kept as estimated: true. |
| bank | 0.8 | 0.8 | true | low | [link](https://en.wikipedia.org/wiki/Shane_Van_Boening) | Wikipedia lists his CSI U.S. Open Bank Pool Championship title; it does not describe his bank style. Value itself is estimated. |
| pot ** | 0.9 | 0.9 | true | low | [link](https://forums.azbilliards.com/threads/mosconi-cup-accu-stats-stats.523253/) | Accu-Stats TPA relayed by forum user patscue, 2020 Mosconi Cup: "SVB: .899". TPA = balls made / (balls made + errors), where errors include misses, position, kick, break-scratch and safety errors [https://drdavepoolinfo.com/?p=2392]. TPA is therefore a lower bound on pot %. Also: an estimated "34 misses in 148 games at the table" vs Shaw in 2019 [https://forums.azbilliards.com/threads/stats-van-boening-vs-shaw-10-ball-race-to-100-august-2019.498355/]. Single-event TPA, so confidence stays low. Value itself is estimated. |
| position | 0.85 | 0.85 | true | low | none | Estimated from general reputation; no published per-shot statistic found. |

### Joshua Filler (The Killer)

| Dim | Seed | New | Estimated | Confidence | Source | Quote / basis |
|---|---|---|---|---|---|---|
| cut | 0.8 | 0.8 | true | low | none | Estimated from general reputation; no published per-shot statistic found. |
| long | 0.85 | 0.85 | true | low | none | Estimated from general reputation; no published per-shot statistic found. |
| side | 0.7 | 0.7 | true | low | none | Estimated from general reputation; no published per-shot statistic found. |
| clutch | 0.85 | 0.85 | true | low | none | Estimated from general reputation; no published per-shot statistic found. |
| safety | 0.75 | 0.75 | true | low | none | Estimated from general reputation; no published per-shot statistic found. |
| breakPower ** | 0.85 | 0.48 | true | low | [link](https://forums.azbilliards.com/threads/break-stats-2020-mosconi-cup-december-2020.523249/) | Derived from team-event break stats: MC2020 7/9 successful, 3/9 B&R; MC2021 12/17 successful, 6/17 B&R; MC2022 11/19 successful, 5/19 B&R; MC2023 9/14 successful, 4/14 B&R; MC2025 12/13 successful, 3/13 B&R; RC2026 12/14 successful, 2/14 B&R (pooled 63/86 successful). Shrunk successful-break rate 0.738 (k=20 toward the pool mean 0.759) x 1.94 balls (calibrated on SVB/Gorst/Shaw, whose balls/break is measured) / 3. Per-player balls per break is not published for these events. |
| runOut ** | 0.8 | 0.21 | true | low | [link](https://forums.azbilliards.com/threads/break-stats-2020-mosconi-cup-december-2020.523249/) | Derived: shrunk B&R rate on all breaks 0.270 (raw 23/86; k=20 toward 0.280) x 0.79 run-outs per game per unit B&R rate, calibrated on SVB/Gorst/Shaw. Events: MC2020 7/9 successful, 3/9 B&R; MC2021 12/17 successful, 6/17 B&R; MC2022 11/19 successful, 5/19 B&R; MC2023 9/14 successful, 4/14 B&R; MC2025 12/13 successful, 3/13 B&R; RC2026 12/14 successful, 2/14 B&R. |
| bank | 0.6 | 0.6 | true | low | none | Estimated from general reputation; no published per-shot statistic found. |
| pot ** | 0.9 | 0.9 | true | low | [link](https://forums.azbilliards.com/threads/mosconi-cup-accu-stats-stats.523253/) | Accu-Stats TPA, 2020 Mosconi Cup: "Filler: .842", the lowest of the 2020 European team. One event, which conflicts with his reputation; the seed value 0.9 is kept, with confidence low. Value itself is estimated. |
| position | 0.8 | 0.8 | true | low | none | Estimated from general reputation; no published per-shot statistic found. |

### Fedor Gorst (The Ghost)

| Dim | Seed | New | Estimated | Confidence | Source | Quote / basis |
|---|---|---|---|---|---|---|
| cut | 0.8 | 0.8 | true | low | none | Estimated from general reputation; no published per-shot statistic found. |
| long | 0.8 | 0.8 | true | low | none | Estimated from general reputation; no published per-shot statistic found. |
| side | 0.75 | 0.75 | true | low | none | Estimated from general reputation; no published per-shot statistic found. |
| clutch | 0.8 | 0.8 | true | low | none | Estimated from general reputation; no published per-shot statistic found. |
| safety | 0.8 | 0.8 | true | low | none | Estimated from general reputation; no published per-shot statistic found. |
| breakPower ** | 0.7 | 0.48 | false | medium | [link](https://forums.azbilliards.com/threads/stats-shane-van-boening-vs-fedor-gorst-10-ball-race-to-120-august-2024.567611/) | Measured: 1.45 balls made per break, break-weighted over 286 breaks in SVBvGorst2024 (1.4 on 116 breaks), SVBvGorst2025 (1.6 on 120 breaks), SVBvGorst2026 (1.2 on 50 breaks) [https://forums.azbilliards.com/threads/stats-shane-van-boening-vs-fedor-gorst-10-ball-race-to-120-august-2024.567611/; https://forums.azbilliards.com/threads/stats-shane-van-boening-vs-fedor-gorst-10-ball-race-to-120-june-2025.576819/; https://forums.azbilliards.com/threads/stats-shane-van-boening-vs-fedor-gorst-9-ball-race-to-50-july-2026.588438/]. Value = 1.45/3. AtLarge's counts come from streams, by one compiler; mostly 10-ball challenge matches. |
| runOut ** | 0.8 | 0.26 | true | medium | [link](https://forums.azbilliards.com/threads/stats-shane-van-boening-vs-fedor-gorst-10-ball-race-to-120-august-2024.567611/) | Lower bound, measured: 136 run-outs from the first shot after a break (B&Rs included) in 514 games: SVBvGorst2024 54/236, SVBvGorst2025 60/198, SVBvGorst2026 22/80. This excludes mid-game run-outs after safeties and misses, so it is kept as estimated: true. |
| bank | 0.6 | 0.6 | true | low | none | Estimated from general reputation; no published per-shot statistic found. |
| pot ** | 0.9 | 0.9 | true | low | [link](https://forums.azbilliards.com/threads/mosconi-cup-accu-stats-stats.523253/) | Accu-Stats TPA, 2020 Mosconi Cup: "Gorst: .871" (one event). Fewer estimated misses than SVB in their 2025 race to 120: "47 in 177 games at the table (1 per 3.8)" vs SVB "1 per 3.2" [https://forums.azbilliards.com/threads/stats-shane-van-boening-vs-fedor-gorst-10-ball-race-to-120-june-2025.576819/]. Value itself is estimated. |
| position | 0.85 | 0.85 | true | low | none | Estimated from general reputation; no published per-shot statistic found. |

### Earl Strickland (Earl the Pearl)

| Dim | Seed | New | Estimated | Confidence | Source | Quote / basis |
|---|---|---|---|---|---|---|
| cut | 0.8 | 0.8 | true | low | none | Estimated from general reputation; no published per-shot statistic found. |
| long | 0.8 | 0.8 | true | low | none | Estimated from general reputation; no published per-shot statistic found. |
| side | 0.7 | 0.7 | true | low | none | Estimated from general reputation; no published per-shot statistic found. |
| clutch ** | 0.75 | 0.75 | true | low | [link](https://en.wikipedia.org/wiki/Earl_Strickland) | Wikipedia: he "trailed 13-15 but won the last four racks to claim a 17–15 victory"; he won the 1996 PCA $1,000,000 challenge by running 10+ racks. Only one source. Value itself is estimated. |
| safety | 0.6 | 0.6 | true | low | none | Estimated from general reputation; no published per-shot statistic found. |
| breakPower ** | 0.9 | 0.45 | true | low | [link](https://forums.azbilliards.com/threads/break-stats-2022-mosconi-cup-nov-dec-2022.548763/) | Derived from team-event break stats: MC2022 7/12 successful, 1/12 B&R (pooled 7/12 successful). Shrunk successful-break rate 0.693 (k=20 toward the pool mean 0.759) x 1.94 balls (calibrated on SVB/Gorst/Shaw, whose balls/break is measured) / 3. Per-player balls per break is not published for these events. The only sample is 12 breaks at the 2022 Mosconi Cup (age 61); prime-era data not found. Wikipedia's 1996 PCA account ("made nine-on-the-breaks and early nines") shows strong prime breaking, but it is anecdotal. |
| runOut ** | 0.85 | 0.16 | true | low | [link](https://forums.azbilliards.com/threads/break-stats-2022-mosconi-cup-nov-dec-2022.548763/) | Derived: shrunk B&R rate on all breaks 0.206 (raw 1/12; k=20 toward 0.280) x 0.79 run-outs per game per unit B&R rate, calibrated on SVB/Gorst/Shaw. Events: MC2022 7/12 successful, 1/12 B&R. Late-career sample only. Prime-era evidence (Wikipedia): ran "11 consecutive racks" at the 1996 PCA event, "the first player to run 10 consecutive racks in a tournament". |
| bank | 0.55 | 0.55 | true | low | none | Estimated from general reputation; no published per-shot statistic found. |
| pot | 0.9 | 0.9 | true | low | none | Estimated from general reputation; no published per-shot statistic found. |
| position | 0.8 | 0.8 | true | low | none | Estimated from general reputation; no published per-shot statistic found. |

### Ko Pin-yi (Prince of Pool)

| Dim | Seed | New | Estimated | Confidence | Source | Quote / basis |
|---|---|---|---|---|---|---|
| cut | 0.8 | 0.8 | true | low | none | Estimated from general reputation; no published per-shot statistic found. |
| long | 0.8 | 0.8 | true | low | none | Estimated from general reputation; no published per-shot statistic found. |
| side | 0.75 | 0.75 | true | low | none | Estimated from general reputation; no published per-shot statistic found. |
| clutch | 0.8 | 0.8 | true | low | none | Estimated from general reputation; no published per-shot statistic found. |
| safety | 0.7 | 0.7 | true | low | none | Estimated from general reputation; no published per-shot statistic found. |
| breakPower ** | 0.8 | 0.49 | true | low | [link](https://forums.azbilliards.com/threads/break-stats-2024-reyes-cup-october-2024.569410/) | Derived from team-event break stats: RC2024 10/13 successful, 2/13 B&R (pooled 10/13 successful). Shrunk successful-break rate 0.763 (k=20 toward the pool mean 0.759) x 1.94 balls (calibrated on SVB/Gorst/Shaw, whose balls/break is measured) / 3. Per-player balls per break is not published for these events. |
| runOut ** | 0.8 | 0.18 | true | low | [link](https://forums.azbilliards.com/threads/break-stats-2024-reyes-cup-october-2024.569410/) | Derived: shrunk B&R rate on all breaks 0.230 (raw 2/13; k=20 toward 0.280) x 0.79 run-outs per game per unit B&R rate, calibrated on SVB/Gorst/Shaw. Events: RC2024 10/13 successful, 2/13 B&R. |
| bank | 0.6 | 0.6 | true | low | none | Estimated from general reputation; no published per-shot statistic found. |
| pot | 0.9 | 0.9 | true | low | none | Estimated from general reputation; no published per-shot statistic found. |
| position | 0.85 | 0.85 | true | low | none | Estimated from general reputation; no published per-shot statistic found. |

### Carlo Biado (The Black Tiger)

| Dim | Seed | New | Estimated | Confidence | Source | Quote / basis |
|---|---|---|---|---|---|---|
| cut | 0.8 | 0.8 | true | low | none | Estimated from general reputation; no published per-shot statistic found. |
| long | 0.85 | 0.85 | true | low | none | Estimated from general reputation; no published per-shot statistic found. |
| side | 0.75 | 0.75 | true | low | none | Estimated from general reputation; no published per-shot statistic found. |
| clutch | 0.85 | 0.85 | true | low | none | Estimated from general reputation; no published per-shot statistic found. |
| safety | 0.75 | 0.75 | true | low | none | Estimated from general reputation; no published per-shot statistic found. |
| breakPower ** | 0.7 | 0.48 | true | low | [link](https://forums.azbilliards.com/threads/break-stats-2024-reyes-cup-october-2024.569410/) | Derived from team-event break stats: RC2024 12/14 successful, 2/14 B&R; RC2025 4/9 successful, 1/9 B&R; RC2026 10/12 successful, 2/12 B&R (pooled 26/35 successful). Shrunk successful-break rate 0.749 (k=20 toward the pool mean 0.759) x 1.94 balls (calibrated on SVB/Gorst/Shaw, whose balls/break is measured) / 3. Per-player balls per break is not published for these events. |
| runOut ** | 0.7 | 0.15 | true | low | [link](https://forums.azbilliards.com/threads/break-stats-2024-reyes-cup-october-2024.569410/) | Derived: shrunk B&R rate on all breaks 0.193 (raw 5/35; k=20 toward 0.280) x 0.79 run-outs per game per unit B&R rate, calibrated on SVB/Gorst/Shaw. Events: RC2024 12/14 successful, 2/14 B&R; RC2025 4/9 successful, 1/9 B&R; RC2026 10/12 successful, 2/12 B&R. |
| bank | 0.65 | 0.65 | true | low | none | Estimated from general reputation; no published per-shot statistic found. |
| pot | 0.88 | 0.88 | true | low | none | Estimated from general reputation; no published per-shot statistic found. |
| position | 0.8 | 0.8 | true | low | none | Estimated from general reputation; no published per-shot statistic found. |

### Aloysius Yapp (Majin Buu)

| Dim | Seed | New | Estimated | Confidence | Source | Quote / basis |
|---|---|---|---|---|---|---|
| cut | 0.75 | 0.75 | true | low | none | Estimated from general reputation; no published per-shot statistic found. |
| long | 0.8 | 0.8 | true | low | none | Estimated from general reputation; no published per-shot statistic found. |
| side | 0.7 | 0.7 | true | low | none | Estimated from general reputation; no published per-shot statistic found. |
| clutch | 0.8 | 0.8 | true | low | none | Estimated from general reputation; no published per-shot statistic found. |
| safety | 0.8 | 0.8 | true | low | none | Estimated from general reputation; no published per-shot statistic found. |
| breakPower ** | 0.7 | 0.5 | true | low | [link](https://forums.azbilliards.com/threads/break-stats-2024-reyes-cup-october-2024.569410/) | Derived from team-event break stats: RC2024 11/15 successful, 6/15 B&R; RC2025 10/12 successful, 5/12 B&R (pooled 21/27 successful). Shrunk successful-break rate 0.770 (k=20 toward the pool mean 0.759) x 1.94 balls (calibrated on SVB/Gorst/Shaw, whose balls/break is measured) / 3. Per-player balls per break is not published for these events. |
| runOut ** | 0.7 | 0.28 | true | low | [link](https://forums.azbilliards.com/threads/break-stats-2024-reyes-cup-october-2024.569410/) | Derived: shrunk B&R rate on all breaks 0.353 (raw 11/27; k=20 toward 0.280) x 0.79 run-outs per game per unit B&R rate, calibrated on SVB/Gorst/Shaw. Events: RC2024 11/15 successful, 6/15 B&R; RC2025 10/12 successful, 5/12 B&R. |
| bank | 0.6 | 0.6 | true | low | none | Estimated from general reputation; no published per-shot statistic found. |
| pot | 0.88 | 0.88 | true | low | none | Estimated from general reputation; no published per-shot statistic found. |
| position | 0.85 | 0.85 | true | low | none | Estimated from general reputation; no published per-shot statistic found. |

### Jayson Shaw (Eagle Eye)

| Dim | Seed | New | Estimated | Confidence | Source | Quote / basis |
|---|---|---|---|---|---|---|
| cut | 0.8 | 0.8 | true | low | none | Estimated from general reputation; no published per-shot statistic found. |
| long | 0.85 | 0.85 | true | low | none | Estimated from general reputation; no published per-shot statistic found. |
| side | 0.75 | 0.75 | true | low | none | Estimated from general reputation; no published per-shot statistic found. |
| clutch | 0.75 | 0.75 | true | low | none | Estimated from general reputation; no published per-shot statistic found. |
| safety | 0.65 | 0.65 | true | low | none | Estimated from general reputation; no published per-shot statistic found. |
| breakPower ** | 0.8 | 0.53 | false | low | [link](https://forums.azbilliards.com/threads/stats-van-boening-vs-shaw-10-ball-race-to-100-august-2019.498355/) | Measured: 1.60 balls made per break, break-weighted over 91 breaks in SVBvShaw2019 (1.6 on 91 breaks) [https://forums.azbilliards.com/threads/stats-van-boening-vs-shaw-10-ball-race-to-100-august-2019.498355/]. Value = 1.60/3. AtLarge's counts come from streams, by one compiler; mostly 10-ball challenge matches. |
| runOut ** | 0.9 | 0.28 | true | low | [link](https://forums.azbilliards.com/threads/stats-van-boening-vs-shaw-10-ball-race-to-100-august-2019.498355/) | Lower bound, measured: 54 run-outs from the first shot after a break (B&Rs included) in 192 games: SVBvShaw2019 54/192. This excludes mid-game run-outs after safeties and misses, so it is kept as estimated: true. |
| bank | 0.6 | 0.6 | true | low | none | Estimated from general reputation; no published per-shot statistic found. |
| pot ** | 0.92 | 0.92 | true | medium | [link](https://azbilliards.com/?p=222343) | Two independent sources agree. (1) AZBilliards, Frank Lance, 2023-07-19: "He has an uncanny ability to identify and make shots that many other players would gloss over"; "He can also shoot with unmatched precision." (2) Accu-Stats TPA, 2020 Mosconi Cup: "Shaw: .905", 2nd highest of all 10 players [https://forums.azbilliards.com/threads/mosconi-cup-accu-stats-stats.523253/]. Value itself is estimated. |
| position ** | 0.9 | 0.9 | true | low | [link](https://en.wikipedia.org/wiki/Jayson_Shaw) | Wikipedia: 14.1 world high-run record (714 in 2022, then 832 in 2025, per the seed). Long straight-pool runs need sustained position play, but that is an inference. Value itself is estimated. |

### Francisco Sánchez Ruiz (The Ferrari)

| Dim | Seed | New | Estimated | Confidence | Source | Quote / basis |
|---|---|---|---|---|---|---|
| cut | 0.8 | 0.8 | true | low | none | Estimated from general reputation; no published per-shot statistic found. |
| long | 0.8 | 0.8 | true | low | none | Estimated from general reputation; no published per-shot statistic found. |
| side | 0.75 | 0.75 | true | low | none | Estimated from general reputation; no published per-shot statistic found. |
| clutch | 0.8 | 0.8 | true | low | none | Estimated from general reputation; no published per-shot statistic found. |
| safety | 0.75 | 0.75 | true | low | none | Estimated from general reputation; no published per-shot statistic found. |
| breakPower ** | 0.75 | 0.49 | true | low | [link](https://forums.azbilliards.com/threads/break-stats-2022-mosconi-cup-nov-dec-2022.548763/) | Derived from team-event break stats: MC2022 5/11 successful, 1/11 B&R; MC2023 7/11 successful, 2/11 B&R; MC2024 13/14 successful, 5/14 B&R; RC2024 12/15 successful, 4/15 B&R; RC2025 8/10 successful, 0/10 B&R; RC2026 10/12 successful, 2/12 B&R (pooled 55/73 successful). Shrunk successful-break rate 0.755 (k=20 toward the pool mean 0.759) x 1.94 balls (calibrated on SVB/Gorst/Shaw, whose balls/break is measured) / 3. Per-player balls per break is not published for these events. |
| runOut ** | 0.75 | 0.17 | true | low | [link](https://forums.azbilliards.com/threads/break-stats-2022-mosconi-cup-nov-dec-2022.548763/) | Derived: shrunk B&R rate on all breaks 0.211 (raw 14/73; k=20 toward 0.280) x 0.79 run-outs per game per unit B&R rate, calibrated on SVB/Gorst/Shaw. Events: MC2022 5/11 successful, 1/11 B&R; MC2023 7/11 successful, 2/11 B&R; MC2024 13/14 successful, 5/14 B&R; RC2024 12/15 successful, 4/15 B&R; RC2025 8/10 successful, 0/10 B&R; RC2026 10/12 successful, 2/12 B&R. |
| bank | 0.6 | 0.6 | true | low | none | Estimated from general reputation; no published per-shot statistic found. |
| pot | 0.9 | 0.9 | true | low | none | Estimated from general reputation; no published per-shot statistic found. |
| position | 0.85 | 0.85 | true | low | none | Estimated from general reputation; no published per-shot statistic found. |

## Video pipeline options

Goal: derive aggregate per-shot stats (cut / long / side / bank / position / safety) from match footage at dev time.
No video was downloaded in this pass. The quotes below were read from the live terms pages on 2026-11-06. This is not legal
advice, and fair-use or text-and-data-mining exceptions vary by country and were not assessed.

### Permitted

| Source | Why it is usable | Terms citation |
|---|---|---|
| **Footage the user records themselves** (own matches, friends' matches, local venue) | The user owns the copyright. Needs consent from the people filmed (CLAUDE.md: no personal footage in the public repo), plus the venue's permission. Not possible at Matchroom/WNT events (next row). This is the only source with no third-party licence in the way. | n/a |
| **Pro footage under written licence** from the rights holder (Accu-Stats Video Productions, Matchroom Multi Sport / WNT) | Every pro-footage source below has a "prior written consent/permission" exception. The path is to ask. | Accu-Stats FAQ and YouTube ToS, quoted below |
| **Manual stat-logging while watching** (what AtLarge does: a human watches a legitimate stream and records shot outcomes, with no copying, capture or download) | YouTube allows viewing "for your personal, non-commercial use". No content is reproduced. Whether facts logged from a stream can be used commercially is a legal question I have not verified. | [YouTube ToS](https://www.youtube.com/static?template=terms) |

### Prohibited without permission

| Source | Restriction (verbatim) | Terms page |
|---|---|---|
| **YouTube** (incl. official Matchroom / WNT / Accu-Stats channels) | "You may view or listen to Content for your personal, non-commercial use." You are not allowed to "access, reproduce, download, distribute, transmit, broadcast, display, sell, license, alter, modify or otherwise use any part of the Service or any Content except: (a) as expressly authorized by the Service; or (b) with prior written permission from YouTube and, if applicable, the respective rights holders". Also no access "using any automated means (such as robots, botnets or scrapers)". Effective December 15, 2023. | [youtube.com/static?template=terms](https://www.youtube.com/static?template=terms) |
| YouTube **CC BY** videos | CC BY lets "other creators ... reuse your work subject to the terms of the CC BY license". The help page frames this as reuse inside YouTube's editing tools. I found no clause authorizing a download, so the ToS download restriction still applies. Grey area: treat as not permitted unless the uploader supplies the file. | [YouTube Help 2797468](https://support.google.com/youtube/answer/2797468?hl=en) |
| **X / Twitter** | "NOTE: crawling or scraping the Services in any form, for any purpose without our prior written consent is expressly prohibited"; and "you cannot scrape the Services without X's express written permission". Effective October 9, 2026. | [x.com/en/tos](https://x.com/en/tos) |
| **Accu-Stats** (PPV, Vimeo VOD, DVDs) | "All content is the exclusive copyrighted property of Accu-Stats Video Productions and may NOT be copied, reproduced, posted online, Facebook Live, or otherwise conveyed in any manner without the express prior written consent of Accu-Stats Video Productions." | [accu-stats.com/faq](https://www.accu-stats.com/faq) |
| **Matchroom / World Nineball Tour** (WNT TV, Mosconi Cup, Reyes Cup, World Championship) | Site footer: "© 2024 Matchroom Multi Sport Ltd all rights reserved". Event T&Cs: "The unauthorised use of cameras, video or sound recording equipment is prohibited at the event and such items may be confiscated." I could not find the WNT TV subscriber terms (wnttv.com returned no content), so the licence terms for streams are **unverified**. Treat them as all-rights-reserved. | [worldnineballtour.com/terms-conditions](https://worldnineballtour.com/terms-conditions/) |

### Not checked

CueScore (live-scoring streams), Facebook-hosted streams and Kozoom were not reviewed in this pass.
FargoRate publishes ratings only, not footage.

### Recommendation

The only clean dev-time corpus is **self-recorded footage**, with consent forms. Pro footage requires a written licence. A short
email to Accu-Stats (`livestream@accu-stats.com` is the address on their FAQ) or to Matchroom (`wnttvsupport@matchroom.com`, as quoted in a search summary of
the [WNT TV launch FAQ](https://matchroompool.com/news/wnt-tv-all-you-need-to-know); the page itself was not fetched) asking about dev-time analysis use is the only path to pro per-shot data. Until then, the per-shot dimensions in the pro
profiles stay `estimated: true`.

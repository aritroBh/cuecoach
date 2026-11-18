// Generated seed data — the bundled ProProfiles.json (SPEC §8), embedded as a string so the Stats target
// needs no SwiftPM resource bundle. Validated by ProProfiles.decode and ProProfilesDataTests.

let proProfilesJSON = #"""
{
  "version": 2,
  "note": "Pro profiles v2 (SPEC §8), research pass 2026-11-06. breakPower and runOut are now on the Archetypes.swift scale: breakPower = mean balls per break / 3, runOut = (run-outs + B&Rs) per game. Measured values come from AtLarge's shot-by-shot stats threads on AzBilliards forums, compiled from streams. Shrunk/calibrated estimates are documented per trait. Other dimensions keep their seed values: no public per-shot data exists for cut/long/side/bank/position/clutch, so only sources and confidence changed there. See pro-stats.md.",
  "profiles": [
    {
      "id": "efren-reyes",
      "name": "Efren Reyes",
      "nickname": "The Magician",
      "profileSource": "https://en.wikipedia.org/wiki/Efren_Reyes",
      "traits": {
        "cut": {
          "value": 0.75,
          "estimated": true,
          "confidence": "low",
          "note": "Dr. Dave's top-10 Efren shots include 'thin inside cut for shape' and a '3-rail kick back cut'. This is anecdotal: it shows the shots, not a rate. Value itself is estimated.",
          "source": "https://forums.azbilliards.com/threads/top-10-efren-reyes-famous-shots-and-how-to-shoot-them.522020/"
        },
        "long": {
          "value": 0.65,
          "estimated": true,
          "confidence": "low",
          "note": "Estimated from general reputation; no published per-shot statistic found."
        },
        "side": {
          "value": 0.75,
          "estimated": true,
          "confidence": "low",
          "note": "Estimated from general reputation; no published per-shot statistic found."
        },
        "clutch": {
          "value": 0.85,
          "estimated": true,
          "confidence": "medium",
          "note": "Two independent sources agree. (1) Billiards Digest: the Z-shot came \"With the score tied 12-12 in the race-to-13 final against Earl Strickland\". (2) Wikipedia: \"Reyes won the match 120–117 despite being 17 racks behind\"; in 2004 \"He trailed 0–4, but won eight straight racks and won the final 11–8.\" Value itself is estimated.",
          "source": "https://billiardsdigest.com/new_strokeofgenius/jan08index.php"
        },
        "safety": {
          "value": 0.85,
          "estimated": true,
          "confidence": "low",
          "note": "Dr. Dave (dr_dave), 'Top 10 Greatest Safeties of All Time by Efren Reyes', 2020-12-10: \"These safeties are quite advanced and really show off Efren's kicking, carom, and CB control skills.\" Only one source, so confidence stays low. Value itself is estimated.",
          "source": "https://forums.azbilliards.com/threads/top-10-greatest-safeties-of-all-time-by-efren-reyes.523581/"
        },
        "breakPower": {
          "value": 0.42,
          "estimated": true,
          "confidence": "low",
          "note": "Unsourced. No break statistics were found for Reyes. The value sits just below the measured/derived pro range (0.45-0.53), which keeps the seed's view that he is not a power breaker. That view itself is unsourced."
        },
        "runOut": {
          "value": 0.14,
          "estimated": true,
          "confidence": "low",
          "note": "Unsourced. No run-out statistics were found for Reyes. The seed ranked him lowest (0.5 vs 0.7-0.9 for the others). That rank is kept by putting him just under the measured/derived pro range (0.15-0.28)."
        },
        "bank": {
          "value": 0.95,
          "estimated": true,
          "confidence": "medium",
          "source": "https://en.wikipedia.org/wiki/Efren_Reyes",
          "note": "Two independent sources agree. (1) Wikipedia: \"Reyes' ability to play kick shots led to his gaining the nickname 'Magician'.\" (2) Billiards Digest [https://billiardsdigest.com/new_strokeofgenius/jan08index.php]: his \"two-rail kick shot in the case game of the 1995 Sands Regency XXI final\" is \"often now described as 'the greatest shot in pool history.'\" (3) Dr. Dave's top-10 Efren shots [https://forums.azbilliards.com/threads/top-10-efren-reyes-famous-shots-and-how-to-shoot-them.522020/]: 6 of the 10 are kicks or banks. Value itself is estimated."
        },
        "pot": {
          "value": 0.82,
          "estimated": true,
          "confidence": "low",
          "note": "Estimated from general reputation; no published per-shot statistic found."
        },
        "position": {
          "value": 0.85,
          "estimated": true,
          "confidence": "low",
          "note": "Dr. Dave credits \"CB control skills\" (safeties video), and his top-10 shots list includes 'hook follow shot for shape', 'jump over obstacle ball for shape' and 'thin inside cut for shape' [https://forums.azbilliards.com/threads/top-10-efren-reyes-famous-shots-and-how-to-shoot-them.522020/]. Both come from the same author, which counts as one source. Value itself is estimated.",
          "source": "https://forums.azbilliards.com/threads/top-10-greatest-safeties-of-all-time-by-efren-reyes.523581/"
        }
      }
    },
    {
      "id": "shane-van-boening",
      "name": "Shane Van Boening",
      "nickname": "Captain America",
      "profileSource": "https://en.wikipedia.org/wiki/Shane_Van_Boening",
      "traits": {
        "cut": {
          "value": 0.75,
          "estimated": true,
          "confidence": "low",
          "note": "Estimated from general reputation; no published per-shot statistic found."
        },
        "long": {
          "value": 0.8,
          "estimated": true,
          "confidence": "low",
          "note": "Estimated from general reputation; no published per-shot statistic found."
        },
        "side": {
          "value": 0.75,
          "estimated": true,
          "confidence": "low",
          "note": "Estimated from general reputation; no published per-shot statistic found."
        },
        "clutch": {
          "value": 0.8,
          "estimated": true,
          "confidence": "low",
          "note": "Estimated from general reputation; no published per-shot statistic found."
        },
        "safety": {
          "value": 0.75,
          "estimated": true,
          "confidence": "low",
          "note": "No safety success rate was found. AtLarge counts only safeties per game (\"by Van Boening only -- 16\" in the 2019 race to 100), not whether they succeeded. Value itself is estimated.",
          "source": "https://forums.azbilliards.com/threads/stats-van-boening-vs-shaw-10-ball-race-to-100-august-2019.498355/"
        },
        "breakPower": {
          "value": 0.48,
          "estimated": false,
          "confidence": "medium",
          "source": "https://forums.azbilliards.com/threads/stats-van-boening-vs-shaw-10-ball-race-to-100-august-2019.498355/",
          "note": "Measured: 1.44 balls made per break, break-weighted over 329 breaks in SVBvShaw2019 (1.6 on 101 breaks), SVBvGorst2024 (1.5 on 120 breaks), SVBvGorst2025 (1.3 on 78 breaks), SVBvGorst2026 (1.0 on 30 breaks) [https://forums.azbilliards.com/threads/stats-van-boening-vs-shaw-10-ball-race-to-100-august-2019.498355/; https://forums.azbilliards.com/threads/stats-shane-van-boening-vs-fedor-gorst-10-ball-race-to-120-august-2024.567611/; https://forums.azbilliards.com/threads/stats-shane-van-boening-vs-fedor-gorst-10-ball-race-to-120-june-2025.576819/; https://forums.azbilliards.com/threads/stats-shane-van-boening-vs-fedor-gorst-9-ball-race-to-50-july-2026.588438/]. Value = 1.44/3. AtLarge's counts come from streams, by one compiler; mostly 10-ball challenge matches."
        },
        "runOut": {
          "value": 0.2,
          "estimated": true,
          "confidence": "medium",
          "source": "https://forums.azbilliards.com/threads/stats-van-boening-vs-shaw-10-ball-race-to-100-august-2019.498355/",
          "note": "Lower bound, measured: 140 run-outs from the first shot after a break (B&Rs included) in 706 games: SVBvShaw2019 52/192, SVBvGorst2024 53/236, SVBvGorst2025 27/198, SVBvGorst2026 8/80. This excludes mid-game run-outs after safeties and misses, so it is kept as estimated: true."
        },
        "bank": {
          "value": 0.8,
          "estimated": true,
          "confidence": "low",
          "source": "https://en.wikipedia.org/wiki/Shane_Van_Boening",
          "note": "Wikipedia lists his CSI U.S. Open Bank Pool Championship title; it does not describe his bank style. Value itself is estimated."
        },
        "pot": {
          "value": 0.9,
          "estimated": true,
          "confidence": "low",
          "note": "Accu-Stats TPA relayed by forum user patscue, 2020 Mosconi Cup: \"SVB: .899\". TPA = balls made / (balls made + errors), where errors include misses, position, kick, break-scratch and safety errors [https://drdavepoolinfo.com/?p=2392]. TPA is therefore a lower bound on pot %. Also: an estimated \"34 misses in 148 games at the table\" vs Shaw in 2019 [https://forums.azbilliards.com/threads/stats-van-boening-vs-shaw-10-ball-race-to-100-august-2019.498355/]. Single-event TPA, so confidence stays low. Value itself is estimated.",
          "source": "https://forums.azbilliards.com/threads/mosconi-cup-accu-stats-stats.523253/"
        },
        "position": {
          "value": 0.85,
          "estimated": true,
          "confidence": "low",
          "note": "Estimated from general reputation; no published per-shot statistic found."
        }
      }
    },
    {
      "id": "joshua-filler",
      "name": "Joshua Filler",
      "nickname": "The Killer",
      "profileSource": "https://en.wikipedia.org/wiki/Joshua_Filler",
      "traits": {
        "cut": {
          "value": 0.8,
          "estimated": true,
          "confidence": "low",
          "note": "Estimated from general reputation; no published per-shot statistic found."
        },
        "long": {
          "value": 0.85,
          "estimated": true,
          "confidence": "low",
          "note": "Estimated from general reputation; no published per-shot statistic found."
        },
        "side": {
          "value": 0.7,
          "estimated": true,
          "confidence": "low",
          "note": "Estimated from general reputation; no published per-shot statistic found."
        },
        "clutch": {
          "value": 0.85,
          "estimated": true,
          "confidence": "low",
          "note": "Estimated from general reputation; no published per-shot statistic found."
        },
        "safety": {
          "value": 0.75,
          "estimated": true,
          "confidence": "low",
          "note": "Estimated from general reputation; no published per-shot statistic found."
        },
        "breakPower": {
          "value": 0.48,
          "estimated": true,
          "confidence": "low",
          "source": "https://forums.azbilliards.com/threads/break-stats-2020-mosconi-cup-december-2020.523249/",
          "note": "Derived from team-event break stats: MC2020 7/9 successful, 3/9 B&R; MC2021 12/17 successful, 6/17 B&R; MC2022 11/19 successful, 5/19 B&R; MC2023 9/14 successful, 4/14 B&R; MC2025 12/13 successful, 3/13 B&R; RC2026 12/14 successful, 2/14 B&R (pooled 63/86 successful). Shrunk successful-break rate 0.738 (k=20 toward the pool mean 0.759) x 1.94 balls (calibrated on SVB/Gorst/Shaw, whose balls/break is measured) / 3. Per-player balls per break is not published for these events."
        },
        "runOut": {
          "value": 0.21,
          "estimated": true,
          "confidence": "low",
          "source": "https://forums.azbilliards.com/threads/break-stats-2020-mosconi-cup-december-2020.523249/",
          "note": "Derived: shrunk B&R rate on all breaks 0.270 (raw 23/86; k=20 toward 0.280) x 0.79 run-outs per game per unit B&R rate, calibrated on SVB/Gorst/Shaw. Events: MC2020 7/9 successful, 3/9 B&R; MC2021 12/17 successful, 6/17 B&R; MC2022 11/19 successful, 5/19 B&R; MC2023 9/14 successful, 4/14 B&R; MC2025 12/13 successful, 3/13 B&R; RC2026 12/14 successful, 2/14 B&R."
        },
        "bank": {
          "value": 0.6,
          "estimated": true,
          "confidence": "low",
          "note": "Estimated from general reputation; no published per-shot statistic found."
        },
        "pot": {
          "value": 0.9,
          "estimated": true,
          "confidence": "low",
          "note": "Accu-Stats TPA, 2020 Mosconi Cup: \"Filler: .842\", the lowest of the 2020 European team. One event, which conflicts with his reputation; the seed value 0.9 is kept, with confidence low. Value itself is estimated.",
          "source": "https://forums.azbilliards.com/threads/mosconi-cup-accu-stats-stats.523253/"
        },
        "position": {
          "value": 0.8,
          "estimated": true,
          "confidence": "low",
          "note": "Estimated from general reputation; no published per-shot statistic found."
        }
      }
    },
    {
      "id": "fedor-gorst",
      "name": "Fedor Gorst",
      "nickname": "The Ghost",
      "profileSource": "https://en.wikipedia.org/wiki/Fedor_Gorst",
      "traits": {
        "cut": {
          "value": 0.8,
          "estimated": true,
          "confidence": "low",
          "note": "Estimated from general reputation; no published per-shot statistic found."
        },
        "long": {
          "value": 0.8,
          "estimated": true,
          "confidence": "low",
          "note": "Estimated from general reputation; no published per-shot statistic found."
        },
        "side": {
          "value": 0.75,
          "estimated": true,
          "confidence": "low",
          "note": "Estimated from general reputation; no published per-shot statistic found."
        },
        "clutch": {
          "value": 0.8,
          "estimated": true,
          "confidence": "low",
          "note": "Estimated from general reputation; no published per-shot statistic found."
        },
        "safety": {
          "value": 0.8,
          "estimated": true,
          "confidence": "low",
          "note": "Estimated from general reputation; no published per-shot statistic found."
        },
        "breakPower": {
          "value": 0.48,
          "estimated": false,
          "confidence": "medium",
          "source": "https://forums.azbilliards.com/threads/stats-shane-van-boening-vs-fedor-gorst-10-ball-race-to-120-august-2024.567611/",
          "note": "Measured: 1.45 balls made per break, break-weighted over 286 breaks in SVBvGorst2024 (1.4 on 116 breaks), SVBvGorst2025 (1.6 on 120 breaks), SVBvGorst2026 (1.2 on 50 breaks) [https://forums.azbilliards.com/threads/stats-shane-van-boening-vs-fedor-gorst-10-ball-race-to-120-august-2024.567611/; https://forums.azbilliards.com/threads/stats-shane-van-boening-vs-fedor-gorst-10-ball-race-to-120-june-2025.576819/; https://forums.azbilliards.com/threads/stats-shane-van-boening-vs-fedor-gorst-9-ball-race-to-50-july-2026.588438/]. Value = 1.45/3. AtLarge's counts come from streams, by one compiler; mostly 10-ball challenge matches."
        },
        "runOut": {
          "value": 0.26,
          "estimated": true,
          "confidence": "medium",
          "source": "https://forums.azbilliards.com/threads/stats-shane-van-boening-vs-fedor-gorst-10-ball-race-to-120-august-2024.567611/",
          "note": "Lower bound, measured: 136 run-outs from the first shot after a break (B&Rs included) in 514 games: SVBvGorst2024 54/236, SVBvGorst2025 60/198, SVBvGorst2026 22/80. This excludes mid-game run-outs after safeties and misses, so it is kept as estimated: true."
        },
        "bank": {
          "value": 0.6,
          "estimated": true,
          "confidence": "low",
          "note": "Estimated from general reputation; no published per-shot statistic found."
        },
        "pot": {
          "value": 0.9,
          "estimated": true,
          "confidence": "low",
          "note": "Accu-Stats TPA, 2020 Mosconi Cup: \"Gorst: .871\" (one event). Fewer estimated misses than SVB in their 2025 race to 120: \"47 in 177 games at the table (1 per 3.8)\" vs SVB \"1 per 3.2\" [https://forums.azbilliards.com/threads/stats-shane-van-boening-vs-fedor-gorst-10-ball-race-to-120-june-2025.576819/]. Value itself is estimated.",
          "source": "https://forums.azbilliards.com/threads/mosconi-cup-accu-stats-stats.523253/"
        },
        "position": {
          "value": 0.85,
          "estimated": true,
          "confidence": "low",
          "note": "Estimated from general reputation; no published per-shot statistic found."
        }
      }
    },
    {
      "id": "earl-strickland",
      "name": "Earl Strickland",
      "nickname": "Earl the Pearl",
      "profileSource": "https://en.wikipedia.org/wiki/Earl_Strickland",
      "traits": {
        "cut": {
          "value": 0.8,
          "estimated": true,
          "confidence": "low",
          "note": "Estimated from general reputation; no published per-shot statistic found."
        },
        "long": {
          "value": 0.8,
          "estimated": true,
          "confidence": "low",
          "note": "Estimated from general reputation; no published per-shot statistic found."
        },
        "side": {
          "value": 0.7,
          "estimated": true,
          "confidence": "low",
          "note": "Estimated from general reputation; no published per-shot statistic found."
        },
        "clutch": {
          "value": 0.75,
          "estimated": true,
          "confidence": "low",
          "note": "Wikipedia: he \"trailed 13-15 but won the last four racks to claim a 17–15 victory\"; he won the 1996 PCA $1,000,000 challenge by running 10+ racks. Only one source. Value itself is estimated.",
          "source": "https://en.wikipedia.org/wiki/Earl_Strickland"
        },
        "safety": {
          "value": 0.6,
          "estimated": true,
          "confidence": "low",
          "note": "Estimated from general reputation; no published per-shot statistic found."
        },
        "breakPower": {
          "value": 0.45,
          "estimated": true,
          "confidence": "low",
          "source": "https://forums.azbilliards.com/threads/break-stats-2022-mosconi-cup-nov-dec-2022.548763/",
          "note": "Derived from team-event break stats: MC2022 7/12 successful, 1/12 B&R (pooled 7/12 successful). Shrunk successful-break rate 0.693 (k=20 toward the pool mean 0.759) x 1.94 balls (calibrated on SVB/Gorst/Shaw, whose balls/break is measured) / 3. Per-player balls per break is not published for these events. The only sample is 12 breaks at the 2022 Mosconi Cup (age 61); prime-era data not found. Wikipedia's 1996 PCA account (\"made nine-on-the-breaks and early nines\") shows strong prime breaking, but it is anecdotal."
        },
        "runOut": {
          "value": 0.16,
          "estimated": true,
          "confidence": "low",
          "source": "https://forums.azbilliards.com/threads/break-stats-2022-mosconi-cup-nov-dec-2022.548763/",
          "note": "Derived: shrunk B&R rate on all breaks 0.206 (raw 1/12; k=20 toward 0.280) x 0.79 run-outs per game per unit B&R rate, calibrated on SVB/Gorst/Shaw. Events: MC2022 7/12 successful, 1/12 B&R. Late-career sample only. Prime-era evidence (Wikipedia): ran \"11 consecutive racks\" at the 1996 PCA event, \"the first player to run 10 consecutive racks in a tournament\"."
        },
        "bank": {
          "value": 0.55,
          "estimated": true,
          "confidence": "low",
          "note": "Estimated from general reputation; no published per-shot statistic found."
        },
        "pot": {
          "value": 0.9,
          "estimated": true,
          "confidence": "low",
          "note": "Estimated from general reputation; no published per-shot statistic found."
        },
        "position": {
          "value": 0.8,
          "estimated": true,
          "confidence": "low",
          "note": "Estimated from general reputation; no published per-shot statistic found."
        }
      }
    },
    {
      "id": "ko-pin-yi",
      "name": "Ko Pin-yi",
      "nickname": "Prince of Pool",
      "profileSource": "https://en.wikipedia.org/wiki/Ko_Pin-yi",
      "traits": {
        "cut": {
          "value": 0.8,
          "estimated": true,
          "confidence": "low",
          "note": "Estimated from general reputation; no published per-shot statistic found."
        },
        "long": {
          "value": 0.8,
          "estimated": true,
          "confidence": "low",
          "note": "Estimated from general reputation; no published per-shot statistic found."
        },
        "side": {
          "value": 0.75,
          "estimated": true,
          "confidence": "low",
          "note": "Estimated from general reputation; no published per-shot statistic found."
        },
        "clutch": {
          "value": 0.8,
          "estimated": true,
          "confidence": "low",
          "note": "Estimated from general reputation; no published per-shot statistic found."
        },
        "safety": {
          "value": 0.7,
          "estimated": true,
          "confidence": "low",
          "note": "Estimated from general reputation; no published per-shot statistic found."
        },
        "breakPower": {
          "value": 0.49,
          "estimated": true,
          "confidence": "low",
          "source": "https://forums.azbilliards.com/threads/break-stats-2024-reyes-cup-october-2024.569410/",
          "note": "Derived from team-event break stats: RC2024 10/13 successful, 2/13 B&R (pooled 10/13 successful). Shrunk successful-break rate 0.763 (k=20 toward the pool mean 0.759) x 1.94 balls (calibrated on SVB/Gorst/Shaw, whose balls/break is measured) / 3. Per-player balls per break is not published for these events."
        },
        "runOut": {
          "value": 0.18,
          "estimated": true,
          "confidence": "low",
          "source": "https://forums.azbilliards.com/threads/break-stats-2024-reyes-cup-october-2024.569410/",
          "note": "Derived: shrunk B&R rate on all breaks 0.230 (raw 2/13; k=20 toward 0.280) x 0.79 run-outs per game per unit B&R rate, calibrated on SVB/Gorst/Shaw. Events: RC2024 10/13 successful, 2/13 B&R."
        },
        "bank": {
          "value": 0.6,
          "estimated": true,
          "confidence": "low",
          "note": "Estimated from general reputation; no published per-shot statistic found."
        },
        "pot": {
          "value": 0.9,
          "estimated": true,
          "confidence": "low",
          "note": "Estimated from general reputation; no published per-shot statistic found."
        },
        "position": {
          "value": 0.85,
          "estimated": true,
          "confidence": "low",
          "note": "Estimated from general reputation; no published per-shot statistic found."
        }
      }
    },
    {
      "id": "carlo-biado",
      "name": "Carlo Biado",
      "nickname": "The Black Tiger",
      "profileSource": "https://en.wikipedia.org/wiki/Carlo_Biado",
      "traits": {
        "cut": {
          "value": 0.8,
          "estimated": true,
          "confidence": "low",
          "note": "Estimated from general reputation; no published per-shot statistic found."
        },
        "long": {
          "value": 0.85,
          "estimated": true,
          "confidence": "low",
          "note": "Estimated from general reputation; no published per-shot statistic found."
        },
        "side": {
          "value": 0.75,
          "estimated": true,
          "confidence": "low",
          "note": "Estimated from general reputation; no published per-shot statistic found."
        },
        "clutch": {
          "value": 0.85,
          "estimated": true,
          "confidence": "low",
          "note": "Estimated from general reputation; no published per-shot statistic found."
        },
        "safety": {
          "value": 0.75,
          "estimated": true,
          "confidence": "low",
          "note": "Estimated from general reputation; no published per-shot statistic found."
        },
        "breakPower": {
          "value": 0.48,
          "estimated": true,
          "confidence": "low",
          "source": "https://forums.azbilliards.com/threads/break-stats-2024-reyes-cup-october-2024.569410/",
          "note": "Derived from team-event break stats: RC2024 12/14 successful, 2/14 B&R; RC2025 4/9 successful, 1/9 B&R; RC2026 10/12 successful, 2/12 B&R (pooled 26/35 successful). Shrunk successful-break rate 0.749 (k=20 toward the pool mean 0.759) x 1.94 balls (calibrated on SVB/Gorst/Shaw, whose balls/break is measured) / 3. Per-player balls per break is not published for these events."
        },
        "runOut": {
          "value": 0.15,
          "estimated": true,
          "confidence": "low",
          "source": "https://forums.azbilliards.com/threads/break-stats-2024-reyes-cup-october-2024.569410/",
          "note": "Derived: shrunk B&R rate on all breaks 0.193 (raw 5/35; k=20 toward 0.280) x 0.79 run-outs per game per unit B&R rate, calibrated on SVB/Gorst/Shaw. Events: RC2024 12/14 successful, 2/14 B&R; RC2025 4/9 successful, 1/9 B&R; RC2026 10/12 successful, 2/12 B&R."
        },
        "bank": {
          "value": 0.65,
          "estimated": true,
          "confidence": "low",
          "note": "Estimated from general reputation; no published per-shot statistic found."
        },
        "pot": {
          "value": 0.88,
          "estimated": true,
          "confidence": "low",
          "note": "Estimated from general reputation; no published per-shot statistic found."
        },
        "position": {
          "value": 0.8,
          "estimated": true,
          "confidence": "low",
          "note": "Estimated from general reputation; no published per-shot statistic found."
        }
      }
    },
    {
      "id": "aloysius-yapp",
      "name": "Aloysius Yapp",
      "nickname": "Majin Buu",
      "profileSource": "https://en.wikipedia.org/wiki/Aloysius_Yapp",
      "traits": {
        "cut": {
          "value": 0.75,
          "estimated": true,
          "confidence": "low",
          "note": "Estimated from general reputation; no published per-shot statistic found."
        },
        "long": {
          "value": 0.8,
          "estimated": true,
          "confidence": "low",
          "note": "Estimated from general reputation; no published per-shot statistic found."
        },
        "side": {
          "value": 0.7,
          "estimated": true,
          "confidence": "low",
          "note": "Estimated from general reputation; no published per-shot statistic found."
        },
        "clutch": {
          "value": 0.8,
          "estimated": true,
          "confidence": "low",
          "note": "Estimated from general reputation; no published per-shot statistic found."
        },
        "safety": {
          "value": 0.8,
          "estimated": true,
          "confidence": "low",
          "note": "Estimated from general reputation; no published per-shot statistic found."
        },
        "breakPower": {
          "value": 0.5,
          "estimated": true,
          "confidence": "low",
          "source": "https://forums.azbilliards.com/threads/break-stats-2024-reyes-cup-october-2024.569410/",
          "note": "Derived from team-event break stats: RC2024 11/15 successful, 6/15 B&R; RC2025 10/12 successful, 5/12 B&R (pooled 21/27 successful). Shrunk successful-break rate 0.770 (k=20 toward the pool mean 0.759) x 1.94 balls (calibrated on SVB/Gorst/Shaw, whose balls/break is measured) / 3. Per-player balls per break is not published for these events."
        },
        "runOut": {
          "value": 0.28,
          "estimated": true,
          "confidence": "low",
          "source": "https://forums.azbilliards.com/threads/break-stats-2024-reyes-cup-october-2024.569410/",
          "note": "Derived: shrunk B&R rate on all breaks 0.353 (raw 11/27; k=20 toward 0.280) x 0.79 run-outs per game per unit B&R rate, calibrated on SVB/Gorst/Shaw. Events: RC2024 11/15 successful, 6/15 B&R; RC2025 10/12 successful, 5/12 B&R."
        },
        "bank": {
          "value": 0.6,
          "estimated": true,
          "confidence": "low",
          "note": "Estimated from general reputation; no published per-shot statistic found."
        },
        "pot": {
          "value": 0.88,
          "estimated": true,
          "confidence": "low",
          "note": "Estimated from general reputation; no published per-shot statistic found."
        },
        "position": {
          "value": 0.85,
          "estimated": true,
          "confidence": "low",
          "note": "Estimated from general reputation; no published per-shot statistic found."
        }
      }
    },
    {
      "id": "jayson-shaw",
      "name": "Jayson Shaw",
      "nickname": "Eagle Eye",
      "profileSource": "https://en.wikipedia.org/wiki/Jayson_Shaw",
      "traits": {
        "cut": {
          "value": 0.8,
          "estimated": true,
          "confidence": "low",
          "note": "Estimated from general reputation; no published per-shot statistic found."
        },
        "long": {
          "value": 0.85,
          "estimated": true,
          "confidence": "low",
          "note": "Estimated from general reputation; no published per-shot statistic found."
        },
        "side": {
          "value": 0.75,
          "estimated": true,
          "confidence": "low",
          "note": "Estimated from general reputation; no published per-shot statistic found."
        },
        "clutch": {
          "value": 0.75,
          "estimated": true,
          "confidence": "low",
          "note": "Estimated from general reputation; no published per-shot statistic found."
        },
        "safety": {
          "value": 0.65,
          "estimated": true,
          "confidence": "low",
          "note": "Estimated from general reputation; no published per-shot statistic found."
        },
        "breakPower": {
          "value": 0.53,
          "estimated": false,
          "confidence": "low",
          "source": "https://forums.azbilliards.com/threads/stats-van-boening-vs-shaw-10-ball-race-to-100-august-2019.498355/",
          "note": "Measured: 1.60 balls made per break, break-weighted over 91 breaks in SVBvShaw2019 (1.6 on 91 breaks) [https://forums.azbilliards.com/threads/stats-van-boening-vs-shaw-10-ball-race-to-100-august-2019.498355/]. Value = 1.60/3. AtLarge's counts come from streams, by one compiler; mostly 10-ball challenge matches."
        },
        "runOut": {
          "value": 0.28,
          "estimated": true,
          "confidence": "low",
          "source": "https://forums.azbilliards.com/threads/stats-van-boening-vs-shaw-10-ball-race-to-100-august-2019.498355/",
          "note": "Lower bound, measured: 54 run-outs from the first shot after a break (B&Rs included) in 192 games: SVBvShaw2019 54/192. This excludes mid-game run-outs after safeties and misses, so it is kept as estimated: true."
        },
        "bank": {
          "value": 0.6,
          "estimated": true,
          "confidence": "low",
          "note": "Estimated from general reputation; no published per-shot statistic found."
        },
        "pot": {
          "value": 0.92,
          "estimated": true,
          "confidence": "medium",
          "note": "Two independent sources agree. (1) AZBilliards, Frank Lance, 2023-07-19: \"He has an uncanny ability to identify and make shots that many other players would gloss over\"; \"He can also shoot with unmatched precision.\" (2) Accu-Stats TPA, 2020 Mosconi Cup: \"Shaw: .905\", 2nd highest of all 10 players [https://forums.azbilliards.com/threads/mosconi-cup-accu-stats-stats.523253/]. Value itself is estimated.",
          "source": "https://azbilliards.com/?p=222343"
        },
        "position": {
          "value": 0.9,
          "estimated": true,
          "confidence": "low",
          "note": "Wikipedia: 14.1 world high-run record (714 in 2022, then 832 in 2025, per the seed). Long straight-pool runs need sustained position play, but that is an inference. Value itself is estimated.",
          "source": "https://en.wikipedia.org/wiki/Jayson_Shaw"
        }
      }
    },
    {
      "id": "francisco-sanchez-ruiz",
      "name": "Francisco Sánchez Ruiz",
      "nickname": "The Ferrari",
      "profileSource": "https://en.wikipedia.org/wiki/Francisco_S%C3%A1nchez_Ruiz",
      "traits": {
        "cut": {
          "value": 0.8,
          "estimated": true,
          "confidence": "low",
          "note": "Estimated from general reputation; no published per-shot statistic found."
        },
        "long": {
          "value": 0.8,
          "estimated": true,
          "confidence": "low",
          "note": "Estimated from general reputation; no published per-shot statistic found."
        },
        "side": {
          "value": 0.75,
          "estimated": true,
          "confidence": "low",
          "note": "Estimated from general reputation; no published per-shot statistic found."
        },
        "clutch": {
          "value": 0.8,
          "estimated": true,
          "confidence": "low",
          "note": "Estimated from general reputation; no published per-shot statistic found."
        },
        "safety": {
          "value": 0.75,
          "estimated": true,
          "confidence": "low",
          "note": "Estimated from general reputation; no published per-shot statistic found."
        },
        "breakPower": {
          "value": 0.49,
          "estimated": true,
          "confidence": "low",
          "source": "https://forums.azbilliards.com/threads/break-stats-2022-mosconi-cup-nov-dec-2022.548763/",
          "note": "Derived from team-event break stats: MC2022 5/11 successful, 1/11 B&R; MC2023 7/11 successful, 2/11 B&R; MC2024 13/14 successful, 5/14 B&R; RC2024 12/15 successful, 4/15 B&R; RC2025 8/10 successful, 0/10 B&R; RC2026 10/12 successful, 2/12 B&R (pooled 55/73 successful). Shrunk successful-break rate 0.755 (k=20 toward the pool mean 0.759) x 1.94 balls (calibrated on SVB/Gorst/Shaw, whose balls/break is measured) / 3. Per-player balls per break is not published for these events."
        },
        "runOut": {
          "value": 0.17,
          "estimated": true,
          "confidence": "low",
          "source": "https://forums.azbilliards.com/threads/break-stats-2022-mosconi-cup-nov-dec-2022.548763/",
          "note": "Derived: shrunk B&R rate on all breaks 0.211 (raw 14/73; k=20 toward 0.280) x 0.79 run-outs per game per unit B&R rate, calibrated on SVB/Gorst/Shaw. Events: MC2022 5/11 successful, 1/11 B&R; MC2023 7/11 successful, 2/11 B&R; MC2024 13/14 successful, 5/14 B&R; RC2024 12/15 successful, 4/15 B&R; RC2025 8/10 successful, 0/10 B&R; RC2026 10/12 successful, 2/12 B&R."
        },
        "bank": {
          "value": 0.6,
          "estimated": true,
          "confidence": "low",
          "note": "Estimated from general reputation; no published per-shot statistic found."
        },
        "pot": {
          "value": 0.9,
          "estimated": true,
          "confidence": "low",
          "note": "Estimated from general reputation; no published per-shot statistic found."
        },
        "position": {
          "value": 0.85,
          "estimated": true,
          "confidence": "low",
          "note": "Estimated from general reputation; no published per-shot statistic found."
        }
      }
    }
  ]
}
"""#

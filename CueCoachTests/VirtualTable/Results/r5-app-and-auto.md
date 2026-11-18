# Virtual table lock matrix

Generated 2026-11-08T06:41:46Z by `CueCoachTests/VirtualTable` (branch wt/virtual-qa). 540 simulated sessions × 2 locators, 10 s window each, fed through a replica of FrameTap's locating gate (0.2 s × 0.9 interval, busy flag = measured thread-CPU of convert + ingest, plane-found + tracking gating) at 30/60 fps ARKit timestamps.

- **accurate** = locked with max corner error ≤ 5 cm. **false** = locked with max corner error > 20 cm (wrong surface / wrong pose).
- **TTL** = seconds from session start (camera on) to lock, accurate locks only; *from plane* = from the first frame FrameTap handed to the locator.
- **reason** = % of non-locking sessions where the locator's own output carried a failure reason (FeltQuad's `TableEstimate` has no field for one).
- **in view** = % of sessions whose 4 cloth corners were all inside the frame at t = 1.5 s.

| condition | locator | n | lock % | accurate % | false % | TTL med (s) | TTL p90 | from plane | err med (cm) | yaw med (°) | size ok | reason % | top failure | cpu ms | in view |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| baseline | Auto | 20 | 90 | 90 | 0 | 1.33 | 3.73 | 0.33 | 0.4 | 0.0 | 100% | 100 | partialTable ×1 | 9 | 35 |
| baseline | FeltQuad | 0 | 0 | 0 | 0 | – | – | – | – | – | 0% | 100 |  | – | 0 |
| baseline | Auto | 20 | 80 | 80 | 0 | 2.90 | 4.13 | 1.00 | 0.4 | 0.0 | 100% | 100 | no quad (partial: no rail corner (2 runs, 2 rails)) ×1 | 4 | 35 |
| felt-blue | Auto | 20 | 95 | 95 | 0 | 1.33 | 3.93 | 0.33 | 0.4 | 0.0 | 100% | 100 | partialTable ×1 | 3 | 35 |
| felt-blue | FeltQuad | 0 | 0 | 0 | 0 | – | – | – | – | – | 0% | 100 |  | – | 0 |
| felt-blue | Auto | 20 | 85 | 85 | 0 | 2.87 | 4.08 | 1.00 | 0.3 | 0.0 | 100% | 100 | converging (spread > lock) ×1 | 4 | 35 |
| felt-red | Auto | 20 | 80 | 80 | 0 | 1.33 | 3.28 | 0.40 | 0.5 | 0.1 | 100% | 100 | unstable ×2 | 6 | 35 |
| felt-red | FeltQuad | 0 | 0 | 0 | 0 | – | – | – | – | – | 0% | 100 |  | – | 0 |
| felt-red | Auto | 20 | 70 | 70 | 0 | 2.90 | 4.82 | 1.00 | 0.5 | 0.0 | 100% | 100 | cloth touches frame (partial: < 2 rails) ×2 | 3 | 35 |
| felt-grey | Auto | 20 | 5 | 5 | 0 | 9.00 | 9.00 | 8.13 | 0.4 | 0.0 | 100% | 100 | partialTable ×10 | 12 | 35 |
| felt-grey | FeltQuad | 0 | 0 | 0 | 0 | – | – | – | – | – | 0% | 100 |  | – | 0 |
| felt-grey | Auto | 20 | 0 | 0 | 0 | – | – | – | – | – | 0% | 100 | reprojection ×7 | 3 | 35 |
| felt-tan | Auto | 20 | 55 | 55 | 0 | 1.27 | 2.83 | 0.33 | 0.3 | 0.0 | 100% | 100 | partialTable ×8 | 11 | 35 |
| felt-tan | FeltQuad | 0 | 0 | 0 | 0 | – | – | – | – | – | 0% | 100 |  | – | 0 |
| felt-tan | Auto | 20 | 55 | 55 | 0 | 2.57 | 3.13 | 1.00 | 0.4 | 0.0 | 100% | 100 | cloth touches frame (partial: < 2 rails) ×2 | 4 | 35 |
| light-lamp | Auto | 20 | 50 | 50 | 0 | 1.27 | 5.77 | 0.43 | 0.5 | 0.0 | 100% | 100 | unstable ×7 | 7 | 60 |
| light-lamp | FeltQuad | 0 | 0 | 0 | 0 | – | – | – | – | – | 0% | 100 |  | – | 0 |
| light-lamp | Auto | 20 | 40 | 40 | 0 | 2.77 | 3.23 | 1.10 | 0.5 | 0.0 | 100% | 100 | reprojection ×6 | 3 | 60 |
| light-dim | Auto | 20 | 5 | 5 | 0 | 1.47 | 1.47 | 0.87 | 0.3 | 0.0 | 100% | 100 | partialTable ×19 | 13 | 35 |
| light-dim | FeltQuad | 0 | 0 | 0 | 0 | – | – | – | – | – | 0% | 100 |  | – | 0 |
| light-dim | Auto | 20 | 5 | 5 | 0 | 9.40 | 9.40 | 8.43 | 0.2 | 0.0 | 100% | 100 | cloth touches frame (partial: < 2 rails) ×13 | 5 | 35 |
| light-neon | Auto | 20 | 90 | 90 | 0 | 1.33 | 3.40 | 0.37 | 0.5 | 0.0 | 100% | 100 | partialTable ×2 | 7 | 25 |
| light-neon | FeltQuad | 0 | 0 | 0 | 0 | – | – | – | – | – | 0% | 100 |  | – | 0 |
| light-neon | Auto | 20 | 80 | 80 | 0 | 3.00 | 5.03 | 1.10 | 0.4 | 0.0 | 100% | 100 | no quad (partial: no rail corner (2 runs, 1 rails)) ×2 | 4 | 25 |
| light-cueShadow | Auto | 20 | 5 | 0 | 5 | – | – | – | – | – | 0% | 95 | partialTable ×15 / FALSE: wrong pose on this table ×1 | 11 | 60 |
| light-cueShadow | FeltQuad | 0 | 0 | 0 | 0 | – | – | – | – | – | 0% | 100 |  | – | 0 |
| light-cueShadow | Auto | 20 | 0 | 0 | 0 | – | – | – | – | – | 0% | 100 | no quad (partial: no rail corner (2 runs, 2 rails)) ×6 | 4 | 60 |
| clutter-secondTable | Auto | 20 | 95 | 95 | 0 | 1.27 | 3.33 | 0.35 | 0.4 | 0.0 | 100% | 100 | partialTable ×1 | 9 | 35 |
| clutter-secondTable | FeltQuad | 0 | 0 | 0 | 0 | – | – | – | – | – | 0% | 100 |  | – | 0 |
| clutter-secondTable | Auto | 20 | 80 | 80 | 0 | 2.85 | 4.17 | 1.00 | 0.3 | 0.0 | 100% | 100 | no quad (partial: no rail corner (3 runs, 2 rails)) ×1 | 3 | 35 |
| clutter-coffeeTable | Auto | 20 | 90 | 90 | 0 | 1.20 | 4.02 | 0.33 | 0.4 | 0.0 | 100% | 100 | partialTable ×1 | 5 | 35 |
| clutter-coffeeTable | FeltQuad | 0 | 0 | 0 | 0 | – | – | – | – | – | 0% | 100 |  | – | 0 |
| clutter-coffeeTable | Auto | 20 | 80 | 80 | 0 | 2.63 | 4.08 | 1.28 | 0.4 | 0.0 | 100% | 100 | cloth touches frame (partial: < 2 rails) ×2 | 3 | 35 |
| clutter-people | Auto | 20 | 25 | 25 | 0 | 6.33 | 9.77 | 5.33 | 0.8 | 0.0 | 100% | 100 | partialTable ×10 | 11 | 35 |
| clutter-people | FeltQuad | 0 | 0 | 0 | 0 | – | – | – | – | – | 0% | 100 |  | – | 0 |
| clutter-people | Auto | 20 | 10 | 10 | 0 | 4.03 | 4.03 | 2.60 | 1.0 | 0.1 | 100% | 100 | no quad (partial: mask disagrees) ×10 | 4 | 35 |
| clutter-railObjects | Auto | 20 | 90 | 90 | 0 | 1.20 | 3.33 | 0.37 | 0.5 | 0.0 | 100% | 100 | partialTable ×1 | 6 | 35 |
| clutter-railObjects | FeltQuad | 0 | 0 | 0 | 0 | – | – | – | – | – | 0% | 100 |  | – | 0 |
| clutter-railObjects | Auto | 20 | 80 | 80 | 0 | 2.67 | 4.12 | 1.00 | 0.5 | 0.0 | 100% | 100 | cloth touches frame (partial: < 2 rails) ×2 | 3 | 35 |
| dist-1.0m | Auto | 20 | 90 | 90 | 0 | 1.37 | 4.27 | 0.37 | 0.5 | 0.0 | 100% | 100 | badShape ×1 | 5 | 25 |
| dist-1.0m | FeltQuad | 0 | 0 | 0 | 0 | – | – | – | – | – | 0% | 100 |  | – | 0 |
| dist-1.0m | Auto | 20 | 90 | 90 | 0 | 2.87 | 4.70 | 1.47 | 0.4 | 0.0 | 100% | 100 | cloth touches frame (partial: < 2 rails) ×1 | 4 | 25 |
| dist-2.0m | Auto | 20 | 75 | 75 | 0 | 1.33 | 3.83 | 0.33 | 0.6 | 0.0 | 100% | 100 | partialTable ×4 | 4 | 60 |
| dist-2.0m | FeltQuad | 0 | 0 | 0 | 0 | – | – | – | – | – | 0% | 100 |  | – | 0 |
| dist-2.0m | Auto | 20 | 65 | 65 | 0 | 2.87 | 4.82 | 1.00 | 0.4 | 0.0 | 100% | 100 | converging (spread > lock) ×2 | 3 | 60 |
| dist-3.0m | Auto | 20 | 15 | 15 | 0 | 1.93 | 2.47 | 0.93 | 0.3 | 0.0 | 100% | 100 | partialTable ×11 | 13 | 100 |
| dist-3.0m | FeltQuad | 0 | 0 | 0 | 0 | – | – | – | – | – | 0% | 100 |  | – | 0 |
| dist-3.0m | Auto | 20 | 15 | 15 | 0 | 2.57 | 2.87 | 1.00 | 0.3 | 0.0 | 100% | 100 | view too shallow ×4 | 6 | 100 |
| elev-25deg | Auto | 20 | 30 | 30 | 0 | 1.42 | 4.70 | 0.53 | 0.4 | 0.0 | 100% | 100 | partialTable ×10 | 12 | 0 |
| elev-25deg | FeltQuad | 0 | 0 | 0 | 0 | – | – | – | – | – | 0% | 100 |  | – | 0 |
| elev-25deg | Auto | 20 | 30 | 30 | 0 | 3.17 | 4.97 | 1.83 | 0.5 | 0.0 | 100% | 100 | cloth touches frame (partial: no rail corner (2 runs, 2 rails)) ×4 | 5 | 0 |
| elev-45deg | Auto | 20 | 0 | 0 | 0 | – | – | – | – | – | 0% | 100 | partialTable ×18 | 16 | 0 |
| elev-45deg | FeltQuad | 0 | 0 | 0 | 0 | – | – | – | – | – | 0% | 100 |  | – | 0 |
| elev-45deg | Auto | 20 | 0 | 0 | 0 | – | – | – | – | – | 0% | 100 | cloth touches frame (partial: < 2 rails) ×9 | 7 | 0 |
| elev-60deg | Auto | 20 | 5 | 5 | 0 | 3.00 | 3.00 | 2.00 | 0.2 | 0.0 | 100% | 100 | partialTable ×15 | 15 | 0 |
| elev-60deg | FeltQuad | 0 | 0 | 0 | 0 | – | – | – | – | – | 0% | 100 |  | – | 0 |
| elev-60deg | Auto | 20 | 10 | 10 | 0 | 6.67 | 6.67 | 5.20 | 0.3 | 0.0 | 100% | 100 | cloth touches frame (partial: < 2 rails) ×10 | 6 | 0 |
| path-endPan | Auto | 20 | 90 | 90 | 0 | 1.20 | 1.40 | 0.33 | 0.4 | 0.0 | 100% | 100 | partialTable ×1 | 4 | 65 |
| path-endPan | FeltQuad | 0 | 0 | 0 | 0 | – | – | – | – | – | 0% | 100 |  | – | 0 |
| path-endPan | Auto | 20 | 85 | 85 | 0 | 2.73 | 3.35 | 1.00 | 0.3 | 0.0 | 100% | 100 | cloth touches frame (partial: < 2 rails) ×1 | 3 | 65 |
| path-sideWalk | Auto | 20 | 90 | 90 | 0 | 1.42 | 9.03 | 0.63 | 0.5 | 0.0 | 100% | 100 | partialTable ×1 | 9 | 5 |
| path-sideWalk | FeltQuad | 0 | 0 | 0 | 0 | – | – | – | – | – | 0% | 100 |  | – | 0 |
| path-sideWalk | Auto | 20 | 65 | 65 | 0 | 3.10 | 4.15 | 1.60 | 0.4 | 0.0 | 100% | 100 | converging (spread > lock) ×3 | 4 | 5 |
| path-partial | Auto | 20 | 95 | 95 | 0 | 1.27 | 3.72 | 0.40 | 0.4 | 0.0 | 100% | 100 | unstable ×1 | 8 | 5 |
| path-partial | FeltQuad | 0 | 0 | 0 | 0 | – | – | – | – | – | 0% | 100 |  | – | 0 |
| path-partial | Auto | 20 | 75 | 75 | 0 | 2.90 | 4.90 | 1.20 | 0.3 | 0.0 | 100% | 100 | cloth touches frame (partial: no rail corner (4 runs, 1 rails)) ×2 | 6 | 5 |
| hold-portrait | Auto | 20 | 90 | 90 | 0 | 1.33 | 3.67 | 0.37 | 0.3 | 0.0 | 100% | 100 | partialTable ×1 | 4 | 20 |
| hold-portrait | FeltQuad | 0 | 0 | 0 | 0 | – | – | – | – | – | 0% | 100 |  | – | 0 |
| hold-portrait | Auto | 20 | 70 | 70 | 0 | 2.87 | 3.35 | 1.00 | 0.2 | 0.0 | 100% | 100 | no quad (partial: no rail corner (2 runs, 2 rails)) ×2 | 3 | 20 |
| hold-landscape | Auto | 20 | 95 | 95 | 0 | 1.27 | 1.47 | 0.33 | 0.6 | 0.0 | 100% | 100 | converging (spread > lock) ×1 | 3 | 70 |
| hold-landscape | FeltQuad | 0 | 0 | 0 | 0 | – | – | – | – | – | 0% | 100 |  | – | 0 |
| hold-landscape | Auto | 20 | 85 | 85 | 0 | 2.90 | 3.47 | 1.00 | 0.5 | 0.0 | 100% | 100 | reprojection ×1 | 3 | 70 |
| fps-30 | Auto | 20 | 95 | 95 | 0 | 1.33 | 6.10 | 0.33 | 0.4 | 0.0 | 100% | 100 | partialTable ×1 | 4 | 35 |
| fps-30 | FeltQuad | 0 | 0 | 0 | 0 | – | – | – | – | – | 0% | 100 |  | – | 0 |
| fps-30 | Auto | 20 | 80 | 80 | 0 | 2.97 | 4.13 | 1.00 | 0.4 | 0.0 | 100% | 100 | cloth touches frame (partial: < 2 rails) ×1 | 3 | 35 |
| fps-60 | Auto | 20 | 95 | 95 | 0 | 1.33 | 4.13 | 0.35 | 0.4 | 0.0 | 100% | 100 | partialTable ×1 | 5 | 35 |
| fps-60 | FeltQuad | 0 | 0 | 0 | 0 | – | – | – | – | – | 0% | 100 |  | – | 0 |
| fps-60 | Auto | 20 | 80 | 80 | 0 | 2.87 | 4.08 | 0.92 | 0.4 | 0.0 | 100% | 100 | cloth touches frame (partial: < 2 rails) ×1 | 3 | 35 |
| bar-rive-combo | Auto | 20 | 10 | 10 | 0 | 5.67 | 5.67 | 4.73 | 0.4 | 0.0 | 100% | 100 | partialTable ×8 | 10 | 60 |
| bar-rive-combo | FeltQuad | 0 | 0 | 0 | 0 | – | – | – | – | – | 0% | 100 |  | – | 0 |
| bar-rive-combo | Auto | 20 | 5 | 5 | 0 | 5.80 | 5.80 | 4.20 | 0.2 | 0.0 | 100% | 100 | no quad (partial: no rail corner (2 runs, 2 rails)) ×5 | 3 | 60 |

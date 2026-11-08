# Virtual table lock matrix

Generated 2026-11-07T08:38:30Z by `CueCoachTests/VirtualTable` (branch wt/virtual-qa). 540 simulated sessions × 2 locators, 10 s window each, fed through a replica of FrameTap's locating gate (0.2 s × 0.9 interval, busy flag = measured thread-CPU of convert + ingest, plane-found + tracking gating) at 30/60 fps ARKit timestamps.

- **accurate** = locked with max corner error ≤ 5 cm. **false** = locked with max corner error > 20 cm (wrong surface / wrong pose).
- **TTL** = seconds from session start (camera on) to lock, accurate locks only; *from plane* = from the first frame FrameTap handed to the locator.
- **reason** = % of non-locking sessions where the locator's own output carried a failure reason (FeltQuad's `TableEstimate` has no field for one).
- **in view** = % of sessions whose 4 cloth corners were all inside the frame at t = 1.5 s.

| condition | locator | n | lock % | accurate % | false % | TTL med (s) | TTL p90 | from plane | err med (cm) | yaw med (°) | size ok | reason % | top failure | cpu ms | in view |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| baseline | Auto | 20 | 40 | 40 | 0 | 1.93 | 3.00 | 0.93 | 0.4 | 0.0 | 100% | 100 | partialTable ×7 | 10 | 35 |
| baseline | FeltQuad | 0 | 0 | 0 | 0 | – | – | – | – | – | 0% | 100 |  | – | 0 |
| baseline | Auto | 20 | 40 | 40 | 0 | 4.90 | 6.75 | 2.80 | 0.3 | 0.0 | 100% | 100 | cloth touches frame ×8 | 5 | 35 |
| felt-blue | Auto | 20 | 45 | 45 | 0 | 1.93 | 3.33 | 0.93 | 0.5 | 0.0 | 100% | 100 | partialTable ×6 | 10 | 35 |
| felt-blue | FeltQuad | 0 | 0 | 0 | 0 | – | – | – | – | – | 0% | 100 |  | – | 0 |
| felt-blue | Auto | 20 | 45 | 45 | 0 | 4.93 | 7.93 | 2.80 | 0.4 | 0.0 | 100% | 100 | cloth touches frame ×7 | 4 | 35 |
| felt-red | Auto | 20 | 30 | 30 | 0 | 1.80 | 3.60 | 0.93 | 0.9 | 0.0 | 100% | 100 | partialTable ×10 | 10 | 35 |
| felt-red | FeltQuad | 0 | 0 | 0 | 0 | – | – | – | – | – | 0% | 100 |  | – | 0 |
| felt-red | Auto | 20 | 30 | 30 | 0 | 4.93 | 6.70 | 3.00 | 0.9 | 0.0 | 100% | 100 | cloth touches frame ×10 | 5 | 35 |
| felt-grey | Auto | 20 | 0 | 0 | 0 | – | – | – | – | – | 0% | 100 | noFelt ×16 | 13 | 35 |
| felt-grey | FeltQuad | 0 | 0 | 0 | 0 | – | – | – | – | – | 0% | 100 |  | – | 0 |
| felt-grey | Auto | 20 | 0 | 0 | 0 | – | – | – | – | – | 0% | 100 | no cloth colour ×16 | 7 | 35 |
| felt-tan | Auto | 20 | 30 | 30 | 0 | 3.40 | 7.53 | 2.53 | 0.5 | 0.0 | 100% | 100 | partialTable ×10 | 11 | 35 |
| felt-tan | FeltQuad | 0 | 0 | 0 | 0 | – | – | – | – | – | 0% | 100 |  | – | 0 |
| felt-tan | Auto | 20 | 20 | 20 | 0 | 4.90 | 5.62 | 3.00 | 0.5 | 0.1 | 100% | 100 | cloth touches frame ×11 | 5 | 35 |
| light-lamp | Auto | 20 | 45 | 45 | 0 | 1.93 | 4.40 | 1.07 | 0.5 | 0.0 | 100% | 100 | badShape ×6 | 3 | 60 |
| light-lamp | FeltQuad | 0 | 0 | 0 | 0 | – | – | – | – | – | 0% | 100 |  | – | 0 |
| light-lamp | Auto | 20 | 40 | 40 | 0 | 4.53 | 9.63 | 3.40 | 0.5 | 0.0 | 100% | 100 | no quad ×6 | 3 | 60 |
| light-dim | Auto | 20 | 0 | 0 | 0 | – | – | – | – | – | 0% | 100 | badShape ×16 | 9 | 35 |
| light-dim | FeltQuad | 0 | 0 | 0 | 0 | – | – | – | – | – | 0% | 100 |  | – | 0 |
| light-dim | Auto | 20 | 0 | 0 | 0 | – | – | – | – | – | 0% | 100 | no quad ×13 | 4 | 35 |
| light-neon | Auto | 20 | 30 | 30 | 0 | 3.47 | 8.20 | 2.47 | 0.7 | 0.0 | 100% | 100 | partialTable ×11 | 10 | 25 |
| light-neon | FeltQuad | 0 | 0 | 0 | 0 | – | – | – | – | – | 0% | 100 |  | – | 0 |
| light-neon | Auto | 20 | 25 | 25 | 0 | 6.85 | 9.60 | 4.95 | 0.6 | 0.1 | 100% | 100 | cloth touches frame ×11 | 5 | 25 |
| light-cueShadow | Auto | 20 | 0 | 0 | 0 | – | – | – | – | – | 0% | 100 | badShape ×15 | 7 | 60 |
| light-cueShadow | FeltQuad | 0 | 0 | 0 | 0 | – | – | – | – | – | 0% | 100 |  | – | 0 |
| light-cueShadow | Auto | 20 | 0 | 0 | 0 | – | – | – | – | – | 0% | 100 | no quad ×16 | 3 | 60 |
| clutter-secondTable | Auto | 20 | 50 | 50 | 0 | 1.87 | 3.93 | 1.07 | 0.4 | 0.0 | 100% | 100 | partialTable ×5 | 7 | 35 |
| clutter-secondTable | FeltQuad | 0 | 0 | 0 | 0 | – | – | – | – | – | 0% | 100 |  | – | 0 |
| clutter-secondTable | Auto | 20 | 45 | 45 | 0 | 4.87 | 8.42 | 3.00 | 0.3 | 0.0 | 100% | 100 | cloth touches frame ×6 | 4 | 35 |
| clutter-coffeeTable | Auto | 20 | 40 | 40 | 0 | 1.87 | 3.07 | 1.00 | 0.3 | 0.0 | 100% | 100 | partialTable ×7 | 10 | 35 |
| clutter-coffeeTable | FeltQuad | 0 | 0 | 0 | 0 | – | – | – | – | – | 0% | 100 |  | – | 0 |
| clutter-coffeeTable | Auto | 20 | 35 | 35 | 0 | 4.25 | 5.87 | 2.75 | 0.2 | 0.0 | 100% | 100 | cloth touches frame ×9 | 5 | 35 |
| clutter-people | Auto | 20 | 0 | 0 | 0 | – | – | – | – | – | 0% | 100 | badShape ×9 | 9 | 35 |
| clutter-people | FeltQuad | 0 | 0 | 0 | 0 | – | – | – | – | – | 0% | 100 |  | – | 0 |
| clutter-people | Auto | 20 | 0 | 0 | 0 | – | – | – | – | – | 0% | 100 | cloth touches frame ×10 | 4 | 35 |
| clutter-railObjects | Auto | 20 | 40 | 40 | 0 | 1.80 | 2.27 | 0.93 | 0.4 | 0.0 | 100% | 100 | partialTable ×5 | 10 | 35 |
| clutter-railObjects | FeltQuad | 0 | 0 | 0 | 0 | – | – | – | – | – | 0% | 100 |  | – | 0 |
| clutter-railObjects | Auto | 20 | 35 | 35 | 0 | 4.48 | 5.05 | 2.80 | 0.2 | 0.0 | 100% | 100 | cloth touches frame ×8 | 5 | 35 |
| dist-1.0m | Auto | 20 | 50 | 50 | 0 | 1.93 | 2.13 | 0.93 | 0.5 | 0.0 | 100% | 100 | partialTable ×6 | 4 | 25 |
| dist-1.0m | FeltQuad | 0 | 0 | 0 | 0 | – | – | – | – | – | 0% | 100 |  | – | 0 |
| dist-1.0m | Auto | 20 | 45 | 45 | 0 | 4.67 | 5.03 | 2.80 | 0.4 | 0.0 | 100% | 100 | cloth touches frame ×7 | 4 | 25 |
| dist-2.0m | Auto | 20 | 0 | 0 | 0 | – | – | – | – | – | 0% | 100 | partialTable ×12 | 10 | 60 |
| dist-2.0m | FeltQuad | 0 | 0 | 0 | 0 | – | – | – | – | – | 0% | 100 |  | – | 0 |
| dist-2.0m | Auto | 20 | 0 | 0 | 0 | – | – | – | – | – | 0% | 100 | cloth touches frame ×13 | 5 | 60 |
| dist-3.0m | Auto | 20 | 0 | 0 | 0 | – | – | – | – | – | 0% | 100 | partialTable ×13 | 11 | 100 |
| dist-3.0m | FeltQuad | 0 | 0 | 0 | 0 | – | – | – | – | – | 0% | 100 |  | – | 0 |
| dist-3.0m | Auto | 20 | 0 | 0 | 0 | – | – | – | – | – | 0% | 100 | cloth touches frame ×13 | 5 | 100 |
| elev-25deg | Auto | 20 | 15 | 15 | 0 | 3.93 | 7.67 | 3.40 | 0.4 | 0.0 | 100% | 100 | partialTable ×13 | 11 | 0 |
| elev-25deg | FeltQuad | 0 | 0 | 0 | 0 | – | – | – | – | – | 0% | 100 |  | – | 0 |
| elev-25deg | Auto | 20 | 10 | 10 | 0 | 9.47 | 9.47 | 8.00 | 0.4 | 0.0 | 100% | 100 | cloth touches frame ×13 | 5 | 0 |
| elev-45deg | Auto | 20 | 0 | 0 | 0 | – | – | – | – | – | 0% | 100 | partialTable ×20 | 12 | 0 |
| elev-45deg | FeltQuad | 0 | 0 | 0 | 0 | – | – | – | – | – | 0% | 100 |  | – | 0 |
| elev-45deg | Auto | 20 | 0 | 0 | 0 | – | – | – | – | – | 0% | 100 | cloth touches frame ×20 | 6 | 0 |
| elev-60deg | Auto | 20 | 0 | 0 | 0 | – | – | – | – | – | 0% | 100 | partialTable ×20 | 12 | 0 |
| elev-60deg | FeltQuad | 0 | 0 | 0 | 0 | – | – | – | – | – | 0% | 100 |  | – | 0 |
| elev-60deg | Auto | 20 | 0 | 0 | 0 | – | – | – | – | – | 0% | 100 | cloth touches frame ×20 | 6 | 0 |
| path-endPan | Auto | 20 | 55 | 55 | 0 | 1.67 | 2.27 | 0.93 | 0.4 | 0.0 | 100% | 100 | partialTable ×5 | 3 | 65 |
| path-endPan | FeltQuad | 0 | 0 | 0 | 0 | – | – | – | – | – | 0% | 100 |  | – | 0 |
| path-endPan | Auto | 20 | 55 | 55 | 0 | 4.33 | 5.62 | 2.80 | 0.3 | 0.0 | 100% | 100 | cloth touches frame ×5 | 4 | 65 |
| path-sideWalk | Auto | 20 | 15 | 15 | 0 | 1.53 | 1.93 | 0.93 | 0.5 | 0.1 | 100% | 100 | partialTable ×13 | 10 | 5 |
| path-sideWalk | FeltQuad | 0 | 0 | 0 | 0 | – | – | – | – | – | 0% | 100 |  | – | 0 |
| path-sideWalk | Auto | 20 | 5 | 5 | 0 | 4.33 | 4.33 | 2.80 | 0.2 | 0.0 | 100% | 100 | cloth touches frame ×15 | 5 | 5 |
| path-partial | Auto | 20 | 25 | 25 | 0 | 1.93 | 3.60 | 0.93 | 0.3 | 0.0 | 100% | 100 | partialTable ×14 | 11 | 5 |
| path-partial | FeltQuad | 0 | 0 | 0 | 0 | – | – | – | – | – | 0% | 100 |  | – | 0 |
| path-partial | Auto | 20 | 25 | 25 | 0 | 4.70 | 7.43 | 2.80 | 0.3 | 0.0 | 100% | 100 | cloth touches frame ×14 | 6 | 5 |
| hold-portrait | Auto | 20 | 35 | 35 | 0 | 1.93 | 3.00 | 0.93 | 0.2 | 0.0 | 100% | 100 | partialTable ×9 | 10 | 20 |
| hold-portrait | FeltQuad | 0 | 0 | 0 | 0 | – | – | – | – | – | 0% | 100 |  | – | 0 |
| hold-portrait | Auto | 20 | 35 | 35 | 0 | 4.90 | 5.62 | 3.00 | 0.2 | 0.0 | 100% | 100 | cloth touches frame ×10 | 5 | 20 |
| hold-landscape | Auto | 20 | 50 | 50 | 0 | 1.93 | 9.67 | 0.93 | 0.4 | 0.0 | 100% | 100 | noFelt ×4 | 5 | 70 |
| hold-landscape | FeltQuad | 0 | 0 | 0 | 0 | – | – | – | – | – | 0% | 100 |  | – | 0 |
| hold-landscape | Auto | 20 | 40 | 40 | 0 | 4.52 | 6.75 | 2.80 | 0.4 | 0.0 | 100% | 100 | no cloth colour ×4 | 4 | 70 |
| fps-30 | Auto | 20 | 40 | 40 | 0 | 1.93 | 3.00 | 0.93 | 0.4 | 0.0 | 100% | 100 | partialTable ×7 | 9 | 35 |
| fps-30 | FeltQuad | 0 | 0 | 0 | 0 | – | – | – | – | – | 0% | 100 |  | – | 0 |
| fps-30 | Auto | 20 | 35 | 35 | 0 | 4.33 | 5.97 | 2.80 | 0.2 | 0.0 | 100% | 100 | cloth touches frame ×9 | 5 | 35 |
| fps-60 | Auto | 20 | 40 | 40 | 0 | 1.93 | 2.93 | 0.93 | 0.4 | 0.0 | 100% | 100 | partialTable ×7 | 10 | 35 |
| fps-60 | FeltQuad | 0 | 0 | 0 | 0 | – | – | – | – | – | 0% | 100 |  | – | 0 |
| fps-60 | Auto | 20 | 40 | 40 | 0 | 4.65 | 6.75 | 2.75 | 0.4 | 0.0 | 100% | 100 | cloth touches frame ×8 | 5 | 35 |
| bar-rive-combo | Auto | 20 | 5 | 5 | 0 | 5.20 | 5.20 | 4.27 | 0.4 | 0.0 | 100% | 100 | badShape ×12 | 7 | 60 |
| bar-rive-combo | FeltQuad | 0 | 0 | 0 | 0 | – | – | – | – | – | 0% | 100 |  | – | 0 |
| bar-rive-combo | Auto | 20 | 0 | 0 | 0 | – | – | – | – | – | 0% | 100 | no quad ×13 | 3 | 60 |

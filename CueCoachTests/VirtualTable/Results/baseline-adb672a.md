# Virtual table lock matrix

Generated 2026-11-07T08:31:54Z by `CueCoachTests/VirtualTable` (branch wt/virtual-qa). 540 simulated sessions × 2 locators, 10 s window each, fed through a replica of FrameTap's locating gate (0.2 s × 0.9 interval, busy flag = measured thread-CPU of convert + ingest, plane-found + tracking gating) at 30/60 fps ARKit timestamps.

- **accurate** = locked with max corner error ≤ 5 cm. **false** = locked with max corner error > 20 cm (wrong surface / wrong pose).
- **TTL** = seconds from session start (camera on) to lock, accurate locks only; *from plane* = from the first frame FrameTap handed to the locator.
- **reason** = % of non-locking sessions where the locator's own output carried a failure reason (FeltQuad's `TableEstimate` has no field for one).
- **in view** = % of sessions whose 4 cloth corners were all inside the frame at t = 1.5 s.

| condition | locator | n | lock % | accurate % | false % | TTL med (s) | TTL p90 | from plane | err med (cm) | yaw med (°) | size ok | reason % | top failure | cpu ms | in view |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| baseline | FeltQuad | 20 | 5 | 0 | 0 | – | – | – | 12.6 | 0.1 | 100% | 55 | proposer: no felt quad ×15 | 5 | 35 |
| baseline | Auto | 20 | 35 | 35 | 0 | 4.33 | 6.35 | 2.80 | 0.2 | 0.0 | 100% | 100 | cloth touches frame ×9 | 5 | 35 |
| felt-blue | FeltQuad | 20 | 10 | 0 | 0 | – | – | – | 14.6 | 0.2 | 100% | 60 | proposer: no felt quad ×16 | 5 | 35 |
| felt-blue | Auto | 20 | 40 | 40 | 0 | 4.93 | 7.93 | 2.80 | 0.4 | 0.0 | 100% | 100 | cloth touches frame ×8 | 5 | 35 |
| felt-red | FeltQuad | 20 | 5 | 0 | 0 | – | – | – | 12.3 | 0.1 | 100% | 60 | proposer: no felt quad ×17 | 5 | 35 |
| felt-red | Auto | 20 | 30 | 30 | 0 | 4.93 | 6.70 | 3.00 | 0.9 | 0.0 | 100% | 100 | cloth touches frame ×10 | 5 | 35 |
| felt-grey | FeltQuad | 20 | 10 | 0 | 0 | – | – | – | 15.0 | 0.1 | 100% | 55 | proposer: no felt quad ×15 | 5 | 35 |
| felt-grey | Auto | 20 | 0 | 0 | 0 | – | – | – | – | – | 0% | 100 | no cloth colour ×16 | 8 | 35 |
| felt-tan | FeltQuad | 20 | 5 | 0 | 0 | – | – | – | 12.3 | 0.1 | 100% | 55 | proposer: no felt quad ×14 | 5 | 35 |
| felt-tan | Auto | 20 | 20 | 20 | 0 | 4.70 | 5.62 | 2.80 | 0.5 | 0.1 | 100% | 100 | cloth touches frame ×10 | 5 | 35 |
| light-lamp | FeltQuad | 20 | 0 | 0 | 0 | – | – | – | – | – | 0% | 60 | proposer: no felt quad ×14 | 4 | 60 |
| light-lamp | Auto | 20 | 40 | 40 | 0 | 4.53 | 9.63 | 3.20 | 0.5 | 0.0 | 100% | 100 | no quad ×6 | 3 | 60 |
| light-dim | FeltQuad | 20 | 0 | 0 | 0 | – | – | – | – | – | 0% | 65 | proposer: no felt quad ×20 | 5 | 35 |
| light-dim | Auto | 20 | 0 | 0 | 0 | – | – | – | – | – | 0% | 100 | no quad ×13 | 4 | 35 |
| light-neon | FeltQuad | 20 | 0 | 0 | 0 | – | – | – | – | – | 0% | 75 | proposer: no felt quad ×20 | 5 | 25 |
| light-neon | Auto | 20 | 25 | 25 | 0 | 4.70 | 9.60 | 3.00 | 0.7 | 0.1 | 100% | 100 | cloth touches frame ×11 | 5 | 25 |
| light-cueShadow | FeltQuad | 20 | 0 | 0 | 0 | – | – | – | – | – | 0% | 60 | proposer: no felt quad ×19 | 4 | 60 |
| light-cueShadow | Auto | 20 | 0 | 0 | 0 | – | – | – | – | – | 0% | 100 | no quad ×16 | 3 | 60 |
| clutter-secondTable | FeltQuad | 20 | 5 | 0 | 0 | – | – | – | 12.7 | 0.1 | 100% | 65 | proposer: no felt quad ×16 | 5 | 35 |
| clutter-secondTable | Auto | 20 | 45 | 45 | 0 | 4.87 | 8.42 | 3.00 | 0.3 | 0.0 | 100% | 100 | cloth touches frame ×6 | 4 | 35 |
| clutter-coffeeTable | FeltQuad | 20 | 5 | 0 | 0 | – | – | – | 11.7 | 0.1 | 100% | 50 | proposer: no felt quad ×16 | 5 | 35 |
| clutter-coffeeTable | Auto | 20 | 35 | 35 | 0 | 4.25 | 5.87 | 2.75 | 0.2 | 0.0 | 100% | 100 | cloth touches frame ×9 | 5 | 35 |
| clutter-people | FeltQuad | 20 | 0 | 0 | 0 | – | – | – | – | – | 0% | 60 | proposer: no felt quad ×18 | 5 | 35 |
| clutter-people | Auto | 20 | 0 | 0 | 0 | – | – | – | – | – | 0% | 100 | no quad ×9 | 5 | 35 |
| clutter-railObjects | FeltQuad | 20 | 5 | 0 | 0 | – | – | – | 11.9 | 0.1 | 100% | 65 | proposer: no felt quad ×16 | 5 | 35 |
| clutter-railObjects | Auto | 20 | 35 | 35 | 0 | 4.48 | 5.05 | 2.80 | 0.2 | 0.0 | 100% | 100 | cloth touches frame ×8 | 5 | 35 |
| dist-1.0m | FeltQuad | 20 | 35 | 5 | 5 | 3.63 | 3.63 | 1.83 | 13.6 | 0.1 | 85% | 31 | proposer: no felt quad ×12 / FALSE: wrong pose on this table ×1 | 5 | 25 |
| dist-1.0m | Auto | 20 | 45 | 45 | 0 | 4.53 | 5.03 | 2.80 | 0.4 | 0.0 | 100% | 100 | cloth touches frame ×7 | 4 | 25 |
| dist-2.0m | FeltQuad | 20 | 0 | 0 | 0 | – | – | – | – | – | 0% | 70 | proposer: no felt quad ×20 | 5 | 60 |
| dist-2.0m | Auto | 20 | 0 | 0 | 0 | – | – | – | – | – | 0% | 100 | cloth touches frame ×12 | 6 | 60 |
| dist-3.0m | FeltQuad | 20 | 0 | 0 | 0 | – | – | – | – | – | 0% | 65 | proposer: no felt quad ×20 | 5 | 100 |
| dist-3.0m | Auto | 20 | 0 | 0 | 0 | – | – | – | – | – | 0% | 100 | cloth touches frame ×13 | 5 | 100 |
| elev-25deg | FeltQuad | 20 | 5 | 0 | 0 | – | – | – | 9.7 | 0.0 | 100% | 60 | proposer: no felt quad ×19 | 5 | 0 |
| elev-25deg | Auto | 20 | 10 | 10 | 0 | 9.47 | 9.47 | 8.00 | 0.4 | 0.0 | 100% | 100 | cloth touches frame ×13 | 5 | 0 |
| elev-45deg | FeltQuad | 20 | 0 | 0 | 0 | – | – | – | – | – | 0% | 65 | proposer: no felt quad ×20 | 5 | 0 |
| elev-45deg | Auto | 20 | 0 | 0 | 0 | – | – | – | – | – | 0% | 100 | cloth touches frame ×20 | 6 | 0 |
| elev-60deg | FeltQuad | 20 | 0 | 0 | 0 | – | – | – | – | – | 0% | 55 | proposer: no felt quad ×20 | 5 | 0 |
| elev-60deg | Auto | 20 | 0 | 0 | 0 | – | – | – | – | – | 0% | 100 | cloth touches frame ×20 | 6 | 0 |
| path-endPan | FeltQuad | 20 | 5 | 0 | 0 | – | – | – | 12.6 | 0.1 | 100% | 45 | proposer: no felt quad ×14 | 5 | 65 |
| path-endPan | Auto | 20 | 50 | 50 | 0 | 4.33 | 6.35 | 2.80 | 0.3 | 0.0 | 100% | 100 | cloth touches frame ×5 | 4 | 65 |
| path-sideWalk | FeltQuad | 20 | 5 | 0 | 0 | – | – | – | 10.2 | 0.0 | 100% | 55 | proposer: no felt quad ×19 | 5 | 5 |
| path-sideWalk | Auto | 20 | 5 | 5 | 0 | 4.33 | 4.33 | 2.80 | 0.2 | 0.0 | 100% | 100 | cloth touches frame ×15 | 5 | 5 |
| path-partial | FeltQuad | 20 | 10 | 0 | 0 | – | – | – | 12.5 | 0.1 | 100% | 60 | proposer: no felt quad ×18 | 5 | 5 |
| path-partial | Auto | 20 | 25 | 25 | 0 | 4.70 | 7.43 | 2.80 | 0.3 | 0.0 | 100% | 100 | cloth touches frame ×14 | 6 | 5 |
| hold-portrait | FeltQuad | 20 | 5 | 0 | 0 | – | – | – | 15.3 | 0.1 | 100% | 55 | proposer: no felt quad ×17 | 5 | 20 |
| hold-portrait | Auto | 20 | 35 | 35 | 0 | 4.90 | 6.35 | 3.00 | 0.2 | 0.0 | 100% | 100 | cloth touches frame ×10 | 5 | 20 |
| hold-landscape | FeltQuad | 20 | 15 | 0 | 0 | – | – | – | 12.7 | 0.1 | 100% | 45 | proposer: no felt quad ×13 | 5 | 70 |
| hold-landscape | Auto | 20 | 35 | 35 | 0 | 4.33 | 4.93 | 2.80 | 0.3 | 0.0 | 100% | 100 | cloth touches frame ×4 | 5 | 70 |
| fps-30 | FeltQuad | 20 | 5 | 0 | 0 | – | – | – | 12.6 | 0.1 | 100% | 75 | proposer: no felt quad ×15 | 5 | 35 |
| fps-30 | Auto | 20 | 35 | 35 | 0 | 4.33 | 6.17 | 2.80 | 0.2 | 0.0 | 100% | 100 | cloth touches frame ×8 | 5 | 35 |
| fps-60 | FeltQuad | 20 | 5 | 0 | 0 | – | – | – | 11.3 | 0.1 | 100% | 45 | proposer: no felt quad ×15 | 4 | 35 |
| fps-60 | Auto | 20 | 35 | 35 | 0 | 4.38 | 6.35 | 2.57 | 0.2 | 0.0 | 100% | 100 | cloth touches frame ×9 | 5 | 35 |
| bar-rive-combo | FeltQuad | 20 | 0 | 0 | 0 | – | – | – | – | – | 0% | 55 | proposer: no felt quad ×18 | 4 | 60 |
| bar-rive-combo | Auto | 20 | 0 | 0 | 0 | – | – | – | – | – | 0% | 100 | no quad ×13 | 3 | 60 |

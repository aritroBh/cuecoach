# Ball detector benchmark (D32, virtual simulations)

**Decision:** the app default stays the **hybrid detector** (`DetectorChoice.benchmarkWinner = .hybrid`), and it now ships
**new model weights, `yolo26n-sim3d-ft`**: the synth30 model fine-tuned on more realistic 3D renders. Classical-only
is the worst of the measured options; the hybrid with the new weights is best on every accuracy metric. All numbers are
on synthetic renders only; real-table accuracy is still unmeasured (see Limits).

## Setup

- **Scenes** (`tools/detector/sim3d.py`, `bench_scenes.py`, seed 32, namespace `0xD32BE7C4`). These are 136 hand-held clips × 4 frames =
  544 frames at 1920×1440 (the ARKit capture size): 120 clips with balls (3,414 balls ≥ 50 % visible) and 16 of empty cloth.
  The renderer ray-casts a pinhole camera against the cloth, cushions, rails and pockets and against true spheres
  (stripes, number discs and digits on a randomly rotated ball, measles cue balls). Lighting is 1–3 lamps or a window in
  linear light, with soft shadows, contact shading, a cloth-coloured bounce, clear-coat highlights and cloth sheen.
  - **Camera:** 1–4 m from the table at 20–80° down (40 % at 45–60°), eye 0.25–1.45 m above the cloth, 60–70° field of
    view, roll, and hand-shake jitter between frames.
  - **Scene content:** scatter, touching clusters, full racks and broken racks. A third of the clips have a cue stick
    and bridge hand (plus sometimes a second hand), a quarter have moving balls (up to 2.5 m/s, blurred), and chalk
    cubes, chalk marks and specks appear as distractors.
  - **Camera pipeline:** shake blur, lens softness, vignetting, chromatic aberration, flare and veiling glare,
    auto-exposure with ±EV error, partial white balance, shot and read noise scaled by gain, tone curve, 4:2:0 chroma,
    sharpening and JPEG quality 55–92.
- **Held out:** the bench uses its own "bench" style (nine cloth colours, two ball-set palettes and lamp layouts that
  no training render uses) and its own seed namespace. The fine-tune data is `sim3d_dataset.py` in the disjoint "train" style.
- **App code path** (`CueCoachTests/DetectorBenchTests`, opt-in, simulator "CueCoach Sim D", built with `-O`):
  - JPEG → `PixelImage(cgImage:)` (960 wide, point-sampled like the AR path) → `detect(in:geometry:feltReference:timestamp:)`.
  - The pipeline's no-LiDAR shading filter is applied when the detector asks for it.
  - Candidates are built by the app's own factory, `DetectorChoice.make()`.
  - Each clip also runs 12 frames (30 Hz) through `PerceptionPipeline`, and its confirmed tracks are scored.
- **Scoring** (`bench_score.py`):
  - **Matching:** on the table, nearest-first, within one ball diameter.
  - **Which balls count:** balls ≥ 50 % visible are required. Balls under 50 % visible are optional: matching one is
    neither a hit nor a false positive.
  - **Selection metric, fixed before measuring — identity F1:** the harmonic mean of two rates. Identity recall is
    required balls found *and* named correctly, over all required balls. Identity precision is correctly named
    detections over all detections.

## Results

Candidates: `classical` (v0 colour detector), `model` (bundled model every frame), `hybrid` (model ≤ 30 Hz of frame time,
classical between runs and on failure). The app processes ≤ 30 Hz (CapturePolicy), so the hybrid's model is always due;
`hybrid` and `model` scored identically for both weight sets and are shown once.

| metric | classical | hybrid, synth30 (old) | **hybrid, sim3d-ft (shipped)** |
|---|---|---|---|
| **identity F1 (selection metric)** | 24.2% | 42.1% | **77.5%** |
| detection recall (vis ≥ 50%) | 67.9% | 80.5% | 84.7% |
| detection precision | 50.5% | 89.1% | 99.9% |
| detection F1 | 57.9% | 84.6% | 91.7% |
| exact identity, of found balls | 41.7% | 49.7% | 84.5% |
| group (cue/8/solid/stripe), of found | 47.8% | 58.2% | 91.5% |
| wrong number claimed, of found | 46.3% | 50.3% | 15.5% |
| localisation median / p90 (cm) | 0.89 / 2.44 | 0.79 / 1.98 | 0.19 / 0.65 |
| false positives, 544 frames | 2,272 | 335 | 2 |
| false positives per empty-cloth frame | 5.86 | 1.23 | 0.02 |
| tracker (clip) identity F1 | 21.7% | 42.0% | 77.4% |
| tracker recall / precision | 73.6% / 43.4% | 87.2% / 82.3% | 89.4% / 95.7% |
| latency mean / p95, ms (simulator CPU, relative only) | 13.9 / 38.6 | 40.3 / 46.2 | 41.8 / 53.5 |

Identity F1 / recall for each condition, shipped hybrid vs classical:

| condition | classical | hybrid sim3d-ft |
|---|---|---|
| 20–32° / 32–45° / 45–60° / 60–80° down | 22 / 31 / 25 / 19% | 71 / 80 / 81 / 82% |
| 1–2 m / 2–3 m / 3–4 m | 26 / 24 / 22% | 83 / 69 / 58% |
| full rack / touching clusters | 27 / 32% | 61 / 84% |
| hand + cue in view / none | 14 / 33% | 80 / 76% |
| moving balls / camera shake / still | 24 / 20 / 27% | 76 / 76 / 79% |
| flare or sheen / none | 26 / 25% | 80 / 77% |

On the original 2D test split (400 renders, same Ultralytics val settings for both), mAP50 rose from 0.873 to 0.983 and mAP50–95
from 0.689 to 0.755, so the fine-tune did not trade away the old domain.

### Why the old model lost

The synth30 model found balls well (80.5 % recall) but named half of them wrong. The top confusions were a solid read as
its same-colour stripe (6→14, 2→10, 4→12, 5→13, 1→9) and a stripe seen with its band edge-on read as the cue ball
(10/14/15→cue). Its 2D training renders always show a flat band and a centred number. Once its training renders showed
the 3D look (a rotated band, a number disc off-centre or hidden), identity accuracy of found balls went from 49.7 % to
84.5 %.

## Choice and why

**Hybrid + `yolo26n-sim3d-ft`.** It is best on the selection metric (77.5 % vs 42.1 % and 24.2 %) and on every accuracy
row. It is near-perfect on empty cloth (2 false positives in 544 frames vs 2,272 for classical), and it keeps the classical
fallback if inference fails. The hybrid and the model-every-frame variant tie because the app never runs the detector
above 30 Hz. The hybrid is kept for its fallback. Classical costs about a third of the simulator time, but the simulator
runs Core ML on the CPU, so the ~40 ms there says nothing about the ANE. The 30 Hz device budget still needs a phone run.

Wiring: `DetectorChoice` (CoreMLBallDetector.swift) builds every candidate, and both the app factory
(`PerceptionPipeline.defaultDetector`) and the bench use it. `BallDetector.json` records the weights and the benchmark
(`DetectorChoiceTests`).

## Limits

- **Synthetic only.** No real footage was used. The fine-tune and the bench share the renderer family, with held-out
  styles and seeds only. Part of the gain is renderer familiarity, so the 77.5 % is an upper bound for real tables.
  The ranking (model ≫ classical; the 3D fine-tune ≫ the 2D-only model on both test sets) is the robust finding. Re-run
  the bench on labelled real footage when it exists (D32).
- **Not modelled:** lamp shades or people in view, real cloth weave and wear, ball scuffs and dirt, logo and odd ball
  sets, rolling-shutter skew, HDR and night-mode processing, LiDAR. The Kalman tracker sees 12-frame clips, not full
  shots.
- **Weak spots still visible:** 3–4 m (58 % identity F1), full racks (61 %, small touching balls), and over-exposed
  frames.
- **Latency is simulator CPU time** and only relative. ANE latency on the iPhone 15 Pro Max is unmeasured.
- **Single-frame bench:** it passes no lock-time cloth reference (`feltReference: nil`), which slightly understates
  classical under coloured light.

Reproduce: `tools/detector/README.md` ("D32 virtual-sim benchmark").

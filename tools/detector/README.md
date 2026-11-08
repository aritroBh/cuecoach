# CueCoach detector

Python 3.12 pipeline for a 16-class YOLO26n pool-ball detector. A single class-specific model keeps inference to one pass; tracker-side smoothing is still needed when a ball number is hidden or too small to read.

## Setup and run

```sh
uv sync --python 3.12
uv run --python 3.12 python generate_dataset.py --train 2400 --val 400 --test 400 --seed 20261106
uv run --python 3.12 python train.py --epochs 8 --batch 12 --name yolo26n-synthetic-quick
uv run --python 3.12 python evaluate.py --model runs/detect/yolo26n-synthetic-quick/weights/best.pt
uv run --python 3.12 python export_coreml.py --weights runs/detect/yolo26n-synthetic-quick/weights/best.pt
uv run --python 3.12 pytest
```

The generator writes 3,200 seed-reproducible scenes by default under ignored `data/synthetic/`. It draws the WPA-size 57.15 mm ball set with the standard 1–7 solids, 8, 9–15 stripes, and cue ball; labels are normalized YOLO boxes. Table cloth, elevation, camera roll, lighting, occlusion, blur, noise, and ball placement vary per scene.

`train.py` uses MPS when available and starts from `yolo26n.pt`. Override `--model` with local weights to train offline. `evaluate.py` reports mAP50 and mAP50–95 on the held-out synthetic test split and on each compatible dataset YAML under `tools/datasets/`; pass `--real-data path/to/data.yaml` to select a dataset explicitly.

## Real data

The import hook refuses projects with a missing or unrecognized license. It allows CC BY 2.0/3.0/4.0, CC0 1.0, and Public Domain; it records project/version/license/attribution in `DATASETS.md` and a local manifest. The downloaded dataset stays under the root ignored `tools/datasets/`. Use it with this 16-class model only after mapping its class order to `cue, 1, ..., 15`.

Put personal videos under the root ignored `tools/footage/`, then extract review frames with:

```sh
uv run --python 3.12 python ingest_footage.py --every-n-frames 15
```

Frames and timestamps go to ignored `data/footage_frames/`; they are unlabeled and ready for manual or later detector-assisted proposals.

## Core ML and limits

`export_coreml.py` writes `CueCoach/Resources/Models/BallDetector.mlpackage` and a small adjacent `BallDetector.json`. The model is static 640×640, FP16, with embedded NMS; export stops if the package exceeds 15 MB. The local smoke test loads the package and runs one generated scene. This repo worker has no iPhone 15 Pro attached, so the 30+ FPS target still needs a sustained device benchmark.

Ultralytics states that its code and trained models use AGPL-3.0 by default; a commercial/proprietary deployment needs an Enterprise license. See [Ultralytics licensing](https://www.ultralytics.com/license) before shipping.

#!/usr/bin/env python3
"""Measure held-out pose error in pixels and as a fraction of table diagonal."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np
import torch
from ultralytics import YOLO


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--weights", type=Path, required=True)
    parser.add_argument("--data", type=Path, default=Path(__file__).parent / "data" / "synthetic" / "dataset.yaml")
    parser.add_argument("--split", choices=("val", "test"), default="test")
    parser.add_argument("--device", default="auto")
    args = parser.parse_args()
    if not args.weights.is_file() or not args.data.is_file():
        parser.error("--weights and --data must exist")

    config = json.loads(args.data.read_text())
    image_dir = Path(config["path"]) / config[args.split]
    images = sorted(image_dir.glob("*.jpg"))
    if not images:
        parser.error(f"no test images found in {image_dir}")
    device = args.device if args.device != "auto" else ("mps" if torch.backends.mps.is_available() else "cpu")
    model = YOLO(str(args.weights))
    predictions = model.predict(source=[str(path) for path in images], imgsz=640, device=device,
                                stream=True, verbose=False, conf=0.001)
    errors, normalized, detected = [], [], 0
    for image_path, result in zip(images, predictions):
        values = np.fromstring(image_path.with_suffix(".txt").read_text(), sep=" ", dtype=float)
        truth = values[5:].reshape(10, 3)
        visible = truth[:, 2] > 0
        nose = truth[6:, :2] * 640
        diagonal = max(np.linalg.norm(nose[0] - nose[2]), np.linalg.norm(nose[1] - nose[3]), 1.0)
        if result.boxes is None or len(result.boxes) == 0:
            error = np.full((int(visible.sum()),), diagonal)
        else:
            classes = result.boxes.cls.cpu().numpy()
            confidence = result.boxes.conf.cpu().numpy()
            candidates = np.flatnonzero(classes == 0)
            if not len(candidates):
                error = np.full((int(visible.sum()),), diagonal)
            else:
                best = int(candidates[np.argmax(confidence[candidates])])
                prediction = result.keypoints.xyn[best].cpu().numpy() * 640
                error = np.linalg.norm(prediction[visible] - truth[visible, :2] * 640, axis=1)
                detected += 1
        errors.extend(error.tolist())
        normalized.extend((error / diagonal * 100).tolist())
    report = {"images": len(images), "detected": detected, "detection_rate": detected / len(images),
              "median_keypoint_error_px": float(np.median(errors)),
              "median_keypoint_error_pct_table_diagonal": float(np.median(normalized))}
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()

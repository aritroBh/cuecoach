#!/usr/bin/env python3
"""Train YOLO26n-pose; pass an annotated real-frame dataset YAML to fine-tune."""

from __future__ import annotations

import argparse
from pathlib import Path

import torch
from ultralytics import YOLO


HERE = Path(__file__).resolve().parent


def choose_device(requested: str) -> str:
    if requested != "auto":
        return requested
    return "mps" if torch.backends.mps.is_available() else "cpu"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data", type=Path, default=HERE / "data" / "synthetic" / "dataset.yaml",
                        help="YOLO pose YAML; use tools/footage/tablekeypoints/dataset.yaml to fine-tune on labeled real frames")
    parser.add_argument("--model", default="yolo26n-pose.pt", help="pretrained checkpoint or prior best.pt")
    parser.add_argument("--epochs", type=int, default=80)
    parser.add_argument("--batch", type=int, default=12)
    parser.add_argument("--workers", type=int, default=4)
    parser.add_argument("--seed", type=int, default=20261106)
    parser.add_argument("--device", default="auto", help="auto, mps, or cpu")
    parser.add_argument("--name", default="yolo26n-table-keypoints")
    args = parser.parse_args()
    if args.epochs < 1 or args.batch < 1 or not args.data.is_file():
        parser.error("epochs and batch must be positive and --data must exist")
    device = choose_device(args.device)
    model = YOLO(args.model)
    result = model.train(
        data=str(args.data.resolve()), imgsz=640, epochs=args.epochs, batch=args.batch,
        workers=args.workers, device=device, seed=args.seed, deterministic=True,
        fliplr=0.0, project=str(HERE / "runs"), name=args.name, exist_ok=False,
        patience=max(10, min(30, args.epochs // 3)), plots=True, verbose=True,
    )
    print(f"Best checkpoint: {Path(result.save_dir) / 'weights' / 'best.pt'}")
    print(f"Training device: {device}")


if __name__ == "__main__":
    main()

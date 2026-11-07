#!/usr/bin/env python3
"""Fine-tune YOLO26n on a YOLO-format pool-ball dataset."""

from __future__ import annotations

import argparse
from pathlib import Path

import torch
from ultralytics import YOLO


HERE = Path(__file__).parent


def choose_device(requested: str) -> str:
    if requested != "auto":
        return requested
    return "mps" if torch.backends.mps.is_available() else "cpu"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data", type=Path, default=HERE / "data" / "synthetic" / "dataset.yaml")
    parser.add_argument("--model", default="yolo26n.pt", help="YOLO26n checkpoint or compatible local weights")
    parser.add_argument("--epochs", type=int, default=60)
    parser.add_argument("--batch", type=int, default=12)
    parser.add_argument("--imgsz", type=int, default=640)
    parser.add_argument("--workers", type=int, default=4)
    parser.add_argument("--seed", type=int, default=20261106)
    parser.add_argument("--device", default="auto", help="auto, mps, or cpu")
    parser.add_argument("--name", default="yolo26n-pool")
    args = parser.parse_args()
    if args.epochs < 1 or args.batch < 1 or args.imgsz != 640:
        parser.error("epochs and batch must be positive; this pipeline exports at imgsz 640")
    if not args.data.is_file():
        parser.error(f"dataset YAML does not exist: {args.data}")
    device = choose_device(args.device)
    model = YOLO(args.model)
    result = model.train(
        data=str(args.data.resolve()),
        imgsz=args.imgsz,
        epochs=args.epochs,
        batch=args.batch,
        workers=args.workers,
        device=device,
        seed=args.seed,
        deterministic=True,
        project=str(HERE / "runs" / "detect"),
        name=args.name,
        exist_ok=False,
        patience=max(8, min(30, args.epochs // 3)),
        plots=True,
        verbose=True,
    )
    run_dir = Path(result.save_dir)
    print(f"Best checkpoint: {run_dir / 'weights' / 'best.pt'}")
    print(f"Training device: {device}")


if __name__ == "__main__":
    main()

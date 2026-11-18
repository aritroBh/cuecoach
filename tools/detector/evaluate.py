#!/usr/bin/env python3
"""Report mAP50 for the held-out synthetic split and any imported real datasets."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import yaml
from ultralytics import YOLO

from train import choose_device


ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).parent


def evaluate(model: YOLO, dataset_yaml: Path, device: str, imgsz: int) -> dict:
    config = yaml.safe_load(dataset_yaml.read_text())
    split = "test" if config.get("test") else "val"
    metrics = model.val(data=str(dataset_yaml), split=split, imgsz=imgsz, device=device, plots=False, verbose=False)
    return {
        "dataset": str(dataset_yaml),
        "split": split,
        "map50": float(metrics.box.map50),
        "map50_95": float(metrics.box.map),
        "precision": float(metrics.box.mp),
        "recall": float(metrics.box.mr),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--synthetic", type=Path, default=HERE / "data" / "synthetic" / "dataset.yaml")
    parser.add_argument("--real-data", type=Path, action="append", help="repeat for each compatible real-data YAML")
    parser.add_argument("--device", default="auto")
    parser.add_argument("--imgsz", type=int, default=640)
    parser.add_argument("--out", type=Path, default=HERE / "runs" / "eval" / "metrics.json")
    args = parser.parse_args()
    if not args.model.is_file():
        parser.error(f"model checkpoint does not exist: {args.model}")
    if not args.synthetic.is_file():
        parser.error(f"synthetic dataset YAML does not exist: {args.synthetic}")
    real_data = args.real_data if args.real_data is not None else sorted((ROOT / "tools" / "datasets").glob("**/data.yaml"))
    model = YOLO(str(args.model))
    device = choose_device(args.device)
    reports = [evaluate(model, args.synthetic, device, args.imgsz)]
    reports.extend(evaluate(model, path, device, args.imgsz) for path in real_data if path.is_file())
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps({"device": device, "results": reports}, indent=2) + "\n")
    for report in reports:
        print(f"{report['dataset']} ({report['split']}): mAP50={report['map50']:.4f}")
    print(f"Metrics written to {args.out}")


if __name__ == "__main__":
    main()

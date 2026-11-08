#!/usr/bin/env python3
"""Export trained YOLO weights as a compact FP16 Core ML package with NMS."""

from __future__ import annotations

import argparse
import json
import shutil
from pathlib import Path

import coremltools as ct
from ultralytics import YOLO


ROOT = Path(__file__).resolve().parents[2]
DESTINATION = ROOT / "CueCoach" / "Resources" / "Models" / "BallDetector.mlpackage"
METADATA = ROOT / "CueCoach" / "Resources" / "Models" / "BallDetector.json"
MAX_MODEL_BYTES = 15_000_000


def model_names(names) -> list[str]:
    if isinstance(names, dict):
        return [str(names[index]) for index in sorted(names)]
    return [str(name) for name in names]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--weights", type=Path, required=True)
    parser.add_argument("--out", type=Path, default=DESTINATION)
    parser.add_argument("--max-mb", type=float, default=15)
    parser.add_argument("--overwrite", action="store_true")
    args = parser.parse_args()
    if not args.weights.is_file():
        parser.error(f"checkpoint does not exist: {args.weights}")
    output = args.out.resolve()
    if output.suffix != ".mlpackage":
        parser.error("output path must end with .mlpackage")
    metadata_path = output.with_suffix(".json")
    if (output.exists() or metadata_path.exists()) and not args.overwrite:
        parser.error(f"{output} or its metadata already exists; pass --overwrite to replace")

    model = YOLO(str(args.weights))
    names = model_names(model.names)
    exported = Path(
        model.export(
            format="coreml",
            imgsz=640,
            quantize=16,
            nms=True,
            dynamic=False,
            device="cpu",
            conf=0.01,
            iou=0.6,
            max_det=100,
        )
    )
    size_bytes = sum(item.stat().st_size for item in exported.rglob("*") if item.is_file())
    if size_bytes > args.max_mb * 1_000_000:
        raise RuntimeError(f"FP16 package is {size_bytes / 1_000_000:.2f} MB, above the {args.max_mb:g} MB limit")
    if output.exists():
        shutil.rmtree(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(exported, output)
    mlmodel = ct.models.MLModel(str(output), compute_units=ct.ComputeUnit.CPU_ONLY)
    spec = mlmodel.get_spec()
    image_inputs = [item for item in spec.description.input if item.type.WhichOneof("Type") == "imageType"]
    if not image_inputs or image_inputs[0].type.imageType.width != 640 or image_inputs[0].type.imageType.height != 640:
        raise RuntimeError("exported package does not have a 640x640 image input")
    metadata = {"input_size": 640, "classes": names}
    metadata_path.write_text(json.dumps(metadata, separators=(",", ":")) + "\n")
    final_size = sum(item.stat().st_size for item in output.rglob("*") if item.is_file())
    print(f"Exported {output} ({final_size / 1_000_000:.2f} MB, FP16, embedded NMS)")
    print(f"Class metadata: {metadata_path}")


if __name__ == "__main__":
    main()

import json
from pathlib import Path

import pytest

from generate_dataset import render_scene

ct = pytest.importorskip("coremltools")
Image = pytest.importorskip("PIL.Image")

ROOT = Path(__file__).resolve().parents[3]
MODEL_PATH = ROOT / "CueCoach" / "Resources" / "Models" / "BallDetector.mlpackage"
METADATA_PATH = ROOT / "CueCoach" / "Resources" / "Models" / "BallDetector.json"


def test_coreml_model_loads_and_returns_boxes_for_a_rendered_table():
    metadata = json.loads(METADATA_PATH.read_text())
    assert metadata["input_size"] == 640
    assert len(metadata["classes"]) == 16

    model = ct.models.MLModel(str(MODEL_PATH), compute_units=ct.ComputeUnit.CPU_ONLY)
    spec = model.get_spec()
    image_input = next(item for item in spec.description.input if item.type.WhichOneof("Type") == "imageType")
    image, _ = render_scene(seed=73)
    prediction = model.predict({image_input.name: Image.fromarray(image, mode="RGB")})

    assert prediction
    assert "coordinates" in prediction
    assert "confidence" in prediction
    assert prediction["coordinates"].shape[-1] == 4
    # Ultralytics' Core ML NMS pipeline pads class scores to 80 (COCO width); extra columns must be zero
    # and the app reads only the first len(classes) columns.
    n = len(metadata["classes"])
    assert prediction["confidence"].shape[-1] >= n
    assert prediction["confidence"][:, n:].max(initial=0) == 0
    assert prediction["confidence"].max() > 0

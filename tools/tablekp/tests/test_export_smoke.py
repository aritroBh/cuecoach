import json
from pathlib import Path

import numpy as np
import pytest

ct = pytest.importorskip("coremltools")
Image = pytest.importorskip("PIL.Image")

from generate_dataset import render_scene


ROOT = Path(__file__).resolve().parents[3]
MODEL_PATH = ROOT / "CueCoach" / "Resources" / "Models" / "TableKeypoints.mlpackage"
METADATA_PATH = MODEL_PATH.with_suffix(".json")


@pytest.mark.skipif(not MODEL_PATH.exists(), reason="run export_coreml.py after training")
def test_coreml_pose_package_loads_and_returns_table_keypoints():
    metadata = json.loads(METADATA_PATH.read_text())
    assert metadata["input"] == {"width": 640, "height": 640, "color": "RGB"}
    assert len(metadata["keypoints"]) == 10
    assert metadata["precision"] == "FP16"

    model = ct.models.MLModel(str(MODEL_PATH), compute_units=ct.ComputeUnit.CPU_ONLY)
    image_input = next(item for item in model.get_spec().description.input if item.type.WhichOneof("Type") == "imageType")
    image = Image.fromarray(render_scene(73).image)
    prediction = model.predict({image_input.name: image})
    arrays = [np.asarray(value) for value in prediction.values() if hasattr(value, "shape")]

    assert arrays
    assert any(array.ndim >= 2 and any(dimension >= 20 for dimension in array.shape) for array in arrays)
    assert all(np.isfinite(array).all() for array in arrays)


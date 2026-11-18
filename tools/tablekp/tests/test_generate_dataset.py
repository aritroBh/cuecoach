import json

import cv2
import numpy as np

from generate_dataset import format_yolo_label, generate_split, render_scene


def test_pose_labels_are_the_projected_rendered_geometry():
    scene = render_scene(seed=417)
    projected = cv2.perspectiveTransform(
        scene.source_keypoints.astype(np.float32).reshape(-1, 1, 2), scene.homography
    ).reshape(-1, 2)
    length_in = {7: 80, 8: 92, 9: 100}[scene.table_size_ft]
    mouth_offset = (1160 - 120) / length_in * 2.25

    assert scene.image.shape == (640, 640, 3)
    assert scene.pose_label[0] == 0
    assert len(scene.pose_label) == 5 + 10 * 3
    center_x, center_y, box_w, box_h = scene.pose_label[1:5]
    assert 0 <= center_x <= 1 and 0 <= center_y <= 1
    assert 0 < box_w <= 1 and 0 < box_h <= 1
    assert center_x - box_w / 2 >= 0 and center_x + box_w / 2 <= 1
    assert center_y - box_h / 2 >= 0 and center_y + box_h / 2 <= 1
    np.testing.assert_allclose(projected, scene.keypoints_px, atol=0.01)
    np.testing.assert_allclose(np.abs(scene.source_keypoints[:4] - scene.source_keypoints[6:]), mouth_offset, atol=0.01)
    np.testing.assert_array_equal(np.sort(scene.source_keypoints[4:6, 1]), [100, 620])
    for index, (x, y, visibility) in enumerate(np.asarray(scene.pose_label[5:]).reshape(10, 3)):
        if visibility:
            np.testing.assert_allclose((x * 640, y * 640), projected[index], atol=0.001)
        else:
            assert (x, y) == (0, 0)
    fields = np.fromstring(format_yolo_label(scene), sep=" ")
    assert len(fields) == 35
    np.testing.assert_allclose(fields, scene.pose_label, atol=0.0000005)


def test_scene_rendering_is_deterministic():
    first, second = render_scene(20261106), render_scene(20261106)
    assert np.array_equal(first.image, second.image)
    assert first.pose_label == second.pose_label
    assert first.camera_mode == second.camera_mode


def test_dataset_has_yolo_pose_metadata_and_repeatable_splits(tmp_path):
    output = tmp_path / "dataset"
    generate_split(output, train=1, val=1, test=1, seed=91)
    first_image = (output / "images/train/00000.jpg").read_bytes()
    metadata = json.loads((output / "dataset.yaml").read_text())
    row = (output / "labels/train/00000.txt").read_text().split()

    assert metadata["kpt_shape"] == [10, 3]
    assert metadata["names"] == ["table"]
    assert len(row) == 35
    generate_split(output, train=1, val=1, test=1, seed=91, overwrite=True)
    assert (output / "images/train/00000.jpg").read_bytes() == first_image


def test_seeded_batch_contains_crops_and_occluded_keypoints():
    scenes = [render_scene(seed) for seed in range(64)]
    values = {value for scene in scenes for value in scene.keypoint_visibility}
    assert 0 in values
    assert 1 in values
    assert {scene.table_size_ft for scene in scenes} == {7, 8, 9}
    assert {scene.camera_mode for scene in scenes} == {"tripod", "handheld"}


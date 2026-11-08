import numpy as np

from generate_dataset import CLASS_NAMES, render_scene, validate_labels


def test_rendered_boxes_are_valid_and_match_image_bounds():
    image, labels = render_scene(seed=417)

    assert image.shape == (640, 640, 3)
    assert image.dtype == np.uint8
    assert len(labels) >= 2
    validate_labels(labels, width=640, height=640)

    for class_id, center_x, center_y, box_width, box_height in labels:
        assert 0 <= class_id < len(CLASS_NAMES)
        assert 0 < box_width <= 1
        assert 0 < box_height <= 1
        assert box_width <= 2 * min(center_x, 1 - center_x) + 1e-6
        assert box_height <= 2 * min(center_y, 1 - center_y) + 1e-6


def test_rendering_is_repeatable_for_the_same_seed():
    image_a, labels_a = render_scene(seed=20261106)
    image_b, labels_b = render_scene(seed=20261106)

    assert np.array_equal(image_a, image_b)
    assert labels_a == labels_b

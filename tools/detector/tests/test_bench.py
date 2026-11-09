import math

import numpy as np

import bench_scenes
import bench_score
import sim3d


def test_bench_seeds_are_their_own_namespace_and_deterministic():
    a = bench_scenes.clip_rng(32, 0).integers(0, 2**31, 4)
    b = bench_scenes.clip_rng(32, 0).integers(0, 2**31, 4)
    training = np.random.default_rng(np.random.SeedSequence([20261106, 0, 0])).integers(0, 2**31, 4)
    assert (a == b).all() and not (a == training).all()


def test_bench_and_train_styles_share_no_cloth_or_ball_palette():
    assert not set(sim3d.CLOTH["bench"].values()) & set(sim3d.CLOTH["train"].values())
    bench_sets = {tuple(sorted(s.items())) for s in sim3d.BALL_SETS["bench"]}
    train_sets = {tuple(sorted(s.items())) for s in sim3d.BALL_SETS["train"]}
    assert not bench_sets & train_sets


def test_projection_matches_the_app_camera_convention():
    cam = sim3d.Camera.look_at([1.0, -1.5, 1.2], [1.0, 0.5, 0.0], 65)
    u, v, z = cam.project([1.0, 0.5, 0.0])
    assert abs(u - cam.width / 2) < 1e-6 and abs(v - cam.height / 2) < 1e-6 and z > 0
    # A point farther along +y (away from the camera, on the table) sits higher in the image (smaller v).
    _, v2, _ = cam.project([1.0, 1.0, 0.0])
    assert v2 < v


def test_render_ground_truth_lands_on_the_ball_pixels():
    rng = np.random.default_rng(1)
    scene = sim3d.make_scene(rng)
    scene.balls = [sim3d.Ball(0, 1.0, 0.5)]
    cam = sim3d.Camera.look_at([1.0, -0.8, 1.0], [1.0, 0.5, 0.0], 65, width=640, height=480)
    img, truth, _ = sim3d.render(scene, cam, rng, post={"flare": False, "shake_px": 0, "ev": 0, "jpeg": 95})
    u, v = truth[0]["image"]
    assert truth[0]["visible"] > 0.95
    assert img[int(v), int(u)].mean() > 140  # the white cue ball is bright at its projected centre


def test_match_is_greedy_nearest_within_a_diameter():
    truth = [{"x": 0.0, "y": 0.0}, {"x": 0.06, "y": 0.0}]
    dets = [{"x": 0.055, "y": 0.0}, {"x": 0.5, "y": 0.5}]
    m = bench_score.match(truth, dets)
    assert [(i, j) for i, j, _ in m] == [(1, 0)]
    assert math.isclose(m[0][2], 0.005, abs_tol=1e-9)


def test_tally_counts_identity_and_false_positives():
    truth = [{"number": 3, "x": 0.0, "y": 0.0, "visible": 1.0, "image": [0, 0]},
             {"number": 11, "x": 0.5, "y": 0.0, "visible": 0.3, "image": [0, 0]}]
    dets = [{"x": 0.0, "y": 0.0, "kind": "solid", "number": 3},
            {"x": 0.5, "y": 0.0, "kind": "stripe", "number": 11},   # optional: neither hit nor FP
            {"x": 1.0, "y": 0.0, "kind": "unknown", "number": -1}]  # FP
    t = bench_score.Tally()
    t.add(truth, dets)
    r = t.row()
    assert r["required"] == 1 and r["recall"] == 1 and r["fp"] == 1
    assert r["id_recall"] == 1 and math.isclose(r["id_precision"], 0.5)

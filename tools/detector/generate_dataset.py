#!/usr/bin/env python3
"""Render deterministic, license-safe pool-table scenes in YOLO format."""

from __future__ import annotations

import argparse
import json
import math
import shutil
from pathlib import Path

import cv2
import numpy as np


CLASS_NAMES = ["cue", *[str(number) for number in range(1, 16)]]
IMAGE_SIZE = 640
CANVAS_WIDTH, CANVAS_HEIGHT = 1320, 700
SURFACE = (70, 55, 1250, 645)
BALL_DIAMETER_MM = 57.15
TABLE_LENGTH_IN = (80, 92, 100)
SURFACE_COLORS = {
    "green": (68, 112, 27),
    "blue": (145, 92, 40),
    "red": (49, 43, 112),
    "grey": (108, 103, 100),
}
BALL_COLORS = {
    1: (28, 190, 242),
    2: (188, 83, 44),
    3: (48, 39, 202),
    4: (140, 53, 111),
    5: (22, 104, 235),
    6: (68, 126, 39),
    7: (47, 41, 107),
    8: (27, 27, 30),
    9: (28, 190, 242),
    10: (188, 83, 44),
    11: (48, 39, 202),
    12: (140, 53, 111),
    13: (22, 104, 235),
    14: (68, 126, 39),
    15: (47, 41, 107),
}


def validate_labels(labels: list[tuple[int, float, float, float, float]], width: int, height: int) -> None:
    """Reject malformed or out-of-frame normalized YOLO boxes."""
    if width <= 0 or height <= 0:
        raise ValueError("image dimensions must be positive")
    for row, label in enumerate(labels, start=1):
        if len(label) != 5:
            raise ValueError(f"label {row} must have class, center x/y, and width/height")
        class_id, center_x, center_y, box_width, box_height = label
        if isinstance(class_id, bool) or not isinstance(class_id, (int, np.integer)):
            raise ValueError(f"label {row} has a non-integer class id")
        if not 0 <= class_id < len(CLASS_NAMES):
            raise ValueError(f"label {row} has unknown class id {class_id}")
        values = (center_x, center_y, box_width, box_height)
        if not all(math.isfinite(float(value)) for value in values):
            raise ValueError(f"label {row} has non-finite coordinates")
        if not 0 <= center_x <= 1 or not 0 <= center_y <= 1 or not 0 < box_width <= 1 or not 0 < box_height <= 1:
            raise ValueError(f"label {row} is outside normalized image bounds")
        if center_x - box_width / 2 < -1e-6 or center_x + box_width / 2 > 1 + 1e-6:
            raise ValueError(f"label {row} extends beyond image width")
        if center_y - box_height / 2 < -1e-6 or center_y + box_height / 2 > 1 + 1e-6:
            raise ValueError(f"label {row} extends beyond image height")


def _make_table(rng: np.random.Generator) -> np.ndarray:
    x0, y0, x1, y1 = SURFACE
    table = np.zeros((CANVAS_HEIGHT, CANVAS_WIDTH, 4), dtype=np.uint8)
    wood = rng.choice(
        np.array([(31, 44, 77), (42, 67, 113), (40, 44, 48), (65, 105, 150)], dtype=np.uint8)
    )
    cv2.rectangle(table, (x0 - 58, y0 - 48), (x1 + 58, y1 + 48), (*map(int, wood), 255), -1)
    cushion = tuple(int(channel * 0.55) for channel in wood)
    cv2.rectangle(table, (x0 - 13, y0 - 13), (x1 + 13, y1 + 13), (*cushion, 255), -1)

    color = np.array(rng.choice(list(SURFACE_COLORS.values())), dtype=np.float32)
    region_w, region_h = x1 - x0, y1 - y0
    xx, yy = np.meshgrid(np.linspace(-1, 1, region_w), np.linspace(-1, 1, region_h))
    light_x, light_y = rng.uniform(-0.8, 0.8, size=2)
    light = 0.82 + 0.18 * np.exp(-((xx - light_x) ** 2 + (yy - light_y) ** 2) / rng.uniform(0.35, 1.0))
    light += rng.uniform(-0.12, 0.12) * xx + rng.uniform(-0.12, 0.12) * yy
    texture = rng.normal(0, rng.uniform(1.5, 6.0), (region_h, region_w, 1))
    felt = np.clip(color[None, None, :] * light[:, :, None] + texture, 0, 255).astype(np.uint8)
    table[y0:y1, x0:x1, :3] = felt
    table[y0:y1, x0:x1, 3] = 255

    pocket_r = 28
    pockets = [(x0, y0), ((x0 + x1) // 2, y0), (x1, y0), (x0, y1), ((x0 + x1) // 2, y1), (x1, y1)]
    for px, py in pockets:
        cv2.ellipse(table, (px, py), (pocket_r + 7, pocket_r + 4), 0, 0, 360, (12, 13, 15, 255), -1)
        cv2.ellipse(table, (px, py), (pocket_r, pocket_r - 3), 0, 0, 360, (2, 3, 4, 255), -1)
        cv2.ellipse(table, (px - 4, py - 5), (pocket_r // 2, pocket_r // 3), -18, 0, 180, (34, 33, 31, 255), 2)

    rail_color = tuple(int(channel * 0.86) for channel in wood)
    for fraction in np.linspace(0.13, 0.87, 7):
        px = round(x0 + fraction * region_w)
        for py in (y0 - 32, y1 + 32):
            cv2.circle(table, (px, py), 4, (*rail_color, 255), -1)
        py = round(y0 + fraction * region_h)
        for px in (x0 - 32, x1 + 32):
            cv2.circle(table, (px, py), 4, (*rail_color, 255), -1)
    return table


def _camera_quad(rng: np.random.Generator, width: int, height: int) -> tuple[np.ndarray, float]:
    elevation = float(rng.uniform(15, 60))
    yaw = math.radians(float(rng.uniform(-25, 25)))
    elevation_radians = math.radians(elevation)
    # Project a 2:1 table from a side tripod; yaw adds realistic depth at oblique views.
    horizontal_span = math.sqrt((math.cos(yaw) * 2) ** 2 + (math.sin(yaw) * 1) ** 2)
    depth_span = math.sin(elevation_radians) * math.sqrt((math.sin(yaw) * 2) ** 2 + (math.cos(yaw) * 1) ** 2)
    ratio = float(np.clip(depth_span / horizontal_span, 0.13, 0.75))
    table_width = float(rng.uniform(0.83, 0.89) * min(width, height))
    table_height = table_width * ratio
    center_x = width / 2 + float(rng.uniform(-12, 12))
    center_y = height / 2 + float(rng.uniform(-38, 34))
    far_scale = float(rng.uniform(0.72, 0.94))
    skew = float(rng.uniform(-0.07, 0.07) * table_width)
    far_center = center_x + skew
    near_center = center_x - skew * 0.35
    far_y = center_y - table_height / 2
    near_y = center_y + table_height / 2
    quad = np.array(
        [
            (far_center - table_width * far_scale / 2, far_y),
            (far_center + table_width * far_scale / 2, far_y),
            (near_center + table_width / 2, near_y),
            (near_center - table_width / 2, near_y),
        ],
        dtype=np.float32,
    )
    roll = math.radians(float(rng.uniform(-9, 9) if rng.random() < 0.28 else rng.uniform(-2.5, 2.5)))
    rotation = np.array([[math.cos(roll), -math.sin(roll)], [math.sin(roll), math.cos(roll)]])
    quad = (quad - np.array([[center_x, center_y]], dtype=np.float32)) @ rotation.T
    quad += np.array([[center_x, center_y]], dtype=np.float32)
    return quad.astype(np.float32), table_width


def _map_points(matrix: np.ndarray, points: list[tuple[float, float]]) -> np.ndarray:
    points_array = np.array(points, dtype=np.float32).reshape((-1, 1, 2))
    return cv2.perspectiveTransform(points_array, matrix).reshape((-1, 2))


def _ball_positions(rng: np.random.Generator, count: int, radius: float) -> list[tuple[int, float, float]]:
    x0, y0, x1, y1 = SURFACE
    pocket_margin = 43 + radius
    pocket_centers = [
        (x0, y0), ((x0 + x1) / 2, y0), (x1, y0),
        (x0, y1), ((x0 + x1) / 2, y1), (x1, y1),
    ]
    balls: list[tuple[int, float, float]] = []
    class_ids = [0, *rng.choice(np.arange(1, 16), size=count - 1, replace=False).tolist()]
    rng.shuffle(class_ids)

    for index, class_id in enumerate(class_ids):
        for attempt in range(800):
            if index > 1 and rng.random() < 0.34:
                _, base_x, base_y = balls[int(rng.integers(0, len(balls)))]
                angle = float(rng.uniform(0, math.tau))
                distance = 2 * radius * float(rng.uniform(0.98, 1.18))
                x = base_x + math.cos(angle) * distance
                y = base_y + math.sin(angle) * distance
            else:
                x = float(rng.uniform(x0 + 2 * radius, x1 - 2 * radius))
                y = float(rng.uniform(y0 + 2 * radius, y1 - 2 * radius))
            if any(math.dist((x, y), center) < pocket_margin for center in pocket_centers):
                continue
            if any(math.dist((x, y), (bx, by)) < 2 * radius * 0.96 for _, bx, by in balls):
                continue
            balls.append((int(class_id), x, y))
            break
        else:
            # ponytail: cap placement retries; dense racks can drop a ball instead of growing a spatial index.
            continue
    if len(balls) < 2:
        raise RuntimeError("could not place the cue ball and an object ball")
    return balls


def _paint_ball(image: np.ndarray, x: float, y: float, radius: int, class_id: int, rng: np.random.Generator) -> None:
    cx, cy = int(round(x)), int(round(y))
    radius = max(radius, 4)
    x0, x1 = max(0, cx - radius - 1), min(image.shape[1], cx + radius + 2)
    y0, y1 = max(0, cy - radius - 1), min(image.shape[0], cy + radius + 2)
    if x0 >= x1 or y0 >= y1:
        return
    yy, xx = np.mgrid[y0:y1, x0:x1]
    dx, dy = (xx - cx) / radius, (yy - cy) / radius
    distance = np.sqrt(dx * dx + dy * dy)
    coverage = np.clip((1.0 - distance) * radius + 0.7, 0, 1)[..., None]
    base = np.array((229, 241, 244) if class_id == 0 else BALL_COLORS[class_id], dtype=np.float32)
    hx, hy = rng.uniform(-0.48, 0.15), rng.uniform(-0.65, -0.15)
    specular = 0.24 * np.exp(-((dx - hx) ** 2 + (dy - hy) ** 2) / 0.07)
    shade = np.clip(0.66 + 0.24 * np.sqrt(np.maximum(0, 1 - distance * distance)) + specular, 0.3, 1.08)
    ball = np.clip(base[None, None, :] * shade[..., None] + 10 * specular[..., None], 0, 255)
    disk = distance <= 1
    if class_id >= 9:
        angle = math.radians(float(rng.uniform(0, 180)))
        band_coord = -math.sin(angle) * dx + math.cos(angle) * dy
        stripe = (np.abs(band_coord) < 0.37) & disk
        ball[stripe] = np.clip(238 * shade[stripe, None], 0, 255)
    if class_id != 0:
        number_disk = disk & (distance <= 0.31)
        number_border = disk & (distance > 0.27) & (distance <= 0.31)
        ball[number_disk] = np.clip(244 * shade[number_disk, None], 0, 255)
        ball[number_border] = (43, 42, 40)
    roi = image[y0:y1, x0:x1].astype(np.float32)
    image[y0:y1, x0:x1] = np.clip(roi * (1 - coverage) + ball * coverage, 0, 255).astype(np.uint8)
    if class_id != 0 and radius >= 8:
        label = str(class_id)
        scale = max(0.28, radius / 24)
        thickness = max(1, radius // 8)
        text_size = cv2.getTextSize(label, cv2.FONT_HERSHEY_SIMPLEX, scale, thickness)[0]
        text_x = cx - text_size[0] // 2
        text_y = cy + text_size[1] // 2
        cv2.putText(image, label, (text_x, text_y), cv2.FONT_HERSHEY_SIMPLEX, scale, (18, 18, 20), thickness, cv2.LINE_AA)


def _draw_shadow(image: np.ndarray, x: float, y: float, radius: int) -> None:
    shadow = np.zeros(image.shape[:2], dtype=np.uint8)
    cv2.ellipse(shadow, (round(x + radius * 0.18), round(y + radius * 0.30)), (round(radius * 1.2), max(2, round(radius * 0.55))), -8, 0, 360, 85, -1)
    shadow = cv2.GaussianBlur(shadow, (0, 0), max(1.2, radius * 0.35))
    alpha = shadow[:, :, None].astype(np.float32) / 255
    image[:] = np.clip(image.astype(np.float32) * (1 - alpha), 0, 255).astype(np.uint8)


def _motion_blur(image: np.ndarray, rng: np.random.Generator) -> np.ndarray:
    length = int(rng.integers(3, 9))
    kernel = np.zeros((length, length), dtype=np.float32)
    angle = float(rng.uniform(-math.pi, math.pi))
    cx = cy = length // 2
    dx, dy = math.cos(angle) * (length - 1) / 2, math.sin(angle) * (length - 1) / 2
    cv2.line(kernel, (round(cx - dx), round(cy - dy)), (round(cx + dx), round(cy + dy)), 1, 1)
    kernel /= max(kernel.sum(), 1)
    return cv2.filter2D(image, -1, kernel)


def render_scene(seed: int, width: int = IMAGE_SIZE, height: int = IMAGE_SIZE) -> tuple[np.ndarray, list[tuple[int, float, float, float, float]]]:
    """Return an RGB scene and normalized YOLO labels from a stable seed."""
    if width < 256 or height < 256:
        raise ValueError("render dimensions must be at least 256 pixels")
    rng = np.random.default_rng(seed)
    table = _make_table(rng)
    quad, projected_width = _camera_quad(rng, width, height)
    x0, y0, x1, y1 = SURFACE
    source = np.array([(x0, y0), (x1, y0), (x1, y1), (x0, y1)], dtype=np.float32)
    matrix = cv2.getPerspectiveTransform(source, quad)
    warped_table = cv2.warpPerspective(table[:, :, :3], matrix, (width, height), flags=cv2.INTER_LINEAR)
    table_mask = cv2.warpPerspective(table[:, :, 3], matrix, (width, height), flags=cv2.INTER_LINEAR)

    room_color = np.array(rng.choice(np.array([(39, 39, 42), (57, 51, 47), (69, 68, 65)], dtype=np.uint8)), dtype=np.uint8)
    room = np.broadcast_to(room_color, (height, width, 3)).copy()
    room_noise = rng.normal(0, 4, room.shape).astype(np.int16)
    room = np.clip(room.astype(np.int16) + room_noise, 0, 255).astype(np.uint8)
    alpha = table_mask[:, :, None].astype(np.float32) / 255
    image = np.clip(room * (1 - alpha) + warped_table * alpha, 0, 255).astype(np.uint8)

    length_in = int(rng.choice(TABLE_LENGTH_IN))
    diameter_source = BALL_DIAMETER_MM / (length_in * 25.4) * (x1 - x0)
    source_radius = diameter_source / 2
    balls = _ball_positions(rng, int(rng.integers(2, 17)), source_radius)
    labels: list[tuple[int, float, float, float, float]] = []
    # Draw farther balls first so near balls naturally cover their edges.
    for class_id, source_x, source_y in sorted(balls, key=lambda ball: ball[2]):
        center_x, center_y = _map_points(matrix, [(source_x, source_y)])[0]
        perspective_scale = 0.88 + 0.18 * (source_y - y0) / (y1 - y0)
        radius = max(4, int(round(projected_width * BALL_DIAMETER_MM / (length_in * 25.4) * perspective_scale / 2)))
        _draw_shadow(image, float(center_x), float(center_y), radius)
        _paint_ball(image, float(center_x), float(center_y), radius, class_id, rng)
        left, top = max(0.0, center_x - radius), max(0.0, center_y - radius)
        right, bottom = min(float(width), center_x + radius), min(float(height), center_y + radius)
        labels.append((class_id, (left + right) / (2 * width), (top + bottom) / (2 * height), (right - left) / width, (bottom - top) / height))

    if rng.random() < 0.33:
        cue = next((ball for ball in balls if ball[0] == 0), balls[0])
        start = _map_points(matrix, [(cue[1], cue[2])])[0]
        edge_x, edge_y = rng.choice([0, width - 1]), int(rng.integers(0, height))
        if rng.random() < 0.5:
            edge_x, edge_y = int(rng.integers(0, width)), rng.choice([0, height - 1])
        thickness = max(3, int(projected_width / 150))
        cv2.line(image, tuple(np.rint((edge_x, edge_y)).astype(int)), tuple(np.rint(start).astype(int)), (32, 28, 24), thickness + 2, cv2.LINE_AA)
        cv2.line(image, tuple(np.rint((edge_x, edge_y)).astype(int)), tuple(np.rint(start).astype(int)), (157, 113, 72), thickness, cv2.LINE_AA)
        cv2.circle(image, tuple(np.rint(start).astype(int)), max(2, thickness // 2), (26, 24, 23), -1, cv2.LINE_AA)

    if rng.random() < 0.12:
        skin = rng.choice(np.array([(105, 142, 195), (72, 103, 154), (140, 175, 220), (58, 79, 116)], dtype=np.uint8))
        sleeve = rng.choice(np.array([(53, 41, 34), (40, 43, 94), (64, 73, 40), (201, 209, 211)], dtype=np.uint8))
        side = int(rng.integers(0, 4))
        if side < 2:
            sx = 0 if side == 0 else width - 1
            sy = int(rng.uniform(height * 0.2, height * 0.8))
            hand = np.array([(sx, sy - 32), (sx, sy + 36), (sx + (38 if sx == 0 else -38), sy + 25), (sx + (31 if sx == 0 else -31), sy - 20)], dtype=np.int32)
        else:
            sy = 0 if side == 2 else height - 1
            sx = int(rng.uniform(width * 0.2, width * 0.8))
            hand = np.array([(sx - 34, sy), (sx + 34, sy), (sx + 25, sy + (40 if sy == 0 else -40)), (sx - 20, sy + (36 if sy == 0 else -36))], dtype=np.int32)
        cv2.fillPoly(image, [hand], tuple(map(int, sleeve)), cv2.LINE_AA)
        cv2.ellipse(image, tuple(hand.mean(axis=0).astype(int)), (17, 12), float(rng.uniform(-40, 40)), 0, 360, tuple(map(int, skin)), -1, cv2.LINE_AA)

    if rng.random() < 0.24:
        glare = np.zeros((height, width), dtype=np.uint8)
        gx, gy = int(rng.integers(width // 5, width * 4 // 5)), int(rng.integers(height // 5, height * 4 // 5))
        cv2.ellipse(glare, (gx, gy), (int(rng.integers(20, 85)), int(rng.integers(8, 34))), int(rng.integers(0, 180)), 0, 360, int(rng.integers(22, 75)), -1)
        glare = cv2.GaussianBlur(glare, (0, 0), rng.uniform(7, 24))
        light = glare[:, :, None].astype(np.float32) / 255
        image = np.clip(image.astype(np.float32) * (1 - light * 0.45) + 255 * light * 0.45, 0, 255).astype(np.uint8)
    if rng.random() < 0.26:
        image = _motion_blur(image, rng)
    noise = rng.normal(0, rng.uniform(0.8, 4.6), image.shape).astype(np.int16)
    image = np.clip(image.astype(np.int16) + noise, 0, 255).astype(np.uint8)
    quality = int(rng.integers(50, 96))
    ok, encoded = cv2.imencode(".jpg", image, [cv2.IMWRITE_JPEG_QUALITY, quality])
    if ok:
        image = cv2.imdecode(encoded, cv2.IMREAD_COLOR)
        image = cv2.cvtColor(image, cv2.COLOR_BGR2RGB)

    validate_labels(labels, width=width, height=height)
    return image, labels


def generate_split(output: Path, train: int, val: int, test: int, seed: int, overwrite: bool = False) -> None:
    """Write train/val/test images, labels, and a YOLO data file."""
    if min(train, val, test) < 0 or train + val + test == 0:
        raise ValueError("split counts must be non-negative and total more than zero")
    output = output.resolve()
    if output.exists() and any(output.iterdir()):
        if not overwrite:
            raise FileExistsError(f"{output} already contains data; pass --overwrite to replace it")
        shutil.rmtree(output)
    split_counts = {"train": train, "val": val, "test": test}
    for split_number, (split, count) in enumerate(split_counts.items()):
        image_dir, label_dir = output / "images" / split, output / "labels" / split
        image_dir.mkdir(parents=True, exist_ok=True)
        label_dir.mkdir(parents=True, exist_ok=True)
        for index in range(count):
            image_seed = int(np.random.SeedSequence([seed, split_number, index]).generate_state(1)[0])
            image, labels = render_scene(image_seed)
            filename = f"{index:05d}.jpg"
            image_bgr = cv2.cvtColor(image, cv2.COLOR_RGB2BGR)
            if not cv2.imwrite(str(image_dir / filename), image_bgr, [cv2.IMWRITE_JPEG_QUALITY, 95]):
                raise OSError(f"failed to write {image_dir / filename}")
            label_text = "".join("{} {:.6f} {:.6f} {:.6f} {:.6f}\n".format(*row) for row in labels)
            (label_dir / f"{index:05d}.txt").write_text(label_text)

    data = {
        "path": str(output),
        "train": "images/train",
        "val": "images/val",
        "test": "images/test",
        "names": CLASS_NAMES,
    }
    (output / "dataset.yaml").write_text(json.dumps(data, indent=2) + "\n")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, default=Path(__file__).parent / "data" / "synthetic")
    parser.add_argument("--train", type=int, default=2400)
    parser.add_argument("--val", type=int, default=400)
    parser.add_argument("--test", type=int, default=400)
    parser.add_argument("--seed", type=int, default=20261106)
    parser.add_argument("--overwrite", action="store_true")
    args = parser.parse_args()
    generate_split(args.out, args.train, args.val, args.test, args.seed, args.overwrite)
    print(f"Generated {args.train + args.val + args.test} synthetic scenes at {args.out}")


if __name__ == "__main__":
    main()

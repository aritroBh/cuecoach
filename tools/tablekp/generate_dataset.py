#!/usr/bin/env python3
"""Seeded synthetic pool-table scenes and YOLO pose labels."""

from __future__ import annotations

import argparse
import json
import math
import shutil
from dataclasses import dataclass
from pathlib import Path

import cv2
import numpy as np


WIDTH, HEIGHT = 640, 640
CANVAS = (1280, 720)
NOSE = np.array(((120, 100), (1160, 100), (1160, 620), (120, 620)), dtype=np.float32)
TABLE_LENGTH_IN = (80, 92, 100)
FELT = ((57, 105, 37), (39, 95, 124), (117, 47, 54), (91, 87, 80), (49, 112, 91))
WOOD = ((42, 58, 81), (52, 91, 132), (38, 39, 42), (86, 57, 35), (110, 85, 58))
BALLS = ((28, 190, 242), (188, 83, 44), (48, 39, 202), (140, 53, 111), (22, 104, 235),
         (68, 126, 39), (47, 41, 107), (27, 27, 30), (28, 190, 242), (188, 83, 44),
         (48, 39, 202), (140, 53, 111), (22, 104, 235), (68, 126, 39), (47, 41, 107))
KEYPOINT_NAMES = (
    "corner_mouth_0", "corner_mouth_1", "corner_mouth_2", "corner_mouth_3",
    "side_mouth_0", "side_mouth_1",
    "nose_corner_0", "nose_corner_1", "nose_corner_2", "nose_corner_3",
)


@dataclass
class Scene:
    image: np.ndarray
    pose_label: list[float | int]
    source_keypoints: np.ndarray
    keypoints_px: np.ndarray
    keypoint_visibility: tuple[int, ...]
    homography: np.ndarray
    camera_mode: str
    table_size_ft: int


def _project(matrix: np.ndarray, points: np.ndarray) -> np.ndarray:
    return cv2.perspectiveTransform(np.asarray(points, np.float32).reshape(-1, 1, 2), matrix).reshape(-1, 2)


def _choice(rng: np.random.Generator, choices):
    return choices[int(rng.integers(0, len(choices)))]


def _ordered_corners(points: np.ndarray) -> list[int]:
    center = points.mean(axis=0)
    order = np.argsort(np.arctan2(points[:, 1] - center[1], points[:, 0] - center[0]))
    start = min(range(4), key=lambda i: (points[order[i], 1], points[order[i], 0]))
    return list(np.roll(order, -start))


def _room(rng: np.random.Generator, width: int, height: int) -> np.ndarray:
    # ponytail: procedural rooms keep samples license-safe; labeled real footage is the domain-gap upgrade path.
    base = np.array(_choice(rng, ((31, 32, 34), (49, 43, 38), (60, 58, 54), (40, 48, 54))), dtype=np.float32)
    y = np.linspace(0.94, 1.12, height, dtype=np.float32)[:, None, None]
    image = np.broadcast_to(base[None, None, :] * y, (height, width, 3)).copy()
    noise = rng.normal(0, 4, image.shape).astype(np.float32)
    image = np.clip(image + noise, 0, 255).astype(np.uint8)

    # Soft-focus room details make the table compete with real bar clutter.
    for _ in range(int(rng.integers(2, 7))):
        x = int(rng.integers(-80, width + 80))
        y0 = int(rng.integers(0, max(1, height // 2)))
        w = int(rng.integers(25, 130))
        h = int(rng.integers(20, 100))
        color = tuple(int(c) for c in _choice(rng, ((66, 59, 49), (71, 77, 83), (83, 65, 51), (93, 91, 83))))
        cv2.rectangle(image, (x, y0), (x + w, y0 + h), color, -1)
        if rng.random() < 0.55:
            cv2.rectangle(image, (x + 5, y0 + 7), (x + w - 5, y0 + max(10, h // 3)), (145, 119, 74), -1)
    if rng.random() < 0.7:
        shelf_y = int(rng.uniform(height * 0.10, height * 0.34))
        cv2.rectangle(image, (0, shelf_y), (width, shelf_y + 7), (29, 28, 27), -1)
        for x in range(15, width, int(rng.integers(28, 54))):
            bottle_h = int(rng.integers(18, 47))
            bottle = _choice(rng, ((61, 91, 68), (74, 71, 100), (113, 83, 44)))
            cv2.rectangle(image, (x, shelf_y - bottle_h), (x + 9, shelf_y), bottle, -1)
            cv2.circle(image, (x + 4, shelf_y - bottle_h), 4, (129, 106, 70), -1)
    if rng.random() < 0.55:
        lamp_x, lamp_y = int(rng.uniform(width * 0.2, width * 0.8)), int(rng.uniform(height * 0.02, height * 0.22))
        cv2.line(image, (lamp_x, 0), (lamp_x, lamp_y), (35, 35, 34), 3)
        cv2.ellipse(image, (lamp_x, lamp_y), (int(rng.integers(35, 90)), 10), 0, 0, 360, (197, 171, 112), -1, cv2.LINE_AA)
        glow = np.zeros((height, width), np.uint8)
        cv2.ellipse(glow, (lamp_x, lamp_y + 15), (100, 50), 0, 0, 360, 65, -1)
        glow = cv2.GaussianBlur(glow, (0, 0), 30)[:, :, None].astype(np.float32) / 255
        image = np.clip(image.astype(np.float32) + glow * 30, 0, 255).astype(np.uint8)
    for _ in range(int(rng.integers(0, 3))):
        person_x = int(rng.integers(0, width))
        person_y = int(rng.uniform(height * 0.22, height * 0.60))
        shade = _choice(rng, ((28, 29, 34), (47, 39, 36), (42, 52, 55)))
        cv2.ellipse(image, (person_x, person_y - 18), (8, 10), 0, 0, 360, (46, 40, 36), -1)
        cv2.ellipse(image, (person_x, person_y + 12), (13, 25), 0, 0, 360, shade, -1)
    if rng.random() < 0.6:
        # A second, smaller table in the background is a common visual distractor.
        cx, cy = int(rng.integers(0, width)), int(rng.integers(0, height // 2 + 1))
        tw, th = int(rng.integers(70, 220)), int(rng.integers(35, 90))
        poly = np.array(((cx - tw // 2, cy - th // 2), (cx + tw // 2, cy - th // 2),
                         (cx + tw // 2 - 10, cy + th // 2), (cx - tw // 2 + 10, cy + th // 2)))
        cv2.fillConvexPoly(image, poly, (43, 52, 48), cv2.LINE_AA)
        cv2.polylines(image, [poly], True, (69, 53, 39), 9, cv2.LINE_AA)
        cv2.GaussianBlur(image, (0, 0), 2, dst=image)
    return image


def _make_table(rng: np.random.Generator, length_in: int) -> tuple[np.ndarray, np.ndarray]:
    width, height = CANVAS
    table = np.zeros((height, width, 3), dtype=np.uint8)
    wood = tuple(int(c) for c in _choice(rng, WOOD))
    felt = np.array(_choice(rng, FELT), np.float32)
    x0, y0 = NOSE[0]
    x1, y1 = NOSE[2]
    x0, y0, x1, y1 = map(int, (x0, y0, x1, y1))
    table[:] = (12, 13, 14)
    cv2.rectangle(table, (35, 35), (width - 35, height - 35), wood, -1)
    edge = tuple(max(0, int(c * 0.68)) for c in wood)
    cv2.rectangle(table, (72, 72), (width - 72, height - 72), edge, -1)
    for row in range(42, height - 38, 9):
        grain = tuple(int(np.clip(c + rng.integers(-8, 9), 0, 255)) for c in wood)
        cv2.line(table, (40, row), (width - 40, row + int(rng.integers(-2, 3))), grain, 1, cv2.LINE_AA)

    xs, ys = np.meshgrid(np.linspace(-1, 1, x1 - x0), np.linspace(-1, 1, y1 - y0))
    light_x, light_y = rng.uniform(-0.8, 0.8, 2)
    light = 0.78 + 0.28 * np.exp(-((xs - light_x) ** 2 + (ys - light_y) ** 2) / rng.uniform(0.25, 1.1))
    light += rng.uniform(-0.1, 0.1) * xs + rng.uniform(-0.1, 0.1) * ys
    cloth = np.clip(felt[None, None, :] * light[:, :, None] + rng.normal(0, rng.uniform(2, 7), (y1-y0, x1-x0, 1)), 0, 255).astype(np.uint8)
    table[y0:y1, x0:x1] = cloth

    # Felt seams, directional nap, and cushion noses.
    if rng.random() < 0.65:
        for yy in range(y0 + 5, y1, int(rng.integers(18, 34))):
            cv2.line(table, (x0 + 2, yy), (x1 - 2, yy), tuple(int(c * 0.97) for c in felt), 1)
    cushion = tuple(int(c * 0.58) for c in felt)
    cv2.line(table, (x0, y0 + 2), (x1, y0 + 2), cushion, 10, cv2.LINE_AA)
    cv2.line(table, (x0, y1 - 2), (x1, y1 - 2), cushion, 10, cv2.LINE_AA)
    cv2.line(table, (x0 + 2, y0), (x0 + 2, y1), cushion, 10, cv2.LINE_AA)
    cv2.line(table, (x1 - 2, y0), (x1 - 2, y1), cushion, 10, cv2.LINE_AA)

    scale = (x1 - x0) / length_in
    radius = max(6, round(2.25 * scale / 2))
    pocket_avoid = np.array(((x0, y0), ((x0 + x1) / 2, y0), (x1, y0),
                             (x0, y1), ((x0 + x1) / 2, y1), (x1, y1)), dtype=np.float32)
    ball_centers: list[tuple[int, int]] = []
    for _ in range(int(rng.integers(2, 16))):
        for _attempt in range(160):
            bx = int(rng.integers(x0 + 3 * radius, x1 - 3 * radius))
            by = int(rng.integers(y0 + 3 * radius, y1 - 3 * radius))
            if any(math.dist((bx, by), point) < 55 for point in pocket_avoid):
                continue
            if any(math.dist((bx, by), other) < radius * 2.15 for other in ball_centers):
                continue
            ball_centers.append((bx, by))
            break
    for index, (bx, by) in enumerate(ball_centers):
        cv2.ellipse(table, (bx + radius // 3, by + radius // 2), (radius, max(3, radius // 2)), -8, 0, 360, (18, 20, 18), -1, cv2.LINE_AA)
        cv2.circle(table, (bx, by), radius, (229, 232, 228) if index == 0 else BALLS[(index - 1) % len(BALLS)], -1, cv2.LINE_AA)
        cv2.ellipse(table, (bx - radius // 3, by - radius // 3), (max(2, radius // 3), max(2, radius // 4)), -25, 0, 360, (250, 250, 245), -1, cv2.LINE_AA)
        if index >= 9:
            cv2.ellipse(table, (bx, by), (radius, max(2, radius // 3)), float(rng.uniform(-35, 35)), 0, 360, (238, 238, 234), -1, cv2.LINE_AA)
        if index > 0 and radius >= 8:
            cv2.circle(table, (bx, by), max(2, radius // 3), (235, 234, 225), -1, cv2.LINE_AA)
            cv2.putText(table, str(index), (bx - 3, by + 3), cv2.FONT_HERSHEY_SIMPLEX, 0.22, (28, 27, 26), 1, cv2.LINE_AA)

    corner_mouth = 4.5 * scale
    side_mouth = 5.0 * scale
    # Mouth centers sit halfway into the cloth from theoretical corner nose points.
    source_corners = NOSE.copy()
    corner_centers = np.array((
        (x0 + corner_mouth / 2, y0 + corner_mouth / 2),
        (x1 - corner_mouth / 2, y0 + corner_mouth / 2),
        (x1 - corner_mouth / 2, y1 - corner_mouth / 2),
        (x0 + corner_mouth / 2, y1 - corner_mouth / 2),
    ), dtype=np.float32)
    side_centers = np.array((((x0 + x1) / 2, y0), ((x0 + x1) / 2, y1)), dtype=np.float32)
    dark = (8, 8, 9)
    for point in corner_centers:
        center = tuple(np.rint(point).astype(int))
        cv2.ellipse(table, center, (int(corner_mouth / 2), int(corner_mouth / 2)), 0, 0, 360, (32, 25, 18), -1, cv2.LINE_AA)
        cv2.ellipse(table, center, (max(3, int(corner_mouth * 0.36)), max(3, int(corner_mouth * 0.36))), 0, 0, 360, dark, -1, cv2.LINE_AA)
        cv2.ellipse(table, (center[0], center[1] - 2), (max(2, int(corner_mouth * 0.19)), max(2, int(corner_mouth * 0.13))), -16, 180, 360, (46, 43, 39), 2, cv2.LINE_AA)
    for point in side_centers:
        center = tuple(np.rint(point).astype(int))
        radius = int(side_mouth / 2)
        cv2.ellipse(table, center, (radius + 5, radius), 0, 0, 360, (31, 25, 20), -1, cv2.LINE_AA)
        cv2.ellipse(table, center, (radius, max(4, int(radius * 0.8))), 0, 0, 360, dark, -1, cv2.LINE_AA)

    # Diamonds and rail bolts.
    rail_color = tuple(min(255, int(c * 1.25 + 12)) for c in wood)
    for fraction in np.linspace(0.12, 0.88, 7):
        px = round(x0 + fraction * (x1 - x0))
        py = round(y0 + fraction * (y1 - y0))
        cv2.circle(table, (px, y0 - 28), 5, rail_color, -1, cv2.LINE_AA)
        cv2.circle(table, (px, y1 + 28), 5, rail_color, -1, cv2.LINE_AA)
        cv2.circle(table, (x0 - 28, py), 5, rail_color, -1, cv2.LINE_AA)
        cv2.circle(table, (x1 + 28, py), 5, rail_color, -1, cv2.LINE_AA)

    return table, np.concatenate((corner_centers, side_centers, source_corners), axis=0)


def _camera_quad(rng: np.random.Generator, width: int, height: int, mode: str) -> np.ndarray:
    elevation = math.radians(float(rng.uniform(15, 60)))
    yaw_limit = 25 if mode == "tripod" else 65
    yaw = math.radians(float(rng.uniform(-yaw_limit, yaw_limit)))
    horizontal = math.sqrt((math.cos(yaw) * 2) ** 2 + (math.sin(yaw)) ** 2)
    depth = math.sin(elevation) * math.sqrt((math.sin(yaw) * 2) ** 2 + math.cos(yaw) ** 2)
    ratio = float(np.clip(depth / horizontal, 0.12, 0.84))
    span = float(rng.uniform(0.69, 1.12) * min(width, height))
    height_span = span * ratio
    cx = width / 2 + float(rng.uniform(-35, 35))
    cy = height / 2 + float(rng.uniform(-35, 35))
    if rng.random() < (0.12 if mode == "tripod" else 0.52):
        cx += float(rng.choice((-1, 1)) * rng.uniform(width * 0.12, width * 0.25))
        cy += float(rng.choice((-1, 1)) * rng.uniform(height * 0.08, height * 0.18))
    far_scale = float(rng.uniform(0.70, 0.95))
    skew = float(rng.uniform(-0.09, 0.09) * span)
    quad = np.array(((cx + skew - span * far_scale / 2, cy - height_span / 2),
                     (cx + skew + span * far_scale / 2, cy - height_span / 2),
                     (cx - skew * 0.35 + span / 2, cy + height_span / 2),
                     (cx - skew * 0.35 - span / 2, cy + height_span / 2)), dtype=np.float32)
    roll_limit = 4 if mode == "tripod" else 34
    roll = math.radians(float(rng.uniform(-roll_limit, roll_limit)))
    rotation = np.array(((math.cos(roll), -math.sin(roll)), (math.sin(roll), math.cos(roll))), dtype=np.float32)
    return ((quad - (width / 2, height / 2)) @ rotation.T + (width / 2, height / 2)).astype(np.float32)


def _occluders(image: np.ndarray, mask: np.ndarray, rng: np.random.Generator, pockets: np.ndarray) -> None:
    h, w = image.shape[:2]
    if rng.random() < 0.36:
        target = tuple(np.rint(pockets[int(rng.integers(0, 6))]).astype(int))
        edge = int(rng.integers(0, 4))
        if edge == 0:
            start = (-15, int(rng.uniform(0, h)))
        elif edge == 1:
            start = (w + 15, int(rng.uniform(0, h)))
        elif edge == 2:
            start = (int(rng.uniform(0, w)), -15)
        else:
            start = (int(rng.uniform(0, w)), h + 15)
        sleeve = tuple(int(c) for c in _choice(rng, ((43, 46, 81), (61, 53, 43), (85, 95, 102), (37, 62, 53))))
        skin = tuple(int(c) for c in _choice(rng, ((104, 137, 178), (127, 157, 192), (75, 102, 134), (166, 139, 116))))
        dx, dy = target[0] - start[0], target[1] - start[1]
        norm = max(math.hypot(dx, dy), 1)
        px, py = -dy / norm, dx / norm
        arm_width = float(rng.uniform(17, 36))
        arm = np.array(((start[0] + px * arm_width, start[1] + py * arm_width),
                        (start[0] - px * arm_width, start[1] - py * arm_width),
                        (target[0] - px * arm_width * 0.55, target[1] - py * arm_width * 0.55),
                        (target[0] + px * arm_width * 0.55, target[1] + py * arm_width * 0.55)), dtype=np.int32)
        cv2.fillConvexPoly(image, arm, sleeve, cv2.LINE_AA)
        cv2.fillConvexPoly(mask, arm, 255, cv2.LINE_AA)
        cv2.ellipse(image, target, (18, 13), float(rng.uniform(-50, 50)), 0, 360, skin, -1, cv2.LINE_AA)
        cv2.ellipse(mask, target, (18, 13), 0, 0, 360, 255, -1, cv2.LINE_AA)
    if rng.random() < 0.42:
        start = (int(rng.choice((-10, w + 10))), int(rng.uniform(0, h)))
        end = tuple(np.rint(pockets[int(rng.integers(0, 6))]).astype(int))
        thickness = int(rng.integers(3, 7))
        cv2.line(image, start, end, (31, 27, 23), thickness + 3, cv2.LINE_AA)
        cv2.line(mask, start, end, 255, thickness + 3, cv2.LINE_AA)
        cv2.line(image, start, end, (142, 102, 66), thickness, cv2.LINE_AA)


def render_scene(seed: int, width: int = WIDTH, height: int = HEIGHT) -> Scene:
    """Return an RGB image and a YOLO pose label with 10 (x,y,visibility) points."""
    if width < 256 or height < 256:
        raise ValueError("render dimensions must be at least 256 pixels")
    rng = np.random.default_rng(seed)
    length_in = int(rng.choice(TABLE_LENGTH_IN))
    mode = "tripod" if rng.random() < 0.65 else "handheld"
    table, source_keypoints = _make_table(rng, length_in)
    quad = _camera_quad(rng, width, height, mode)
    matrix = cv2.getPerspectiveTransform(NOSE, quad)
    warped = cv2.warpPerspective(table, matrix, (width, height), flags=cv2.INTER_LINEAR)
    source_mask = np.zeros(table.shape[:2], np.uint8)
    cv2.rectangle(source_mask, (35, 35), (CANVAS[0] - 35, CANVAS[1] - 35), 255, -1)
    alpha = cv2.warpPerspective(source_mask, matrix, (width, height))[:, :, None].astype(np.float32) / 255
    room = _room(rng, width, height)
    shadow = cv2.warpPerspective(source_mask, matrix, (width, height), flags=cv2.INTER_LINEAR)
    shadow = cv2.warpAffine(shadow, np.array(((1, 0, 9), (0, 1, 15)), np.float32), (width, height))
    shadow = cv2.GaussianBlur(shadow, (0, 0), 10)[:, :, None].astype(np.float32) / 255
    room = np.clip(room.astype(np.float32) * (1 - shadow * 0.48), 0, 255).astype(np.uint8)
    image = np.clip(room * (1 - alpha) + warped * alpha, 0, 255).astype(np.uint8)

    corners_px = _project(matrix, NOSE)
    corner_indices = _ordered_corners(corners_px)
    raw_pockets_px = _project(matrix, source_keypoints[:6])
    raw_nose_px = _project(matrix, source_keypoints[6:])
    ordered_source = np.concatenate((
        source_keypoints[corner_indices],
        source_keypoints[4:6][np.argsort(raw_pockets_px[4:6, 1])],
        source_keypoints[6 + np.asarray(corner_indices)],
    ), axis=0)
    points_px = _project(matrix, ordered_source)

    mask = np.zeros((height, width), np.uint8)
    _occluders(image, mask, rng, raw_pockets_px)
    visibility: list[int] = []
    label_points: list[float | int] = []
    for x, y in points_px:
        if not (0 <= x < width and 0 <= y < height):
            visibility.append(0)
            label_points.extend((0.0, 0.0, 0))
            continue
        x0, x1 = max(0, int(x) - 4), min(width, int(x) + 5)
        y0, y1 = max(0, int(y) - 4), min(height, int(y) + 5)
        covered = bool(np.any(mask[y0:y1, x0:x1]))
        flag = 1 if covered else 2
        visibility.append(flag)
        label_points.extend((float(x / width), float(y / height), flag))

    if rng.random() < 0.26:
        glare = np.zeros((height, width), np.uint8)
        gx, gy = int(rng.integers(width // 5, width * 4 // 5)), int(rng.integers(height // 5, height * 4 // 5))
        cv2.ellipse(glare, (gx, gy), (int(rng.integers(25, 110)), int(rng.integers(10, 42))), int(rng.integers(0, 180)), 0, 360, int(rng.integers(24, 90)), -1)
        glare = cv2.GaussianBlur(glare, (0, 0), float(rng.uniform(8, 25)))[:, :, None].astype(np.float32) / 255
        image = np.clip(image * (1 - glare * 0.45) + 255 * glare * 0.45, 0, 255).astype(np.uint8)
    if rng.random() < 0.25:
        length = int(rng.integers(3, 9))
        kernel = np.zeros((length, length), np.float32)
        angle = float(rng.uniform(0, math.tau))
        cx = cy = length // 2
        dx, dy = math.cos(angle) * (length - 1) / 2, math.sin(angle) * (length - 1) / 2
        cv2.line(kernel, (round(cx - dx), round(cy - dy)), (round(cx + dx), round(cy + dy)), 1, 1)
        image = cv2.filter2D(image, -1, kernel / max(kernel.sum(), 1))
    if rng.random() < 0.16:
        image = cv2.GaussianBlur(image, (3, 3), float(rng.uniform(0.3, 1.1)))
    image = np.clip(image.astype(np.int16) + rng.normal(0, rng.uniform(0.7, 3.5), image.shape), 0, 255).astype(np.uint8)
    ok, encoded = cv2.imencode(".jpg", cv2.cvtColor(image, cv2.COLOR_RGB2BGR), [cv2.IMWRITE_JPEG_QUALITY, int(rng.integers(48, 97))])
    if ok:
        image = cv2.cvtColor(cv2.imdecode(encoded, cv2.IMREAD_COLOR), cv2.COLOR_BGR2RGB)

    # Use the rails' outer corners for the clipped table bounding box.
    outer = np.array(((35, 35), (CANVAS[0] - 35, 35), (CANVAS[0] - 35, CANVAS[1] - 35), (35, CANVAS[1] - 35)), np.float32)
    outer_px = _project(matrix, outer)
    left = float(np.clip(outer_px[:, 0].min(), 0, width - 1))
    right = float(np.clip(outer_px[:, 0].max(), 0, width - 1))
    top = float(np.clip(outer_px[:, 1].min(), 0, height - 1))
    bottom = float(np.clip(outer_px[:, 1].max(), 0, height - 1))
    if right <= left or bottom <= top:
        raise RuntimeError("camera crop removed the full table")
    label = [0, (left + right) / (2 * width), (top + bottom) / (2 * height),
             (right - left) / width, (bottom - top) / height, *label_points]
    size_ft = {80: 7, 92: 8, 100: 9}[length_in]
    return Scene(image, label, ordered_source, points_px, tuple(visibility), matrix, mode, size_ft)


def format_yolo_label(scene: Scene) -> str:
    fields = ["0", *(f"{float(value):.6f}" for value in scene.pose_label[1:5])]
    for index in range(10):
        x, y, visibility = scene.pose_label[5 + index * 3:8 + index * 3]
        fields.extend((f"{float(x):.6f}", f"{float(y):.6f}", str(int(visibility))))
    return " ".join(fields) + "\n"


def generate_split(output: Path, train: int, val: int, test: int, seed: int, overwrite: bool = False) -> None:
    if min(train, val, test) < 0 or train + val + test == 0:
        raise ValueError("split counts must be non-negative and total more than zero")
    output = output.resolve()
    if output.exists() and any(output.iterdir()):
        if not overwrite:
            raise FileExistsError(f"{output} already contains data; pass --overwrite to replace it")
        shutil.rmtree(output)
    for split_number, (split, count) in enumerate((("train", train), ("val", val), ("test", test))):
        images, labels = output / "images" / split, output / "labels" / split
        images.mkdir(parents=True, exist_ok=True)
        labels.mkdir(parents=True, exist_ok=True)
        for index in range(count):
            image_seed = int(np.random.SeedSequence((seed, split_number, index)).generate_state(1)[0])
            scene = render_scene(image_seed)
            name = f"{index:05d}"
            if not cv2.imwrite(str(images / f"{name}.jpg"), cv2.cvtColor(scene.image, cv2.COLOR_RGB2BGR)):
                raise OSError(f"failed to write {images / (name + '.jpg')}")
            (labels / f"{name}.txt").write_text(format_yolo_label(scene))
    dataset = {"path": str(output), "train": "images/train", "val": "images/val", "test": "images/test",
               "names": ["table"], "kpt_shape": [10, 3], "flip_idx": [1, 0, 3, 2, 4, 5, 7, 6, 9, 8]}
    (output / "dataset.yaml").write_text(json.dumps(dataset, indent=2) + "\n")


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
    print(f"Generated {args.train + args.val + args.test} scenes at {args.out}")


if __name__ == "__main__":
    main()

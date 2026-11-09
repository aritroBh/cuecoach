#!/usr/bin/env python3
"""Physically-motivated 3D pool-table renderer ("virtual sim") with exact camera geometry.

Unlike `generate_dataset.py` (2D paint on a homography), this ray-casts a real pinhole camera against the
table (cloth, cushions, rails, pockets) and true spheres, lit by overhead lamps in linear light, then runs a
phone-camera pipeline: motion blur, optics, auto-exposure and white-balance error, shot/read noise, tone curve,
4:2:0 chroma and JPEG. Every frame carries the camera (ARKit convention) and ground-truth ball positions on the
table, so the app's detectors can be scored in table centimetres through their real code path.

World = table frame: x along the length (head x = 0), y across, z up, cloth at z = 0 (CueCoach `TableFrame` with an
identity `tableToWorld`). Camera-to-world columns are right, up, back, eye (camera looks along -back).

Two disjoint styles: "bench" (held-out evaluation) and "train" (optional training data). They never share cloth
colours, ball-set palettes, lamp layouts or seed namespaces, so a model trained on "train" is still scored on
unseen looks.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field

import cv2
import numpy as np

BALL_R = 0.05715 / 2
TABLE_LENGTHS = {"sevenFoot": 80 * 0.0254, "eightFoot": 92 * 0.0254, "nineFoot": 100 * 0.0254}
CUSHION_W = 0.0508
NOSE_H = 0.0365
RAIL_H = 0.045
RAIL_OUTER = 0.16
CORNER_MOUTH = 4.5 * 0.0254
SIDE_MOUTH = 5.0 * 0.0254
SRC_W, SRC_H = 1920, 1440  # ARKit capturedImage (4:3); the app point-samples it to 960 wide.

# sRGB colours. Bench and train use disjoint cloth palettes and ball-set variants.
CLOTH = {
    "bench": {
        "tournament_blue": (38, 104, 160), "olive_green": (78, 110, 40), "burgundy": (112, 28, 38),
        "black": (30, 30, 34), "purple": (82, 52, 120), "camel": (176, 140, 92), "steel_grey": (96, 104, 112),
        "teal": (16, 116, 118), "bright_green": (40, 140, 60),
    },
    "train": {
        "green": (30, 118, 68), "blue": (32, 86, 150), "red": (140, 36, 42), "grey": (110, 110, 112),
        "navy": (26, 44, 92), "spruce": (36, 92, 76), "wine": (90, 30, 50), "gold": (170, 130, 40),
    },
}
BALL_SETS = {
    "bench": [
        {1: (250, 196, 0), 2: (0, 66, 170), 3: (214, 26, 32), 4: (84, 40, 122), 5: (246, 110, 18),
         6: (0, 122, 68), 7: (122, 26, 30), 8: (16, 16, 18)},
        {1: (255, 210, 40), 2: (30, 90, 200), 3: (230, 50, 40), 4: (200, 60, 140), 5: (255, 130, 30),
         6: (20, 140, 90), 7: (110, 60, 30), 8: (20, 20, 22)},
    ],
    "train": [
        {1: (240, 186, 10), 2: (10, 60, 150), 3: (200, 30, 36), 4: (100, 50, 140), 5: (236, 104, 30),
         6: (10, 110, 60), 7: (140, 36, 40), 8: (22, 22, 24)},
        {1: (255, 200, 20), 2: (20, 80, 185), 3: (220, 40, 30), 4: (150, 50, 150), 5: (250, 120, 40),
         6: (30, 130, 80), 7: (120, 40, 25), 8: (18, 18, 20)},
    ],
}
CUE_WHITE = (246, 243, 232)


def srgb_to_linear(c) -> np.ndarray:
    c = np.asarray(c, dtype=np.float32) / 255.0
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4).astype(np.float32)


def linear_to_srgb(x: np.ndarray) -> np.ndarray:
    x = np.clip(x, 0, 1)
    return np.where(x <= 0.0031308, 12.92 * x, 1.055 * np.power(x, 1 / 2.4) - 0.055)


def kelvin_rgb(kelvin: float) -> np.ndarray:
    """Approximate linear RGB of a black-body light, normalized to green = 1."""
    t = kelvin / 100.0
    r = 255.0 if t <= 66 else 329.7 * (t - 60) ** -0.1332
    g = 99.47 * math.log(t) - 161.12 if t <= 66 else 288.12 * (t - 60) ** -0.0755
    b = 255.0 if t >= 66 else (0.0 if t <= 19 else 138.52 * math.log(t - 10) - 305.04)
    rgb = srgb_to_linear(np.clip([r, g, b], 0, 255))
    return (rgb / max(rgb[1], 1e-6)).astype(np.float32)


@dataclass
class Camera:
    fx: float
    fy: float
    cx: float
    cy: float
    width: int
    height: int
    to_world: np.ndarray  # 4x4, columns right, up, back, eye

    @staticmethod
    def look_at(eye, target, fov_deg: float, roll_deg: float = 0.0, width: int = SRC_W, height: int = SRC_H) -> "Camera":
        eye, target = np.asarray(eye, float), np.asarray(target, float)
        back = eye - target
        back /= np.linalg.norm(back)
        up_world = np.array([0.0, 0.0, 1.0])
        right = np.cross(up_world, back)
        right /= np.linalg.norm(right)
        up = np.cross(back, right)
        roll = math.radians(roll_deg)
        right, up = right * math.cos(roll) + up * math.sin(roll), -right * math.sin(roll) + up * math.cos(roll)
        m = np.eye(4)
        m[:3, 0], m[:3, 1], m[:3, 2], m[:3, 3] = right, up, back, eye
        f = (max(width, height) / 2) / math.tan(math.radians(fov_deg) / 2)
        return Camera(f, f, width / 2, height / 2, width, height, m)

    @property
    def eye(self) -> np.ndarray:
        return self.to_world[:3, 3]

    def project(self, p) -> tuple[float, float, float] | None:
        """World point → (u, v, depth); None behind the camera."""
        c = np.linalg.inv(self.to_world) @ np.array([*p, 1.0])
        if c[2] >= -1e-6:
            return None
        return self.fx * c[0] / -c[2] + self.cx, self.fy * -c[1] / -c[2] + self.cy, -c[2]

    def rays(self) -> np.ndarray:
        u, v = np.meshgrid(np.arange(self.width, dtype=np.float32) + 0.5, np.arange(self.height, dtype=np.float32) + 0.5)
        d = np.stack([(u - self.cx) / self.fx, -(v - self.cy) / self.fy, -np.ones_like(u)], axis=-1)
        d = d @ self.to_world[:3, :3].T.astype(np.float32)
        return d / np.linalg.norm(d, axis=-1, keepdims=True)

    def as_json(self) -> dict:
        return {"fx": self.fx, "fy": self.fy, "cx": self.cx, "cy": self.cy, "width": self.width, "height": self.height,
                "cameraToWorld": [float(x) for x in self.to_world.T.reshape(-1)]}  # column-major (simd)


@dataclass
class Ball:
    number: int  # 0 = cue
    x: float
    y: float
    rotation: np.ndarray = field(default_factory=lambda: np.eye(3))
    velocity: tuple[float, float] = (0.0, 0.0)  # m/s on the table


@dataclass
class Lamp:
    pos: np.ndarray
    color: np.ndarray
    power: float
    radius: float


@dataclass
class Scene:
    """Everything that stays fixed over a clip (table, light, balls); the camera and noise vary per frame."""

    style: str
    table: str
    cloth: np.ndarray  # linear albedo
    cloth_name: str
    rail: np.ndarray
    lamps: list[Lamp]
    ambient: np.ndarray
    balls: list[Ball]
    ball_set: dict
    measles: bool
    two_sided_numbers: bool
    cloth_sheen: float
    distractors: list[dict]
    wear: tuple[float, float, float]
    tags: dict

    @property
    def length(self) -> float:
        return TABLE_LENGTHS[self.table]

    @property
    def width(self) -> float:
        return self.length / 2

    def pockets(self) -> list[tuple[float, float, float]]:
        L, W = self.length, self.width
        c, s = CORNER_MOUTH / 2 * 1.05, SIDE_MOUTH / 2
        o = 0.022
        return [(-o, -o, c), (L + o, -o, c), (-o, W + o, c), (L + o, W + o, c), (L / 2, -0.03, s), (L / 2, W + 0.03, s)]


def _rotation(rng: np.random.Generator) -> np.ndarray:
    q = rng.normal(size=4)
    q /= np.linalg.norm(q)
    w, x, y, z = q
    return np.array([[1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
                     [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
                     [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]])


def _place(rng, L, W, numbers, layout) -> list[Ball]:
    R = BALL_R
    balls: list[Ball] = []
    pockets = [(0, 0), (L / 2, 0), (L, 0), (0, W), (L / 2, W), (L, W)]

    def ok(x, y, gap=2 * R * 1.001):
        if not (R * 1.05 <= x <= L - R * 1.05 and R * 1.05 <= y <= W - R * 1.05):
            return False
        if any(math.dist((x, y), p) < 0.09 for p in pockets):
            return False
        return all(math.dist((x, y), (b.x, b.y)) >= gap for b in balls)

    if layout == "rack":
        apex = (L * 0.75, W / 2)
        order = [n for n in numbers if n != 0]
        k = 0
        d = 2 * R * 1.0005
        for row in range(5):
            for j in range(row + 1):
                if k >= len(order):
                    break
                x = apex[0] + row * d * math.sqrt(3) / 2
                y = apex[1] + (j - row / 2) * d
                balls.append(Ball(order[k], x, y, _rotation(rng)))
                k += 1
        if 0 in numbers:
            balls.append(Ball(0, L * 0.25 + rng.uniform(-0.1, 0.1), W / 2 + rng.uniform(-0.15, 0.15), _rotation(rng)))
        return balls
    for n in numbers:
        for _ in range(500):
            if layout in ("clusters", "broken") and balls and rng.random() < (0.6 if layout == "clusters" else 0.35):
                b = balls[int(rng.integers(len(balls)))]
                a = rng.uniform(0, math.tau)
                dist = 2 * R * (1.0005 if rng.random() < 0.7 else rng.uniform(1.02, 1.4))
                x, y = b.x + math.cos(a) * dist, b.y + math.sin(a) * dist
            elif layout == "broken" and rng.random() < 0.5:
                x, y = L * 0.75 + rng.normal(0, 0.18), W / 2 + rng.normal(0, 0.15)
            else:
                x, y = rng.uniform(R, L - R), rng.uniform(R, W - R)
            if ok(x, y):
                balls.append(Ball(n, x, y, _rotation(rng)))
                break
    return balls


def make_scene(rng: np.random.Generator, style: str = "bench", empty: bool = False) -> Scene:
    table = str(rng.choice(list(TABLE_LENGTHS)))
    L = TABLE_LENGTHS[table]
    W = L / 2
    cloth_name = str(rng.choice(list(CLOTH[style])))
    cloth_srgb = np.array(CLOTH[style][cloth_name], float) * rng.uniform(0.9, 1.08, 3)
    cloth = srgb_to_linear(np.clip(cloth_srgb, 0, 255))
    rail = srgb_to_linear(rng.choice(np.array([(70, 40, 22), (110, 70, 40), (40, 30, 26), (150, 110, 70), (24, 24, 26)])))
    # Lamps: bench = 1–3 hanging shades over the centreline or a single long bar; train = 2–4 shades or ceiling cans.
    n_lamps = int(rng.integers(1, 4)) if style == "bench" else int(rng.integers(2, 5))
    kelvin = float(rng.choice([2700, 3000, 3500, 4000, 5000, 6500]) if style == "bench" else rng.uniform(2800, 6000))
    lamps = []
    h = rng.uniform(0.75, 1.3)
    for i in range(n_lamps):
        fx = (i + 0.5) / n_lamps if rng.random() < 0.8 else rng.uniform(0.1, 0.9)
        pos = np.array([L * fx + rng.normal(0, 0.08), W / 2 + rng.normal(0, 0.12 if style == "bench" else 0.25), h + rng.normal(0, 0.05)])
        lamps.append(Lamp(pos, kelvin_rgb(kelvin + rng.normal(0, 150)), float(rng.uniform(0.5, 1.4)), float(rng.uniform(0.04, 0.2))))
    ambient = kelvin_rgb(float(rng.uniform(3000, 7000))) * float(rng.uniform(0.04, 0.25))
    if rng.random() < 0.15:  # window light from one side: cool, strong ambient tilt
        lamps.append(Lamp(np.array([rng.uniform(0, L), -3.0 if rng.random() < 0.5 else W + 3.0, 2.0]), kelvin_rgb(7500),
                          float(rng.uniform(6, 16)), 0.8))
    if empty:
        numbers, layout = [], "empty"
    else:
        layout = str(rng.choice(["scatter", "clusters", "rack", "broken"], p=[0.4, 0.3, 0.12, 0.18]))
        if layout == "rack":
            numbers = [0, *rng.permutation(np.arange(1, 16)).tolist()]
        else:
            count = int(rng.integers(1, 16))
            numbers = [0, *rng.choice(np.arange(1, 16), size=count, replace=False).tolist()]
    balls = _place(rng, L, W, numbers, layout)
    # Distractors on the cloth/rail: chalk cube, chalk smudges, a white lint/paper speck.
    distractors = []
    for _ in range(int(rng.integers(0, 3)) + (2 if empty else 0)):
        kind = str(rng.choice(["chalk_cube", "chalk_mark", "speck"]))
        distractors.append({"kind": kind, "x": float(rng.uniform(0.05, L - 0.05)), "y": float(rng.uniform(0.05, W - 0.05)),
                            "on_rail": bool(kind == "chalk_cube" and rng.random() < 0.5), "angle": float(rng.uniform(0, 90))})
    set_variants = BALL_SETS[style]
    ball_set = dict(set_variants[int(rng.integers(len(set_variants)))])
    ball_set = {k: tuple(np.clip(np.array(v) * rng.uniform(0.92, 1.06, 3), 0, 255)) for k, v in ball_set.items()}
    for n in range(9, 16):
        ball_set[n] = ball_set[n - 8]
    return Scene(style=style, table=table, cloth=cloth, cloth_name=cloth_name, rail=rail, lamps=lamps, ambient=ambient,
                 balls=balls, ball_set=ball_set, measles=bool(rng.random() < 0.2), two_sided_numbers=bool(rng.random() < 0.5),
                 cloth_sheen=float(rng.uniform(0.0, 0.25) if rng.random() < 0.6 else rng.uniform(0.25, 0.7)),
                 distractors=distractors, wear=(float(rng.uniform(0, 0.08)), float(rng.uniform(0.2, 0.8)), float(rng.uniform(0.2, 0.8))),
                 tags={"layout": layout, "cloth": cloth_name, "table": table, "lamps": n_lamps, "kelvin": kelvin})


def sample_camera(rng: np.random.Generator, scene: Scene) -> tuple[Camera, dict]:
    """Hand-held phone pose: 1–4 m from a point on the table, 20–80° down, eye 0.25–1.45 m above the cloth."""
    L, W = scene.length, scene.width
    for _ in range(1000):
        elevation = float(rng.choice([rng.uniform(20, 32), rng.uniform(32, 45), rng.uniform(45, 60), rng.uniform(60, 80)],
                                     p=[0.15, 0.25, 0.4, 0.2]))
        distance = float(rng.uniform(1.0, 4.0))
        height = distance * math.sin(math.radians(elevation))
        if 0.25 <= height <= 1.45:
            break
    target = np.array([L / 2 + rng.uniform(-0.3, 0.3) * L, W / 2 + rng.uniform(-0.25, 0.25) * W, 0.0])
    azimuth = rng.uniform(0, math.tau)
    horiz = distance * math.cos(math.radians(elevation))
    eye = target + np.array([math.cos(azimuth) * horiz, math.sin(azimuth) * horiz, height])
    fov = float(rng.uniform(60, 70))
    roll = float(rng.normal(0, 4))
    cam = Camera.look_at(eye, target, fov, roll)
    return cam, {"elevation_deg": elevation, "distance_m": distance, "height_m": height, "fov_deg": fov, "roll_deg": roll,
                 "azimuth": float(azimuth), "target": target.tolist()}


def jitter_camera(rng: np.random.Generator, base: dict, scale: float) -> Camera:
    """Hand shake between clip frames: ~mm–cm translation and sub-degree rotation."""
    target = np.array(base["target"]) + rng.normal(0, 0.01 * scale, 3) * np.array([1, 1, 0])
    el = math.radians(base["elevation_deg"] + rng.normal(0, 0.6 * scale))
    d = base["distance_m"] * (1 + rng.normal(0, 0.01 * scale))
    az = base["azimuth"] + rng.normal(0, 0.01 * scale)
    eye = target + np.array([math.cos(az) * d * math.cos(el), math.sin(az) * d * math.cos(el), d * math.sin(el)])
    return Camera.look_at(eye, target, base["fov_deg"], base["roll_deg"] + rng.normal(0, 0.5 * scale))


_DIGITS: dict[int, np.ndarray] = {}


def _digit_texture(n: int) -> np.ndarray:
    """1 = ink, 0 = white, on a 64×64 disc chart."""
    if n not in _DIGITS:
        t = np.zeros((64, 64), np.uint8)
        s = str(n)
        scale = 1.5 if len(s) == 1 else 1.1
        size = cv2.getTextSize(s, cv2.FONT_HERSHEY_DUPLEX, scale, 3)[0]
        cv2.putText(t, s, ((64 - size[0]) // 2, (64 + size[1]) // 2), cv2.FONT_HERSHEY_DUPLEX, scale, 255, 3, cv2.LINE_AA)
        _DIGITS[n] = t.astype(np.float32) / 255
    return _DIGITS[n]


def _ball_albedo(scene: Scene, ball: Ball, nl: np.ndarray) -> np.ndarray:
    """Albedo (linear) at local unit normals `nl` (N×3)."""
    n = ball.number
    white = srgb_to_linear(CUE_WHITE)
    out = np.empty((nl.shape[0], 3), np.float32)
    if n == 0:
        out[:] = white
        if scene.measles:
            dirs = np.array([[1, 0, 0], [-1, 0, 0], [0, 1, 0], [0, -1, 0], [0, 0, 1], [0, 0, -1]], np.float32)
            for d in dirs:
                out[(nl @ d) > math.cos(math.radians(9))] = srgb_to_linear((200, 30, 40))
        return out
    base = srgb_to_linear(scene.ball_set[n])
    if n >= 9:
        out[:] = white
        out[np.abs(nl[:, 2]) < math.sin(math.radians(36))] = base
    else:
        out[:] = base
    axes = [np.array([1.0, 0, 0])] + ([np.array([-1.0, 0, 0])] if scene.two_sided_numbers or n >= 9 else [])
    disc = math.radians(23.5)
    tex = _digit_texture(n)
    for a in axes:
        cosang = nl @ a
        inside = cosang > math.cos(disc)
        if not inside.any():
            continue
        e1 = np.array([0, 0, 1.0])
        e2 = np.cross(a, e1)
        u = (nl[inside] @ e2) / math.sin(disc)
        v = (nl[inside] @ e1) / math.sin(disc)
        tu = np.clip(((u + 1) / 2 * 63).astype(int), 0, 63)
        tv = np.clip(((1 - (v + 1) / 2) * 63).astype(int), 0, 63)
        ink = tex[tv, tu][:, None]
        out[inside] = white * (1 - ink) + srgb_to_linear((20, 20, 22)) * ink
        ring = inside & (cosang < math.cos(disc * 0.93))
        out[ring] = srgb_to_linear((60, 60, 60))
    return out


def render(scene: Scene, cam: Camera, rng: np.random.Generator, occluders: dict | None = None,
           post: dict | None = None) -> tuple[np.ndarray, list[dict], dict]:
    """Render one frame → (sRGB uint8 H×W×3 after the camera pipeline, ball ground truth, frame factors)."""
    L, W = scene.length, scene.width
    H, Wd = cam.height, cam.width
    eye = cam.eye.astype(np.float32)
    d = cam.rays()
    dz = d[..., 2]
    img = np.zeros((H, Wd, 3), np.float32)
    nan = np.float32(np.inf)

    def plane_hit(z):
        t = np.where(dz < -1e-6, (z - eye[2]) / np.where(dz < -1e-6, dz, -1), nan)
        return t, eye[0] + d[..., 0] * t, eye[1] + d[..., 1] * t

    pockets = scene.pockets()

    def in_pocket(x, y, grow=1.0):
        m = np.zeros(x.shape, bool)
        for px, py, pr in pockets:
            m |= (x - px) ** 2 + (y - py) ** 2 < (pr * grow) ** 2
        return m

    # Surfaces from highest to lowest; the first hit wins (all horizontal, camera above).
    tr, xr, yr = plane_hit(RAIL_H)
    rail = (np.abs(xr - L / 2) <= L / 2 + RAIL_OUTER) & (np.abs(yr - W / 2) <= W / 2 + RAIL_OUTER) & \
           ~((np.abs(xr - L / 2) <= L / 2 + CUSHION_W) & (np.abs(yr - W / 2) <= W / 2 + CUSHION_W)) & np.isfinite(tr)
    tn, xn, yn = plane_hit((NOSE_H + RAIL_H) / 2)
    cush = ~rail & (np.abs(xn - L / 2) <= L / 2 + CUSHION_W) & (np.abs(yn - W / 2) <= W / 2 + CUSHION_W) & \
           ~((np.abs(xn - L / 2) <= L / 2) & (np.abs(yn - W / 2) <= W / 2)) & np.isfinite(tn)
    t0, x0, y0 = plane_hit(0.0)
    under = ~rail & ~cush & np.isfinite(t0)
    cloth = under & (np.abs(x0 - L / 2) <= L / 2) & (np.abs(y0 - W / 2) <= W / 2)
    face = under & ~cloth & (np.abs(x0 - L / 2) <= L / 2 + CUSHION_W) & (np.abs(y0 - W / 2) <= W / 2 + CUSHION_W)
    hole = (rail & in_pocket(xr, yr, 1.15)) | (cush & in_pocket(xn, yn)) | ((cloth | face) & in_pocket(x0, y0))
    rail &= ~hole
    cush &= ~hole
    cloth &= ~hole
    face &= ~hole
    floor = ~(rail | cush | cloth | face | hole)

    lamps = scene.lamps

    def lit(px, py, pz, nz=1.0, sheen=0.0):
        """Irradiance at points (N,) on a horizontal surface, with ball shadows on the cloth."""
        e = np.zeros((px.shape[0], 3), np.float32) + scene.ambient
        pts = np.stack([px, py, np.full_like(px, pz)], -1)
        for lamp in lamps:
            v = lamp.pos[None, :] - pts
            dist2 = (v ** 2).sum(-1)
            dist = np.sqrt(dist2)
            cos = np.clip(v[:, 2] / dist * nz, 0, 1)
            irr = lamp.power * cos / np.maximum(dist2, 0.05)
            shadow = np.ones_like(irr)
            for b in scene.balls:
                c = np.array([b.x, b.y, BALL_R])
                near = (px - b.x) ** 2 + (py - b.y) ** 2 < 0.35 ** 2
                if not near.any():
                    continue
                pc = c[None, :] - pts[near]
                ln = v[near] / dist[near, None]
                along = (pc * ln).sum(-1)
                perp = np.sqrt(np.maximum((pc ** 2).sum(-1) - along ** 2, 0))
                pen = lamp.radius * np.maximum(along, 0) / np.maximum(dist[near] - along, 0.05) + 0.002
                occ = np.clip((BALL_R + pen - perp) / (2 * pen), 0, 1) * (along > 0)
                shadow[near] *= 1 - occ
            e += lamp.color[None, :] * (irr * shadow)[:, None]
            if sheen > 0:
                # Cloth sheen / glare: broad specular lobe toward the lamp's mirror direction.
                view = eye[None, :] - pts
                view /= np.linalg.norm(view, axis=-1, keepdims=True)
                half = view + v / dist[:, None]
                half /= np.linalg.norm(half, axis=-1, keepdims=True)
                spec = np.clip(half[:, 2], 0, 1) ** 40
                e += lamp.color[None, :] * (sheen * 6 * lamp.power * spec * shadow / np.maximum(dist2, 0.05))[:, None]
        return e

    # Cloth with felt texture, wear and contact AO.
    if cloth.any():
        cx, cy = x0[cloth], y0[cloth]
        texture = 1 + 0.035 * rng.standard_normal(cx.shape[0]).astype(np.float32)
        wa, wx, wy = scene.wear
        texture *= 1 + wa * np.exp(-(((cx / L - wx) ** 2) + ((cy / W - wy) ** 2)) / 0.02)
        albedo = scene.cloth[None, :] * texture[:, None]
        e = lit(cx, cy, 0.0, sheen=scene.cloth_sheen)
        ao = np.ones_like(cx)
        for b in scene.balls:
            r2 = (cx - b.x) ** 2 + (cy - b.y) ** 2
            ao *= 1 - 0.55 * np.exp(-r2 / (0.55 * BALL_R) ** 2)
        img[cloth] = albedo * e * ao[:, None]
    if cush.any():
        img[cush] = scene.cloth * 0.92 * lit(xn[cush], yn[cush], NOSE_H)
    if face.any():
        img[face] = scene.cloth * 0.45 * (lit(x0[face], y0[face], 0.0) * 0.6)
    if rail.any():
        grain = 1 + 0.08 * np.sin(xr[rail] * 90 + yr[rail] * 7)
        e = lit(xr[rail], yr[rail], RAIL_H)
        img[rail] = scene.rail[None, :] * grain[:, None] * e
        # Diamond sights.
        for k in range(1, 8):
            for (sx, sy) in [(L * k / 8, -0.1), (L * k / 8, W + 0.1)] + ([(-0.1, W * k / 4), (L + 0.1, W * k / 4)] if k < 4 else []):
                m = rail & ((xr - sx) ** 2 + (yr - sy) ** 2 < 0.007 ** 2)
                img[m] = 0.7 * lit(xr[m], yr[m], RAIL_H)
    img[hole] = 0.004
    if floor.any():
        tf, xf, yf = plane_hit(-0.76)
        far = floor & np.isfinite(tf)
        carpet = 0.8 + 0.2 * np.sin(xf[far] * 3.1 + np.sin(yf[far] * 2.3)) + 0.08 * rng.standard_normal(xf[far].shape)
        img[far] = (scene.ambient * 0.2 + 0.006) * carpet[:, None].astype(np.float32)
        img[floor & ~np.isfinite(tf)] = scene.ambient * 0.15

    # Distractors on cloth (approximate as flat-ish marks in cloth space, drawn into the cloth pixels).
    for dd in scene.distractors:
        if dd["kind"] == "chalk_mark" and cloth.any():
            m = cloth & ((x0 - dd["x"]) ** 2 / 0.03 ** 2 + (y0 - dd["y"]) ** 2 / 0.012 ** 2 < 1)
            img[m] = img[m] * 0.6 + srgb_to_linear((60, 120, 200)) * 0.4 * img[m].mean(-1, keepdims=True) * 4
        elif dd["kind"] == "speck" and cloth.any():
            m = cloth & ((x0 - dd["x"]) ** 2 + (y0 - dd["y"]) ** 2 < 0.006 ** 2)
            img[m] = 0.9 * lit(x0[m], y0[m], 0.0)

    # Balls: true spheres, nearest hit wins.
    depth = np.where(np.isfinite(t0), t0, nan).astype(np.float32)
    depth[rail] = tr[rail]
    depth[cush] = tn[cush]
    ids = np.full((H, Wd), -1, np.int16)
    full_area = []
    cloth_irr_mean = (scene.cloth * 0.25).astype(np.float32)
    for i, b in enumerate(scene.balls):
        c = np.array([b.x, b.y, BALL_R], np.float32)
        pr = cam.project(c)
        if pr is None:
            full_area.append(0)
            continue
        u, v, z = pr
        rpx = cam.fx * BALL_R / max(z - BALL_R, 1e-3) * 1.3 + 3
        x0b, x1b = int(max(0, u - rpx)), int(min(Wd, u + rpx + 1))
        y0b, y1b = int(max(0, v - rpx)), int(min(H, v + rpx + 1))
        if x0b >= x1b or y0b >= y1b:
            full_area.append(0)
            continue
        dr = d[y0b:y1b, x0b:x1b]
        oc = eye - c
        bq = (dr * oc).sum(-1)
        disc = bq * bq - (oc @ oc - BALL_R ** 2)
        hit = disc >= 0
        t = -bq - np.sqrt(np.maximum(disc, 0))
        hit &= t > 0
        full_area.append(int(hit.sum()))
        win = hit & (t < depth[y0b:y1b, x0b:x1b])
        if not win.any():
            continue
        tt = t[win]
        p = eye[None, :] + dr[win] * tt[:, None]
        n = (p - c[None, :]) / BALL_R
        nl = n @ b.rotation  # world normal → ball-local
        alb = _ball_albedo(scene, b, nl)
        view = -dr[win]
        col = np.zeros_like(alb)
        # Ambient: sky from above, cloth-coloured bounce from below.
        up = np.clip(n[:, 2], 0, 1)[:, None]
        down = np.clip(-n[:, 2], 0, 1)[:, None]
        col += alb * (scene.ambient[None, :] * (0.4 + 0.6 * up) + cloth_irr_mean[None, :] * down * 0.8)
        spec_total = np.zeros_like(alb)
        for lamp in lamps:
            lv = lamp.pos[None, :] - p
            dist2 = (lv ** 2).sum(-1)
            ln = lv / np.sqrt(dist2)[:, None]
            ndl = np.clip((n * ln).sum(-1), 0, 1)
            irr = lamp.power / np.maximum(dist2, 0.05)
            col += alb * lamp.color[None, :] * (ndl * irr)[:, None]
            h = ln + view
            h /= np.linalg.norm(h, axis=-1, keepdims=True)
            ndh = np.clip((n * h).sum(-1), 0, 1)
            # Clear-coat lamp reflection: sharp core (lamp disc) plus a soft lobe.
            shininess = 2.0 / max(lamp.radius, 0.03) ** 2 * 0.02
            spec_total += lamp.color[None, :] * ((ndh ** (shininess * 40) * 8 + ndh ** 60 * 0.3) * irr * (ndl > 0))[:, None]
        cosv = np.clip((n * view).sum(-1), 0, 1)
        fres = (0.04 + 0.96 * (1 - cosv) ** 5)[:, None]
        refl = 2 * cosv[:, None] * n - view
        env = np.where(refl[:, 2:3] < 0, cloth_irr_mean[None, :] * 0.8, scene.ambient[None, :] * 0.5)
        col = col * (1 - fres) + fres * env + spec_total * 0.5
        # Contact shading from the neighbour: darken where a touching ball blocks the side.
        for o in scene.balls:
            if o is b:
                continue
            dvec = np.array([o.x - b.x, o.y - b.y, 0.0])
            dn = np.linalg.norm(dvec)
            if dn < 3 * BALL_R:
                col *= (1 - 0.35 * np.clip((n @ (dvec / dn)) * (2.5 * BALL_R - dn) / BALL_R, 0, 1))[:, None]
        sub = img[y0b:y1b, x0b:x1b]
        sub[win] = col
        dsub = depth[y0b:y1b, x0b:x1b]
        dsub[win] = tt
        isub = ids[y0b:y1b, x0b:x1b]
        isub[win] = i

    # Chalk cubes (3D-ish: a projected square with a lit top) on rail or cloth, after balls (rarely overlap).
    for dd in scene.distractors:
        if dd["kind"] != "chalk_cube":
            continue
        zc = RAIL_H if dd["on_rail"] else 0.0
        x, y = (dd["x"], -0.1) if dd["on_rail"] else (dd["x"], dd["y"])
        s = 0.011
        a = math.radians(dd["angle"])
        top = [(x + s * (math.cos(a) * i - math.sin(a) * j), y + s * (math.sin(a) * i + math.cos(a) * j), zc + 0.022)
               for i, j in [(-1, -1), (1, -1), (1, 1), (-1, 1)]]
        base = [(px, py, zc) for px, py, _ in top]
        pts_top = [cam.project(q) for q in top]
        pts_base = [cam.project(q) for q in base]
        if any(q is None for q in pts_top + pts_base):
            continue
        poly = np.array([q[:2] for q in pts_base + pts_top], np.float32)
        hull = cv2.convexHull(poly).astype(np.int32)
        m = np.zeros((H, Wd), np.uint8)
        cv2.fillConvexPoly(m, hull, 1)
        side = srgb_to_linear((40, 90, 170)) * 0.5
        img[m > 0] = side
        mt = np.zeros((H, Wd), np.uint8)
        cv2.fillConvexPoly(mt, np.array([q[:2] for q in pts_top], np.float32).astype(np.int32), 1)
        img[mt > 0] = srgb_to_linear((50, 110, 200))

    # Moving balls: directional blur of the ball's neighbourhood along its image velocity (exposure ~1/60 s).
    blur_px = {}
    for i, b in enumerate(scene.balls):
        speed = math.hypot(*b.velocity)
        if speed < 1e-3:
            continue
        c = np.array([b.x, b.y, BALL_R])
        p0 = cam.project(c - np.array([*b.velocity, 0]) / 120)
        p1 = cam.project(c + np.array([*b.velocity, 0]) / 120)
        if p0 is None or p1 is None:
            continue
        du, dv = p1[0] - p0[0], p1[1] - p0[1]
        length = math.hypot(du, dv)
        blur_px[i] = length
        if length < 1.5:
            continue
        m = (ids == i).astype(np.float32)
        ys, xs = np.nonzero(m)
        if len(xs) == 0:
            continue
        pad = int(length) + 6
        bx0, bx1 = max(0, xs.min() - pad), min(Wd, xs.max() + pad + 1)
        by0, by1 = max(0, ys.min() - pad), min(H, ys.max() + pad + 1)
        k = int(math.ceil(length)) | 1
        kern = np.zeros((k, k), np.float32)
        cv2.line(kern, (int(k / 2 - du / length * k / 2), int(k / 2 - dv / length * k / 2)),
                 (int(k / 2 + du / length * k / 2), int(k / 2 + dv / length * k / 2)), 1.0, 1)
        kern /= kern.sum()
        patch = img[by0:by1, bx0:bx1]
        bm = cv2.filter2D(m[by0:by1, bx0:bx1], -1, kern)
        blurred = cv2.filter2D(patch, -1, kern)
        alpha = np.clip(np.maximum(bm, m[by0:by1, bx0:bx1]) * 1.0, 0, 1)[..., None]
        img[by0:by1, bx0:bx1] = patch * (1 - alpha) + blurred * alpha

    # Occluders (drawn last, nearest the camera): cue stick and bridge hand / forearm in image space.
    occ_mask = np.zeros((H, Wd), np.uint8)
    occluders = occluders or {}
    if occluders.get("stick") is not None:
        st = occluders["stick"]
        tip, butt = np.array(st["tip"]), np.array(st["butt"])
        pt, pb = cam.project(tip), cam.project(butt)
        if pt is not None and pb is not None:
            rt = max(2, cam.fx * 0.0065 / pt[2])
            rb = max(3, cam.fx * 0.015 / pb[2])
            a, bb = np.array(pt[:2]), np.array(pb[:2])
            dvec = bb - a
            if np.linalg.norm(dvec) > 1:
                nrm = np.array([-dvec[1], dvec[0]]) / np.linalg.norm(dvec)
                quad = np.array([a + nrm * rt, a - nrm * rt, bb - nrm * rb, bb + nrm * rb], np.int32)
                m = np.zeros((H, Wd), np.uint8)
                cv2.fillConvexPoly(m, quad, 1)
                shaft = srgb_to_linear(st.get("color", (214, 184, 140)))
                light = sum(l.power * l.color for l in lamps) / max(len(lamps), 1) * 0.6 + scene.ambient
                img[m > 0] = shaft * light
                occ_mask |= m
                # Ferrule and tip.
                m2 = np.zeros((H, Wd), np.uint8)
                cv2.circle(m2, tuple(a.astype(int)), int(rt * 1.1), 1, -1)
                img[m2 > 0] = srgb_to_linear((240, 240, 236)) * light
                occ_mask |= m2
    for hand in occluders.get("hands", []):
        center = cam.project(np.array(hand["center"]))
        if center is None:
            continue
        scale = cam.fx * hand["size"] / center[2]
        skin = srgb_to_linear(hand["skin"])
        sleeve = srgb_to_linear(hand["sleeve"])
        light = sum(l.power * l.color for l in lamps) / max(len(lamps), 1) * 0.5 + scene.ambient
        m = np.zeros((H, Wd), np.uint8)
        ang = hand["angle"]
        cu, cv_ = int(center[0]), int(center[1])
        # Forearm/sleeve: a thick band from the hand to the frame edge.
        far = (int(cu + math.cos(ang) * 4000), int(cv_ + math.sin(ang) * 4000))
        cv2.line(m, (cu, cv_), far, 1, max(4, int(scale * 0.9)))
        img[m > 0] = sleeve * light * 0.9
        occ_mask |= m
        m2 = np.zeros((H, Wd), np.uint8)
        cv2.ellipse(m2, (cu, cv_), (max(3, int(scale * 0.75)), max(2, int(scale * 0.45))), math.degrees(ang), 0, 360, 1, -1)
        for f in range(4):  # bridge fingers splayed on the cloth
            fa = ang + math.pi + (f - 1.5) * 0.35
            tipf = (int(cu + math.cos(fa) * scale * 1.2), int(cv_ + math.sin(fa) * scale * 1.2))
            cv2.line(m2, (cu, cv_), tipf, 1, max(2, int(scale * 0.18)))
        img[m2 > 0] = skin * light
        occ_mask |= m2

    # Ground truth: visibility = visible sphere pixels (after other balls and occluders) / full projected area.
    truth = []
    for i, b in enumerate(scene.balls):
        vis_px = int(((ids == i) & (occ_mask == 0)).sum())
        pr = cam.project(np.array([b.x, b.y, BALL_R]))
        truth.append({"number": b.number, "x": b.x, "y": b.y, "visible": vis_px / full_area[i] if full_area[i] else 0.0,
                      "full_px": full_area[i], "image": [pr[0], pr[1]] if pr else None,
                      "radius_px": float(cam.fx * BALL_R / pr[2]) if pr else 0.0,
                      "moving": bool(math.hypot(*b.velocity) > 1e-3), "blur_px": float(blur_px.get(i, 0.0))})

    out, factors = camera_pipeline(img, scene, rng, post or {})
    return out, truth, factors


def camera_pipeline(img: np.ndarray, scene: Scene, rng: np.random.Generator, post: dict) -> tuple[np.ndarray, dict]:
    """Linear scene radiance → phone JPEG (sRGB uint8)."""
    H, W = img.shape[:2]
    f: dict = {}
    # Veiling glare / lens flare: a bright blob plus haze (strong when a lamp or window is in view).
    if post.get("flare", rng.random() < 0.25):
        gx, gy = rng.uniform(0.15, 0.85) * W, rng.uniform(0.1, 0.8) * H
        yy, xx = np.ogrid[:H, :W]
        rr = ((xx - gx) ** 2 + (yy - gy) ** 2) / (rng.uniform(0.05, 0.25) * W) ** 2
        strength = float(rng.uniform(0.3, 1.5)) * float(np.median(img))
        img = img + (np.exp(-rr) * strength)[..., None].astype(np.float32) + strength * 0.08
        f["flare"] = True
    # Camera shake (global) blur.
    shake = float(post.get("shake_px", rng.choice([0, 0, 0, rng.uniform(2, 6), rng.uniform(6, 16)])))
    if shake >= 1.5:
        a = rng.uniform(0, math.pi)
        k = int(math.ceil(shake)) | 1
        kern = np.zeros((k, k), np.float32)
        cv2.line(kern, (int(k / 2 - math.cos(a) * k / 2), int(k / 2 - math.sin(a) * k / 2)),
                 (int(k / 2 + math.cos(a) * k / 2), int(k / 2 + math.sin(a) * k / 2)), 1.0, 1)
        img = cv2.filter2D(img, -1, kern / kern.sum())
    f["shake_px"] = shake
    # Optics: lens softness, vignetting, slight lateral chromatic aberration.
    img = cv2.GaussianBlur(img, (0, 0), float(rng.uniform(0.5, 1.0)))
    yy, xx = np.mgrid[:H, :W].astype(np.float32)
    r2 = ((xx - W / 2) ** 2 + (yy - H / 2) ** 2) / (W / 2) ** 2
    img *= (1 - float(rng.uniform(0.1, 0.35)) * r2)[..., None]
    ca = float(rng.uniform(0, 0.0012))
    if ca > 0:
        for ch, s in ((0, 1 + ca), (2, 1 - ca)):
            m = cv2.getRotationMatrix2D((W / 2, H / 2), 0, s)
            img[..., ch] = cv2.warpAffine(img[..., ch], m, (W, H), flags=cv2.INTER_LINEAR, borderMode=cv2.BORDER_REFLECT)
    # Auto exposure on the frame centre (meters the cloth), with an EV bias; auto white balance only partly
    # corrects the lamp colour.
    centre = img[H // 4: 3 * H // 4, W // 4: 3 * W // 4]
    meter = float(np.mean(centre.mean(-1)))
    ev = float(post.get("ev", rng.normal(0, 0.45)))
    img = img * (0.16 / max(meter, 1e-5)) * 2 ** ev
    illum = np.mean([l.color for l in scene.lamps], axis=0)
    correction = float(rng.uniform(0.5, 0.95))
    wb = (1 / illum) ** correction
    wb = wb / wb[1] * rng.uniform(0.96, 1.04, 3)
    img = img * wb[None, None, :].astype(np.float32)
    f["ev"], f["wb_correction"] = ev, correction
    # Sensor noise (shot + read), stronger in dim scenes (higher ISO).
    gain = float(np.clip(0.18 / max(meter, 1e-5) / 30, 0.3, 4.0))
    shot = np.sqrt(np.clip(img, 0, None) * 0.0016 * gain).astype(np.float32)
    img = img + rng.standard_normal(img.shape, dtype=np.float32) * (shot + 0.002 * gain)
    f["iso_gain"] = gain
    # ISP: light denoise, tone curve (sRGB + mild S), 4:2:0 chroma, sharpening, JPEG.
    img = cv2.GaussianBlur(img, (0, 0), 0.6 * min(gain, 2))
    out = linear_to_srgb(img / (1 + 0.15 * img))
    out = np.clip(out * 255 + 0.5, 0, 255).astype(np.uint8)
    ycc = cv2.cvtColor(out, cv2.COLOR_RGB2YCrCb)
    for ch in (1, 2):
        small = cv2.resize(ycc[..., ch], (W // 2, H // 2), interpolation=cv2.INTER_AREA)
        ycc[..., ch] = cv2.resize(small, (W, H), interpolation=cv2.INTER_LINEAR)
    out = cv2.cvtColor(ycc, cv2.COLOR_YCrCb2RGB)
    sharp = cv2.addWeighted(out, 1.35, cv2.GaussianBlur(out, (0, 0), 1.2), -0.35, 0)
    quality = int(post.get("jpeg", rng.integers(55, 93)))
    ok, enc = cv2.imencode(".jpg", cv2.cvtColor(sharp, cv2.COLOR_RGB2BGR), [cv2.IMWRITE_JPEG_QUALITY, quality])
    assert ok
    out = cv2.cvtColor(cv2.imdecode(enc, cv2.IMREAD_COLOR), cv2.COLOR_BGR2RGB)
    f["jpeg"] = quality
    f["jpeg_bytes"] = enc
    return out, f


def make_occluders(rng: np.random.Generator, scene: Scene, cam_info: dict) -> dict:
    """A cue stick aimed at the cue ball and a bridge hand behind it (as when a player is down on a shot)."""
    occ: dict = {"hands": []}
    cue = next((b for b in scene.balls if b.number == 0), None)
    if cue is None and scene.balls:
        cue = scene.balls[0]
    if cue is None:
        ax, ay = rng.uniform(0.3, scene.length - 0.3), rng.uniform(0.2, scene.width - 0.2)
    else:
        ax, ay = cue.x, cue.y
    a = rng.uniform(0, math.tau)
    u = np.array([math.cos(a), math.sin(a)])
    gap = rng.uniform(0.01, 0.06)
    tip = np.array([ax, ay]) - u * (BALL_R + gap)
    butt = tip - u * 1.45
    occ["stick"] = {"tip": [tip[0], tip[1], BALL_R * 1.2], "butt": [butt[0], butt[1], BALL_R * 1.2 + 0.25]}
    bridge = tip - u * rng.uniform(0.12, 0.22)
    skins = [(236, 196, 160), (198, 140, 100), (141, 90, 60), (90, 58, 40)]
    sleeves = [(30, 30, 34), (200, 200, 205), (60, 70, 120), (130, 30, 30)]
    occ["hands"].append({"center": [bridge[0], bridge[1], 0.03], "size": 0.06, "angle": float(a + math.pi / 2 + rng.normal(0, 0.4)),
                         "skin": skins[int(rng.integers(len(skins)))], "sleeve": sleeves[int(rng.integers(len(sleeves)))]})
    if rng.random() < 0.4 and scene.balls:  # another hand resting near some ball
        b = scene.balls[int(rng.integers(len(scene.balls)))]
        occ["hands"].append({"center": [b.x + rng.normal(0, 0.06), b.y + rng.normal(0, 0.06), 0.05], "size": 0.07,
                             "angle": float(rng.uniform(0, math.tau)), "skin": skins[int(rng.integers(len(skins)))],
                             "sleeve": sleeves[int(rng.integers(len(sleeves)))]})
    return occ

#!/usr/bin/env python3
"""Generate deterministic Swift validation fixtures with pooltool 0.6.0."""

from __future__ import annotations

import json
import math
import random
from pathlib import Path

import pooltool as pt
from pooltool.objects.table.specs import PocketTableSpecs
from pooltool.physics import PhysicsEngine, Resolver
from pooltool.physics.resolve.ball_ball.friction import AlciatoreBallBallFriction
from pooltool.physics.resolve.ball_pocket import CanonicalBallPocket
from pooltool.physics.resolve.stick_ball.instantaneous_point import InstantaneousPoint
from pooltool.physics.resolve.transition import CanonicalTransition

ROOT = Path(__file__).resolve().parents[2]
OUTPUT = ROOT / "Packages/CueCore/Tests/PhysicsTests/Fixtures/pooltool_fixtures.json"
SEED = 20261106
RADIUS = 0.028575
MASS = 0.170097
GRAVITY = 9.81
MU_SLIDE = 0.2
MU_ROLL = 0.01
MU_SP_PROPORTIONALITY = 4.0 / 9.0
MU_BALL_BALL_A = 0.009951
MU_BALL_BALL_B = 0.108
MU_BALL_BALL_C = 1.088
E_BALL = 0.95
E_CUSHION = 0.85
F_CUSHION = 0.2
MU_BALL_BALL = 0.05  # BallParams value retained in the header; Alciatore friction is selected.
CUEMASS = 0.567
CUE_END_MASS = MASS / 30
CUE_TIP_RADIUS = 0.0106045
CUSHION_HEIGHT = 0.036576
TABLES = {
    "sevenFoot": (80 * 0.0254, 40 * 0.0254),
    "nineFoot": (100 * 0.0254, 50 * 0.0254),
}
POCKET_IDS = {
    "lt": "footLeft",
    "rt": "footRight",
    "lc": "sideLeft",
    "rc": "sideRight",
    "lb": "headLeft",
    "rb": "headRight",
}

PHYSICAL_PARAMS = {
    "m": MASS,
    "R": RADIUS,
    "u_s": MU_SLIDE,
    "u_r": MU_ROLL,
    "u_sp_proportionality": MU_SP_PROPORTIONALITY,
    "u_b": MU_BALL_BALL,
    "e_b": E_BALL,
    "e_c": E_CUSHION,
    "f_c": F_CUSHION,
    "g": GRAVITY,
}

FRICTION = AlciatoreBallBallFriction(
    a=MU_BALL_BALL_A,
    b=MU_BALL_BALL_B,
    c=MU_BALL_BALL_C,
)
RESOLVER = Resolver(
    ball_ball=pt.physics.ball_ball_models["frictional_inelastic"](friction=FRICTION),
    ball_linear_cushion=pt.physics.ball_lcushion_models["han_2005"](),
    ball_circular_cushion=pt.physics.ball_ccushion_models["han_2005"](),
    ball_pocket=CanonicalBallPocket(),
    stick_ball=InstantaneousPoint(english_throttle=1.0, squirt_throttle=1.0),
    transition=CanonicalTransition(),
)
ENGINE = PhysicsEngine(resolver=RESOLVER)


def table_spec(size: str) -> tuple[float, float, PocketTableSpecs]:
    length, width = TABLES[size]
    return length, width, PocketTableSpecs(
        l=length,
        w=width,
        corner_pocket_width=4.5 * 0.0254,
        side_pocket_width=5.0 * 0.0254,
        cushion_height=CUSHION_HEIGHT,
    )


def point(x: float, y: float) -> dict[str, float]:
    return {"x": round(x, 9), "y": round(y, 9)}


def make_shot(
    shot_id: str,
    tag: str,
    size: str,
    positions: list[tuple[int, float, float]],
    direction: tuple[float, float],
    speed: float,
    tip: tuple[float, float],
) -> dict:
    length, width, specs = table_spec(size)
    # pooltool stores transverse position in x and lengthwise position in y, with +y
    # toward the foot rail. CueCoach +x points toward the head rail.
    table = pt.Table.from_table_specs(specs)
    balls: dict[str, pt.Ball] = {}
    initial_balls = []
    for number, x, y in positions:
        ball_id = "cue" if number == 0 else str(number)
        balls[ball_id] = pt.Ball.create(ball_id, xy=(y, length - x), **PHYSICAL_PARAMS)
        initial_balls.append({"id": number, "position": point(x, y)})

    dx, dy = direction
    norm = math.hypot(dx, dy)
    dx, dy = dx / norm, dy / norm
    a, b = tip
    # Cue.V0 is cue-stick speed. Convert the requested launch speed using cue_strike's
    # theta=0 equal-sphere impulse equation so JSON `speed` matches Stroke.speed.
    impact_speed = speed * (1 + MASS / CUEMASS + 2.5 * (a * a + b * b)) / 2
    phi = math.degrees(math.atan2(-dx, dy)) % 360
    cue = pt.Cue(
        V0=impact_speed,
        phi=phi,
        theta=0,
        a=a,
        b=b,
        cue_ball_id="cue",
    )
    system = pt.System(cue=cue, table=table, balls=balls)
    result = pt.simulate(system, engine=ENGINE, max_events=4096)

    events = []
    event_names = {
        "ball_ball": "ballBall",
        "ball_linear_cushion": "cushion",
        "ball_circular_cushion": "cushion",
        "ball_pocket": "pocket",
        "sliding_rolling": "slideToRoll",
        "rolling_stationary": "rest",
        "rolling_spinning": "rest",
        "spinning_stationary": "spinOff",
    }
    for event in result.events:
        kind = event.event_type.value
        if kind not in event_names:
            continue
        ball_ids = []
        event_ball_ids = event.ids[:2] if kind == "ball_ball" else event.ids[:1]
        for event_id in event_ball_ids:
            if event_id == "cue":
                ball_ids.append(0)
            elif event_id.isdigit():
                ball_ids.append(int(event_id))
        record = {
            "type": event_names[kind],
            "ballIDs": ball_ids,
            "time": round(event.time, 9),
        }
        if kind in ("ball_linear_cushion", "ball_circular_cushion"):
            record["cushionID"] = event.ids[-1]
        if kind == "ball_pocket":
            record["pocket"] = POCKET_IDS.get(event.ids[-1], event.ids[-1])
        events.append(record)

    final_balls = []
    pocketed = []
    for number, _, _ in positions:
        ball_id = "cue" if number == 0 else str(number)
        ball = result.balls[ball_id]
        # Reverse the pooltool axes and its foot-to-head orientation.
        final_balls.append({"id": number, "position": point(length - float(ball.xyz[1]), float(ball.xyz[0]))})
        if ball.state.s == pt.constants.pocketed:
            pocketed.append(number)

    return {
        "id": shot_id,
        "tag": tag,
        "table": {"size": size, "lengthM": round(length, 9), "widthM": round(width, 9)},
        "initial": {"balls": initial_balls},
        "stroke": {
            "direction": point(dx, dy),
            "speed": round(speed, 9),
            "tipOffset": point(a, b),
        },
        "events": events,
        "final": {"balls": final_balls, "pocketed": sorted(pocketed)},
    }


REGRESSION_DATA = {
    193: ("nineFoot", [(0, 0.161942092, 0.500619758), (1, 1.208684328, 0.639143947)],
          (-0.244206032, -0.969723370), 5.575061323, (-0.027689204, -0.003647292)),
    304: ("sevenFoot", [(0, 1.431628285, 0.603774879), (1, 0.501122431, 0.729559151)],
          (0.422231274, -0.906488142), 5.601724, (-0.256742300, 0.234828431)),
    319: ("sevenFoot", [(0, 1.527667770, 0.378614170), (1, 0.881709946, 0.338370389),
                         (2, 1.302294834, 0.836128685), (3, 1.018740385, 0.746567662),
                         (4, 0.205108529, 0.624978949)],
          (0.830838569, -0.556513497), 4.136170284, (-0.258141780, -0.213549916)),
    444: ("nineFoot", [(0, 0.646183994, 0.314647111), (1, 0.261546997, 0.477904498)],
          (-0.059844453, -0.998207715), 5.113370358, (-0.472840557, 0.098151851)),
}


def regression_shots() -> list[dict]:
    return [
        make_shot(f"random_{index:03d}", "regression", size, positions, direction, speed, tip)
        for index, (size, positions, direction, speed, tip) in REGRESSION_DATA.items()
    ]


def random_shots(rng: random.Random) -> list[dict]:
    shots = []

    def random_tip(low: float, high: float) -> tuple[float, float]:
        angle = rng.uniform(0, math.tau)
        radius = rng.uniform(low, high)
        return radius * math.cos(angle), radius * math.sin(angle)

    def random_position(size: str, existing: list[tuple[int, float, float]], gap: float) -> tuple[float, float]:
        length, width = TABLES[size]
        for _ in range(20_000):
            x = rng.uniform(RADIUS + 0.08, length - RADIUS - 0.08)
            y = rng.uniform(RADIUS + 0.08, width - RADIUS - 0.08)
            if all(math.hypot(x - px, y - py) >= gap for _, px, py in existing):
                return x, y
        raise RuntimeError("could not place non-overlapping balls")

    for index in range(1, 501):
        category = "break" if index <= 50 else ("cluster" if index <= 150 else "sparse")
        size = rng.choice(tuple(TABLES))
        length, width = TABLES[size]
        object_count = rng.randint(7, 14)
        positions: list[tuple[int, float, float]] = []
        if category == "break":
            apex_x = length * 0.72
            center_y = width / 2
            # Seed small rack spacing errors like a loosely set real rack.
            diameter = 2 * RADIUS + 1e-6 + rng.uniform(0.00005, 0.0002)
            for row in range(5):
                for column in range(row + 1):
                    positions.append((len(positions) + 1,
                                      apex_x + row * diameter * math.sqrt(3) / 2,
                                      center_y + (column - row / 2) * diameter))
            cue_y = center_y
            positions.insert(0, (0, length * 0.22, cue_y))
            angle = 0.0
            speed = rng.uniform(6.0, 11.0)
            tip = (0.0, 0.0)
        elif category == "cluster":
            diameter = 2 * RADIUS + 1e-6
            cluster_count = rng.randint(2, min(4, object_count))
            cluster_x = rng.uniform(length * 0.38, length * 0.66)
            cluster_y = rng.uniform(width * 0.35, width * 0.65)
            number = 1
            for row in range(5):
                for column in range(row + 1):
                    if number > cluster_count:
                        break
                    positions.append((number, cluster_x + row * diameter * math.sqrt(3) / 2,
                                      cluster_y + (column - row / 2) * diameter))
                    number += 1
                if number > cluster_count:
                    break
            for number in range(cluster_count + 1, object_count + 1):
                x, y = random_position(size, positions, diameter + 0.04)
                positions.append((number, x, y))
            cue_x, cue_y = random_position(size, positions, diameter + 0.04)
            positions.insert(0, (0, cue_x, cue_y))
            angle = rng.uniform(0, math.tau)
            speed = rng.uniform(6.0, 9.0) if rng.random() < 0.02 else rng.uniform(0.5, 4.5)
            tip = random_tip(0.04, 0.28)
        else:
            for number in range(1, object_count + 1):
                x, y = random_position(size, positions, 2 * RADIUS + 0.04)
                positions.append((number, x, y))
            cue_x, cue_y = random_position(size, positions, 2 * RADIUS + 0.04)
            positions.insert(0, (0, cue_x, cue_y))
            angle = rng.uniform(0, math.tau)
            speed = rng.uniform(6.0, 9.0) if rng.random() < 0.02 else rng.uniform(0.5, 4.5)
            tip = random_tip(0.04, 0.28)
        shots.append(
            make_shot(
                f"stress_{index:03d}",
                category,
                size,
                positions,
                (math.cos(angle), math.sin(angle)),
                speed,
                tip,
            )
        )
    return shots


def simple_shots() -> list[dict]:
    shots = []
    index = 0

    def add(name: str, size: str, positions: list[tuple[int, float, float]], direction: tuple[float, float],
            speed: float, tip: tuple[float, float]) -> None:
        nonlocal index
        index += 1
        shots.append(make_shot(f"simple_{index:02d}_{name}", "simple", size, positions, direction, speed, tip))

    for size, speed in [("sevenFoot", 2.0), ("nineFoot", 3.0), ("sevenFoot", 4.0), ("nineFoot", 5.0)]:
        length, width = TABLES[size]
        cue = (length * 0.24, width / 2)
        obj = (cue[0] + 0.42, cue[1])
        add("stop", size, [(0, *cue), (1, *obj)], (1, 0), speed, (0, 0))

    for offset in [1.0, 1.2, 1.4, 1.6]:
        length, width = TABLES["sevenFoot"]
        cue = (length * 0.24, width * 0.48)
        obj = (cue[0] + 0.42, cue[1] + RADIUS * offset)
        add("half_cut", "sevenFoot", [(0, *cue), (1, *obj)], (1, 0), 3.5, (0, 0))

    for size, speed in [("sevenFoot", 2.5), ("nineFoot", 3.0), ("sevenFoot", 3.5), ("nineFoot", 4.0)]:
        length, width = TABLES[size]
        cue = (length * 0.45, width * 0.30)
        obj = (cue[0], width * 0.72)
        add("rail_first", size, [(0, *cue), (1, *obj)], (0, -1), speed, (0.12, 0))

    for size, speed in [("sevenFoot", 0.65), ("nineFoot", 0.75), ("sevenFoot", 0.9), ("nineFoot", 1.0)]:
        length, width = TABLES[size]
        cue = (0.24, 0.19)
        obj = (length * 0.65, width * 0.65)
        direction = (-cue[0], -cue[1])
        add("slow_pocket", size, [(0, *cue), (1, *obj)], direction, speed, (0, 0))

    for size, speed, draw in [("sevenFoot", 3.5, -0.35), ("nineFoot", 4.0, -0.3)]:
        length, width = TABLES[size]
        cue = (length * 0.26, width * 0.5)
        obj = (cue[0] + 0.28, cue[1])
        add("draw", size, [(0, *cue), (1, *obj)], (1, 0), speed, (0, draw))

    for size, speed, follow in [("sevenFoot", 3.5, 0.35), ("nineFoot", 4.0, 0.3)]:
        length, width = TABLES[size]
        cue = (length * 0.26, width * 0.5)
        obj = (cue[0] + 0.28, cue[1])
        add("follow", size, [(0, *cue), (1, *obj)], (1, 0), speed, (0, follow))

    return shots


def main() -> None:
    if pt.__version__ != "0.6.0":
        raise RuntimeError(f"expected pooltool 0.6.0, found {pt.__version__}")
    shots = random_shots(random.Random(SEED)) + regression_shots() + simple_shots()
    fixture = {
        "formatVersion": 1,
        "pooltoolVersion": pt.__version__,
        "seed": SEED,
        "models": {
            "ballBall": "frictional_inelastic + alciatore",
            "ballLinearCushion": "han_2005",
            "ballCircularCushion": "han_2005",
            "ballPocket": "canonical",
            "cueStrike": "instantaneous_point",
            "slideRollSpin": "evolve_ball_motion",
            "transition": "canonical",
        },
        "constants": {
            "units": "SI; angles are radians in Swift stroke vectors",
            "ballRadiusM": RADIUS,
            "ballMassKg": MASS,
            "muSlide": MU_SLIDE,
            "muRoll": MU_ROLL,
            "muSpinProportionalityPerM": MU_SP_PROPORTIONALITY,
            "muSpinM": RADIUS * MU_SP_PROPORTIONALITY,
            "muBallBallNominal": MU_BALL_BALL,
            "muBallBallAlciatore": {"a": MU_BALL_BALL_A, "b": MU_BALL_BALL_B, "cPerMps": MU_BALL_BALL_C},
            "eBallBall": E_BALL,
            "eCushion": E_CUSHION,
            "fCushion": F_CUSHION,
            "cushionHeightM": CUSHION_HEIGHT,
            "cushionWidthM": 0.0508,
            "cornerPocketDepthM": 0.0417,
            "cornerPocketRadiusM": 0.062,
            "cornerPocketAngleDegrees": 5.3,
            "cornerJawRadiusM": 0.02095,
            "sidePocketDepthM": 0.0685,
            "sidePocketRadiusM": 0.0645,
            "sidePocketAngleDegrees": 7.14,
            "sideJawRadiusM": 0.00795,
            "gravityMps2": GRAVITY,
            "cueMassKg": CUEMASS,
            "cueEndMassKg": CUE_END_MASS,
            "cueTipRadiusM": CUE_TIP_RADIUS,
            "cueTipRadiusUse": "pooltool 0.6.0 instantaneous_point solver uses normalized a,b directly",
            "englishThrottle": 1.0,
            "squirtThrottle": 1.0,
            "cueElevationRadians": 0.0,
            "tablePresets": {
                key: {"lengthM": length, "widthM": width}
                for key, (length, width) in TABLES.items()
            },
            "cornerPocketMouthM": 4.5 * 0.0254,
            "sidePocketMouthM": 5.0 * 0.0254,
            "han2005Restitution": "constant e_c=0.85 in pooltool 0.6.0",
        },
        "coordinateMapping": {
            "cuecoach": "origin foot-left cushion nose; +x to head rail; +y to opposite long rail",
            "pooltool": "x is transverse and y is lengthwise; +y points toward the foot rail; origin is head-left",
            "conversion": "pooltool(x,y) = cuecoach(y,length-x); directions rotate by -90 degrees",
        },
        "shots": shots,
    }
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(json.dumps(fixture, separators=(",", ":")) + "\n")
    size = OUTPUT.stat().st_size
    if size > 5 * 1024 * 1024:
        OUTPUT.unlink()
        raise RuntimeError(f"fixture file exceeded 5 MiB ({size} bytes)")
    print(f"Wrote {len(shots)} shots ({size:,} bytes) to {OUTPUT}")


if __name__ == "__main__":
    main()

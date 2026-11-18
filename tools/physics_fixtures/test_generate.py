import unittest
from types import SimpleNamespace

import generate


class FixtureGeneratorTests(unittest.TestCase):
    def test_point_preserves_full_float_precision(self):
        x = 0.12345678901234568
        y = -0.9876543210987654

        self.assertEqual(generate.point(x, y), {"x": x, "y": y})

    def test_sanity_audit_rejects_far_contacts_and_position_jumps(self):
        def state(x, time):
            return SimpleNamespace(
                rvw=((x, 0, 0), (0.01, 0, 0), (0, 0, 0)),
                t=time,
            )

        event = SimpleNamespace(
            event_type=SimpleNamespace(value="ball_ball"),
            agents=(
                SimpleNamespace(
                    id="1",
                    agent_type=SimpleNamespace(value="ball"),
                    initial=SimpleNamespace(xyz=(0, 0, 0)),
                    final=SimpleNamespace(xyz=(0.41, 0, 0)),
                ),
                SimpleNamespace(
                    id="2",
                    agent_type=SimpleNamespace(value="ball"),
                    initial=SimpleNamespace(xyz=(0.41, 0, 0)),
                    final=SimpleNamespace(xyz=(0.41, 0, 0)),
                ),
            ),
        )
        result = SimpleNamespace(
            events=[event],
            balls={"1": SimpleNamespace(history=SimpleNamespace(states=[state(0, 0), state(0.41, 0)]))},
        )

        audit = getattr(generate, "sanity_issues", None)
        issues = audit(result) if audit else []

        self.assertTrue(any("ball-ball contact" in issue for issue in issues))
        self.assertTrue(any("position jump" in issue for issue in issues))


if __name__ == "__main__":
    unittest.main()

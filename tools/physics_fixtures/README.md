# Physics fixtures

Run `uv run generate.py` from this directory. The generator requires pooltool 0.6.0 and writes
`Packages/CueCore/Tests/PhysicsTests/Fixtures/pooltool_fixtures.json`.

The pooltool table uses transverse `x` and lengthwise `y` axes, with positive `y` toward the
foot rail. CueCoach uses lengthwise `x` toward the head rail and transverse `y`. The conversion
is `pooltool(x, y) = cuecoach(y, length - x)`; directions and velocities use the matching
rotation. The fixture header contains the resolver model names and all ball, cue, cushion,
pocket, and table constants used to generate the records.

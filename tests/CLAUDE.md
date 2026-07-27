# Test suite

GUT (`addons/gut/`). Tests live under `tests/unit/`, mirroring the source layout
— `rules/`, `game/`, `ai/`, `state/`, `controllers/`, `ui/`, `input/`.

## Running

```
bash .claude/hooks/run-gut.sh                          # full suite
bash .claude/hooks/run-gut.sh -gdir=res://tests/unit/state   # one directory
bash .claude/hooks/run-gut.sh -gdir=res://benchmarks         # benchmarks (not in the default suite)
```

Full suite ≈ 15–18 s locally. **On Windows, redirect rather than pipe** — the
console exe throttles badly on an MSYS pipe (≈90 s vs ≈18 s). On the web, run
`.claude/hooks/wait-for-godot.sh` once first; piping is fine on Linux.

CI runs GUT on every push and PR (`.github/workflows/test.yml`), and the export
job in `deploy.yml` gates on tests passing.

## What gets a test

The domain layer is pure GDScript with no engine APIs, so it is fully testable
headless — every new rule class, domain state type, and reconcile change ships
with a GUT test. Controllers and actors are tested where their logic is
extractable; scene-dependent behavior is verified by the user in a local session.

## Calibration and characterisation tests

Some suites are not pass/fail assertions about a single function but **pinned
measurements** of emergent behavior — the goalie beatability sweeps, the shot
value/angle tables, the blade lever calibration, the AI action-scoring ordering
table. They exist to catch silent drift when an upstream number moves.

When one fails, the question is *"did the behavior change on purpose?"* — not
*"which assertion do I loosen?"* Re-pin the table only once you have confirmed
the new numbers are the intended ones, and say so in the commit.

## Benchmarks

`benchmarks/` holds report-only host-cost scenarios plus a per-evaluator
micro-bench. They are outside the default suite. **AI performance changes run
them** and compare before/after tables — especially per-tick p95/max (host FPS is
set by the worst tick) and the per-call evaluator ranking.

## Determinism

Domain code must be replay-safe: the same inputs produce the same outputs, or
reconcile replay diverges from the host. Tests that touch AI or physics must not
depend on wall-clock time or unseeded randomness.

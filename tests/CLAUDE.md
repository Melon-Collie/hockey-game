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

## Netcode harnesses

Two deterministic simulations under `tests/harness/`, covering the two halves of
the netcode plumbing. Neither is a physics harness — nothing in either one
skates. They exist because every netcode defect found so far has lived in the
plumbing (clocks, queues, buffers, ordering), and every one was found by reading
code or post-hoc telemetry rather than by a failing test.

**Both share one load-bearing property: each can reproduce a KNOWN bug on
demand.** Each has a mode flag selecting the legacy behaviour, and a test
asserting the legacy mode still fails. If one of those tests ever goes green, the
harness has stopped modelling the effect and every other assertion in the file is
worthless — **fix the harness, don't delete the test.**

### Input timing

`net_timing_harness.gd` covers the input pipeline: physics-step scheduling
against the render loop, stamping, the link, the host's dedupe/gate/drain, and
the lead servo.

It runs the real `NetworkManager.next_sim_offset` and the real `ClockSync` servo;
the dedupe/gate/drain rules are mirrors of `RemoteController` (a Node that can't
be stood up headless) pinned to the same constants.

`StampMode` switches between legacy wall-clock stamping and the shipping
tick-domain clock, and `test_legacy_wall_stamping_loses_inputs_at_60fps` is this harness's teeth.

`test_net_timing_harness.gd` sweeps client framerates (including 75/100/144,
which do NOT divide the 120 Hz tick and so produce an irregular step pattern)
against a latency matrix, asserting: stamps never collide, no input is dropped as
a duplicate, the drain never fires on a clean link, queue depth stays bounded,
the lead servo settles below its ceiling, and pop-overdue does not track
framerate.

### Claim rewind

`net_rewind_harness.gd` covers the other half: does every lookup a claim resolver
makes land inside the host's state buffer, and do client and host agree on the
depth they reconstruct a remote body at? It runs the real
`StateBufferManager.get_state_at` (the future-query clamp is the thing under
test) and the real `LagCompRewind` view-times; only the ring WRITE is mirrored,
since `capture()` needs live controllers.

`ResolveMode` selects resolve-on-arrival (legacy) vs holding until the buffer
covers the instant (`DeferredClaimQueue`, shipping).
`test_resolving_on_arrival_overruns_the_buffer` is this harness's teeth, and
`test_a_fast_link_overruns_worse_than_a_slow_one` pins the counter-intuitive
shape that made the bug hard to find by playing: the CLEANER the link, the
further past the buffer the lookup lands.

`warmup_skipped` is reported rather than silently excluded — a claim stamped
before the ring is deep enough to hold its own rewind can only say "the session
just started", so a test can tell "excluded a warmup claim" from "asserted
nothing".

When adding netcode timing or rewind behaviour, add the assertion here first.

## Benchmarks

`benchmarks/` holds report-only host-cost scenarios plus a per-evaluator
micro-bench. They are outside the default suite. **AI performance changes run
them** and compare before/after tables — especially per-tick p95/max (host FPS is
set by the worst tick) and the per-call evaluator ranking.

## Determinism

Domain code must be replay-safe: the same inputs produce the same outputs, or
reconcile replay diverges from the host. Tests that touch AI or physics must not
depend on wall-clock time or unseeded randomness.

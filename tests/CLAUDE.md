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

**On the web the full suite is ≈300 s**, not 15–18 — measured, 4179 tests. The
cost is concentrated in the live-goalie sweeps under `tests/unit/ai/`, which
drive the real `GoalieController` tick-by-tick over large shot grids. Use
`-gselect=<script substring>` to run one of them while iterating; the full suite
is a several-minute commitment there rather than a quick check.

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

## Ratchets

`test_no_god_class_growth.gd` is not an assertion about behavior — it is a
one-way gate on the *shape* of `Scripts/`: 800 lines a file, 25 public functions
a class. Files already over those lines when it went in are grandfathered in a
table, pinned at the size they were.

When it fires it is saying one of three things, and only the first is about the
code you just wrote:

- **grew past its allowance** — split it, or bump the number. Bumping is allowed
  and is not cheating; the ratchet exists to make growth deliberate and visible
  in the diff, not impossible. Say why in the commit.
- **shrank well below its allowance** — you won something. Tighten the entry so
  the space cannot be re-spent quietly. This is the click that makes it a
  ratchet rather than a cap.
- **is now under the limit** — the file graduated; delete its entry.

The same shape suits any "this must not get worse" property.
`test_ui_uses_the_locale_seam.gd` is the second one: untranslated string
literals per file under `Scripts/ui/`, with the migrated live-match surfaces
pinned at zero and the menu files pinned at what they had. What makes the shape
work is that the grandfather table is the backlog written down: un-growable
rather than invisible.

## Netcode harnesses

Three deterministic simulations under `tests/harness/`. None is a physics
harness — nothing in any of them skates. They exist because every netcode defect found so far has lived in the
plumbing (clocks, queues, buffers, ordering), and every one was found by reading
code or post-hoc telemetry rather than by a failing test.

**All three share one load-bearing property: each can reproduce a KNOWN effect
on demand.** Each has a mode flag selecting the legacy behaviour, and a test
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

### Claim geometry

`net_geometry_harness.gd` answers what the other two deliberately leave open:
they assert the lookup was in RANGE, this asserts the ANSWER was right. When the
client sees its blade reach the puck, does the host's rewind agree? A false
negative is a claim the player earned and the host refused — the quantity behind
the host row's `pickup_claim_misses`.

The player aims at what they SEE (blade placed on the rendered puck), so the
client's own view always connects and the host's verdict is the entire
measurement. The blade is exact on both sides — locally predicted, then read
from the buffer rather than re-predicted — so **every disagreement is puck
prediction error and nothing else.**

The puck SOLVER is deliberately not modelled: client and host run the identical
shared step from the identical snapshot, so it contributes zero divergence by
construction. What decides a miss is prediction SPAN against events the client
could not know about, so the puck moves at constant velocity and the host injects
unmodelled deflections — which REDIRECT the puck at constant speed rather than
adding energy, or every distance in the result grows with run length. The
threshold is geometric and worth remembering:

    a miss needs   velocity error > pickup_radius / (one_way + lead)

about 5.5 m/s at 30 ms RTT — which is why gentle perturbations produce a 0% miss
rate rather than a small one.

Two flags, and the pairing is the point:

- `RenderMode` — where the CLIENT draws the puck: host-present (pre-v59) or
  host-present + input lead (shipping). This comparison is the harness's teeth,
  and it measured the regression a single playtest could not separate.
- `AdjudicationMode` — how the HOST answers "where was the puck": look up truth
  (shipping) or reproduce the client's own dead reckon (the treatment remote
  skaters already get). The second cannot refuse an honest claim.

**A refusal is only half the score.** Every way of not refusing grants something
the world moved past, so ranking on miss rate alone puts the most permissive
option first. `mean_grant_staleness_m` is the other half — how far the puck the
host ruled on sat from the true puck at the instant the blade was there — plus
`render_skew_m`, the on-screen gap between the puck's timeline and the player's
own body's, which is a property of the picture rather than of any claim.

Read `phantom_grants` as a distribution and not a count when staleness is
near-constant: with the default 12 m/s puck and 25 ms lead, puck-at-host-present
is stale by within float noise of the 0.30 m pickup radius, so its phantom rate
sits *at* the boundary. That coincidence is the finding; assert on the staleness.

**It reproduces the playtest.** At the conditions that session actually ran at —
lead servo pinned at the 50 ms-extra ceiling, 30–60 ms RTT, contested-puck
deflection rate — it produces 33–41% against the observed ~45%, and the same
conditions at the designed 25 ms lead give 6–15%. That is the validation that
makes the rest of its numbers worth quoting, and it makes the clock fix's effect
a falsifiable prediction rather than a hope.

**Quoting numbers from it.** One run turns on ~60 random deflection directions
and the miss rate moves ±20–25% relative across seeds. Average a dozen seeds
before quoting, and don't read a crossover between two arrangements to better
than ~±30 ms of RTT.

**Two traps it has already fallen into**, both of which flattered the result and
neither of which announced itself:

- *Deflections on a fixed period.* Every even period shares a factor with the
  2-tick snapshot cadence, so every deflection landed on a broadcast tick and the
  broadcast interval cost nothing — hiding ~15% of the prediction error. Timing
  is geometric now, and `test_the_broadcast_interval_costs_prediction_accuracy`
  fails if periodicity ever comes back.
- *The unplanned-blade fallback sitting on the puck.* A tick the client never
  planned a pose for defaulted the blade to the puck's own position, i.e. a
  guaranteed confirm precisely where the harness knew least.

`miss_rate` is an **error-exceedance curve**, not a player's felt miss rate: the
client aims at what it renders, so its own view connects on every eligible tick.
Also absent — jitter, packet loss, and any second claimant, so nothing here says
what a favor-the-actor grant does to the *other* player in a scramble.

When adding netcode timing, rewind, or claim-geometry behaviour, add the
assertion here first.

## Benchmarks

`benchmarks/` holds report-only host-cost scenarios plus a per-evaluator
micro-bench. They are outside the default suite. **AI performance changes run
them** and compare before/after tables — especially per-tick p95/max (host FPS is
set by the worst tick) and the per-call evaluator ranking.

## Determinism

Domain code must be replay-safe: the same inputs produce the same outputs, or
reconcile replay diverges from the host. Tests that touch AI or physics must not
depend on wall-clock time or unseeded randomness.

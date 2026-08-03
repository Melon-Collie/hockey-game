# 5v5 performance — what was measured

Findings from the 5v5 frame-cost investigation. This exists because the tool that
produced most of it (the F7 interleaved cosmetic-freeze sweep, `PerfProbe`) was
removed once it had answered its questions — it made the F3 overlay unusable and
its results were not going to change. The numbers are kept here so nobody
re-runs the same two weeks of work.

**Read every absolute number as a debug build unless marked otherwise.** An
export build measured ~12% cheaper overall and ~30% cheaper on the cosmetic rig
specifically, so the shipped frame is better than these figures. Rankings hold
across both.

Reference machine: i7-11700K / RTX 3080 / 240 Hz display, 5v5 (10 skaters,
2 goalies), host role, offline.

## Measure frame pacing before believing a frame number

`main_thread_ms` in the F3 panel and the digest is **not measured**. It is a
residual: `frame_ms − max(gpu_ms, cpu_render_ms)`. Anything that decides frame
length independently of how much work the main thread did therefore lands in it.

- An **fps cap** idles the main thread by exactly the work you removed, so an A/B
  measures zero.
- **FIFO vsync** (Options → Video → V-Sync: Enabled, and Adaptive until it drops)
  quantises the frame to whole refresh periods. This bites *below* the ceiling
  too, which is the trap: a saving registers only when it flips a frame onto an
  earlier refresh, so the measured gap can read as nothing or as several times
  the truth. On the 240 Hz reference machine frames land at 240 / 120 / 80 fps
  and nothing between — a 125 fps average with a 75 fps minimum is that, not a
  cost.

The shipped defaults are **vsync Enabled, no cap**. A sweep taken there is not
comparable to one taken uncapped. The digest reports `vsync_mode`, `fps_cap`,
`refresh_hz` and `bound_by` so a pasted capture can be checked rather than
trusted.

Mailbox vsync is exempt — triple-buffered and not capped to refresh.

## Where a 5v5 frame goes

Per rendered frame, against a 7.4 ms main thread (~104 fps, debug):

| | ms | share |
|---|---|---|
| cosmetic rig (pose solve + write) | 1.63 | 22% |
| unattributed — engine node work, `_process` | ~2.30 | 31% |
| skater controller step ×10 | 0.87 | 12% |
| VFX + world HUD + ice scratches, combined | 0.59 | 8% |
| goalies ×2 | 0.44 | 6% |
| skater bodies ×10 | 0.44 | 6% |
| AI proper (snapshot + brains + kick) | 0.47 | 6% |
| capture + broadcast | 0.22 | 3% |
| puck | 0.19 | 3% |

There is no hot spot. The largest single item is 22% and everything else is under
an eighth of the frame.

## The cosmetic sweep's verdict (three clean runs, 36–38 rotations each)

Savings in main-thread ms per frame, against an unfrozen baseline. "Resolved"
means the gap cleared two standard errors on the difference.

| frozen | saves | resolved |
|---|---|---|
| ALL cosmetics | 2.22–2.47 | yes |
| the rig | 1.63–1.86 | yes |
| the rig's WRITE half only | 0.24–0.52 | no |
| VFX | 0.04–0.27 | no |
| ice scratch map | 0.04–0.14 | no |
| world HUD | 0.01, and once negative | no |

Conclusions that are settled and should not be re-litigated:

- **The rig is ~73% of all cosmetic cost**, consistently, across every run.
  Within it the *solve* (gait, head tracking, off-hand IK) dominates the *write*
  (bone poses, mesh rebuild) — the write half never resolved in any run.
- **The world HUD is free.** Moving the rings, chevrons, slapper indicator and
  stamina gauge into the ice shader took it to zero. Nothing further to win.
- **The ice scratch map is free.** The `UPDATE_ONCE`-instead-of-`UPDATE_ALWAYS`
  idea is worth nothing; do not spend the correctness risk.
- **VFX is at or below the noise floor.** It measured *negative* in one export
  run. The idle early-out and blade-trail guard that were proposed for it are not
  justified. Separately, swapping `basis.inverse()` for `transposed()` benchmarks
  as noise (0.23 vs 0.22 µs) — leave the clearer spelling.

## Host tick cost (`HostCostProbe`, still live — F3 → P)

Per host physics tick, 8333 µs budget at 120 Hz:

| section | µs | per actor |
|---|---|---|
| dispatch: apply | 826 | 76 ×10 |
| ↳ of which the skater controller step | ~760 | |
| goalies | 386 | **193 ×2** |
| skater bodies | 383 | 38 ×10 |
| snapshot build + enrich + accel | 262 | |
| capture + broadcast | 189 | |
| puck | 163 | |
| dispatch: kick | 122 | |
| game tail (checks + trackers) | 108 | |
| brains | 28 | |
| **attributed total** | **~2500** | |
| *AI worker (off-thread)* | *1330* | worker behind on <6% of ticks |

Three things this settled:

- **`dispatch: apply` is not AI.** The bulk of it is
  `SkaterController._process_input`, the same call `LocalController` and
  `RemoteController` make. It is the ordinary skater tick, paid per skater
  whoever drives it. The AI proper is ~419 µs/tick, about 5% of the tick.
- **The team brains are not a spike source.** 28 µs mean. `force_retick()` firing
  off-cadence on every carrier change was a plausible story for scrum-time
  hitches and it is wrong.
- **The AI worker thread is healthy.** It finishes inside ~1.3 ms of an 8.3 ms
  tick and blocks a fresh kick on under 6% of ticks. Optimising `decide()` would
  buy bot responsiveness, not frame rate — and a faster worker kicks *more*
  batches, which slightly *increases* main-thread work.

The `Tick attributed` percentage on the panel divides by the tick **budget**, not
the step's length. The physics step ends when the work does and the remaining
wall time is `_process` and rendering, so a low percentage is not evidence of
unattributed physics.

## Goalie cost, from `benchmarks/test_goalie_micro_benchmark.gd`

A goalie is the most expensive actor per capita on the tick — 193 µs against a
skater body's 38 µs. Where it goes (µs/call, headless):

```
_physics_process (WHOLE TICK)      111.44
  body parts                        33.40   ← 30%
  state                             14.21
  view invalidate + rebuild         12.44
  tracking                          10.11
  depth                              6.66
  poke                               6.65
  position                           4.04
  facing                             3.36
  shot timer                         1.01
FAR END: whole tick                 55.10
FAR END: body parts (suspended)      1.12
```

The far-end LOD already halves it. The remaining large slice is the body-parts
pose solve, which is save geometry — cutting its rate trades save fidelity for
~0.13 ms/frame. Judged not worth it.

## The AI decide path

`decide()` runs on the worker thread and the main thread never blocks on it. From
`benchmarks/test_ai_micro_benchmark.gd` and `test_ai_perf_benchmark.gd`:

- 5v5 total 122k–149k µs per game-second (12–15% of a core), of which the team
  brains are ~2%.
- Worst AI tick p95 2.3–3.2 ms, max 4.0–7.1 ms — on the worker, so it surfaces as
  the worker falling behind, never as a frame hitch.
- Most expensive evaluators per call: `CARRIER compete` 1.26–1.68 ms, `best_carry`
  candidates ~1.52 ms, `best_pass` ~0.96 ms. The carrier compete is already
  throttled to ~30 Hz.
- 5v5/3v3 multiplier 1.34–1.94× for a 1.67× roster — scaling linearly, no
  blow-up.

The path already has dispatch throttling, a far-play LOD for off-puck bots beyond
18 m, scratch buffers, beam search with exact prune bounds, and the carrier
throttle. No structural waste was found.

## Node-count reduction: what it actually bought

The skinned-skater work (see `docs/skinned-skater-plan.md`) took a skater from 67
nodes to 32 and a goalie from 46 to 41 — roughly 335 fewer scene nodes at 5v5.
Measured main thread before and after: **~6.4 ms → 6.53 ms.** The premise that
per-node transform propagation dominated was wrong, and the honest record of that
is in the plan document's closing section.

What the work did buy: no transparency pass for the on-ice HUD, no z-fighting,
analytic antialiasing, and the HUD's cost going to zero.

## Open levers, and why each is or is not being taken

- **Move host duty to a dedicated server.** Deletes ~2.9 ms/frame of attributed
  host work plus the AI worker from the playing client — the single largest
  available win, and it costs nothing in feel. Server-side it is ~30% of a core
  per lobby at 120 Hz.
- **Rig solve LOD** — run the cosmetic pose solve at half rate for non-local
  skaters, phase-staggered so the load spreads across frames rather than
  alternating heavy/light. Worth ~0.8 ms/frame. The local skater stays at full
  rate. Not yet built.
- **Lowering the physics rate (issue #606, 120 → 90 Hz)** would cut every
  per-tick item at once, ~0.7 ms/frame. **Rejected**: the broadcast cadence is
  counted in physics ticks, so it trades responsiveness over ping for frame rate,
  and responsiveness is the higher priority.
- **Goalie update LOD** — ~0.22 ms/frame, but the only real slice is save
  geometry. Rejected on risk.

## How to measure something new

The freeze-sweep approach is gone, and its lesson is worth keeping: **an A/B that
switches work off is only sound when nothing reads that work back.** It suited
cosmetics and would have been invalid for the AI or the goalie, where suppressing
the work changes the game being measured. Those have clean call seams, so they
are timed in place instead — that is what `HostCostProbe` does.

Two traps the sweep hit, both worth remembering:

1. **A 5v5 frame varies by more than the 1–2 ms being hunted.** Sampling one
   condition at one moment measures the moment. The fix was to interleave
   conditions on a short timer so each saw the same distribution of camera
   angles and scrums, and to treat *one rotation* — not one frame — as the unit
   of observation. Frames inside a rotation are near-copies, and averaging them
   as independent samples makes a result look precise while resting on three
   observations.
2. **Report the error bar.** A 0.3 ms difference means nothing when the
   rotation-to-rotation spread is 1.5 ms, and an early run had three of four
   conditions measuring *slower* than doing the work — impossible, and nothing in
   the output admitted it.

`HostCostProbe` carries the same discipline in a smaller form: means and window
peaks are both over **ticks**, so a per-actor section's peak is the tick's total
rather than the worst single actor.

## Follow-up sweep: what is still open, and four things that are not

A second pass over the paths the 5v5 investigation did not cover — the render-rate
UI/overlay `_process` set, the client frame, the snapshot capture ring, and the
one axis the whole record above ignores (the GPU). Two open items came out of it;
the rest of the candidates were measured and are recorded here as dead so the
next reader does not re-derive them.

### Open: the cosmetic rig gate is not an on-screen gate

`Skater._process` (`skater.gd:691`) wraps the pose solve and mesh rebuild in
`if is_visible_in_tree():`, and the comment beside it justifies the gate as "an
off-screen skater needs no animated pose". But `is_visible_in_tree()` is Godot's
*explicit* visibility — it is true for every skater that has not been deliberately
hidden, whether or not it is in frustum. The renderer culls the skater's *draw*;
its per-frame CPU pose solve runs anyway. The stated intent is unrealized, and
nothing in the project uses `VisibleOnScreenNotifier3D` (checked — the only
frustum handling anywhere is the crowd's per-section AABBs and the two VFX
emitters' oversized boxes, all GPU-side).

The cost being paid for a skater nobody can see, from
`benchmarks/test_gait_micro_benchmark.gd` (headless):

```
_render_pose_update (WHOLE)        30.80 µs
  gait (_skating.apply)            21.85        ← 71%
  head tracking                     1.31
  bottom-hand IK                    2.74
[write] update_arm_mesh             5.27
[write] update_bottom_arm_mesh      5.32
[write] update_stick_mesh           2.47
                                   ─────
                                   43.86 µs per skater per rendered frame
```

The existing settled early-out does not cover this: at rest the gait costs 1.44 µs,
but gliding is 19.40 and skating 22.04, and an off-screen skater in live play is
moving. `SkaterVFX._process` (`skater_vfx.gd:114`) has no visibility gate at all
and would ride the same flag.

Sizing it honestly: on the reference machine the whole cosmetic rig measured
1.63 ms for 10 skaters, so ~163 µs per skater per frame. Four skaters out of
frame is ~0.65 ms — comparable to the half-rate **Rig solve LOD** above, but with
*zero* visual degradation, and the two compose (LOD the on-screen remotes, gate
the off-screen ones). **The caveat that matters:** this saves most when the roster
is spread (rush, breakout, D-zone cycle with the far pair out of frame) and least
in a scrum where everyone is on screen — and the scrum is where the worst frames
already are. It raises the average; it may not move the minimum. Measure both.

### Open: nothing in this document is GPU-side

Every number above is main-thread CPU. The one place the HUD rework moved work
*onto* the GPU has never been measured from that side: `Shaders/ice.gdshader`
runs its player-ring loop (`:190`, up to `ring_count` = 12) and its chevron loop
(`:211`, up to `chevron_count` × `stack` = 36) **per fragment of the whole
26 × 60 m ice plane**, each iteration doing a distance field, an `fwidth`, two
`smoothstep`s and a blend. There is no spatial reject: a ring is ~0.5 m across, so
better than 99% of ice fragments run the full per-ring math to composite nothing.

Two structural fixes, in order of payoff:

- Hoist one per-fragment pixel footprint (`fwidth` of the world XZ) out of both
  loops instead of taking a derivative per ring and per chevron — 48 `fwidth`
  calls become 1. This also puts derivatives back into uniform control flow,
  which is what makes the next item legal.
- Bounding-reject each ring/chevron against that footprint before the smoothsteps.
  The branch is spatially coherent, so it is close to free per warp.

Sized by hand this is ~0.1 ms on the reference 3080 and 1–3 ms on an integrated
GPU or a Deck — i.e. it is a low-end and high-resolution item, not a reference-machine
one. Do not ship it on this estimate; the F3 perf page already reports `gpu_ms`,
and the video options (MSAA, render scale, shadow-light count, SSAO, SDFGI) are
the confounders to pin before A/B-ing. Note the AA feather changes slightly under
the hoist — an isotropic footprint over-widens a radial one by up to √2, so this
is a visual change, not a pure win.

### Measured and dead — do not re-derive these

- **`for i in range(n)` is not an allocation.** GDScript's compiler special-cases
  `range()` in a `for` header. Measured at n = 270, 200k reps: `range(n)` 3.669 µs
  per loop vs `for i in n` 3.623 µs — inside noise. This kills the "hot-path
  `range()` churn" reading of `Trajectory.predict_final` (`trajectory.gd:37,60`,
  the 270-step path the AI micro-bench prices at 222 µs), of
  `BufferedStateInterpolator.find_bracket:51` (per interpolated actor per client
  tick), and of `GameManager._refresh_goalie_data_cache:5482`. All three are fine
  as written.
- **`get_nodes_in_group` is not worth caching at this size.** Issue #625 proposes
  swapping the per-frame group lookups (`ice_scratch_map.gd:106`,
  `ice_ring_field.gd:114`) for `PlayerRegistry.skaters()`. Measured over 10 nodes,
  200k reps: group lookup + iterate 0.177 µs, cached `Array[Node]` + iterate
  **0.225 µs** — the typed-array iteration costs more than the lookup saves. The
  swap is a small regression *and* it narrows group membership (tutorial puppets).
  That bullet should come off #625.
- **Font shaping is already cached.** `Font` keeps an LRU of shaped `TextLine`s, so
  the per-frame `get_string_size` + `draw_string` pairs in `player_name_overlay.gd`
  and `off_screen_player_indicators.gd` are cache hits on stable text: 2.12 µs for
  ten names (0.21 µs each) against 59.5 µs for ten misses (5.95 µs each, 28×). The
  overlays only pay the miss price if the drawn string or font size actually
  changes, which for name plates it does not.
- **The snapshot capture ring is already allocation-free.** `StateBufferManager.capture`
  fills pre-allocated slots via `fill_network_state` / `fill_state`; the only churn
  left is ~5 Dictionary lookups per peer per tick for the ring pointers, which is
  not worth a struct.

Everything else the sweep turned up — per-frame material and transform writes with
no dirty guard (`puck_shadow`, `puck_vfx`), the goalie-data cache's string-keyed
Dictionary writes, `GameCamera` framing at 120 Hz — was already on issues #625 and
#622 before this pass started.

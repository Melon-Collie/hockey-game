# Net and Jersey Physics — Design Doc

Two features that read as one ask ("make the cloth move") but sit on opposite
sides of the netcode boundary, and have to be designed apart because of it.

**Part A — the net deforms when the puck hits it.** Constrained, because the
puck is a deterministic predict-and-reconcile object and anything the net does
that the puck can feel becomes replayed state.

**Part B — the jersey hem and sleeves carry secondary motion.** Unconstrained,
because the cosmetic rig never touches a tick.

Explicitly NOT in scope, and argued against at the end: true per-vertex cloth on
either, and a net that comes off its moorings.

**Status: both parts were built and then reverted — see the Outcome section
immediately below, which is now the most useful thing in this file.**

## OUTCOME — both features were built, measured, and reverted

**Read this before acting on anything below.** Parts A and B were implemented in
full, tested, and taken back out. The plan's engineering was sound; its premise
was not. Neither deformation is visible at the camera this game is played at, and
nothing in the analysis below noticed that, because nothing in it asked.

`GameCamera` holds 10–32 m above the ice at a −75° pitch and 50° FOV. At a
typical 15 m hold the whole goal is about **11% of the frame width**, and from
75° down you are looking at the net's ROOF — the back panel, where a shot
actually lands, is nearly edge-on. Rendered at that exact framing, at rest and
mid-bulge from a 25 m/s shot:

| | net bulge | share of frame that changes |
|---|---|---|
| 10 m (closest the camera ever gets) | 0.15 m ≈ 25 px | 1.1%, worst pixel delta 0.34 of 3.0 |
| 15 m (typical) | 0.15 m ≈ 17 px | 0.12% |

The two frames are indistinguishable by eye. Amplified 6×, what changes is the
diamond texture shimmering by a pixel — not a shape anyone reads as a bulge. The
jersey hem is about a third of that displacement on an object that never gets
closer, so it is further below the threshold again.

**The lesson is procedural, and it is the whole value of this document now:** a
cosmetic feature needs a visibility check at real game framing BEFORE it is
designed, not after it is built twice. That check cost twenty minutes — build a
scene, put the actual camera on it, render two frames, diff them. Every technical
question below (tessellation density, seam tearing, bone vs shader, netcode
containment) was answered correctly and none of them mattered.

Three things came out of the work and were kept:

1. **A real audio bug, fixed and landed separately.** Contact cues are deferred
   until after the tick commits, so every net thump read its speed off a puck the
   twine had already stopped: `NET_RESTITUTION` is 0.05, so a 25 m/s shot reached
   the volume curve holding 1.25 m/s. The curve spans 1→21 m/s, so the entire
   dynamic range of the cue was about an eighth of a decibel — a slapshot into the
   mesh has always sounded exactly like a dump-in. `puck_hit_goal_body` now
   carries the arrival speed. Nothing to do with net physics; it is a bug the
   visual work happened to walk into.
2. **A latent bug in the shipping celebration ripple, still present.**
   `goal_net.gdshader` displaces each panel along its own face normal, and panels
   meet at right angles, so a bulge moves the two sides of a shared seam apart —
   at the 0.22 m peak, a ~0.3 m hole torn in the twine, worst along the top edge
   at the front. It has shipped invisibly behind a goal horn and a strobe. If net
   visuals are ever revisited, fix this first: it is the one net deformation that
   happens while the camera is pushed in.
3. **The netcode analysis in §0 and Part C stands unchanged.** It was never
   contingent on the features being visible, and it is the answer to "why not
   just use cloth" whenever that comes up again.

If someone does return to this: the only framing where net detail could pay off
is the goal celebration (`GameCamera._GOAL_CINE_ZOOM` 0.72, then the replay's
behind-the-net cut). Spend the budget there, on one event, and measure it at that
camera before writing any of it.

## 0. The dividing line

The puck's sim is analytic and deterministic (`docs/netcode-determinism-
migration.md`). `PuckAuthorityRules.step_frame_substep` runs up to
`MAX_FRAME_SUBSTEPS` = 16 times per tick near the net, is mirrored in C++
(`native/src/native_puck_step.cpp`) under a parity fuzz gate, and the client
**re-runs the whole loop every frame** for `age_ticks × substeps` while a
snapshot ages (`puck_controller.gd:1227`).

So the cost of net physics is not triangles. It is that every piece of net state
the puck reads must be:

1. restorable from the reconcile snapshot,
2. re-simulable inside that replay loop, at that multiplier, and
3. present in both the GDScript and C++ kernels, held together by parity.

A cloth grid fails all three at once. A single scalar per goal passes all three.
That is the entire design constraint, and Part A is shaped around it:

- **puck → net is one-way and free.** Both peers already compute the same
  contact deterministically, so a purely visual response driven off that contact
  needs no wire traffic, no snapshot entry, and no replay.
- **net → puck is expensive, and gets exactly one scalar.**

## Part A — the net that moves *(built, reverted — see Outcome)*

### A.1 What is there now

- Eight flat quads and two triangles, ~14 triangles total, built by
  `HockeyGoal._build_net_panels` (`Scripts/actors/hockey_goal.gd:315`).
- One shared `ShaderMaterial` per goal, `Shaders/goal_net.gdshader`, carrying a
  single `ripple_amount` sine wave radiating from a fixed `ripple_origin` at the
  mouth.
- That ripple fires on **goals only** — `GoalVFX._ripple_net`
  (`Scripts/vfx/goal_vfx.gd:145`) tweens it up over 0.06 s and back down over
  0.9 s. A save off the twine, a rim into the back mesh, and a dump-in that dies
  in the cage all move nothing.
- The puck's response is analytic in `PuckGeometryCollision.resolve_net_panels`
  and `resolve_top_net`, at `NET_RESTITUTION` = 0.05.

The contact event already exists, and not once but three times — the net-contact
*cue* is already fanned out to every peer, because the thump is:

| peer | source | when |
|---|---|---|
| host | `Puck.puck_hit_goal_body` (`puck.gd:16`) | its own authoritative sim |
| client | `PuckController.predicted_net_contact` (`puck_controller.gd:243`) | its own local prediction, immediately |
| either | `NetworkManager.goal_body_hit_received` | the host's broadcast, ~RTT later, echo-suppressed against the local cue |

All three are edge-gated (sustained contact fires once on entry, not 120×/s),
all three carry a position and a speed, and `game_manager.gd` already hangs both
a sound *and* a visual off the equivalent sites for boards and posts
(`puck.fire_board_impact_vfx`, `fire_post_ping_vfx`).

So A.2 needs no new signal at all: the bulge rides the existing cue beside the
sound. It also inherits the property that matters most — a client bulges its own
net the instant its prediction says the puck arrived, rather than waiting a
round trip to be told.

### A.2 Geometry — tessellated panels

`_add_net_quad` and `_add_net_tri` gain a subdivision step targeting a ~4 cm
edge, matching the twine's own diamond scale (`NET_TEXTURE_TILE_SIZE` / 4 =
41 mm).

- Back panel ≈ 1.83 m wide × ~1.30 m of slant → ~46 × 33 quads ≈ 3.0k triangles.
- All panels together ≈ 8k triangles per goal, ~16k for both.
- **Draw calls are unchanged** — still one `MeshInstance3D` per panel sharing one
  material. Only the vertex count moves.

The UV work needs no new thinking. `_project_uv` already expresses each corner in
a 2D basis anchored at corner A and scaled by `1 / NET_TEXTURE_TILE_SIZE`;
subdividing inside that same basis interpolates UVs correctly by construction, so
the diamond grid keeps tiling at its real-world size on every panel.

`hockey_goal.gd` is 572 lines against the 800-line ratchet. The tessellator plus
the impact plumbing will not fit under it, and the panel builder is a clean seam
anyway — extract `Scripts/actors/net_panel_builder.gd` owning `_add_net_quad`,
`_add_net_tri`, `_project_uv` and the new subdivision, leaving `HockeyGoal` to
own the frame, the material and the goal test. Tighten the ratchet entry for
`hockey_goal.gd` to whatever it actually lands at, per the shrink rule.

### A.3 The deformation model

One displacement path, not two. The goal celebration ripple becomes a synthetic
wide impact rather than a separate uniform — that deletes the special case
instead of adding a second one beside it.

An impact record is what the twine actually received:

| field | source |
|---|---|
| origin | puck position at contact, read from the puck at emit time |
| direction | outward normal of the twine surface nearest the contact, negated when the puck is pressing from outside |
| energy | speed at contact (the analytic puck carries no mass — the constant folds into the amplitude tunable; the broadcast path carries no velocity vector to take a normal component of) |
| start | the goal's own `net_time` at emit |

Four in a ring buffer, oldest evicted, as three `vec4` arrays so the shader loop
is fixed-length and one impact is three uniform writes.

Displacement in `vertex()` is a damped spring in time and a gaussian in space:

```
amp     = energy * exp(-t / DECAY_TAU) * cos(SWING_OMEGA * t)
falloff = exp(-(d / RADIUS)^2)          // d = distance from impact origin
VERTEX += dir * amp * falloff
```

**`dir` is one direction for the whole cage, not each panel's own normal**, and
that is the non-obvious part. The panels meet at right angles, so displacing
each along its own face normal moves the two sides of a shared seam apart — at
the 0.20 m bulge cap, a ~0.28 m hole torn in the twine, worst in the back corner,
which is exactly where a puck ends up on a goal. One direction per impact cannot
do that, and it is also the more faithful picture: a puck jammed into the corner
pushes that whole corner of the bag the way it was travelling.

This artifact is not new — the shipping `ripple_amount` shader displaces along
`NORMAL` at the same 0.22 m peak and tears the same seams on every goal
celebration. It is simply invisible in a 0.6 s flourish behind a goal horn. The
celebration therefore moves to a **radial** mode (`normalize(VERTEX -
cavity_center)`), which billows the whole cage and is continuous across seams for
the same reason; a single direction there would shove the net sideways instead of
swelling it.

The first swing dominates, which is what a struck net does — it takes the puck,
bulges once, and settles. `TAU`, `OMEGA` and `RADIUS` are feel tunables and are
legitimately hand-picked: this is cosmetic response, not evaluation code, so the
"grounded models over magic-number curves" rule in CLAUDE.md does not bind here.
The *inputs* are still physical (real momentum, real contact point, real normal),
which is what keeps a soft dump-in from shaking the net like a slapshot.

### A.4 The pocket — the one place the net touches the sim

Visual-only deformation has one honest flaw: at a hard enough bulge the twine on
screen and the plane the puck collides against visibly disagree, and the puck
hangs a few centimetres off the mesh it just stretched.

The fix is one float per goal. `NetGeometry.back_depth_at_height(y)` becomes
`back_depth_at_height(y, give)`, where `give` ∈ [0, ~0.12 m] deepens the cavity,
set on impact from the same normal-energy the shader uses and decaying
exponentially per tick.

This is where the constraint bites, and it must be built to satisfy §0 or not at
all:

- `give` is **derived inside the deterministic step**, as a pure function of the
  puck's own trajectory, so both peers reach the same value without it ever going
  on the wire.
- It joins the puck's reconcile snapshot and is restored before replay. A `give`
  that is not restored makes the same replayed input produce a different carom,
  which is precisely the divergence the whole determinism migration bought out.
- It exists in **both** `PuckGeometryCollision` and `NativePuckStep`, under the
  existing parity fuzz test. `native/README.md` is explicit: change a solver in
  both places or not at all.

Because that is a materially larger and riskier change than everything above it,
**Part A ships in two commits**:

- **A1 — visual only.** Tessellation, the impact model, the shader, the event
  wiring. Touches no rule file, no kernel, no snapshot. Zero netcode surface.
- **A2 — the pocket.** The `give` scalar, in both kernels, in the snapshot, under
  parity. Landed separately so a bisect can tell the two apart.

A1 is the one that carries most of the visible payoff. A2 can be deferred without
A1 looking unfinished.

### A.5 Tests

- Extend `test_net_geometry_mirrors.gd`: **every tessellated vertex must lie on
  the analytic surface `NetGeometry` describes**, within epsilon. This is the
  comment-that-should-be-a-test rule applied to the thing most likely to rot —
  the visible mesh and the collider are two descriptions of one net, and §1 of
  `docs/net-play-plan.md` is the record of what happens when they drift.
- New: tessellated panel UVs still tile at `NET_TEXTURE_TILE_SIZE` regardless of
  subdivision count.
- A2 only: seeded parity fuzz over `give` decay, plus a reconcile test asserting
  a replayed input sequence lands on the same puck state with `give` restored.
- Visual confirmation via `.claude/hooks/render-arena.sh` does **not** cover
  this — that harness builds the stands, not a live goal. The bulge needs the
  user in the game.

### A.6 Cost

| | |
|---|---|
| GPU triangles | +16k across both goals — under one skater's worth |
| GPU vertex work | 16k invocations × a fixed 4-iteration loop; well under 0.05 ms |
| Draw calls | unchanged |
| CPU | 8 uniform writes per impact, edge-gated to a handful per second |
| Netcode (A1) | none |
| Netcode (A2) | one float, derived not transmitted, in the snapshot and both kernels |

## Part B — the jersey that moves *(built, reverted — see Outcome)*

### B.1 What is there now

- The torso is a **shared** 10-side × 7-ring lathe (~70 vertices) on a single
  bone (`UpperBone.TORSO`) with identity binds and identity rests, so a posed
  vertex is exactly `bone_pose * v`.
- The jersey is painted into a 512 × 256 `SubViewport` (`JerseyDecal`) and
  sampled as `albedo_texture` on a `StandardMaterial3D` with
  `uv1_offset.x = 0.25`, `ROUGH_CLOTH` = 0.9, and `BodyRim.apply`
  (`skater_uniform_coordinator.gd:109`).
- The hem flare and the seat sway are baked into `_TORSO_PROFILE` and
  `_TORSO_REAR_SWAY` constants.
- `skater_mesh_builder.gd`'s header states the coupling plainly: the painters are
  written against the lathe's exact UV convention, and the two change together.

### B.2 Tessellation — additive, and deliberately vertical only

The obvious move is to raise `_TORSO_SIDES` from 10 and add rings. **Do not raise
`_TORSO_SIDES`.** The back number is sized to span ~3 facets at 10 sides; changing
the side count changes which facets it lands on and how creased it reads, and it
moves every U coordinate the stripe and nameplate painters are pinned to.

Add **profile stations only**. Two or three extra `_TORSO_PROFILE` entries below
the waist, with matching `_TORSO_REAR_SWAY` entries, give the hem the vertical
resolution to swing. This is safe in a way that is worth stating explicitly:
`_build_lathe` derives each ring's V coordinate from the profile geometry itself
(`vs[i] = 0.5 * (y_top - s.x) / span`), so an inserted station lands at the V its
height implies and **every existing station keeps the V it already had**. The
stripes, the name and the number do not move. U is untouched because the side
count is untouched.

Cost: roughly +120 vertices per skater, ~1.4k across a 5v5. Irrelevant.

### B.3 No shader at all — the skirt is a bone

The first cut of this used a vertex shader, and it was wrong. Writing it turned
up two problems that both have the same root: **a `ShaderMaterial` cannot use
`StandardMaterial3D`'s rim.**

- `BodyRim` is a real lighting term, applied inside the engine's light loop and
  scaled by each light's colour and attenuation, so it vanishes in shadow. A
  custom shader can only approximate it with `EMISSION` — additive, light-
  independent — which is what `goalie_jersey.gdshader` does and says it does.
  On the goalie that is fine, because the whole model is one shader. On a skater
  it puts an emissive rim on the torso and a lit rim on the arms **beside it**,
  so the two disagree in shadow. (Godot also derives the rim's falloff exponent
  from roughness, which at `ROUGH_CLOTH` makes the engine's rim much broader
  than a hand-rolled `pow(…, 3)` — a second mismatch, in all lighting.)
- `SkaterUniformCoordinator.apply_ghost` fades every upper-body surface through
  `_fade_material(mat: StandardMaterial3D, …)`, reached via
  `SkaterMeshBuilder.surface_override`, which does `as StandardMaterial3D` and
  **silently substitutes a fresh white material when the cast fails**. A
  `ShaderMaterial` torso turns white on the first offside and stays white. Not
  hypothetical: it is the bug the stick shaft already hit, and the twelve-line
  comment above the stick branch in `apply_ghost` is its record.

Reproducing the rim faithfully would mean writing a `light()` function, and
defining `light()` replaces the **entire** BRDF — transcribing Godot's diffuse
and specular into the repo, to be maintained against engine releases, so that one
hem can move. That trade is not worth making.

**So don't use a shader.** The only thing the torso needed a shader *for* was
moving vertices, and this rig already has a mechanism for that: the skeleton.
`skater_mesh_builder.gd` is built on "posing a part costs an entry in the
skeleton's pose array."

Cut the torso lathe at the waist into a body surface and a skirt surface, put
the skirt on its own bone (`UpperBone.HEM`), and the swing becomes a bone pose:

- **The rim mismatch disappears.** The jersey stays a `StandardMaterial3D` with
  `BodyRim.apply`, identical to the arms beside it, in light and in shadow.
- **The ghost trap is sidestepped rather than worked around** — no
  `ShaderMaterial` on the torso means no branch in `apply_ghost` at all.
- **The ramp comes free from the geometry.** A rotation about the waist moves
  each ring in proportion to its distance from the pivot, which is what a
  `smoothstep` over UV.y was hand-approximating — and rotating about the waist is
  how a hem actually moves, where a shader displacement translated it.
- **The seam cannot open.** Both halves include the waist ring, and the swing
  rotates *about* that ring, so it does not move. (About the ring, not the mesh
  origin: its own rear sway puts it a few mm off centre.)

Two costs, both real:

- `UPPER_BONE_COUNT` 14→15, `UPPER_SURFACE_COUNT` 17→18, one more `Skin` bind,
  and ratchet bumps on `skater.gd` and `skater_mesh_builder.gd`.
- The bone list is deliberately **flat** — "a hierarchy would compose transforms
  these poses do not expect" — so the skirt cannot parent to the torso to inherit
  the gait's trunk texture and the body dials' scale. `Skater._repose_upper_bone`
  composes it by hand off the torso's own numbers, and reposing TORSO reposes HEM
  as one rule, so no caller can forget the skirt exists. A parent would apply the
  trunk texture twice.

`_build_lathe` grows `first`/`last`/`cap_top`/`cap_bottom` to build a slice, with
V still derived from the **whole** profile — that is what keeps a slice's UVs the
ones it would have had inside the complete lathe, so cutting the mesh moves no
stripe, name or number. `test_jersey_flow.gd` pins it.

### B.4 The motion model

The model is a **lag**, and it needs no acceleration term at all — which is
better than the acceleration formulation, because differencing a physics-rate
velocity at render rate is noisy. Carry one filtered velocity, `flow_lag`, that
chases the body's actual body-local velocity; the *gap* between them is the
swing:

```
flow_lag = lerp(flow_lag, local_velocity, RESPONSE * delta)
swing    = -(local_velocity - flow_lag) * GAIN     # capped
```

Accelerating opens the gap forward, so the skirt trails. Stopping reverses it, so
the skirt swings out ahead and settles as the lag closes. The overshoot is the
filter's, so nothing integrates and nothing accumulates — a dropped frame or a
teleport cannot leave the hem wound up.

`swing` is specified as the **hem ring's own displacement in metres**, which is
what lets B.3's rotation deliver it exactly: the angle is `swing / lever`, and
every ring between waist and hem moves proportionally less because it sits closer
to the pivot. No ramp constant appears anywhere.

The filter has state, so it lives **on the CPU** — one `lerp` per skater per
frame — and drives one bone pose. Nothing at all while the cloth is at rest.

Two placement rules from CLAUDE.md apply and are both satisfied by keeping the
model **body-local**:

- The write goes in `_process` (render rate), not `_physics_process`. That is
  correct for cosmetics.
- The render-clock trap — chrome drawn at render rate off a tick-rate pose must
  read `Skater.render_transform()`, not `global_position` — **does not arise at
  all**, because a body-local swing posing a bone in the torso's own space never
  reads a world position. Keeping it local is what buys that, and it is worth not
  giving up later for convenience.

Skip the write when the skater is off-screen and when `|flow|` is under a
threshold, per hot-path discipline.

### B.5 Tests

- The painter contract, twice over and load-bearing both times: inserted profile
  stations leave every pre-existing station's V unchanged, **and** cutting the
  lathe in two renumbers neither half. Together they are what make B.2 and B.3
  checkable rather than merely argued.
- The seam: both halves carry the waist ring vertex-for-vertex, and a swing moves
  the hem by what it was asked for while leaving that ring exactly where it was.
- The skirt tracks the torso through the channels that would otherwise forget it:
  the gait's trunk texture and a body dial's scale. The bone list is flat, so
  nothing but `_repose_upper_bone` holds those together.
- The jersey keeps a `StandardMaterial3D` with `BodyRim` on it, across both
  surfaces — the assertion that the rim problem stays fixed.
- The swing model itself: trails under acceleration, settles at a steady speed,
  throws forward on a hard stop, and is capped against a one-frame velocity step.

### B.6 Cost

| | |
|---|---|
| GPU | ~1.4k extra vertices across a 5v5; one extra surface per skater |
| CPU | 12 × (one lerp + one bone pose) per frame, and nothing while the cloth is at rest, against a measured 1.63 ms cosmetic rig |
| Netcode | none, structurally — cosmetics may be frame-rate-dependent, non-deterministic and skipped |

## Part C — what this deliberately does not do

**True per-vertex cloth on the net.** A 45 × 27 grid is ~29 KB of state per goal
that must be snapshotted, restored, and re-simulated inside a replay loop that
already multiplies by 16 substeps and by snapshot age. At 8 iterations over ~2400
constraints that is millions of solves per frame, against a measured 7.4 ms 5v5
main thread. `SoftBody3D` is not an escape: it runs in Jolt, it is not
deterministic, and it cannot be rewound — reintroducing it on the puck path would
undo the migration that removed the last Jolt collision from it. The recommendation
is not "later"; it is that the analytic collider stays authoritative and the cloth
stays visual.

**True cloth on the jersey** is merely expensive rather than architecturally
wrong — a compute-shader pass writing a vertex buffer would cost almost no CPU,
since nothing reads it back. It is out of scope here because it needs a
Compatibility-renderer fallback (the arena preview harness runs on Mesa) and
because the jersey currently *is* the torso silhouette: splitting a cloth shell
off the body mesh disturbs the shoulder caps that emerge from the trap line and
every painter convention in B.1. Revisit only if B.4 proves insufficient.

**A net off its moorings** is a separate project and a good one, but its cost is
not the rigid body. `GameRules.push_out_of_net`, `net_proximity`, `NetGeometry`,
`GoalDetectionRules`, `shot_on_net_rules`, `net_blade_collision`, the goalie's
aim shading and the AI carrier's evaluation all read world-fixed constants today.
Every one becomes transform-relative, and the net transform joins the wire format
and the reconcile path.

## Sequencing

1. **A1** — net tessellation, impact model, shader, event wiring. No rule files,
   no kernels, no snapshot.
2. **B** — jersey profile stations, flow shader, ghost-path generalisation.
3. **A2** — the pocket scalar, both kernels, snapshot, parity.

A1 and B are independent and either can land first. A2 depends on A1 only.

## Invariants that must not break

1. **There is exactly one net.** The tessellated mesh and `NetGeometry`'s
   analytic surfaces describe the same object, and a test — not a comment —
   holds them together.
2. **Nothing the puck can feel escapes the snapshot.** If net state reaches the
   puck, it is restored before replay and it exists in both kernels under parity.
   A1 satisfies this by touching no puck state at all.
3. **The net's visual response is derived, never transmitted.** Both peers
   compute the same contact; neither sends a bulge.
4. **The lathe's U convention is frozen.** Jersey motion adds profile stations;
   it does not change `_TORSO_SIDES`, because the painters are pinned to it.
5. **The jersey model stays body-local**, which is what keeps it clear of the
   render-clock rule rather than merely compliant with it.
6. **Cosmetics never enter `_physics_process`**, and skip when off-screen.

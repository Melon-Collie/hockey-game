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

## Part A — the net that moves

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

## Part B — the jersey that moves

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

### B.3 The material swap, and the trap in it

Vertex displacement needs a `ShaderMaterial`, and the torso is a
`StandardMaterial3D` today. The template already exists:
`Assets/Shaders/goalie_jersey.gdshader` was written for exactly this situation and
carries a hand-rolled Fresnel `EMISSION` term reproducing `BodyRim`, because a
`ShaderMaterial` cannot use the standard rim. `Shaders/jersey_flow.gdshader`
copies that rim formula verbatim, samples the jersey viewport texture with the
0.25 U offset folded in, and pins `ROUGHNESS = 0.9`.

**The trap:** `SkaterUniformCoordinator.apply_ghost` fades every upper-body
surface through `_fade_material(mat: StandardMaterial3D, ghost: bool)`, reached
via `SkaterMeshBuilder.surface_override`, which does `as StandardMaterial3D` and
**silently substitutes a fresh white material when the cast fails**
(`skater_mesh_builder.gd:441`). A `ShaderMaterial` torso would therefore turn
white on the first offside and stay white — which is not a hypothetical. It is
the exact bug the stick shaft already hit, and the twelve-line comment above the
stick branch in `apply_ghost` is its record.

So the material swap is not one line. The fix follows the stick's own precedent:
**swap the material while ghosted** rather than fade through an `alpha` uniform.
A shader that writes `ALPHA` renders on the transparent path for every skater on
every frame, to buy a fade that is on screen during offside replays only — so the
ghost gets a translucent `StandardMaterial3D` carrying the same jersey texture,
and un-ghosting restores the shader material.

Budget this as the real work in Part B. The displacement itself is easy; the
ghost path is where it bites. `test_jersey_flow.gd` pins it, and that assertion
was checked against the unfixed code: without the branch, un-ghosting leaves a
bare `StandardMaterial3D` on the torso and the test fails exactly as designed.

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

The filter has state, so it lives **on the CPU** — one `lerp` per skater per
frame — and is pushed as a single packed `vec4`. One `set_shader_parameter` per
skater per frame, not three, and none at all while the cloth is at rest.

The ramp is expressed in the lathe's **V coordinate**, not in vertex Y. V is
skinning-independent and is the same coordinate the painters use, so the shader
never has to assume where in the pipeline Godot applies the bone pose.

Two placement rules from CLAUDE.md apply and are both satisfied by keeping the
model **body-local**:

- The write goes in `_process` (render rate), not `_physics_process`. That is
  correct for cosmetics.
- The render-clock trap — chrome drawn at render rate off a tick-rate pose must
  read `Skater.render_transform()`, not `global_position` — **does not arise at
  all**, because a body-local flow vector displacing vertices in the torso bone's
  own space never reads a world position. Keeping it local is what buys that, and
  it is worth not giving up later for convenience.

Skip the write when the skater is off-screen and when `|flow|` is under a
threshold, per hot-path discipline.

### B.5 Tests

- Wiring: the torso surface carries the flow shader and the jersey viewport
  texture, and the shader declares the uniforms the coordinator writes —
  `test_ice_shader_uniform_contract.gd` is the pattern, and the reason it exists
  is that a renamed uniform otherwise fails silently at runtime.
- The painter contract: inserted profile stations leave every pre-existing
  station's V coordinate unchanged. This is the load-bearing one — it is what
  makes B.2's claim checkable instead of merely argued.
- The ghost path: `apply_ghost(true)` leaves the torso the jersey shader at 0.3
  alpha, and never a white `StandardMaterial3D`.

### B.6 Cost

| | |
|---|---|
| GPU | ~1.4k extra vertices across a 5v5 |
| CPU | 12 × (one lerp + one uniform write) per frame ≈ 0.02–0.05 ms, against a measured 1.63 ms cosmetic rig |
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

# Skinned skater rig — plan

Convert the skater (then goalie) from ~40 separate `MeshInstance3D` parts to a
single skinned mesh driven by a `Skeleton3D`.

**This is an architecture decision, not a performance one.** The performance win
is real but modest (~1 ms/frame of transform propagation); the reason to do it
is that a skinned mesh + skeleton is how an articulated character is supposed to
be built, and every downstream thing — LOD, larger rosters, spectator bodies,
adding a body part — gets cheaper under it. Do not re-litigate this on the size
of the frame-time win.

## Why it is tractable here

The usual skinned-mesh migration hurts because the geometry is artist-authored:
an FBX has to be re-rigged, re-weighted, re-exported, and none of that is
verifiable by diff. None of that applies.

- **The geometry is code.** `SkaterMeshBuilder` generates every part with
  `SurfaceTool`. Building one skinned mesh means generating the same parts,
  appending them into one `ArrayMesh`, and giving every vertex of a part its
  part's bone index at weight 1.0. Two extra vertex attributes on a loop that
  already exists.
- **The skeleton can be code-generated too.** `Skeleton3D.add_bone()` /
  `set_bone_parent()` / `set_bone_rest()` mirrors the node hierarchy that is
  already there, so `Scenes/Skater.tscn` collapses to roughly a
  `MeshInstance3D` + a `Skeleton3D` + the gameplay markers. Minimal editor work
  (scene files are the user's to edit — keep it that way by generating bones in
  code).
- **The write sites are one-to-one.** `bone.transform = X` becomes
  `skeleton.set_bone_pose(idx, X)`. Same math, same call sites, same order.
- **Rigid weights make it exact.** Every vertex weighted 1.0 to a single bone is
  mathematically identical to a mesh parented to a node. This is not
  "approximately the same look" — it is the same pixels, and the diff harness
  can prove it. It also sidesteps the usual non-uniform-bone-scale artifacts,
  because there is no weight blending to distort.

## The thing that made height/weight scaling look like a blocker (it isn't)

`Skeleton3D` bone poses carry **scale**, not just position and rotation.
`set_bone_pose_scale()` is per-bone and per-instance, so per-player proportions
work while every skater still shares ONE mesh. Baking proportions into a
per-player mesh at spawn also works but is strictly worse — it gives up mesh
sharing for nothing.

Per-part materials survive as **surfaces**: one mesh, one surface per material
(jersey, helmet, gloves, skin, laces, steel, ...). That lands ~8-10 draw calls
per skater instead of ~40, and 1 node instead of ~55.

## Verification

`tools/skater_matrix.gd` renders five builds with deliberately loud per-part gear
colours, varied skin tones, and a ghosted column. It caught real errors during
the mesh-merge pass and it byte-compares cleanly. But **it renders ONE STATIC
REST POSE**: it proves proportions, paint and the ghost fade, and nothing about
articulation — which is exactly what a skeleton conversion changes.

`tools/pose_capture.gd` closes that gap and is the harness this work is measured
against. It drives a real `SkaterController` on a real `Skater` with scripted
`InputState` sequences and renders eleven poses: rest, carry, two gait phases at
two facings, a cross-body reach at the arm ROM limit, wrister aim, wrister
follow-through, slapper coil, slapper follow-through, the block stance, and the
lofted blade. `--baseline` records; a bare run compares and prints changed-pixel
count, worst channel delta, and the bounding box per pose, plus a magenta overlay
sheet.

Two properties were verified when it was built, and both need re-checking if it
is ever changed:

- **It is deterministic.** Back-to-back runs report all eleven poses identical.
  This is not free — it is why the skater's `_process` / `_physics_process` are
  driven by hand at a fixed DT, why VFX and the world HUD are frozen, why each
  pose gets a fresh actor, and why nothing casts shadows.
- **It is sensitive.** A 4 mm offset injected into one arm-bone write was caught
  in all eleven poses, with the bounding box landing on the arms.

Sub-perceptual differences localised to alpha-sort seams are acceptable; anything
structural or scattered is not. The bounding box is what separates them — a
change confined to one silhouette edge reads very differently from the same pixel
COUNT scattered across the tile.

## Staged plan

1. ~~**Pose-coverage capture tool** + baseline.~~ Done — `tools/pose_capture.gd`.
   Baselines live in `user://`, so record one from the pre-change tree before
   starting each step rather than expecting a committed reference.
2. ~~**Spike: arm rig only.**~~ Done. Ten nodes (four bones, two elbow balls,
   two gloved fists, two wrist cuffs) → one `Skeleton3D` + one skinned mesh.
   Every pose byte-identical to the node rig bar one edge pixel; the build
   matrix identical outside the ghosted column. **The pattern is proven.**
3. ~~Legs (the gait chain).~~ Done. Sixteen nodes → sixteen bones on one
   skeleton, twelve of them carrying eighteen surfaces. Skater is **45 nodes**
   (from 67 with cuffs before this work started).
4. ~~Torso, helmet, shoulders.~~ Done — folded into the ARM skeleton rather
   than given their own, since they are siblings in `UpperBody`'s frame. Four
   more bones, five more surfaces, zero extra nodes. Skater is **41 nodes**
   (from 67). `SkaterMeshBuilder.apply()` is gone with them.
5. ~~Goalie, same pattern.~~ **Deliberately NOT the same pattern** — see below.
   The rigid-merge win was taken instead: goalie **41 nodes** (from 46), five
   fewer draw calls.

Each step is its own diffable commit. Do not batch them.

## What the spike learned (steps 3-5 must respect these)

- **Godot skins normals with the bone matrix, NOT its inverse transpose.** An
  ordinary `MeshInstance3D` gets a proper normal matrix; a skinned one does not.
  So any bone whose pose carries non-uniform scale renders with skewed normals,
  the wrong way and by the axis ratio. On the arm bones' `(r, r, length)` (~4:1)
  a 6.8° taper shaded as a 27° cone, and the shading changed as the arm
  stretched on an over-reach. This was the ONLY thing the pose diff caught, and
  it was 700-1900 px per pose — invisible to a rest-pose check, obvious here.
  The fix is to give the affected faces normals with no component along the
  scaled axis (`SkaterMeshBuilder._radial_side_normals`); such a normal is
  invariant under that scale.

  **But that fix is only correct where the anisotropy is LARGE, and the legs
  proved it.** Flattening trades the part's true normals for radial ones; that
  is free on the arm bone because at r/length ≈ 0.23 the proper normal matrix
  had already flattened them to 1.6° off radial. The leg parts scale by roughly
  1:1 (limb bulk vs height), so their correct normals ARE the true face normals
  — applying the same fix there nearly doubled the error (800 → 1494 changed
  pixels) and spread it from two builds to all five. It was reverted. Check the
  axis ratio before reaching for it.
- **The pose set cannot see build-dependent bugs; the build matrix can.**
  `pose_capture.gd` renders one neutral build, where limb-bulk and height
  multipliers are both 1.0 and every leg bone's scale is uniform — so the leg
  normal skew was invisible to it (1 px) and plain in `skater_matrix.gd` (800 px
  across SLIM and TANK, the two builds whose dials disagree most). **Run both on
  every remaining step.** The residual left on the legs is that 800 px at worst
  71/255, confined to hip balls and sock/skate seams on the extreme builds, and
  indistinguishable in a side-by-side crop. It is bounded by how far apart the
  height and limb dials can get, not by anything that grows with the rig.
- **Merging transparent parts changes ghost-mode compositing.** Ten alpha
  meshes sorted independently against the body; one mesh sorts once. The build
  matrix's ghosted column moved by up to 36/255 over ~1000 px and reads
  identically by eye. Expect the same on every later step and do not chase it.
- **A pose write replaces the whole transform.** Node code that wrote only
  `position` (leaving rotation alone) or only `quaternion` (leaving scale alone)
  has no equivalent — every such site has to say what it means. The degenerate
  branches in `_pose_arm_*` read the current pose back to preserve exactly what
  the node write preserved.
- **Sizing moved out of the transform.** With nodes, thickness lived in scale
  X/Y and survived a rotation write, which is why two writers could share one
  scale vector. Bones have no such half, so the per-build size is stored
  (`Skater._arm_thickness`) and composed into every pose. This is simpler than
  what it replaced — the two-writer read-back dance is gone.

## State at time of writing

Branch `claude/5v5-fps-performance-43ojlo`. Skater is **64 nodes** (from 82),
goalie **46** (from 50), after a pass that merged rigid child meshes into their
parents, collapsed the arm-bone wrapper/child pairs, and moved the on-ice HUD
(rings, chevrons) into the ice shader and the name plates into one canvas item.

Rules established during that pass that this work must respect:

- **Nothing may set `material_override` on a merged mesh** — it overrides every
  surface at once. Paint through `SkaterMeshBuilder.surface_override()`, which
  duplicates a surface's shared default per instance on first use (the default
  lives on the cached mesh every skater shares, so writing it directly repaints
  the whole roster).
- **Two writers can share a scale vector** if each reads the other's components
  back rather than overwriting the whole thing. This does NOT survive the
  conversion — see the sizing note above.
- **`look_at` is six transform operations**, two of which resolve the global
  chain. Build the basis and assign `transform` once instead.
- `scaled_local` (basis·S) matches how `set_scale` composes; plain `scaled`
  (S·basis) puts the scale on the wrong axes once a node rotates.

## The goalie does not get a skeleton, and that is not an oversight

Its moving parts are `StaticBody3D`s carrying real colliders — the puck bounces
off the pads, the glove and the stick, and the poke geometry reads the blade
collider's world position. `Goalie.apply_body_config` moves six of them per tick
and their meshes ride along as children, so one transform write moves collider
and mesh together.

Bones would not replace those writes. The bodies still have to move for
collision, so a bone pose per mesh is pure addition: six writes would become six
writes plus eleven bone poses, to save nine nodes. That is the same principle
that kept the skater's `blade` and `top_hand` markers as nodes — **what is being
moved is gameplay, so it stays a node.** The skater's parts were the opposite:
pure cosmetics riding markers that stayed.

What did apply is the older merge pattern (the boot and its steel and laces).
The glove's rim, pocket and cuff; the stick's shaft, paddle and blade; the
blocker's board and hand — each group never moves relative to itself AND already
shared one material, so each collapsed to one node, one mesh and one draw call.
All four `goalie_capture.gd` angles came back with zero changed pixels.

The only route to a goalie skeleton is making its collision analytic the way
skater-vs-skater already is. That is a gameplay change with its own risk, and a
separate piece of work.

## What it cost, measured after the fact

**The performance premise of this work was wrong, and the numbers say so.** It is
recorded here because the node counts left behind look like evidence for it.

The conversion was justified on transform propagation: ~40 cosmetic nodes per
skater, each write dirtying a subtree and pushing a global to the
RenderingServer. The F7 sweep was run before and after. Freezing the cosmetic rig
saved ~1.9 ms both times. **Skater went 67 nodes to 32 and the frame did not
move.**

Then the sweep was split (PerfProbe.RIG_WRITE) and a micro-benchmark built
(`benchmarks/test_gait_micro_benchmark.gd`), and the picture came apart further:

| | measured |
|---|---|
| freezing the whole rig | 1.9 ms / frame, 10 skaters |
| freezing only the arm + stick WRITES | 0.12 ms ± 0.32 — unresolved |
| the GDScript in the pose solve | 40 µs/skater → **0.4 ms** |
| the GDScript in the pose writes | 20 µs/skater → **0.2 ms** |

The script accounts for ~0.6 ms of a ~1.9 ms saving. **The missing ~1.3 ms is
engine-side work the writes TRIGGER, not the writes themselves** — resolving both
skeletons and re-uploading their bone data, plus propagating the crouch and
marker nodes the solve still moves.

That also explains the RIG_WRITE null result, which is otherwise baffling.
Freezing the arm and stick writes does not let either skeleton go clean: the gait
still writes four leg bones and the head yaw every frame, so both skeletons are
dirty regardless and the engine pays anyway. Only freezing the WHOLE rig stops
every bone write, and only then does that cost disappear.

Two consequences for anyone optimising this next:

- **The lever is frequency, not arithmetic.** Making the gait's maths faster
  attacks 0.4 ms of a 1.9 ms bill. Making the poses change *less often* — rate
  limiting, distance LOD, skipping unmoved skaters — removes the maths, the
  skeleton resolve and the upload together. The gait costs 27-37 µs in every
  state measured (rest, glide, skate, hockey stop, planted), so there is no cheap
  branch to exploit either; it is uniformly expensive.
- **A skinned rig is not automatically cheaper than nodes.** Bones trade N
  transform propagations for one skeleton resolve plus a texture upload. At this
  part count that came out even. Keep the rig because it is the right structure —
  the argument at the top of this document stands on its own — but do not expect
  frames from it.

## Tools

- `tools/pose_capture.gd` (+ `pose_capture_runner.gd`) — the eleven-pose set and
  its pixel diff. `-- --baseline` records, a bare run compares.
- `tools/skater_matrix.gd` — five builds, loud gear colours, ghosted column.
- `tools/goalie_capture.gd`, `tools/skate_capture.gd` — goalie and gear angles.
- `tools/ring_capture.gd` — drives the ice shader's HUD uniforms directly.
- `benchmarks/test_control_micro_benchmark.gd`,
  `benchmarks/test_goalie_micro_benchmark.gd` — per-tick µs, report-only.
- F3 panel: frame cost split, and F7 the interleaved cosmetic-freeze sweep.

All capture tools need a real (software) renderer, not `--headless`:

```
LIBGL_ALWAYS_SOFTWARE=1 xvfb-run -a godot --path . \
    --rendering-driver opengl3 --audio-driver Dummy -s res://tools/<tool>.gd
```

## Open questions

- **Gameplay anchors.** `blade`, `top_hand`, `shoulder` and friends are
  `Marker3D`s that gameplay reads. Simplest is to keep the handful of them as
  real nodes and drive bones from the same math the controllers already produce;
  the alternative is reading `get_bone_global_pose()` at those seams. Decide
  before step 2 — it shapes where the IK writes land.
- **Stick flex.** The shaft carries a `ShaderMaterial` whose vertex shader bends
  it, plus a per-frame `shaft_len_m` uniform and a live node scale. As a surface
  with a bone it should still work, but it is the least mechanical part of the
  conversion and deserves its own verification pass.
- **Per-part shadow casting.** Currently uniform across the rig; confirm nothing
  depends on toggling it per part before surfaces make that harder.

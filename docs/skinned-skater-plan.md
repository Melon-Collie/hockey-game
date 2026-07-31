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
2. **Spike: arm rig only.** Twelve nodes per skater, purely cosmetic, already
   isolated behind `Skater.bone_visual()`. Convert just those to bones and diff
   across the pose set. If that lands clean the pattern is proven on real code
   and everything after it is repetition.
3. Legs (the gait chain — `LegL/R`, `ShinL/R`, hips/thighs/knees/socks/skates).
4. Torso, helmet, shoulders.
5. Goalie, same pattern.

Each step is its own diffable commit. Do not batch them.

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
  back rather than overwriting the whole thing — the arm bones do this (IK owns
  Z, the sizing seam owns X/Y).
- **`look_at` is six transform operations**, two of which resolve the global
  chain. Build the basis and assign `transform` once instead.
- `scaled_local` (basis·S) matches how `set_scale` composes; plain `scaled`
  (S·basis) puts the scale on the wrong axes once a node rotates.

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

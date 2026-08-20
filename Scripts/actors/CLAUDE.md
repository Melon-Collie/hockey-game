# Skater collaborators

`Skater` (`skater.gd`) is the Node3D in the scene. It owns the tuning vars the
controller scales per player, the **markers** — `Blade`, `Shoulder`, `TopHand`,
`BottomShoulder`, `BottomHand` — which are gameplay geometry every claim
resolver clamps against, the replicated runtime state, and the physics tick.
Everything else is a RefCounted collaborator it constructs in `_ready` and
delegates to.

(The arena bowl has its own directory and its own rules:
`Scripts/actors/arena/CLAUDE.md`.)

| holder | class | what it owns |
|---|---|---|
| `_legs` | `SkaterLegRig` | the leg skeleton, the gait written onto it, foot eversion, and the ice VFX's two reads (skate mark position, edge load) |
| `_arms` | `SkaterArmRig` | the upper skeleton: torso, helmet, deltoid caps, both arms by IK, the trunk texture, the face gear |
| `_stick` | `SkaterStickRig` | the shaft pose, the knob, and the cosmetic flex/whip |
| `_draw` | `SkaterDrawTracker` | the faceoff swipe crest, host-only |
| `_uniform` | `SkaterUniformCoordinator` | the paint |
| `_hud` | `SkaterHUDCoordinator` | the world HUD (ring, plate, chevrons, beacon) |
| `_appearance` | `SkaterAppearanceCoordinator` | per-attribute visual scaling |

## The seam

Traffic runs **one way**. A collaborator holds `_skater` and READS the node's
tuning vars, markers and replicated state; it writes only its own fields and the
NODES it was handed (bone poses, mesh transforms — that is what a rig does).
`Skater` calls methods on a collaborator and never writes one of its fields.

That single rule is the whole contract, and it is not a style preference:
whoever writes a field has re-derived *when* it changes, which is the other
side's lifecycle, and from that moment the other side's own updater is dead code
waiting to happen. The correlation was measured across the goalie's six
collaborators — contested fields 0/2/2/12 predicted dead methods 0/0/0/17. See
`Scripts/controllers/CLAUDE.md`.

Two more, held by the same test
(`tests/unit/actors/test_skater_collaborator_seams.gd`):

- **Rigs never name each other.** They are siblings; a const read across a
  GDScript `class_name` cycle fails at *parse* time and takes every file in the
  cycle down. The single allowed edge is `SkaterStickRig` reading
  `SkaterArmRig.up_for_look_at`, whose composition the stick knob copies.
- **Build order in `_ready` is load-bearing.** The rigs stand first: the uniform
  pass installs the shaft's flex ShaderMaterial and the appearance pass sizes
  bones through the rigs' seams, so both need a rig that exists.

## Why Skater still has a wide public API

The rigs took the *state* and the *code*, not the call sites: `set_leg_swing`,
`upper_surface_material`, `begin_draw_tracking` and the rest stay on `Skater` as
one-line delegates, because the controllers, the gait, the uniform pass and the
ice VFX all address a skater and should not have to know which rig answers.
That is the same shape `_hud` and `_uniform` already had. So the size ratchet
moved a long way and the API ratchet did not — the entanglement the split was
measured against is shared *fields*, and there are now none.

## Cosmetic vs. gameplay, and the render clock

Everything in the three rigs is cosmetic and derived. Nothing gameplay reads
comes out of them, and that is what makes them safe to move: the blade contact
point is the `Blade` marker's, and the rigs only read it.

Two rules the rigs sit inside, both easy to break from in here:

- **Anything drawn onto the skater at render rate reads
  `Skater.render_transform()`**, not `global_position` — the post-tick pose is up
  to a tick of travel from the body on screen. A node placed that way must also
  opt OUT of physics interpolation, or the engine interpolates an
  already-interpolated pose. `SkaterLegRig.mark_position` is the worked example:
  the body half is read interpolated, the bone-pose half as-is.
- **The trunk texture rotates BONES, not the `UpperBody` node.** The blade and
  shoulder markers hang under `UpperBody`, so a node rotation would move
  gameplay geometry at render rate. Bones are pure mesh.

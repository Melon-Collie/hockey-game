# Arena bowl collaborators

`ArenaStands` (`Scripts/actors/arena_stands.gd`) is the Node3D in the scene and
the only thing outside this directory that knows the bowl exists. It owns the
`@export` knobs, the rebuild, the layout cache and the GameManager signal
wiring. Everything that computes or emits geometry lives here, as plain
RefCounteds it constructs.

## The seam

At the top of every `_rebuild`, `ArenaStands` fills one **`ArenaBowlSpec`** — an
immutable snapshot of every export that describes the bowl — and constructs a
fresh collaborator set from it. That is the whole contract, and it is what keeps
the split from rotting:

- **Collaborators read the spec and never write it.** An export has exactly one
  owner, the node, because the node's setter is what decides a rebuild is
  needed. A collaborator writing a spec field would take over that decision
  silently.
- **`ArenaStands` calls methods and never writes a collaborator's field.** Same
  rule from the other side (see `Scripts/controllers/CLAUDE.md` for the goalie
  extraction this rule was learned on).
- **Collaborators are per-rebuild.** They hold no state that has to survive one,
  so there is no lifecycle to get wrong. The two things that DO survive — the
  crowd's shared shader material and the layout cache — are statics with an
  explicit `release_shared_cache()` at app quit.
- **Nothing here names `ArenaStands`.** A const read across a GDScript
  `class_name` cycle fails at *parse* time and takes every file in the cycle
  down with it, so the upward edge is not a design smell here; it is a crash.

`tests/unit/actors/test_arena_collaborator_seams.gd` holds all four
mechanically.

## The tiers

Dependencies run strictly downward, so two collaborators on one tier can never
reach for each other. The table in the seam test is the enforced copy of this.

| tier | class | what it is |
|---|---|---|
| 0 | `ArenaBowlSpec` | the numbers, as a record |
| 0 | `ArenaMeshEmit` | SurfaceTool primitives — treads, risers, boxes, quads |
| 0 | `ArenaRinksideLayout` | where the benches and boxes are, and what they clear |
| 1 | `ArenaBowlPath` | the perimeter in plan: ring sampling, arc-length, aisles, cull slices |
| 1 | `ArenaFigureMesh` | the human figure: geometry, anthropometry, sitting↔standing |
| 2 | `ArenaBowlRake` | the bowl in section: row offsets and heights, deck levels, wells, portals |
| 3 | `ArenaDeckMesh` | the poured concrete: terraces, shell wall, vomitory tunnels |
| 3 | `ArenaCrowd` | spectator layout, paint, excitement sink |
| 3 | `ArenaSeating` | the seats |
| 3 | `ArenaRinkside` | benches, penalty boxes, officials' table, staff |
| 3 | `ArenaSignage` | ribbon board and rafter banners, and their render targets |

Two shared primitives are why tiers 0–2 exist at all, and both were found by
asking what the *remainder* still calls rather than by grouping on topic:
`ArenaRinksideLayout.in_bench_zone` is needed by the rake (to cut the terraces)
as well as by the furniture itself, and `ArenaFigureMesh` is needed by the crowd
(seated) as well as the staff (standing).

## Build order is load-bearing

Each tier-3 collaborator `add_child`s its own nodes at the moment `_rebuild`
calls it, so **the call sequence in `_rebuild` IS the child order** — and with it
the order the opaque passes settle into. Seats go in before spectators so the
occupants draw over their own seat backs. Grouping a stage's children under one
root node would be tidier and would silently re-layer the bowl.
`test_the_build_order_is_the_child_order` pins the whole sequence.

## Two caches, and why they are split that way

`ArenaStands` keeps a static `_layout_cache` keyed on
`ArenaBowlSpec.geometry_key()`. A layout holds the terrace and shell meshes and
the crowd/seat MultiMeshes — everything colour-independent and deterministic
under a fixed seed — so it is built once per geometry-param set and reused for
the process lifetime. A scene change's rebuild becomes at most a crowd repaint;
a same-colours rebuild reattaches without touching a single instance.

The dividing line is exactly which key a param appears in. `seat_shade_variation`
is in the *geometry* key because it is rolled into per-instance colours baked
into the cached MultiMeshes; `seat_color` is in neither, because it lives on the
seat material and multiplies through at draw time.

## Verifying a change

A geometry bug is a proportion or a placement, and a display-less test passes a
figure at twice its width. Three checks, in the order they catch things:

```
.claude/hooks/render-arena.sh                       # before/after PNGs, diff them
ARENA_PREVIEW_AABB_AUDIT=1 .claude/hooks/render-arena.sh   # every declared custom_aabb vs. its instances
bash .claude/hooks/run-gut.sh -gdir=res://tests/unit/actors
```

The AABB audit is the one only a real renderer can make: instance transforms
read back empty under `--headless`, and every MultiMesh here declares a
hand-written `custom_aabb` the renderer never re-checks. Declare one smaller than
its instances and they vanish the moment the shortfall leaves the screen, from
some camera angles and not others.

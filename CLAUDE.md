# CLAUDE.md

Context for Claude about the Mitts project — a 3v3/5v5 hockey game in Godot 4.6.2
(GDScript, 3D), online multiplayer, one player per machine with their own camera
and local simulation. Prioritizes feel over realism: deep stickhandling, multiple
shot types, satisfying puck physics. 3v3 (position-free rovers) is the default;
5v5 is lobby-selectable and adds the forward/defense split.

## Where the detail lives

This file is the always-loaded routing layer: conventions, layout, and workflow.
Deep detail lives next to the code it describes and loads on demand.

| Topic | Document |
|---|---|
| How the game plays — every mechanic, feel, and its reasoning | `docs/gameplay-design.md` |
| Networking invariants (RPCs, reconcile, prediction, lag comp) | `Scripts/networking/CLAUDE.md` |
| Bot AI design rules (evaluators, difficulty axes, determinism) | `Scripts/domain/ai/CLAUDE.md` |
| Bot agent wiring (state graph, reception and chase doctrine) | `Scripts/ai/CLAUDE.md` |
| Goalie doctrine, controller collaborators | `Scripts/controllers/CLAUDE.md` |
| Player attributes (body dials, gear slots, routing) | `Scripts/domain/state/CLAUDE.md` |
| Launch modes, session lifecycle, claim resolvers, backend | `Scripts/game/CLAUDE.md` |
| UI conventions (locale seam, menu style, popups) | `Scripts/ui/CLAUDE.md` |
| Skater collaborators (rig seam, render clock, why the API is wide) | `Scripts/actors/CLAUDE.md` |
| Arena bowl collaborators (spec seam, tiers, build order) | `Scripts/actors/arena/CLAUDE.md` |
| Test suite conventions | `tests/CLAUDE.md` |
| Native C++ kernels (GDExtension build, parity gates) | `native/README.md` |
| Class boundaries, subsystem decisions, invariants | `ARCHITECTURE.md` |
| Feature design records | `docs/*-plan.md` |
| Backlog — perf, extraction candidates, coverage gaps, planned work | GitHub issues |

**Before touching networking code** (RPCs, reconcile, prediction, interpolation,
lag comp, clock sync, spectator swap, body checks), read
`Scripts/networking/CLAUDE.md`. Those rules are non-obvious and cause subtle bugs
if violated.

## Workflow

Complex features may be designed first in Claude.ai chat mode and handed to
Claude Code as a plan document. Treat such a plan as the agreed design — ask
before deviating from it.

**Never push to `main` without the user testing locally first.** Feature branches
(`claude/*`) may be pushed after committing so the user can pull and test.
Merging into `main` is done by the user via a pull request — never `git merge` a
feature branch into `main` directly. For work on `main`, stop at commit and wait
for explicit confirmation before pushing.

**Scene files (`.tscn`) and complex resource files (`.tres`) are CREATED by the
user, not Claude.** The risk is the generated half of the format: node unique
IDs, sub-resource ids and the references between them, editor-enforced property
ordering. Authoring any of that by hand — a node, a property, a sub-resource,
anything in a theme, a shader material or an animation — means inventing
identifiers the editor owns, so describe the change and let the user make it
there.

**Deleting is not that, and is Claude's to do**: a property line, a whole node
block, or a sub-resource nothing references any more. A delete invents no
identifier and reorders nothing. Two obligations come with it. Prove the thing
is inert first — a property line only goes if it already equals the code
default, a node only goes once nothing reads it (check `LEG_BONE_NODE` and its
kin, which name scene paths in code), and a sub-resource only goes once its last
user is gone. Then prove the file still loads: run the suite, since the scene is
instantiated all over it, and render if the rig's shape is what changed. Trivial single-resource `.tres` files
(`PhysicsMaterial`, simple `StandardMaterial3D`) are safe to author directly —
3–5 lines, no cross-references; the UID line is optional.

**You can run the GUT test suite headless, and you can render both the arena bowl
and the skater rig offscreen; you cannot run the game.** Use
`.claude/hooks/run-gut.sh` (wraps `godot --headless -s res://addons/gut/gut_cmdln.gd`,
honoring `.gutconfig.json`). Pass `gut_cmdln` flags through, e.g.
`-gdir=res://tests/unit/state`.
- **Local:** `GODOT_BIN` (in `.claude/settings.local.json`) points at the Godot
  executable. Full suite ≈ 15–18 s. **Redirect to a file, don't pipe** — the
  Windows console exe throttles badly on an MSYS pipe (≈90 s vs ≈18 s):
  `bash .claude/hooks/run-gut.sh > "$TMP/gut.log" 2>&1; tail -40 "$TMP/gut.log"`.
- **Web:** the `SessionStart` hook async-installs Godot; run
  `.claude/hooks/wait-for-godot.sh` once before the first test run, then
  `.claude/hooks/run-gut.sh` (piping is fine on Linux).

**To see procedural arena geometry, render it.** `.claude/hooks/render-arena.sh
[shots]` builds an `ArenaStands` under a camera and writes PNGs to `.preview/`
(shot list in `tools/arena_preview.gd`). Godot's `--headless` draws nothing — the
renderer runs under `xvfb-run` on the Compatibility backend and Mesa's software
rasterizer instead, ~40 s a run. Use it on anything whose bug is a proportion or
a placement: a figure at twice its width passes every assertion a display-less
test can make. It covers the stands only, not a live match.
`ARENA_PREVIEW_AABB_AUDIT=1` skips the pretty picture and measures every
MultiMesh's declared `custom_aabb` against the geometry it must contain — the
check for a suspected mis-cull, and one only a real renderer can make (instance
transforms read back empty under `--headless`).

**To see a POSE, render it too.** `.claude/hooks/render-poses.sh [--baseline]`
drives a real `Skater` + `SkaterController` through a list of held poses (the
gait, an arm-IK reach at its ROM rim, both shot wind-ups and follow-throughs,
the block, the check commit) and pixel-diffs the set against a recorded
baseline; pose list and framing in `tools/pose_capture.gd`. Same xvfb/software-GL
constraint as the arena, and the same argument: articulation is the thing a
display-less test cannot assert. `tools/skater_matrix.gd` is its sibling for
proportions and paint across builds — one static pose, five bodies.

A render answers *how it reads*; it does not answer *whether two placements
agree*. When the question is the second one — does the pad still sit on the arm,
does the mirrored side land where the near side does — measure it in a test
(`tests/unit/actors/test_check_stance_rig.gd` builds the live rig and compares
the two code paths' numbers). Eyeballing a 384 px tile is how a 4 cm
disagreement gets called fine.

Run the suite after touching domain code and report results. **AI perf changes
also run the benchmarks** (`bash .claude/hooks/run-gut.sh -gdir=res://benchmarks`
— report-only host-cost scenarios plus a per-evaluator micro-bench, outside the
default suite): compare before/after, especially per-tick p95/max (host FPS is
set by the worst tick) and the per-call evaluator ranking. For gameplay or
networking changes, describe what to test locally and wait for the user to verify.

**Run gdlint before committing `.gd` changes.** `.claude/hooks/run-lint.sh` runs
gdtoolkit's gdlint (tuned via `.gdlintrc`) — dead code, unused args/vars,
`duplicated-load`, trailing whitespace. A committed `.githooks/pre-commit` gate
blocks any commit with gdlint problems in staged `.gd` files (`--no-verify`
bypasses). Keep the tree gdlint-clean. Caveat: gdlint can't see Godot's
engine-specific analyzer warnings (`SHADOWED_VARIABLE_BASE_CLASS`, `INT_AS_ENUM`,
narrowing) — those stay editor-only, so a clean gdlint run isn't proof the editor
is warning-free.

**Two ratchets gate file shape** (`test_no_god_class_growth.gd`): 800 lines a
file, 25 public functions a class. Files already past those lines are
grandfathered in a table at the size they were, so they cannot grow. A ratchet
firing is a prompt to split — but bumping the number is allowed when the growth
is right, since the point is that growth is deliberate and visible in the diff.
A file that *shrinks* well below its entry must have the entry tightened, or the
win gets re-spent quietly.

**If you spot a bug or code smell while working on something else, flag it.**
Don't silently fix it (out of scope), don't silently ignore it (it'll rot), don't
tack it onto the current commit (muddies the diff). Surface it in chat with a
one-line description and let the user decide. Latent bugs in adjacent code paths
are especially worth flagging.

**Stale documentation is the exception: fix it on the spot.** When a doc or
comment no longer matches the code, correct it as part of whatever you're doing —
don't flag it as out of scope, don't ask. Keeping documentation truthful is
always in scope.

## Comments and documentation

Comments are expensive — they are read on every visit to the file and they
compete with code for context. Large stretches of this codebase are more English
than code, which is not a sign of care — it is a sign that comments are where
information goes when nobody decided where it belongs.

### The scope test

**A comment's scope must not exceed the code beneath it.** That is the whole
rule, and it is the one that can come out *no*.

If a comment explains something larger than the lines it sits on — how a
subsystem thinks, why two files agree, what the design philosophy is, what the
code used to be — it is in the wrong place no matter how true or how well
written it is. "Is this useful?" is not the test; a misplaced comment is usually
useful, which is exactly why it accumulated. Ask instead: *is this a fact about
the code directly below?*

Passes the test — write these:

- why a non-obvious choice was made **here**
- a physical justification for a constant ("blade traverse over the interpolation
  window, plus IK slack")
- a trap the next reader falls into without it
- an invariant this code relies on but cannot check locally
- units and frames of reference
- a present-tense statement of what the code does and does not model ("league
  default rather than the defender's own stick length")

### Where displaced information goes

Four homes, and one of them is always right:

| What it is | Where it goes |
|---|---|
| How a subsystem thinks, cross-file architecture, a design constitution | the nearest area `CLAUDE.md` |
| "must match X", "mirrors Y", "keep in sync with Z" | a **test** that fails when they diverge |
| Deferred work, a known gap, a fix someone should make | a **GitHub issue** — never `TODO`/`FIXME`/`HACK` |
| What the code used to be, which lever was retired, which bug this fixed | **git** — delete it |

The second row is the one most often skipped, and it is the highest-value one. A
comment saying two things must agree is a test that was never written: it makes
the claim, and then nothing checks it. `test_goalie_scene_mirrors.gd` and
`test_net_geometry_mirrors.gd` are what those comments should have been.

The fourth row deserves saying plainly: **narration of the past is not
documentation.** "This used to use rtt/2", "the old signal only captured
attacker rebound", "removed in favour of render == rewind" — every reader pays
for that forever so that one reader might not repeat one mistake. Git holds it,
and the commit that made the change holds *why*. If the old approach is a trap
someone will genuinely fall back into, one present-tense sentence saying what
must NOT be done is worth keeping ("never re-derive the lead at a call site").
The story of how it was discovered is not.

### Size is a symptom, not a limit

There is no ratio to hit. But when a comment is much longer than the code it
governs — five lines of English over one line of code — that is a reliable
signal the information is bigger than its home, and it is a prompt to run the
scope test rather than a violation on its own. Some one-line constants genuinely
earn a paragraph. Most do not.

Two specific shapes to delete on sight:

- **Restating a name.** `# Reset the timer` over `_timer = 0.0`. GDScript is
  already self-naming; a comment that says the identifier back is pure cost.
- **The same explanation twice in one file.** A file header and its per-field
  comments must not restate each other. Say it once, at the more specific site.

### Prefer making the code say it

Before writing an explanation, check whether the code can carry it instead: a
named constant instead of a literal plus a comment, a named local instead of an
expression plus a comment, an extracted function whose name is the sentence you
were about to write. That version cannot go stale.

### You own the comments on code you change

This is what keeps the file from re-accumulating. When you touch a function, the
comments around your change are yours: if one fails the scope test, move it to
its home now — that is not scope creep, it is the same rule that says stale
documentation gets fixed on the spot. You are not obliged to sweep the rest of
the file.

## Layer Architecture

Three layers; dependencies always flow downward:

- **Domain** (`Scripts/domain/`) — pure GDScript, no engine APIs. Rule classes
  (static methods), the game state machine (RefCounted), enums, game-rule
  constants. Fully unit-testable without Godot.
- **Application** — `GameManager` (autoload orchestrator), controllers,
  `ActorSpawner`, and six RefCounted collaborators. Use the domain to decide;
  reach into infrastructure to execute.
- **Infrastructure** — actor nodes (Skater, Puck, Goalie), `NetworkManager`, UI.
  The Godot-side glue.

Lower layers never reach up: actors take collaborators via `setup()` (e.g.
`Puck.set_team_resolver(Callable)`); controllers take a `game_state: Node`
exposing `is_host()` / `is_movement_locked()`. Upward communication is by signals
the orchestrator listens to. See `ARCHITECTURE.md` → **Confusing Boundaries** for
class-responsibility detail.

## Autoloads

The list and its initialization order live in `project.godot → [autoload]`. What
that file can't tell you:

- `NetworkManager._ready()` is a no-op — the menu drives initialization.
- `SteamManager` owns every GodotSteam (`Steam` singleton) call and degrades to a
  no-op (`is_available = false`) when Steam isn't running or the GDExtension is
  absent (headless CI), so offline / free play / tutorial and the GUT suite are
  unaffected.
- `SoundManager` exposes `play_ui` / `play_world`.

## Where New Code Goes

| Task | Location |
|------|----------|
| New game rule or geometry constant | `domain/config/game_rules.gd` |
| New pure stateless math or rule | New file in `domain/rules/` + GUT test |
| New domain state type | New file in `domain/state/` + GUT test |
| New per-player stat | `PlayerStats` → wire format → `WorldStateCodec` → `PlayerStats.to_dict()` for Supabase |
| New career stat column | New `supabase/migrations/<timestamp>_*.sql` (column + `career_totals_for()`) → `PlayerStats.to_dict()` → row in `CareerStatsScreen._on_totals_received`. CI applies it on merge to `main`; never edit an existing migration |
| Submit bug report from UI | Instantiate `BugReportDialog`, `add_child` it, call `.open()` on button press |
| New RPC | `NetworkManager` (define) → emit a signal → `GameManager._wire_network_signals()` (connect) |
| New phase-entry side effect | `PhaseCoordinator` |
| New arena sponsor (boards and in-ice) | Append to `AdBrands.BRANDS` — a row, not an art file; the painters compose the panel. A new in-ice placement is a row in `AdBrands.ICE_SLOTS`, which `test_board_ad_layout.gd` holds against every painted marking |
| New practice drill | Append to `DrillRegistry` (id + `display_name_key` + manager path; add the matching `DRILL_*` row to `locale/translations.csv`) → manager node in `Scripts/game/` extending `DrillLoop` (which owns the stage machine, result hold, puck staging and retry/exit; the drill overrides `_begin_attempt` / `_tick_live`) → `DrillHUD` subclass for its strings. `test_drill_registry.gd` holds all four steps |
| New controller behavior | Method on `SkaterController`; `GameManager` calls it, never pokes internals directly |
| New reconcile logic | `domain/rules/reconciliation_rules.gd` + GUT test |
| New bot AI evaluator | `domain/ai/action_scoring.gd` (shot, pass, dump, and the shared clocks) or `domain/ai/carry_space.gd` (the carrier's room to operate: evasion, controlled space, deke, brake) + GUT calibration test — build it as a grounded model (see `Scripts/domain/ai/CLAUDE.md`) |
| Port a hot kernel to C++ | `native/src/` + seeded parity fuzz test + micro-bench row; GDScript original stays as the reference (see `native/README.md`) |
| New "body dial X scales Y" rule | `PlayerAttributes` (see `Scripts/domain/state/CLAUDE.md`) |
| New skater cosmetic rig behavior | The rig that owns it under `Scripts/actors/` (`SkaterLegRig` / `SkaterArmRig` / `SkaterStickRig`); it reads `Skater`'s tuning and markers and writes only its own state, and `Skater` delegates rather than reaching in. `test_skater_collaborator_seams.gd` holds the seam (see `Scripts/actors/CLAUDE.md`) |
| New arena bowl geometry | A collaborator under `Scripts/actors/arena/`, constructed from the `ArenaBowlSpec` snapshot and never writing it; `ArenaStands` calls it from `_rebuild`, where the call order IS the child order. `test_arena_collaborator_seams.gd` holds the tiers and the seam (see `Scripts/actors/arena/CLAUDE.md`) |
| New HUD panel | Class in `Scripts/ui/hud/` owning its widgets and its state; `HUD` holds a reference, calls methods and never writes its fields — upward flow is a signal. `test_hud_panel_wiring.gd` holds both (see `Scripts/ui/CLAUDE.md`) |
| New user-facing UI string | `KEY,en,es` row in `locale/translations.csv`, then `tr("KEY")` at the display seam; `test_ui_uses_the_locale_seam.gd` ratchets the files that still hold English (see `Scripts/ui/CLAUDE.md`) |

## Code Conventions

**Strong typing everywhere.** Typed arrays (`Array[BufferedPuckState]`), typed
signatures, typed variables. Never omit a type annotation that can be provided.

**Cast or annotate when chaining through superclass APIs.** GDScript can't infer
through methods returning a base class — `Engine.get_main_loop()` returns
`MainLoop`, not `SceneTree`; `find_child()` returns `Node`, not the subclass;
same for `get_node()`, `instance_from_id()`. Add an explicit type or cast so the
analyzer resolves member access on the next line.

**Godot naming.** `snake_case` for variables and functions, `PascalCase` for
classes, `SCREAMING_SNAKE_CASE` for constants.

**Separation of concerns.** Physics bodies (`Puck`, `Skater`) expose a clean API.
Controllers drive them. `GameManager` owns spawning and world state.
`NetworkManager` owns RPCs. Don't reach across these boundaries casually.

**Network API uses typed objects, not raw arrays.** Functions accept
`SkaterNetworkState` / `PuckNetworkState` directly; serialization happens only at
the RPC boundary.

**Get it working, then tune numbers.** Author a tunable as a plain class-level
`var` with its value in code. `@export` is for the handful a `.tscn` genuinely
overrides — of 573 exports on the two controllers and `Skater`, a scene set
exactly zero of them, so the inspector rows were pure cost. They stay `var`
rather than `const` because `apply_attributes` scales them per skater at
runtime. Don't prematurely optimize or bikeshed constants before the mechanic
runs. **Live
editor tuning is not a workflow here** — hot-path code may cache config objects
built from those fields (rebuilt on `apply_attributes`) without preserving per-tick
rebuild semantics. Don't undo config caching to restore live-tuning.

**Grounded models over magic-number curves, in evaluation code especially.** When
code evaluates a situation — bot utility scoring, the goalie's read, any "how
dangerous / open / safe is this?" number — build it from quantities the actor can
physically see, not a curve shaped to feel right. Fix a wrong behavior by fixing
the *model*, not by bolting on a corrective hack. Feel tunables (staging offsets,
loft heights, difficulty knobs) are legitimately hand-picked; the line is
evaluation vs. feel. Full rules: `Scripts/domain/ai/CLAUDE.md`.

**Hot-path discipline — the 120 Hz tick multiplies every cost.** Anything reached
from `_physics_process` or a per-tick `update()` runs 120×/second × actor count
(6 skaters + 2 goalies + puck), and reconcile replay re-runs the per-tick body
once *per replayed input* — so the cost is amplified exactly when the network is
bad. When the host's tick budget overruns, physics dilates and the broadcast
cadence (counted in physics ticks) sags with it, so one host-side regression
degrades the whole lobby. Two failure modes:

1. **Allocation churn** (dominant) — per-tick heap objects: `.new()`,
   Dictionary/Array literals, `.filter()`/`.map()`/lambdas, `x in [literal]`,
   returning a fresh `Dictionary`/`Array`, per-call `String` formatting. Value
   types (`Vector3`, `Basis`, `Transform3D`) do **not** heap-allocate — the enemy
   is the heap object, not the arithmetic.
2. **Unnecessary cosmetic work** — visual-only updates (mesh/arm IK, `look_at`,
   decals) belong in `_process` (render rate), not `_physics_process`, and should
   skip when idle (dirty flag) or off-screen. Gameplay reads the `blade`/
   `Marker3D` anchors, not the cosmetic mesh.

**Render rate is a clock, and clocks must not be mixed inside one frame.** A
rendered frame depicts a single instant, so everything visible in it has to be
sampled at that instant. Moving visual work to `_process` is therefore safe only
when nothing still on the tick shares a spatial relationship with it — and the
camera shares one with every actor, so it can never move alone. Moving *it* to
render rate while actors stayed on the tick is what put a one-tick-of-travel
sawtooth into every skater's screen position above 120 fps (see
`GameCamera._process`). Either everything visible moves together, or the
tick-rate half is interpolated up to render time; `physics/common/
physics_interpolation` now does the latter, which is why actor teleports must
call `reset_physics_interpolation()` (see `SkaterController.teleport_to`). A
uniformly tick-rate scene reads as a lower frame rate, which is fine — a mixed
one reads as jitter, which is not.

**Interpolation makes `global_position` the wrong read for anything drawn onto
an actor.** It is the post-tick pose; the body on screen is between poses. Any
chrome placed at render rate — a nameplate, a marker, an ice-shader uniform —
must read `Skater.render_transform()` (memoized `get_global_transform_
interpolated()`) or it crawls against the body it belongs to, worse the faster
the skater and the higher the refresh rate. A node placed that way must also opt
OUT of interpolation (`PHYSICS_INTERPOLATION_MODE_OFF`), or the engine
interpolates an already-interpolated pose and puts the lag back.

Keep the layer boundary **and** the performance — a Callable/collaborator
boundary is an interface, not a license to allocate per call. *Memoize at the
seam* (`PlayerRegistry` caches `Array[Skater]`; `puck_controller` caches
`team_id_by_skater`). *Build once, fill scratch* — solvers fill a caller-owned
result instead of returning a fresh `Dictionary` (`GoalieBodyConfigBuilder`'s
shared scratch config is the model). This is about *structure*, not constants, so
it doesn't conflict with "get it working, then tune numbers".

**Don't shy away from complexity when it improves feel.** This project already
has client-side prediction with input replay, buffered interpolation, and puck
trajectory prediction with reconciliation. If a complex system makes the game
feel meaningfully better, it's worth doing — think it through, then implement it
properly.

**All popups and modal dialogs must be closeable via `ui_cancel` (Escape).** Add
the popup to the existing `_unhandled_input` block in the relevant UI script —
check `popup.visible`, hide it, call `get_viewport().set_input_as_handled()`.

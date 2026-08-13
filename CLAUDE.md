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
| Goalie doctrine, controller collaborators | `Scripts/controllers/CLAUDE.md` |
| Player attributes (body dials, gear slots, routing) | `Scripts/domain/state/CLAUDE.md` |
| Launch modes, session lifecycle, claim resolvers, backend | `Scripts/game/CLAUDE.md` |
| UI conventions (locale seam, menu style, popups) | `Scripts/ui/CLAUDE.md` |
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

**Scene files (`.tscn`) and complex resource files (`.tres`) are edited by the
user, not Claude.** Godot's text formats are error-prone to edit when they carry
node unique IDs, sub-resource references, or editor-enforced property ordering —
multi-node scenes, themes, shader materials, animations. Describe the change and
let the user make it in the editor. Trivial single-resource `.tres` files
(`PhysicsMaterial`, simple `StandardMaterial3D`) are safe to author directly —
3–5 lines, no cross-references; the UID line is optional.

**You can run the GUT test suite headless; you cannot run the game.** Use
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
compete with code for context. Write the ones that carry information the code
cannot.

**Do write:** why a non-obvious choice was made, a physical justification for a
constant, a trap the next reader will otherwise fall into, an invariant that
isn't locally checkable, units and frames of reference.

**Don't write:** what the code plainly does, changelog prose (what the code used
to be, which lever was retired, what a past bug was — git holds that), or the
same explanation twice in one file. A file header and its per-field comments
should not restate each other.

**Higher-level reasoning belongs in the nearest `CLAUDE.md`, not a file header.**
Design constitutions, cross-file architecture, and "how this subsystem thinks"
load on demand from the area doc; a 200-line header essay is paid for by every
reader of that file. If a comment is explaining the *system* rather than the
*code beneath it*, move it.

**Deferred work does not live in the code — it gets a GitHub issue.** No `TODO`,
`FIXME`, `HACK`, or "NOT YET WIRED" comments. A note in a file header is invisible
to planning, has no owner, and goes stale silently: three `TODO(per-player attrs)`
comments sat in the tree waiting for an API (`attribute_resolver`) that was never
built, long after the feature they were blocked on had shipped under a different
name. File the issue with enough context to act on — mechanism, fix sketch, which
tests move — then delete the comment.

What *may* stay at the call site is a present-tense statement of what the code
does and does not model ("league default rather than the defender's own stick
length"), because that is a fact about the code as it stands. The plan to change
it belongs in the issue.

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
| New practice drill | Append to `DrillRegistry` (id + `display_name_key` + manager path; add the matching `DRILL_*` row to `locale/translations.csv`) → manager node in `Scripts/game/` owning the drill loop (`DrillSession` for the score tally) → `DrillHUD` subclass for its strings |
| New controller behavior | Method on `SkaterController`; `GameManager` calls it, never pokes internals directly |
| New reconcile logic | `domain/rules/reconciliation_rules.gd` + GUT test |
| New bot AI evaluator | `domain/ai/action_scoring.gd` + GUT calibration test — build it as a grounded model (see `Scripts/domain/ai/CLAUDE.md`) |
| Port a hot kernel to C++ | `native/src/` + seeded parity fuzz test + micro-bench row; GDScript original stays as the reference (see `native/README.md`) |
| New "body dial X scales Y" rule | `PlayerAttributes` (see `Scripts/domain/state/CLAUDE.md`) |
| New user-facing UI string | `KEY,en,es` row in `locale/translations.csv`, then `tr("KEY")` at the display seam (see `Scripts/ui/CLAUDE.md`) |

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

**Get it working, then tune numbers.** Use `@export` for tunables. Don't
prematurely optimize or bikeshed constants before the mechanic runs. **Live
editor tuning is not a workflow here** — hot-path code may cache config objects
built from exports (rebuilt on `apply_attributes`) without preserving per-tick
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

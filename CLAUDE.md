# CLAUDE.md

Context for Claude about the Mitts project. Deep technical reference (networking invariants, class-boundary detail, backlog) lives in `ARCHITECTURE.md`.

## Workflow

Complex features (AI state machines, new systems, architectural changes) can be designed first in Claude.ai chat mode, where the developer can iterate on ideas without implementation pressure. The resulting plan is then handed to Claude Code to implement against the actual codebase. When a session starts with a plan document, treat it as the agreed design — ask clarifying questions before deviating from it.

**Never push to `main` without the user testing locally first.** Feature branches (e.g. `claude/*`) may be pushed after committing so the user can pull and test on their machine. Merging a feature branch into `main` is done by the user via a pull request in the UI — do not `git merge` a feature branch into `main` directly. For work done directly on `main`, always stop at commit and wait for explicit confirmation before running `git push`.

**Scene files (`.tscn`) and complex resource files (`.tres`) are edited by the user, not Claude.** Godot's text formats are error-prone to edit when they contain node unique IDs, sub-resource references, or property ordering that the editor enforces — multi-node scenes, themes, shader materials, animations, etc. Describe the change and let the user make it in the Godot editor. **Trivial single-resource `.tres` files (e.g. `PhysicsMaterial`, simple `StandardMaterial3D`) are safe to author directly** — they're 3-5 lines with no cross-references. The UID line is optional; Godot generates one on first import if omitted.

**You cannot run the game or the test suite.** The GUT panel runs in the Godot editor; the headless CLI does not work in this environment. After touching domain code, note which test files cover the affected area and ask the user to run them. For gameplay or networking changes, describe what to test in a local session and wait for the user to verify.

**If you spot a bug or code smell while working on something else, flag it.** Don't silently fix it (out of scope), don't silently ignore it (it'll rot), don't tack it onto the current commit (muddies the diff). Surface it in chat with a one-line description and let the user decide: fix now as a small follow-up, defer to a separate task, or capture as a Known Issue here. Latent bugs in adjacent code paths are especially worth flagging — they often pair with whatever you're touching.

## What This Is

A 3v3 arcade hockey game built in Godot 4.6.2 (GDScript, 3D). Online multiplayer — one player per machine, each with their own camera and local simulation. Prioritizes feel over realism: deep stickhandling, multiple shot types, satisfying puck physics.

**Puck RigidBody3D has Continuous CD enabled.** Do not suggest enabling CCD as a fix for puck tunnelling — it is already on. Puck escaping the rink is more likely a velocity/reflection compounding bug or a Jolt edge case.

## How It Plays

**Mouse + keyboard only, no gamepad.** WASD skates, mouse cursor places the blade in real-time (continuous IK — the blade chases the cursor every frame, no aim button). Camera is third-person, per-player, dynamic-zoom, tilted ~75° so cursor-to-world projection stays usable for stickhandling.

**Stickhandling is physical, not abstract.** The puck is a real `RigidBody3D` that attaches to the blade by proximity; there is no possession flag you press to engage. Carrying slows you. Moving the cursor swings the blade through forehand/backhand with a small lift through center — that's the "dangling" texture. Fast incoming pucks (≥14 m/s) deflect off a static blade; you have to draw the blade *back into* the puck to absorb a pass. No `deke` button — deception is blade placement plus skating rhythm.

**Three shot types, all aim-aware:**
- **Wrister** (LMB) — quick tap fires instantly at moderate speed; hold-and-drag charges by *drag distance*, and the drag direction *is* the aim vector.
- **Slapshot** (RMB) — time-charged wind-up, aim locked at press. Supports **one-timers**: charge without the puck, release fires when the puck enters the shooting zone.
- **Self-shot** (E) — emergency release while carrying.

Backhand shots take a power penalty. Scroll wheel toggles elevation (ballistic targeting, apex-capped so you don't sail it over the net). Passes are quick-shots — same mechanic, no separate pass system, no saucer/tape-to-tape variants.

**Skating is momentum-driven.** Thrust accelerates, drag-friction decelerates naturally, Space brakes hard or carves with direction held. Backward and lateral (crossover) movement are slower than forward. Facing lazily tracks the cursor; Shift freezes facing for strafing shots. No frame-perfect inputs — reads and positioning matter more than execution precision.

**Physicality is emergent, not scripted.** Body checks trigger from closing-velocity impulse, not a hit button. Ctrl crouches to shot-block (wider hitbox, reflects shots). Poke-checks are stick-on-stick momentum contests — the blades collide and the puck goes where the blended momentum sends it. Stick lifts happen naturally from geometry, not a command.

**Goalies are AI-only, never player-controlled.** Designed to feel fair, not realistic — reactive with a small reaction delay (which is the window for close-range top-corner goals), positional depth chart, butterfly with a commit timer to prevent toggling, and threat tracking weighted toward the carrier's body rather than the puck (anti-5-hole-exploit).

**Game format:** 3v3, three periods plus optional OT, period length tunable. Faceoffs have a short "2 → 1 → DROP" prep. **Offsides** ghost the offending player (can't interact with the puck) until they tag back to the blue line. **Icing** ghosts the whole offending team briefly. Goals trigger a short pause + celebration window. The default ruleset is `ARCADE` — offsides on, icing off by default — because strict sim rules get in the way of arcade flow.

**Tone is arcade-casual with a competitive ceiling.** The physics are responsive and forgiving on the surface, but blade placement, shot timing, charge management, and positioning meaningfully separate skilled play. Pick-up-and-play, hard to master.

**Where the numbers live** (don't bake these into prose — read them when you need them): movement and shot tuning in `Scripts/controllers/skater_controller.gd`; shot math in `Scripts/domain/rules/shot_mechanics.gd`; period/faceoff/offsides/icing constants and presets in `Scripts/domain/config/game_rules.gd`; goalie tuning in `Scripts/controllers/goalie_controller.gd`.

## Tech Stack

- **Engine:** Godot 4.6.2 (Jolt Physics)
- **Language:** GDScript
- **Physics tick:** 240 Hz
- **Testing:** GUT v9.6.0 under `addons/gut/`; tests in `tests/unit/` (rules/, state/, game/). Run via GUT panel in the Godot editor.
- **CI:** `.github/workflows/test.yml` runs GUT on every push and PR; `deploy.yml`'s export job gates on tests passing.
- **Deployment:** GitHub Actions → Windows + Linux export → GitHub Releases (tag: `latest`)

## Layer Architecture

The codebase is split into three layers; dependencies always flow downward:

- **Domain** (`Scripts/domain/`) — pure GDScript, no engine APIs. Rule classes (static methods), the game state machine (RefCounted), enums, and game-rule constants. Fully unit-testable without Godot.
- **Application** — `GameManager` (autoload orchestrator), controllers, `ActorSpawner`, and six RefCounted collaborators. Use the domain to make decisions; reach into infrastructure to execute them.
- **Infrastructure** — actor nodes (Skater, Puck, Goalie), `NetworkManager`, UI. The Godot-side glue.

Lower layers never reach up: actors take their collaborators via `setup()` (e.g. `Puck.set_team_resolver(Callable)`); controllers take a `game_state: Node` exposing `is_host()` / `is_movement_locked()`). Upward communication is by signals that the orchestrator listens to.

See `ARCHITECTURE.md` → **Confusing Boundaries** for class-responsibility detail (`GameStateMachine` vs `PhaseCoordinator` vs `GameManager`, `constants.gd` vs `game_rules.gd`, `SkaterController`'s five `RefCounted` collaborators, etc.).

## Autoloads

Initialized in this order: `PlayerPrefs` → `Constants` → `BuildInfo` → `SoundManager` (`sound_manager.gd`, no class_name) → `NetworkManager` → `NetworkSimManager` (`network_sim.gd`, no class_name) → `GameManager`. `NetworkManager._ready()` is a no-op; the menu drives initialization. `SoundManager` exposes `play_ui(sound: SoundManager.Sound, volume_db := 0.0, pitch_variance := 0.0)` and `play_world(sound: SoundManager.Sound, pos: Vector3, volume_db := 0.0, pitch_variance := 0.0)`; sound constants live in its `Sound` enum.

## Networking

Before touching networking code (RPCs, reconcile, prediction, interpolation, lag comp, clock sync, spectator swap, body checks), read `ARCHITECTURE.md` → **Networking Invariants**. Those rules are non-obvious and cause subtle bugs if violated.

## Where New Code Goes

| Task | Location |
|------|----------|
| New game rule or geometry constant | `domain/config/game_rules.gd` |
| New pure stateless math or rule | New file in `domain/rules/` + GUT test |
| New domain state type | New file in `domain/state/` + GUT test |
| New per-player stat | `PlayerStats` → wire format → `WorldStateCodec` → `PlayerStats.to_dict()` for Supabase |
| New career stat column | Add to `career_stats` table in Supabase SQL editor → add to `career_totals` view → add to `PlayerStats.to_dict()` → add row in `CareerStatsScreen._on_totals_received` |
| Submit bug report from UI | Instantiate `BugReportDialog`, `add_child` it, call `.open()` on button press |
| New RPC | `NetworkManager` (define) → emit a signal → `GameManager._wire_network_signals()` (connect) |
| New phase-entry side effect | `PhaseCoordinator` |
| New controller behavior | Method on `SkaterController`; `GameManager` calls it, never pokes internals directly |
| New reconcile logic | `domain/rules/reconciliation_rules.gd` + GUT test |

## Code Conventions

**Strong typing everywhere.** Typed arrays (`Array[BufferedPuckState]`), typed function signatures, typed variables. Never leave a type annotation off when it can be provided. Prefer `var state: PuckNetworkState` over `var state`.

**Cast or annotate when chaining through superclass APIs.** GDScript's type inference can't see through methods that return a base class — e.g. `Engine.get_main_loop()` returns `MainLoop`, not `SceneTree`, so `var scene := Engine.get_main_loop().current_scene` fails to infer. Same pattern for `find_child()` (returns `Node`, not the subclass), `get_node()`, `instance_from_id()`, etc. Add an explicit type (`var scene: Node = ...`) or a cast (`as SceneTree`, `as Node3D`) so the analyzer can resolve member access on the next line. The fix is mechanical; don't ship inferred-from-superclass typing.

**Godot naming conventions.** `snake_case` for variables and functions, `PascalCase` for class names, `SCREAMING_SNAKE_CASE` for constants.

**Separation of concerns.** Physics bodies (`Puck`, `Skater`) expose a clean API. Controllers drive them. `GameManager` owns spawning and world state. `NetworkManager` owns RPCs. Don't reach across these boundaries casually.

**Network API uses typed objects, not raw arrays.** Functions accept `SkaterNetworkState` / `PuckNetworkState` directly. Serialization happens only at the RPC boundary.

**Get it working, then tune numbers.** Use `@export` on tunable parameters so values can be adjusted in the editor. Don't prematurely optimize or bikeshed on constants before the mechanic runs.

**Don't shy away from complexity when it improves feel.** This project already has full client-side prediction with input replay, buffered interpolation, and puck trajectory prediction with reconciliation. If adding a complex system will make the game feel meaningfully better to play, it's worth doing — think it through carefully first, then implement it properly.

**All popups and modal dialogs must be closeable via `ui_cancel` (Escape).** Add the popup to the existing `_unhandled_input` block in the relevant UI script — check `popup.visible`, hide it, and call `get_viewport().set_input_as_handled()`.

## Launch Modes

All start paths go through `MainMenu.tscn`. `NetworkManager._ready()` does nothing — the menu calls `start_offline()`, `start_host()`, or `start_client(ip)` directly. These set up ENet but defer world spawning. `Hockey.tscn`'s root node runs `game_scene.gd`, whose `_ready()` calls `NetworkManager.on_game_scene_ready()`, which emits `host_ready` on hosts; `GameManager` listens and calls `on_host_started`. Client world spawn is triggered by the `client_connected` signal from `_on_connected_to_server()`.

NetworkManager → GameManager communication is signal-based: every RPC / ENet callback emits a typed signal, and GameManager wires all connections once in `_ready()` via `_wire_network_signals()`. The only downward data flow is `NetworkManager.set_world_state_provider(Callable)`.

## Distribution

Playtester builds ship via GitHub Releases (`latest` tag). `deploy.yml` computes `VERSION=0.1.<git rev-list --count HEAD>`, rewrites the placeholder `"dev"` in `Scripts/game/build_info.gd` to that string before export, and publishes with the version as the release name. The main menu's `UpdateChecker` polls the GitHub API on startup and prompts re-download when stale. No in-game patching — Steam (SteamPipe) is the long-term plan. Don't add an in-game downloader/launcher before Steam.

**Supabase backend:** `Scripts/game/supabase_config.gd` holds the project URL and publishable (anon) key — safe to commit, RLS restricts it to INSERT/SELECT/UPDATE. `CareerStatsReporter` (`Scripts/game/career_stats_reporter.gd`) POSTs one row to `career_stats` at game-over and GETs from the `career_totals` view for the career screen. `BugReporter` (`Scripts/game/bug_reporter.gd`) POSTs to `bug_reports` with a telemetry snapshot. Both use fire-and-forget `HTTPRequest` nodes added to the scene tree root and fail silently. The secret key must never be committed — use only the publishable key in `SupabaseConfig`.

## Backlog

Performance hot-paths, god-class extraction candidates, test-coverage gaps, type-safety drift, dead code, and planned features (e.g. reconnect / slot reservation) are tracked in `ARCHITECTURE.md` → **Known Issues / Planned Work**.

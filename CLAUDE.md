# CLAUDE.md

Context for Claude about the Mitts project. Deep technical reference (networking invariants, class-boundary detail, backlog) lives in `ARCHITECTURE.md`.

## Workflow

Complex features (AI state machines, new systems, architectural changes) can be designed first in Claude.ai chat mode, where the developer can iterate on ideas without implementation pressure. The resulting plan is then handed to Claude Code to implement against the actual codebase. When a session starts with a plan document, treat it as the agreed design — ask clarifying questions before deviating from it.

**Never push to `main` without the user testing locally first.** Feature branches (e.g. `claude/*`) may be pushed after committing so the user can pull and test on their machine. Merging a feature branch into `main` is done by the user via a pull request in the UI — do not `git merge` a feature branch into `main` directly. For work done directly on `main`, always stop at commit and wait for explicit confirmation before running `git push`.

**Scene files (`.tscn`) and complex resource files (`.tres`) are edited by the user, not Claude.** Godot's text formats are error-prone to edit when they contain node unique IDs, sub-resource references, or property ordering that the editor enforces — multi-node scenes, themes, shader materials, animations, etc. Describe the change and let the user make it in the Godot editor. **Trivial single-resource `.tres` files (e.g. `PhysicsMaterial`, simple `StandardMaterial3D`) are safe to author directly** — they're 3-5 lines with no cross-references. The UID line is optional; Godot generates one on first import if omitted.

**You can run the GUT test suite headless; you cannot run the game.** Use the `.claude/hooks/run-gut.sh` runner (it invokes `godot --headless -s res://addons/gut/gut_cmdln.gd`, honoring `.gutconfig.json`). Pass `gut_cmdln` flags through, e.g. `-gdir=res://tests/unit/state`.
- **Local:** `GODOT_BIN` (set in `.claude/settings.local.json`) points at the Godot executable. Full suite ≈ 15–18s. **Redirect to a file, don't pipe** — the Windows console exe throttles badly on an MSYS pipe (≈90s vs ≈18s): `bash .claude/hooks/run-gut.sh > "$TMP/gut.log" 2>&1; tail -40 "$TMP/gut.log"`.
- **Web (Claude Code on the web):** the `SessionStart` hook (`session-start.sh`) async-installs Godot; run `.claude/hooks/wait-for-godot.sh` once before the first test run, then `.claude/hooks/run-gut.sh` (piping is fine on Linux).

Run the suite after touching domain code and report results. The **game itself** still can't run here (needs a display / interactive session) — for gameplay or networking changes, describe what to test in a local session and wait for the user to verify.

**Warnings: run gdlint before committing `.gd` changes.** `.claude/hooks/run-lint.sh` runs `gdtoolkit`'s gdlint (tuned via `.gdlintrc`) — the headless, cross-environment subset of warnings: dead code, unused args/vars, `duplicated-load`, trailing whitespace. A committed `.githooks/pre-commit` gate (activated via `core.hooksPath`, set locally and by the SessionStart hook) **blocks any commit with gdlint problems in staged `.gd` files** (`--no-verify` to bypass). Keep the tree gdlint-clean. Caveat: gdlint can't see Godot's *engine-specific* analyzer warnings (`SHADOWED_VARIABLE_BASE_CLASS`, `INT_AS_ENUM`, narrowing) — those remain editor-only, so a clean gdlint run isn't a guarantee the editor is warning-free.

**If you spot a bug or code smell while working on something else, flag it.** Don't silently fix it (out of scope), don't silently ignore it (it'll rot), don't tack it onto the current commit (muddies the diff). Surface it in chat with a one-line description and let the user decide: fix now as a small follow-up, defer to a separate task, or capture as a Known Issue here. Latent bugs in adjacent code paths are especially worth flagging — they often pair with whatever you're touching.

## What This Is

A 3v3 arcade hockey game built in Godot 4.6.2 (GDScript, 3D). Online multiplayer — one player per machine, each with their own camera and local simulation. Prioritizes feel over realism: deep stickhandling, multiple shot types, satisfying puck physics.

**Puck RigidBody3D has Continuous CD enabled.** Do not suggest enabling CCD as a fix for puck tunnelling — it is already on. Puck escaping the rink is more likely a velocity/reflection compounding bug or a Jolt edge case.

## How It Plays

**Mouse + keyboard only, no gamepad.** WASD skates, mouse cursor places the blade in real-time (continuous IK — the blade chases the cursor every frame, no aim button). Camera is third-person, per-player, dynamic-zoom, tilted ~75° so cursor-to-world projection stays usable for stickhandling.

**Stickhandling is physical, not abstract.** The puck is a real `RigidBody3D` that attaches to the blade by proximity; there is no possession flag you press to engage. Carrying slows you. Moving the cursor swings the blade through forehand/backhand with a small lift through center — that's the "dangling" texture. Fast incoming pucks (≥14 m/s) deflect off a static blade; you have to draw the blade *back into* the puck to absorb a pass. No `deke` button — deception is blade placement plus skating rhythm.

**Two shot types, both aim-aware:**
- **Wrister** (LMB) — quick tap fires instantly at moderate speed; hold-and-drag charges by *drag distance*, and the drag direction *is* the aim vector.
- **Slapshot** (RMB) — time-charged wind-up, aim locked at press. Supports **one-timers**: charge without the puck, release fires when the puck enters the shooting zone.

Backhand shots take a power penalty. Scroll wheel toggles elevation (ballistic targeting, apex-capped so you don't sail it over the net). Passes are quick-shots — same mechanic, no separate pass system, no saucer/tape-to-tape variants.

**Skating is momentum-driven.** Thrust accelerates, drag-friction decelerates naturally, Space brakes hard (heavy friction, direction-agnostic). Backward and lateral (crossover) movement are slower than forward. Facing lazily tracks the cursor, and auto-freezes during shot aim/charge/block states and when the cursor swings into the unreachable wedge behind the skater. No frame-perfect inputs — reads and positioning matter more than execution precision.

**Sprint (Shift) is a stamina-gated top-speed burst.** Holding sprint while skating raises the speed cap (and bumps thrust to reach it) but *widens the turn radius* (`sprint_turn_multiplier` scales facing turn rate in `SkaterPoseCoordinator.apply_facing`) — committed straight-line speed traded for agility, so it's a read rather than a hold-always button. It drains a stamina pool; carrying the puck drains it faster. Empty the bar and sprint locks out until it regenerates past half. Stamina is a 0..1 pool computed by `Scripts/domain/rules/stamina_rules.gd` (pure, deterministic from inputs so it survives reconcile replay), driven in `SkaterController._apply_movement` (which resolves `sprint_active` for the tick before the pose pass reads it), replicated on `SkaterNetworkState` (1 wire byte + a flag bit) and snapped from the host at replay start like velocity. The HUD draws the local player's bar. Tunables (`sprint_*`, `stamina_regen_per_sec`) live on `SkaterController`; flat for all players in v1 (the cap it scales, `max_speed`, is already Speed-attributed).

**Physicality is emergent, not scripted.** Body checks trigger from closing-velocity impulse, not a hit button. Ctrl crouches to shot-block (wider hitbox, reflects shots). Poke-checks are stick-on-stick momentum contests — the blades collide and the puck goes where the blended momentum sends it.

**Goalies are AI-only, never player-controlled.** Designed to feel fair, not realistic — reactive with a small reaction delay (which is the window for close-range top-corner goals), positional depth chart, butterfly with a commit timer to prevent toggling, and threat tracking weighted toward the carrier's body rather than the puck (anti-5-hole-exploit).

**Game format:** 3v3, three periods plus optional OT, period length tunable. Faceoffs have a short "2 → 1 → DROP" prep. **Offsides** ghost the offending player (can't interact with the puck) until they tag back to the blue line. **Icing** ghosts the whole offending team briefly. Goals trigger a short pause + celebration window. The default ruleset is `ARCADE` — offsides on, icing off by default — because strict sim rules get in the way of arcade flow.

**Tone is arcade-casual with a competitive ceiling.** The physics are responsive and forgiving on the surface, but blade placement, shot timing, charge management, and positioning meaningfully separate skilled play. Pick-up-and-play, hard to master.

**Where the numbers live** (don't bake these into prose — read them when you need them): movement and shot tuning in `Scripts/controllers/skater_controller.gd`; shot math in `Scripts/domain/rules/shot_mechanics.gd`; period/faceoff/offsides/icing constants and presets in `Scripts/domain/config/game_rules.gd`; goalie tuning in `Scripts/controllers/goalie_controller.gd`; **per-player attribute multipliers** (Speed/Agility/Size/Skill → gameplay + visual effects) in `Scripts/domain/state/player_attributes.gd`.

## Player Attributes

Each skater has four attributes — **Speed, Agility, Size, Skill** — on a 5-step scale (1=floor … 3=medium/baseline … 5=ceiling). The picker UX is *point-buy*: one 1–5 slider per attribute in the side menu's player popup, with the total spend bounded by `PlayerAttributes.BUDGET` (13). All-medium sums to 12, so a committed build always spends at least one point above baseline (the picker requires exact-budget spend to Apply); maxing one stat to 5 forces a dip below medium somewhere. The 5-step tables keep the old 3-step endpoints (old level 3 == new level 5), so widening the scale changed granularity, not range. Bots have curated picks in `data/bot_identities.json` (each summing to budget). Online matches lock attributes at join time (replicated through `request_join` / `spawn_remote_skater`, validated host-side by `is_within_budget` with `<=` so fresh/migrated under-budget builds aren't reset); free-play picks re-apply immediately to the live skater without a respawn.

What each drives (headline effects):
- **Speed** → `max_speed` (top end; also feeds sprint payoff, since sprint multiplies `max_speed`) *(+ visual thigh bulk)*
- **Agility** → `thrust` (all-direction acceleration), turn rate, brake power, edge glide (`friction_drag` inverted), puck-carry retention *(+ visual calf bulk)*
- **Size** → weight (±18% spread, ~1.44× heaviest-to-lightest), brace resistance, hitbox cylinder, arm length (height 5'7"/5'10"/6'0"/6'3"/6'5" by level on the 1.78 m mesh — a tall, modern-NHL-skewed league; note the height/stick/charge multipliers put their 1.0 identity at L2, since medium-Size is 6'0"), ROM derived from arm length, **stick length on a gentler curve** (`stick_len_mult`, ~0.65× the height deviation, ~9.5% L1→L5 vs height's ~15% — the stick is equipment, not anatomy, so small players keep near-full-size sticks; total blade reach is still arm-driven ROM + stick, so taller players still reach furthest) *(+ visual height, torso/shoulder/arm bulk)*. **Body checking is driven purely through `weight`** (the weight_ratio in the check formula, `skater.gd`) — `body_check_transfer` is a flat constant, NOT attribute-scaled. Scaling both weight and delivery by Size would double-count Size multiplicatively. If checks feel too samey across sizes, widen the weight spread (`_SIZE_WEIGHT_MULTS`).
- **Skill** → shot power (all pools), shot charge speed (inverted), `max_blade_speed` (the dangle/pass-absorb "hands" lever) *(no visual — Skill is the invisible stat)*

All tuning multipliers live as private constants on `PlayerAttributes`, accessed via named instance methods (`attrs.speed_mult()`, `attrs.skill_shot_mult()`, `attrs.skill_blade_mult()`, `attrs.height_mult()`, etc.) — **never index a `_*_MULTS` table outside that file**. Different effects need different spreads: Size is widest (±18% canonical), shot-power and Speed stay narrower (±15% / ±7%) so the playable range doesn't compress. Visual scaling decouples from gameplay (e.g. arm-bulk runs ±40% asymmetric, keyed to Size, for a "jacked" big-player silhouette). To add a new "X scales Y" rule, see the doc-block at the top of `player_attributes.gd`.

Application path: `SkaterController.apply_attributes(attrs)` reads the canonical fields and writes scaled values to controller `@export`s, `Skater.weight`, etc.; `SkaterAppearanceCoordinator.apply(attrs)` does the visual mesh scaling. Both are idempotent — they capture baseline values on first call and recompute from baselines on every subsequent call, so repeated applies (from free-play picker changes) never compound. **Prefs migration:** `player_prefs.gd` remaps legacy 1–3 saves to the 1–5 scale (`new = 2·old − 1`) and the renamed Strength → Skill axis, gated by an `attr_scale_version` key.

## Tech Stack

- **Engine:** Godot 4.6.2 (Jolt Physics)
- **Language:** GDScript
- **Physics tick:** 120 Hz
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

Initialized in this order: `PlayerPrefs` → `Constants` → `BuildInfo` → `SoundManager` (`sound_manager.gd`, no class_name) → `NetworkManager` → `NetworkSimManager` (`network_sim.gd`, no class_name) → `SteamManager` (`steam_manager.gd`, no class_name) → `GameManager`. `NetworkManager._ready()` is a no-op; the menu drives initialization. `SteamManager` owns every GodotSteam (`Steam` singleton) call — init + lobby lifecycle — and degrades to a no-op (`is_available = false`) when Steam isn't running or the GDExtension is absent (headless CI), so offline/free-play/tutorial and the GUT suite are unaffected. `SoundManager` exposes `play_ui(sound: SoundManager.Sound, volume_db := 0.0, pitch_variance := 0.0)` and `play_world(sound: SoundManager.Sound, pos: Vector3, volume_db := 0.0, pitch_variance := 0.0)`; sound constants live in its `Sound` enum.

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
| New "attribute X scales Y" rule | `PlayerAttributes` (add `_FOO_MULTS` const + `foo_mult()` accessor) → multiply a captured base value in `SkaterController.apply_attributes` or `SkaterAppearanceCoordinator.apply` |

## Code Conventions

**Strong typing everywhere.** Typed arrays (`Array[BufferedPuckState]`), typed function signatures, typed variables. Never leave a type annotation off when it can be provided. Prefer `var state: PuckNetworkState` over `var state`.

**Cast or annotate when chaining through superclass APIs.** GDScript's type inference can't see through methods that return a base class — e.g. `Engine.get_main_loop()` returns `MainLoop`, not `SceneTree`, so `var scene := Engine.get_main_loop().current_scene` fails to infer. Same pattern for `find_child()` (returns `Node`, not the subclass), `get_node()`, `instance_from_id()`, etc. Add an explicit type (`var scene: Node = ...`) or a cast (`as SceneTree`, `as Node3D`) so the analyzer can resolve member access on the next line. The fix is mechanical; don't ship inferred-from-superclass typing.

**Godot naming conventions.** `snake_case` for variables and functions, `PascalCase` for class names, `SCREAMING_SNAKE_CASE` for constants.

**Separation of concerns.** Physics bodies (`Puck`, `Skater`) expose a clean API. Controllers drive them. `GameManager` owns spawning and world state. `NetworkManager` owns RPCs. Don't reach across these boundaries casually.

**Network API uses typed objects, not raw arrays.** Functions accept `SkaterNetworkState` / `PuckNetworkState` directly. Serialization happens only at the RPC boundary.

**Get it working, then tune numbers.** Use `@export` on tunable parameters so values can be adjusted in the editor. Don't prematurely optimize or bikeshed on constants before the mechanic runs. **Live editor tuning is not a workflow here** — the developer doesn't tweak exports while the game runs, so hot-path code may cache config objects built from exports (rebuilt on `apply_attributes`) without preserving per-tick rebuild semantics. Don't undo config caching to restore live-tuning.

**Hot-path discipline — the 120 Hz tick multiplies every cost.** Anything reached from `_physics_process` or a per-tick controller `update()` runs 120×/second × actor count (6 skaters + 2 goalies + puck), and reconcile replay re-runs the per-tick body once *per replayed input* — so a hot-path cost is amplified again exactly when the network is bad. The host's per-tick budget is shared: when it overruns, physics dilates against the wall clock, and because the broadcast cadence is counted in physics ticks (`network_manager.gd` `_state_tick_divisor`), *every client's* update rate sags with it. A single host-side hot-path regression degrades the whole lobby. Two failure modes, in order of impact: **(1) Allocation churn** — short-lived heap objects per tick: `.new()`, Dictionary/Array literals, `.filter()`/`.map()`/lambdas, `x in [literal]`, returning a fresh `Dictionary`/`Array`, per-call `String` formatting — pressures GDScript's allocator/refcount on the main thread; this is the dominant cost (audit P1–P5). Value types (`Vector3`, `Basis`, `Transform3D`) do **not** heap-allocate, so the math is cheap — the enemy is the heap object, not the arithmetic. **(2) Unnecessary cosmetic work** — visual-only updates (mesh/arm IK, `look_at`, decals) that don't feed gameplay belong in `_process` (render rate), not `_physics_process`, and should skip when idle (dirty-flag) or off-screen (visibility cull); gameplay reads the `blade`/`Marker3D` anchors, not the cosmetic mesh, so cosmetic IK at tick rate is pure waste (audit P2, P8). **Keep the layer boundary AND the performance — they don't conflict:** a Callable/collaborator boundary is an interface, not a license to allocate per call. *Memoize at the seam* — cache the result and invalidate on change (`PlayerRegistry` caches `Array[Skater]`; `puck_controller` caches `team_id_by_skater`). *Build once, fill scratch* — configs that only change on `apply_attributes` are built there and reused; solvers fill a caller-owned result instead of returning a fresh `Dictionary` (`GoalieBodyConfigBuilder`'s shared scratch config is the model). Before adding per-tick code, ask: does it run at 120 Hz × actors? does it allocate? is it cosmetic (→ `_process` + dirty/visibility guard)? Spot a hot-path allocation while working nearby — flag it per the bug-flagging rule; the standing backlog lives in `ARCHITECTURE.md` → Known Issues / Planned Work. This is not in tension with "get it working, then tune numbers" above — that's about *constants/feel*; this is about *structure*, and structure is cheaper to get right up front than to retrofit.

**Don't shy away from complexity when it improves feel.** This project already has full client-side prediction with input replay, buffered interpolation, and puck trajectory prediction with reconciliation. If adding a complex system will make the game feel meaningfully better to play, it's worth doing — think it through carefully first, then implement it properly.

**All popups and modal dialogs must be closeable via `ui_cancel` (Escape).** Add the popup to the existing `_unhandled_input` block in the relevant UI script — check `popup.visible`, hide it, and call `get_viewport().set_input_as_handled()`.

## Launch Modes

All start paths go through `Boot.tscn` (title card): `boot.gd` threaded-loads `Hockey.tscn`, runs `UpdateChecker`, then drops the player into free play via `NetworkManager.start_free_play()` (first launch routes into the Basics tutorial via `start_tutorial()` instead). From there the HUD's `SideMenu` drives session changes — `start_offline()`, `start_host()`, or `start_client_lobby(lobby_id)`. `NetworkManager._ready()` does nothing. Online transport is **Steam P2P via `SteamMultiplayerPeer`** (GodotSteam GDExtension), a drop-in `MultiplayerPeer`, so all RPCs/prediction/reconcile/lag-comp are transport-agnostic and unchanged. Unlike ENet's instant `create_server`/`create_client`, Steam lobby create/join are **async**: `start_host()` waits for `SteamManager.lobby_created` then emits `host_lobby_ready` (the menu spinner waits on it before changing scene); `start_client_lobby()` waits for `lobby_joined`, reads the lobby owner's Steam ID, then the normal `connected_to_server` handshake runs unchanged. `Hockey.tscn`'s root node runs `game_scene.gd`, whose `_ready()` calls `NetworkManager.on_game_scene_ready()`, which emits `host_ready` on hosts; `GameManager` listens and calls `on_host_started`. Client world spawn is triggered by the `client_connected` signal from `_on_connected_to_server()`.

NetworkManager → GameManager communication is signal-based: every RPC / ENet callback emits a typed signal, and GameManager wires all connections once in `_ready()` via `_wire_network_signals()`. The only downward data flow is `NetworkManager.set_world_state_provider(Callable)`.

## Distribution

Playtester builds ship via GitHub Releases (`latest` tag). `deploy.yml` computes `VERSION=0.1.<git rev-list --count HEAD>`, rewrites the placeholder `"dev"` in `Scripts/game/build_info.gd` to that string before export, and publishes with the version as the release name (plus an immutable `v0.1.N` prerelease per build for rollback). The boot title card's `UpdateChecker` polls the GitHub API on startup and prompts re-download when stale. No in-game patching — Steam (SteamPipe) is the long-term plan. Don't add an in-game downloader/launcher before Steam.

**Supabase backend:** `Scripts/game/supabase_config.gd` holds the project URL and publishable (anon) key — safe to commit, RLS restricts it to INSERT/SELECT/UPDATE. `CareerStatsReporter` (`Scripts/game/career_stats_reporter.gd`) POSTs one row to `career_stats` at game-over and GETs from the `career_totals` view for the career screen. `BugReporter` (`Scripts/game/bug_reporter.gd`) POSTs to `bug_reports` with a telemetry snapshot. Both use fire-and-forget `HTTPRequest` nodes added to the scene tree root and fail silently. The secret key must never be committed — use only the publishable key in `SupabaseConfig`.

## Backlog

Performance hot-paths, god-class extraction candidates, test-coverage gaps, type-safety drift, dead code, and planned features (e.g. reconnect / slot reservation) are tracked in `ARCHITECTURE.md` → **Known Issues / Planned Work**.

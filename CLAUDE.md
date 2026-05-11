# CLAUDE.md

Context for Claude about the Mitts project.

## Workflow

Complex features (AI state machines, new systems, architectural changes) can be designed first in Claude.ai chat mode, where the developer can iterate on ideas without implementation pressure. The resulting plan is then handed to Claude Code to implement against the actual codebase. When a session starts with a plan document, treat it as the agreed design — ask clarifying questions before deviating from it.

**Never push to `main` without the user testing locally first.** Feature branches (e.g. `claude/*`) may be pushed after committing so the user can pull and test on their machine. Merging a feature branch into `main` is done by the user via a pull request in the UI — do not `git merge` a feature branch into `main` directly. For work done directly on `main`, always stop at commit and wait for explicit confirmation before running `git push`.

**Scene files (`.tscn`) and complex resource files (`.tres`) are edited by the user, not Claude.** Godot's text formats are error-prone to edit when they contain node unique IDs, sub-resource references, or property ordering that the editor enforces — multi-node scenes, themes, shader materials, animations, etc. Describe the change and let the user make it in the Godot editor. **Trivial single-resource `.tres` files (e.g. `PhysicsMaterial`, simple `StandardMaterial3D`) are safe to author directly** — they're 3-5 lines with no cross-references. The UID line is optional; Godot generates one on first import if omitted.

**You cannot run the game or the test suite.** The GUT panel runs in the Godot editor; the headless CLI does not work in this environment. After touching domain code, note which test files cover the affected area and ask the user to run them. For gameplay or networking changes, describe what to test in a local session and wait for the user to verify.

**If you spot a bug or code smell while working on something else, flag it.** Don't silently fix it (out of scope), don't silently ignore it (it'll rot), don't tack it onto the current commit (muddies the diff). Surface it in chat with a one-line description and let the user decide: fix now as a small follow-up, defer to a separate task, or capture as a Known Issue here. Latent bugs in adjacent code paths are especially worth flagging — they often pair with whatever you're touching.

## What This Is

A 3v3 arcade hockey game built in Godot 4.6.2 (GDScript, 3D). Online multiplayer — one player per machine, each with their own camera and local simulation. Prioritizes feel over realism: deep stickhandling, multiple shot types, satisfying puck physics.

**Puck RigidBody3D has Continuous CD enabled.** Do not suggest enabling CCD as a fix for puck tunnelling — it is already on. Puck escaping the rink is more likely a velocity/reflection compounding bug or a Jolt edge case.

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

## Autoloads

Initialized in this order: `PlayerPrefs` → `Constants` → `BuildInfo` → `SoundManager` (`sound_manager.gd`, no class_name) → `NetworkManager` → `NetworkSimManager` (`network_sim.gd`, no class_name) → `GameManager`. `NetworkManager._ready()` is a no-op; the menu drives initialization. `SoundManager` exposes `play_ui(sound: SoundManager.Sound, volume_db := 0.0, pitch_variance := 0.0)` and `play_world(sound: SoundManager.Sound, pos: Vector3, volume_db := 0.0, pitch_variance := 0.0)`; sound constants live in its `Sound` enum.

## Confusing Boundaries

**`GameStateMachine` vs `PhaseCoordinator` vs `GameManager`:** `GameStateMachine` is a domain `RefCounted` — pure state, no signals, no engine refs, lives on both host and client. `PhaseCoordinator` owns phase-entry side effects (puck lock, goalie reset, faceoff teleport), the goal pipeline, and the goal-replay cinematic (start/stop `GoalReplayDriver`, host-only state-machine advance on natural replay end); emits signals upward including `replay_started`/`replay_stopped`. `GameManager` owns `GoalReplayDriver` Node lifecycle (`add_child`/`queue_free`) and `ReplayFileWriter` lifecycle (open/close/rollover), but delegates cinematic driving to `PhaseCoordinator`. `GameManager` wires everything together and is the only one that **dispatches RPCs to / mutates state on** `NetworkManager`. Read-only timing queries (`estimated_host_time`, `get_latest_rtt_ms`, `is_clock_ready`, `estimated_input_stamp_time`) are an explicit exception — controllers call these directly so prediction / interpolation / input stamping can run without an orchestration hop. `LocalController.send_pickup_claim` is the one *write* exception: it dispatches an RPC directly because pickup-claim eligibility is checked on every physics tick and routing the call through GameManager would add a per-tick orchestration hop for a hot-path check. Do not extend this exception to other RPCs without revisiting the rule. `NetworkManager` holds no references to controllers: it pulls outbound input batches via a `Callable` provider set by GameManager (`set_input_batch_provider`), and emits `input_batch_received(peer_id, inputs)` for inbound batches which GameManager routes through `_registry`.

**`constants.gd` vs `game_rules.gd`:** `constants.gd` (autoload) holds engine-facing values: collision layers/masks, network port, input/state rates, physics tick. `game_rules.gd` (domain) holds game-rule values: rink geometry, icing duration, faceoff positions, ice friction.

**`WorldStateCodec`** is not a pure codec — it also emits `phase_changed` / `game_over_triggered` / `period_changed` / `clock_updated` / `shots_on_goal_changed` / `queue_depth_feedback` when decoding. GameManager connects to these so it can react to authoritative host updates on clients.

**`StateBufferManager`** lives in `Scripts/game/`, not `Scripts/networking/`. Host-only pre-allocated ring buffers (720 slots = 3s at 240 Hz) for all actors. Owned by GameManager; WorldStateCodec reads `latest_*()` for broadcasts; lag-comp rewinds use `get_state_at()`.

**`GameManager` wires six collaborators:** `PlayerRegistry`, `WorldStateCodec`, `ShotOnGoalTracker`, `HitTracker`, `PhaseCoordinator`, `SlotSwapCoordinator`. Documentation that says "five" is stale.

**`SkaterController`'s five `RefCounted` collaborators live in `Scripts/controllers/`, not `domain/`.** `SkaterStateMachine` (current shot state, follow-through timer, locked aim direction), `SkaterAimingBehavior` (charge distance, sweep history, one-timer window), `SkaterPoseCoordinator` (facing, upper-body twist/lean, velocity lean, lower-body lag, head angle, angular-velocity bookkeeping), `SkaterShotPoseCoordinator` (slapper wind-up blade pose, wrister/slapper follow-through), and `SkaterIKCoordinator` (mouse → top-hand IK, bottom-hand IK, net/goalie/butterfly clamps, blade-Y geometry helpers) all carry controller-local mutable state that is tightly coupled to per-tick input processing. Domain rules are stateless static methods; these classes are stateful collaborators owned by `SkaterController` and set up in its `setup()`. The pose and shot-pose coordinators expose public state fields (`facing`, `upper_body_angle`, `lower_body_lag`, `ik_locked_side`) so `LocalController.reconcile` can snap them on replay entry/exit; `_blade_relative_angle` and `_do_release` stay on the controller because they cross multiple coordinator boundaries.

## Networking Invariants

These are non-obvious constraints that cause subtle bugs if violated. Rates and wire format are in `ARCHITECTURE.md`.

**A client's puck is always in one of three modes.** *Carried* — `_carrier_peer_id` is set, puck is pinned to the carrier's blade; no interpolation runs. *Trajectory prediction* — carrier has released; `PuckController` advances the puck forward from the release point using stored velocity and `ICE_FRICTION`, applying three-zone broadcast correction each tick (see below). *Interpolated* — no carrier, no prediction; client buffers host snapshots and renders from `estimated_host_time() - interpolation_delay`. The `carrier_idx` field decoded from world state is what `PuckController.apply_state` reads to switch non-carrier clients between prediction and interpolation modes.

**On clients, `_carrier_peer_id` is managed exclusively by reliable RPCs, never by world state.** Unreliable packet ordering conflicts with locally-predicted carrier transitions. On the server, `_carrier_peer_id` in `PuckController` is set by physics callbacks (`_on_puck_picked_up` / `_on_puck_released`). The world state does encode a `carrier_idx` field, but clients use it only to enter/exit trajectory-prediction mode — they do not write `_carrier_peer_id` from it.

**`rtt_ms` in pickup, shot, and hit claims is the raw unaveraged latest sample** (`latest_rtt_ms` from `ClockSync`), not the smoothed average. Rewind depth must track the actual current round-trip.

**Pickup claim rewind uses separate timestamps for blade and puck.** `blade_timestamp` rewinds the skater snapshot; `puck_timestamp` rewinds the puck path. They diverge when the puck was released under lag.

**Trajectory prediction exits on post contact and puck-goalie contact**, not only on carrier-change RPCs. Both controllers call `end_trajectory_prediction()` directly on the relevant physics signal.

**Goalie state transitions and shot reactions are sent via reliable RPCs** (`state_transitioned`, `shot_reaction_started` on `GoalieController`). `apply_state_transition` directly sets the client state machine; `apply_shot_reaction` seeds `_shot_timer` so the butterfly cadence matches the host. The client runs a full copy of the goalie AI every frame — do not add interpolation logic or attempt to derive goalie state from unreliable broadcasts.

**Reconcile saves and restores only narrow shot-state fields** (`_state`, follow-through timers, one-timer window, `slapper_charge_timer`). Visual and charge fields come from replay output. The `slapper_charge_timer` save/restore is required because `_update_slapper_charge` ticks the timer inside the replay loop — without it each reconcile re-ticks the unconfirmed inputs and the timer inflates O(N) per broadcast, popping the blade above `slapper_wind_up_height`. Server authority on shot state: if `server_state.shot_state` differs after replay, server wins — `_state` and `_charge_distance` are overwritten. **Two symmetric guards protect in-flight shot transitions:**
- **`FOLLOW_THROUGH` → aim state blocked.** When the client is in `FOLLOW_THROUGH` it has already sent the release RPC; the host is processing-lag behind. Reverting would loop the follow-through animation every broadcast.
- **`WRISTER_AIM` / `SLAPPER_CHARGE_WITH_PUCK` → skating blocked when `has_puck = true`.** There is a ~23ms window between the client pressing shoot and the host processing that input (60Hz batch window + network transit). World states broadcast at 40Hz have a ~90% chance of arriving during this window carrying `shot_state = SKATING_WITH_PUCK`. Without this guard reconcile resets the state machine on every broadcast; `shoot_pressed` has already fired once and `shoot_held` never re-enters aim, so the shot never releases. Gated on `has_puck` so a puck steal (which clears `has_puck` before the next reconcile) still overrides correctly.

**Mouse position is seeded from the first replayed input at replay start and the last at replay end.** Wrister-aim charge accumulation is a function of sweep distance; both endpoints must match for deterministic replay across reconcile.

**Board collision is clamped in the reconcile replay loop** via `GameRules.clamp_to_rink_inner` after each `global_position += velocity * delta` step. Without this, board-bounce divergence triggers a feedback loop of reconciles.

**Blade and top-hand positions on remote skaters are extrapolated from the body velocity field**, not from derived position deltas. Dividing position deltas by client receive-time gaps amplifies jitter into visible blade jumps.

**Post-reconcile blade pose dispatches by state on the local controller.** After replay completes, `LocalController.reconcile` re-applies the blade based on the restored `_sm.get_state()`: slapper-charge states call `_apply_slapper_blade_position`, follow-through calls the matching `_apply_*_follow_through`, shot-blocking is a no-op (block stance owns the pose), everything else calls `_apply_blade_from_mouse`. Calling `_apply_blade_from_mouse` unconditionally would IK the blade to the mouse position every reconcile, popping it down from the slapper wind-up pose at the broadcast rate (~40Hz) and producing a visible flicker against the next physics tick's slapper handler.

**Body check impulse is injected into the reconcile replay at the matching `host_timestamp`**, so replay reproduces the post-collision trajectory without oscillation.

**`LocalController.reconcile` is blocked during dead-puck phases.** `on_faceoff_positions` RPC is the authoritative source of skater positions during locked phases.

**Client inputs are applied immediately (no local delay) and stamped with `NetworkManager.estimated_input_stamp_time()`.** This stamps each input for `estimated_host_time() + INPUT_LEAD_SEC` where `INPUT_LEAD_SEC = BATCH_INTERVAL + BUFFER_TICKS * TICK_DURATION ≈ 25ms`. The lead accounts for: worst-case 60Hz batch-send delay (≈16.7ms) so the input is already in transit before the stamp expires at the host, plus a 2-tick buffer (≈8.3ms) so the host queue stays non-empty between batches. `estimated_host_time()` already encodes RTT/2 via the NTP offset — adding RTT/2 again to the stamp would double-count transit. `estimated_input_stamp_time()` is the only consumer of `INPUT_LEAD_SEC`; interpolation and all other callers use the unmodified `estimated_host_time()`.

**The host gates input consumption on `host_timestamp`.** `RemoteController._drive_from_input` only pops the front input when `host_timestamp <= NetworkManager.estimated_host_time()`. Without this gate, inputs are consumed immediately on arrival regardless of their timestamp, the queue empties between 60Hz batches, and fallback-input fires for ~4 ticks per gap. The gate falls through (`input_due = true`) when the clock is not yet ready so behaviour is unchanged during NTP warmup. When the queue is empty and not movement-locked, `NetworkTelemetry.record_input_starvation()` is called; when an input is popped, `record_input_lead(estimated_host_time() - input.host_timestamp)` records how overdue it was (target: near-zero ms, ideally ≤8.3ms).

**The pending input queue is drained on `is_movement_locked()` phases.** `is_input_blocked()` returns immediately without draining — there is no longer a queue to flush since inputs are applied the frame they are gathered.

**Trajectory prediction uses a three-zone response, not a single hard snap.** Each broadcast computes `latency_corrected.position = state.position + state.velocity * rtt_s` (full-RTT forward correction) then compares the distance to two thresholds (`trajectory_soft_blend_threshold` = 0.3 m, `trajectory_hard_snap_threshold` = 1.5 m): below 0.3 m — soft position blend (`position_correction_blend` = 0.1) plus velocity blend; 0.3–1.5 m — velocity-only blend, no position change; above 1.5 m — hard snap both position and velocity and clear the state buffer. This eliminates the visible pop that previously occurred at exactly 1.5 m.

**Body check impulse uses `body_check_impulse_applied(impulse)`, not `body_checked_player`.** `Skater` emits `body_check_impulse_applied` symmetrically: the attacker emits its rebound delta from its own `body_check_delta = velocity - vel_after_slide` capture (`skater.gd:645-647`), and the same `_resolve_player_collisions` loop also captures `other.velocity` before the transfer `-=` and emits the victim's transfer delta directly on `other` (`skater.gd:720-727`). Both sides' `LocalController` connect to the signal and inject the captured impulse into reconcile replay at the matching `host_timestamp`. Without the victim emission, only attacker rebound was captured and the victim relied entirely on snapshot authority absorbing the impulse — broken if the snapshot predated the host's resolve. The old `body_checked_player` signal only captured attacker rebound, causing consistent under-correction; that signal is still emitted but is now exclusively used for server-side puck-strip dispatch via `SkaterController._on_body_checked_player`.

**`ClockSync` does pure NTP only — do not add queue-depth feedback to it.** The clock offset (`_offset`) is computed from ping/pong samples alone: collect up to 8 samples, drop the 2 highest-RTT outliers, average the rest, EMA-smooth (α=0.3) after `is_ready`. `estimated_host_time()` adds a monotone floor so time never goes backward. Do not nudge `_offset` for any other reason (buffer depth, queue length, etc.) — any unbounded integrator on the clock drifts without limit and makes the offset display useless. On same-machine sessions the offset will be approximately equal to the time between host start and client connection (e.g. +1.3 s if the client connected 1.3 s after the host started) — this is correct after the session-relative timestamp change. The important invariant is that the offset is **stable** (not drifting over time); ongoing drift is a code bug. Buffer depth is managed separately: the client receive buffer via `_adapt_interpolation_delay()` in each controller; the host input queue depth is governed by `INPUT_LEAD_SEC` in `ClockSync` (the constants live there because they are a companion to the offset; the method `estimated_input_stamp_time()` is the only call site).

**`facing` in `SkaterNetworkState` is `Vector2` (XZ packed as XY), not `Vector3`.** Both `WorldStateCodec` and `BufferedStateInterpolator.lerp_facing` use the same compass convention: extract angle via `atan2(x, y)` (bearing from +Z/forward axis) and reconstruct with `Vector2(sin, cos)`. Do not pass a `Vector3` facing direction to `lerp_facing`. `RemoteController` and `StateBufferManager` use `BufferedStateInterpolator.hermite_angle` for C1-continuous facing and upper-body rotation interpolation, driven by `facing_angular_velocity` and `upper_body_angular_velocity` fields on `SkaterNetworkState` (encoded as s16, scale `PI * 10` rad/s, at wire offsets 27–28 and 29–30 of the 37-byte skater block).

**All interpolators use host-capture timestamps, not client arrival time.** `apply_network_state` / `apply_state` on `RemoteController`, `PuckController`, and `GoalieController` each take a `host_ts: float` parameter decoded from the world-state header. `RemoteController` and `PuckController` buffer it as the snapshot timestamp (`render_time = NetworkManager.estimated_host_time() - interpolation_delay`). `GoalieController` uses it differently — `elapsed = estimated_host_time() - host_ts` drives position forward-prediction rather than buffer lookup. Using client arrival time instead of host-capture time causes same-frame world-state packets to silently clobber each other and decouples the render timeline from the simulation timeline.

**Spectator slots use `team_id == NetworkManager.SPECTATOR_TEAM_ID` (-1) end-to-end.** Lobby keys spectators at `_SPECTATOR_KEY_BASE = 100` upward so they never collide with the 0..5 home/away keys; `LobbyManager._team_id_from_key`/`_slot_from_key` decode them. The `assign_player_slot` RPC carries `team_id = -1` for spectators (with zero-color tuples that the receiver ignores); `GameManager.on_slot_assigned` branches on this and calls `_become_local_spectator()` instead of `_registry.spawn`, mounting `SpectatorCamera` and emitting `local_spectator_state_changed(true)` for HUD chrome. Spectators are deliberately NOT in `_registry`, so every iterator that already loops `_registry.all()` (scoreboard, off-screen indicators, TOI accumulator, career stats reporter, world-state codec) excludes them naturally — do not add explicit spectator filters to those callsites. The host-only mirror for cross-peer queries is `GameManager._spectator_peers: Dictionary[int, bool]`, populated in `on_host_started` / `on_player_connected` / `_push_lobby_assignments_to_clients` and exposed via `is_spectator_peer(peer_id)` and `spectator_peer_count()`. ENet connection cap is `GameRules.MAX_CONNECTIONS = MAX_PLAYERS + MAX_SPECTATORS`; the player roster is still gated separately by `PlayerRules.MAX_PER_TEAM`.

**Mid-game spectator ↔ player swap routes through `_on_slot_swap_requested` with separate paths.** `SlotSwapCoordinator.try_swap_slot` only validates peers already in `_state_machine.players`, so promote/demote bypass it: `new_team_id == -1` runs `_demote_player_to_spectator` (drops puck if carrier, broadcasts `notify_spectator_demoted`), `_spectator_peers.has(peer_id)` runs `_promote_spectator_to_player` (validates slot/team capacity inline, spawns + RPCs the same as `_push_lobby_assignments_to_clients`). The demote RPC is a one-way "despawn this peer's skater everywhere"; promote reuses the existing `spawn_remote_skater` + `assign_player_slot` RPCs that mid-game joins use, so other peers see promotion as if a fresh peer joined. The promoted peer's `on_slot_assigned` detects mid-game by `_state_machine != null` and skips `_spawn_world()`. Demote of the local peer **must clear the input batch provider before** `_registry.remove` queue-frees the LocalController — otherwise NetworkManager's input pump would call into a freed object.

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

## Known Issues / Planned Work

**Performance, deferred until profiling shows them mattering:**
- **`GoalieController._get_config(_state)`** rebuilds a fresh `GoalieBodyConfig` (~150 LOC of branching + `Vector3` literals) every physics tick per goalie. Memoize per `(state, _five_hole_openness, reaction_state)` tuple; this is the largest known hot-path allocation.
- **`PlayerRegistry.resolve_peer_id` / `_resolve_skater_team_id`** are O(N) per call, hit on hot paths (per-tick body-check / pickup / `_team_resolver` callable). Reverse-map `Dictionary[Skater, int]` would make them O(1). Fine at 6 players; revisit if rosters grow.
- **AI snapshot-level caching.** Today every bot's `_pick_action` rebuilds its own teammate-id list and runs its own closest-teammate-to-puck scan. Once per-bot off-puck utility AI lands (every bot, not just the carrier), publish a per-frame teammate roster + closest-teammate map on `GameManager.current_snapshot` so all bots read it without recomputing.

**Maintainability, address opportunistically (don't refactor for its own sake):**
- **God classes.** `Scripts/game/game_manager.gd` (~2000 LOC), `Scripts/controllers/goalie_controller.gd` (~1500), `Scripts/ui/hud.gd` (~1100), `Scripts/ui/main_menu.gd` (~1000), `Scripts/ui/options_panel.gd` (~800). Extraction candidates flagged: a `PickupClaimResolver` from GameManager, a `GoalieBodyConfigBuilder` from GoalieController, per-popup splits from HUD/MainMenu. Refactor only when a concrete need arises (e.g. unit-testing the lag-comp pickup logic).
- **Test coverage gaps.** No GUT tests for `team_brain`, `skater_agent_state_machine`, `possession_state` (recently-added stateful AI), `PhaseCoordinator`, `SlotSwapCoordinator` host paths, `FileReplayDriver`, `GoalReplayDriver`, `decode_for_replay`. Domain rules are well-covered; the stateful collaborators are not.
- **Type-safety drift.** Bare `Array` / `Dictionary` returns in AI domain modules (`role_slots`, `possession_state`, action-pair returns from `_compute_best_pass` / `_best_carry`), shot/charge rules (`ShotMechanics.release_wrister` returns Dict), and the replay engine path. Project rule says "strong typing everywhere"; fix when touching the file.
- **Dead code.** `AIActionScoring.score_pass` is only called from tests; the runtime PASS scoring lives in `_compute_best_pass`. `TeamBrain._is_human_resolver` is stored on the constructor signature but never used. Either wire in or delete.

## Planned Features

**Tier 3 — larger scope:**
- **Reconnect / slot reservation:** When a peer drops, host marks the slot "reserved" for ~60 s. If the same player (matched by name) reconnects within the window, they reclaim their slot, stats, and team without restarting the game. Requires a pending-reconnect state in `GameManager` and a rejoin handshake in `NetworkManager`.

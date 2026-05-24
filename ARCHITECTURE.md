# Architecture

Technical decisions and reference tables for Mitts. Layer model, code conventions, and development workflow are in `CLAUDE.md`.

---

## Design Philosophy

Depth over breadth — few inputs with rich emergent behavior rather than many explicit mechanics.

The Rocket League freeplay ceiling is a guiding star: the stickhandling-to-shot pipeline should reward practice and feel satisfying to master.

**Key inspirations:** Omega Strikers / Rocket League (structure), Breakpoint (twin-stick melee blade feel), Mario Superstar Baseball (stylized characters, exaggerated tuning, pre-match draft). Slapshot: Rebound is a cautionary reference — pure physics shooting feels unintuitive; the blade proximity pickup system is explicitly designed to solve that accessibility gap.

---

## Reference

### Network Rates

| Channel | Rate | Transport |
|---------|------|-----------|
| Input (client → host) | 60 Hz | Unreliable, last 12 frames per packet |
| World state (host → clients) | 120 Hz | Unreliable, ~302 bytes at 6 players + 2 goalies (single flat PackedByteArray, well under 1392-byte ENet MTU) |
| Events (pickup, spawn, goal, goalie transitions) | On event | Reliable |
| Stats sync | On change | Reliable |

Interpolation delay: 75ms baseline, adapts per-packet via `lerp(0.15)`, capped at +10ms / −1.5ms per packet.

Wire format: Skater 37B · Puck 12B · Goalie 12B. ~62% reduction vs unquantized.

**Input timestamp lead:** Client inputs are stamped with `NetworkManager.estimated_input_stamp_time()` = `estimated_host_time() + INPUT_LEAD_SEC` (~25ms). `estimated_host_time()` already encodes the NTP-measured RTT/2, so inputs arrive at the host at approximately their timestamp. The 25ms lead = 16.7ms worst-case batch-send jitter + 8.3ms two-tick buffer, ensuring the host input queue never starves between 60Hz batches. The host gates consumption in `RemoteController._drive_from_input`: inputs are held until `host_timestamp <= estimated_host_time()`. F3 overlay reports `InBuf: lead X ms  starved Y/s` — healthy values are lead ≈ 0–8ms, starved = 0.

### Collision Layers

| Constant | Value | Purpose |
|----------|-------|---------|
| `LAYER_WALLS` | 1 | Boards, ice surface, goalie body parts |
| `LAYER_BLADE_AREAS` | 2 | Skater blade `Area3D`s |
| `LAYER_PUCK` | 8 | Puck `RigidBody3D` |
| `LAYER_SKATER_BODIES` | 16 | Skater `CharacterBody3D` bodies |

Composed masks: `MASK_PUCK = 1` (walls + goalie only, not skater bodies), `MASK_SKATER = 17` (walls + other skater bodies).

The puck's pickup zone `Area3D` sits on `LAYER_WALLS | LAYER_BLADE_AREAS` (3) with `collision_mask = LAYER_BLADE_AREAS` (2) so it detects blade `Area3D`s via `area_entered`.

### Game Phases

| Phase | Duration | Movement |
|-------|----------|----------|
| `PLAYING` | Until goal or clock expires | Full |
| `GOAL_SCORED` | 2s | Locked |
| `FACEOFF_PREP` | 0.5s | Locked |
| `FACEOFF` | Until pickup or 10s timeout | Full |
| `END_OF_PERIOD` | 3s | Locked |
| `GAME_OVER` | Indefinite | Locked |

Period clock ticks only during `PLAYING`. On expiry: if periods remain → `END_OF_PERIOD` → `FACEOFF_PREP` (period increments, clock resets); if last period → `GAME_OVER`.

---

## Decisions

**Authoritative host, no dedicated server.** One player hosts; the host runs all physics. Eliminates server costs and NAT complexity at the expense of host-advantage. Acceptable for a small-scale arcade game.

**No pickup prediction.** Two players can contest the same puck — the server arbitrates who wins. Predicting pickup locally and rolling it back on a contested play feels worse than the single round-trip delay. Pickup is detected server-side via lag-compensated rewind; only the grant confirmation travels to the client.

**Ghost mode over stoppages for offsides and icing.** Stoppages interrupt flow; ghost mode keeps the puck live and lets offending players correct their position. Downside: slightly less legible than a whistle. Acceptable for an arcade game that prioritizes momentum.

**`_carrier_peer_id` managed by reliable RPCs, never world state.** Unreliable packets can arrive out of order relative to pickup/release RPCs, causing the puck to flicker between carried and loose. Reliable RPCs guarantee ordering; world state is ignored for carrier identity.

**Immediate physics snap, visual offset blend for the local player.** The `CharacterBody3D` always sits at the authoritative position — gradual physics blending would create a window where the client is in a known-wrong position for collision/contact logic. Instead, `LocalController.reconcile` captures `pre_reconcile_visual_pos`, runs the input replay (which snaps the body to truth), then sets `skater.visual_offset = pre_reconcile_visual_pos - skater.global_position`. `Skater.visual_offset` (`skater.gd:154`) writes into `mesh_root.position` only, so the rendered mesh stays where it was on screen while the physics body has moved. Each physics frame `LocalController._physics_process` decays the offset by `_RECONCILE_VISUAL_ALPHA = 0.20` (≈88ms to 99% convergence). The game camera reads `global_position + visual_offset` so it tracks the smoothed visual rather than fighting the physics snap; `teleport_to` clears the offset so faceoff snaps don't carry residue. Remote players don't currently need this — they're interpolated between buffered snapshots, which is inherently smooth. If trajectory-style forward-prediction is ever extended to remote skaters, the same `Skater.visual_offset` mechanism is the natural place to hook in.

**Trajectory prediction exits on physics contact, not only carrier RPCs.** When the predicted puck hits a post or the goalie, host and client diverge immediately — the host's Jolt sees the collision but the client doesn't know to stop predicting. Ending prediction on local post/goalie contact lets the client fall back to interpolation before the divergence compounds.

**Goalie state transitions and shot reactions via reliable RPCs.** Interpolation gives smooth position but can't guarantee reaction timing — a butterfly during a rapid shot sequence may arrive in the wrong bracket order. Reliable RPCs deliver exact state changes; clients play a local reaction timer from the RPC payload for immediate visual feedback.

**Trajectory prediction uses a three-zone response.** Each broadcast computes `latency_corrected.position = state.position + state.velocity * rtt_s` (full-RTT forward correction) then compares the distance to two thresholds: below `trajectory_soft_blend_threshold` (0.3 m) — soft position blend (`position_correction_blend` = 0.1) plus velocity blend; 0.3–1.5 m — velocity-only blend, no position change; above `trajectory_hard_snap_threshold` (1.5 m) — hard snap both position and velocity and clear the state buffer. RTT jitter (±20ms at 20m/s = ±0.4m) falls in the velocity-only zone so position never visibly snaps; the hard snap fires only on genuine physics divergence (wall/goalie bounce that differed between host and client).

**Carrier transitions:**
- Pickup: client sends a reliable `receive_pickup_claim` RPC with `host_timestamp` and `interp_delay_ms`. Host rewinds `StateBufferManager` via `LagCompRewind`: blade at `self_view_time = host_timestamp + INPUT_LEAD_SEC` (the host snapshot whose blade reflects the client's locally-predicted view), puck at `remote_view_time = host_timestamp - interp_delay` (the interpolated puck the client was actually rendering). Reads `blade_contact_world` (world-space mid-blade, host-only non-serialized field on `SkaterNetworkState`) from the rewound skater snapshot, runs the segment-segment distance test against the rewound puck path, and either grants the pickup, squirts the puck on a contested claim (two claims within 50ms, contest timer in `_physics_process`), or drops it as stale/invalid. On grant: reliable `notify_puck_picked_up` RPC to the carrier → `on_puck_picked_up_network()` on their LocalController + `notify_local_pickup(skater)` pins puck to blade. Simultaneously, reliable `notify_carrier_changed(peer_id)` broadcast to **all** peers so non-carrier clients exit trajectory-prediction mode regardless of unreliable world-state delivery.
- Release: client predicts immediately (state machine transitions, trajectory prediction begins) → reliable RPC to server to execute physics. Server fires `notify_carrier_changed(-1)` to all peers; carrier's own handler ignores it (guards against killing its own trajectory prediction).
- Poke check (strip): server detects opposing blade contact while `carrier != null` → clears carrier, launches puck via `_poke_check()` → `puck_stripped` signal → reliable RPC to victim client (`notify_puck_stolen`) → victim calls `on_puck_released_network()` + `notify_local_puck_dropped()` to clear carry state and drop back to interpolation.
- Goal scored: server captures carrier peer_id before `puck.drop()` → sends `notify_goal` (reliable, all peers) and `notify_puck_dropped` (reliable, carrier only) as separate RPCs → carrier client clears state in `on_carrier_puck_dropped()`; `puck.drop()` also fires `puck_released` → `notify_carrier_changed(-1)` broadcast. Decoupled so `notify_goal` isn't responsible for carrier cleanup.

`_carrier_peer_id` on clients is managed exclusively by `notify_local_pickup()` / `notify_local_release()` in `PuckController`. It is intentionally never updated from world state — unreliable packet ordering would cause it to conflict with locally-predicted transitions.

### Goalie Networking

**GoalieController** AI runs on both host and client. Clients do not interpolate server snapshots — they run the full goalie state machine every physics tick using their local puck position. This eliminates interpolation delay and keeps goalie reactions immediate. Server broadcasts (120 Hz) soft-correct position only, keeping client and host in sync despite the client tracking a slightly stale puck.

Serialized per goalie: position (x/z), rotation_y, state_enum, five_hole_openness, velocity (x/z) — 7 fields, 8 B quantized. `apply_state` forward-predicts the server position using `velocity * elapsed` (elapsed ≈ RTT/2 at call time), then blends at 40% per broadcast. `five_hole_openness` is computed only on the server; clients adopt it at 80% blend per broadcast so the visual pad gap matches server physics within ~50 ms. The client AI does not recompute `five_hole_openness`, so nothing fights the correction. Body part configs are rebuilt from the running AI state each frame.

State changes (STANDING ↔ BUTTERFLY ↔ RVH) and shot reactions are delivered via reliable RPCs (`apply_state_transition`, `apply_shot_reaction`). `apply_state_transition` directly sets the client state machine. `apply_shot_reaction` seeds `_shot_timer` on the client so the butterfly drop cadence matches the server.

RVH triggers when `_is_puck_in_defensive_zone()` — either the puck is behind the goal line, or it is within `zone_post_z` of the goal line and the horizontal angle to the puck exceeds `rvh_early_angle` (default 60°). This matches the Buckley depth chart's "Defensive" corner zones, which extend slightly in front of the goal line at sharp angles.

**Tracking lag:** `GoalieController` maintains `_tracked_puck_position` that lerps toward the real puck at `tracking_speed` (default 6.0) each frame. All positioning logic — lateral target, depth, facing, and state transitions — reads from this tracked position rather than the real puck. `_on_puck_released` (shot detection, server only) reads the real puck position and velocity so butterfly reactions stay accurate. `tracking_speed` is the master difficulty export: lower = more positional lag.

### Puck Interactions (server-side)

All puck contact logic runs on the host via `PuckController._check_interactions` each physics tick using swept-segment distance tests in `PuckInteractionRules`:

- **Segment-segment detection:** both `check_pickup` and `check_poke` use an Eberly analytical segment-segment minimum distance test. The puck is swept `puck_prev → puck_curr`; the blade is swept `blade_prev → blade_curr` (`blade_prev` captured at the start of `SkaterController._process_input`, *before* the per-tick IK update mutates `blade.position` — so the segment spans both the IK swing and the post-`move_and_slide` body motion). This catches fast blade swings through the pickup zone even when the puck is nearly stationary — the old static-blade test would miss those.
- **Catch vs deflect:** relative velocity `(puck_vel - blade_world_vel).length()` against `deflect_min_speed`. Moving your blade backward with the puck reduces relative velocity → catch. Stationary blade hit by fast puck → deflect. Below `pickup_max_speed` always catches.
- **Deflect direction:** contact normal = `(puck_pos - blade_world_pos).normalized()` (billiard ball style). Physical reflection blended toward incoming direction via `deflect_blend`. If `skater.is_elevated`, outgoing direction is tilted upward by `deflect_elevation_angle`.
- **Poke check:** when any opposing blade's sweep path passes within radius of the puck while `carrier != null`, `_poke_check` strips the puck (teammates cannot strip each other — gated by `PuckCollisionRules.can_poke_check`). Strip direction = `checker_blade_vel + carrier_blade_vel * poke_carrier_vel_blend` (or spatial direction as fallback). Ex-carrier gets `reattach_cooldown`; checker gets brief `poke_checker_cooldown`. Pokes are also lag-compensated via a client-claim path — see `PokeClaimResolver`. Both detection paths run concurrently; idempotency guards on `PuckController.apply_lag_comp_poke` and the `puck.carrier != null` early-return in `_check_interactions` prevent double-strip.
- **Body check strip:** `SkaterController._on_body_checked_player` (server only) calls `puck.on_body_check(checker, victim, force, direction)`. If `force = weight × approach_speed ≥ body_check_strip_threshold` and `victim == carrier`, `_body_check_strip` clears the carrier and launches the puck in the hit direction. Emits `puck_stripped` + `puck_released` — same notification path as poke check. `Skater` also emits `body_check_impulse_applied(impulse)` with the total velocity delta from `_resolve_player_collisions()` each tick (attacker rebound + victim transfer from remote's check both included). `LocalController` connects to this signal and injects the complete delta into kinematic reconcile replay at the matching `host_timestamp`; the old `body_checked_player` approach captured only the attacker rebound, causing consistent under-correction and jitter. Body check VFX fires client-side from the sim — `SkaterVFX` connects to `body_checked_player` on every skater; no RPC needed.
- **Passive body block:** each `Skater` has a `BodyBlockArea` (`Area3D`, `collision_layer = 0`, `collision_mask = LAYER_PUCK`, sphere radius `body_block_radius`). On `body_entered`, Skater emits `body_block_hit`; `SkaterController._on_body_block_hit` (server only) calls `puck.on_body_block(blocker)`. Only fires on loose pucks (`carrier == null`). Reflects puck off body-center contact normal, multiplies speed by `body_block_dampen`, sets brief pickup cooldown on the blocker.
- **Per-skater cooldowns:** `_cooldown_timers: Dictionary` (Skater → float). Cooldown only applies to loose-puck pickups/deflects, not to poke checks. Lets two players race a loose puck — only the ex-carrier has a disadvantage.

### Why Not Predict Pickup?

Pickup is detected server-side via physics collision. Two players can contest the same puck — the server arbitrates who wins. Predicting pickup locally and rolling it back on a contested play would feel worse than the single round-trip delay. Pickup prediction is explicitly out of scope.

---

## Input Architecture

All input flows through an `InputState` data object populated by `LocalInputGatherer`. The abstraction supports swapping to network input or AI input without touching game logic.

`LocalInputGatherer` accumulates `just_pressed` events between physics ticks so no inputs are dropped. Mouse world position is computed via ray-plane intersection at y=0.

`InputState` fields: `sequence`, `delta`, `move_vector`, `mouse_world_pos`, `shoot_pressed`, `shoot_held`, `slap_pressed`, `slap_held`, `facing_held`, `brake`, `elevation_up`, `elevation_down`, `block_held`.

---

## Skater State Machine

| State | Blade | Movement | Facing |
|-------|-------|----------|--------|
| `SKATING_WITHOUT_PUCK` | Follows mouse | Full | Follows movement |
| `SKATING_WITH_PUCK` | Follows mouse | Full | Follows movement |
| `WRISTER_AIM` | Follows mouse | Full | Locked |
| `SLAPPER_CHARGE_WITH_PUCK` | Fixed forehand | Glide only | Locked (upper body aims) |
| `SLAPPER_CHARGE_WITHOUT_PUCK` | Fixed forehand | Full | Continuous toward mouse |
| `FOLLOW_THROUGH` | Stored relative angle | Full | Follows movement |
| `SHOT_BLOCKING` | Faces puck | Slowed | Continuous toward puck |

---

## Blade Control

Blade placement goes through a custom top-hand inverse-kinematics solver (`TopHandIK.solve` in `domain/rules/top_hand_ik.gd`). The stick is a rigid rod of fixed length (`stick_length`, baseline 1.30 m). The `shoulder` marker anchors the top hand on the opposite side of the body from the blade (right shoulder for a left-handed shooter). The `top_hand` marker is the moving IK output.

**Blade-first feel:** The mouse world position is the desired blade target. The solver works backwards from the target: place the hand where it needs to be so the stick reaches, clamp the hand to an asymmetric ROM, then recompute the blade from the clamped hand along the aim line at `stick_horiz`. Whenever the target is reachable, blade lands exactly on it. When not, blade clips along the same aim line — angular aim is preserved, only distance drops.

**Asymmetric top-hand ROM (relative to shoulder):**
- Forehand (cross-body) side: tight — `rom_forehand_reach_max ≈ 0.45 m`, `rom_forehand_angle_max ≈ 90°`. Hand stays near the body.
- Backhand (same-side as shoulder) side: open — `rom_backhand_reach_max ≈ 0.70 m` (≈ full arm length), `rom_backhand_angle_max ≈ 120°`. Supports one-handed backhand reaches.

**Vertical:** Blade Y stays locked at `blade_height`. Hand Y adapts: in the FAR regime (target past rest stick reach) it sits at `hand_rest_y`; in the CLOSE regime (target inside rest stick reach) it rises so `stick_horiz` matches the target distance and the blade lands on the target exactly. Capped by `hand_y_max` — past that the stick's min horizontal projection causes the blade to overshoot along the aim line.

**Arm rendering:** The shoulder and hand drive a 2-bone IK (`TwoBoneIK.solve_elbow`) that places the elbow on the plane perpendicular to the shoulder-hand axis in the pole direction (`arm_pole_local`). Two BoxMesh segments (`UpperArmMesh` / `ForearmMesh`) are scaled per-tick to the bone lengths and `look_at` their endpoints, following the same pattern as `StickMesh`. Arm meshes are auto-created if absent from the scene and included in ghost-mode transparency.

**Bottom hand (reactive):** A second hand grips the shaft a short way below the top hand. It is purely reactive — it never influences blade placement. After each top-hand solve, the controller computes the grip target as `top_hand.lerp(blade, bottom_hand_grip_fraction)` (default 0.25, ≈0.33 m down a 1.30 m shaft) and runs `BottomHandIK.solve` against an anchor at the `bottom_shoulder` marker (blade side of the body). The solver places the hand on the grip target unless the blade has swung into extreme backhand. Release is angle-based: the controller measures the blade's world direction in the skater's body frame, normalizes it so positive = backhand, and drives a smoothstep from `bh_release_angle_deg` (67°, matching the upper-body rotation clamp) to `+bh_release_angle_band_deg` (15°) — so the hand stays on the stick throughout any swing the upper body can track, and only blends to a shoulder rest pose when the blade genuinely passes the body's rotation limit. Rendered via the same `TwoBoneIK.solve_elbow` path with a mirrored pole. No network state is added — clients recompute the bottom hand locally from the interpolated top-hand + blade positions.

**Wall-clamp hand retraction:** When `clamp_blade_to_walls` pulls the blade back (boards in the way), the controller applies the same horizontal offset to `top_hand` so the stick keeps its rigid length. The arm re-solves on the retracted hand, so the stick looks like it's being pulled back rather than compressing. Wall-pin puck auto-release fires on squeeze magnitude, independent of the retraction.

**Facing drag:** Aiming past the angular ROM rotates the body's facing (`facing_drag_speed`) to bring the target back in range.

**Upper body twist:** Rotates independently to express the angle between facing and blade direction (`upper_body_twist_ratio = 0.8`).

**Wall clamping:** The solved blade is shortened by `RayCast3D` before being written. If squeeze exceeds `wall_squeeze_threshold`, the puck releases along the wall normal.

**Network:** Both `blade_position` and `top_hand_position` are broadcast per world-state tick and interpolated on clients so remote players show a consistent stick pose.

---

## Shooting

**Puck carry speed penalty:** While carrying the puck, `effective_max_speed = max_speed * puck_carry_speed_multiplier` (default 0.85). The speed cap only applies to the cap check, not to thrust — so the skater still accelerates normally but is capped lower, preserving feel while making skating with the puck meaningfully slower than without it.

**Quick shot:** Tap left click. Fires blade-direction at `quick_shot_power`. Low skill floor.

**Wrister:** Hold left click, sweep blade to charge (distance-based), release to fire. Direction variance check resets charge if blade changes direction > 55° — prevents charge farming.

**Slapshot (with puck):** Hold right click. Blade fixes forehand, skater glides, upper body aims within `slapper_aim_arc`. Time-based charge.

**One-timer:** Hold right click without puck. Full movement available. Puck arriving while charging auto-transitions to slapshot state with charge carried over.

**Elevation:** Scroll to toggle. Persists until changed.

---

## Physics

- **Engine:** Godot 4.6.2 with Jolt Physics
- 240 Hz physics tick (prevents tunneling at high puck speeds)
- CCD enabled on puck
- Puck mass 0.17 kg, radius 0.1 m
- `GameRules.ICE_FRICTION = 0.01` — used in puck trajectory prediction. The rink ice surface is a child `StaticBody3D` with `physics_material_override` set directly, so friction applies correctly.
- Puck velocity is clamped in `_integrate_forces()` (runs on all peers) so CCD always receives a sane speed. The `_physics_process()` cap is kept as a secondary check.

---

## Camera

One camera per player. Weighted anchor:

| Anchor | Weight |
|--------|--------|
| Player | 1.0 (non-negotiable) |
| Puck | 1.0 |
| Mouse world pos | 0.5 |
| Attacking goal | 0.3 |

Player-first guarantee: weighted target is clamped so player never exceeds `player_margin` from frame edge. Zoom computed after position clamping to prevent fighting. Soft rink clamp applied last.

---

## Game Flow

### Phase FSM

`GamePhase` is host-driven. Clients receive phase via reliable RPC on goal events and as a correction channel in every world state broadcast.

| Phase | Duration | Description |
|-------|----------|-------------|
| `PLAYING` | Until goal or clock expires | Normal gameplay; period clock counts down |
| `GOAL_SCORED` | 2s (`GOAL_PAUSE_DURATION`) | Dead puck, celebration freeze |
| `FACEOFF_PREP` | 0.5s (`FACEOFF_PREP_DURATION`) | Players teleport to dots, puck resets, goalies reset to crease |
| `FACEOFF` | Until pickup or 10s timeout | Puck live at center dot, waiting for a player to pick it up |
| `END_OF_PERIOD` | 3s (`END_OF_PERIOD_PAUSE`) | Period clock hit zero; brief pause before next-period faceoff prep |
| `GAME_OVER` | Indefinite | All periods exhausted; movement locked until host resets |

Period clock (`GameRules.PERIOD_DURATION = 240s`, `NUM_PERIODS = 3`) ticks down only during `PLAYING`. When it expires: if periods remain → `END_OF_PERIOD` → `FACEOFF_PREP` (period increments, clock resets); if last period → `GAME_OVER`. `END_OF_PERIOD` and `GAME_OVER` are dead-puck phases.

### Dead-Puck Enforcement

The `GameStateMachine` exposes `is_movement_locked()` — true during `GOAL_SCORED`, `FACEOFF_PREP`, `END_OF_PERIOD`, and `GAME_OVER`. `GameManager` re-exposes this as an instance method and is passed into each controller at `setup()` as the `game_state` dependency. Controllers call `_game_state.is_movement_locked()` every frame:
- `LocalController._physics_process`: zeros velocity, drains `_input_history`, skips input gathering and processing
- `RemoteController._drive_from_input`: still advances `last_processed_sequence` (keeps reconcile bookkeeping current) but zeros velocity and skips `_process_input`
- `LocalController.reconcile`: returns early during locked phases — `on_faceoff_positions` (reliable RPC) is the authoritative source of faceoff positions

### Controller API

`GameManager` describes *what* it wants; controllers implement *how*:
- `controller.teleport_to(pos)` — sets position, zeros velocity. `LocalController` override also clears `_input_history`.
- `controller.on_puck_released_network()` — idempotent; safe to call without checking `has_puck` first.

---

## Build Status

| Stage | Description | Status |
|-------|-------------|--------|
| 1 | Skating feel | Done |
| 2 | Stick / puck interaction | Done |
| 3 | Basic goalie | Done |
| 4 | Networking (prediction, interpolation, reconciliation) | Done |
| 5 | Goalie AI rework + networking | Done |
| 6 | Full game flow (goals, faceoffs, score) | Done |
| 7 | Testable domain layer (rules extraction, state machine, GUT tests, CI) | Done |
| 8 | Period-based game loop (clock, period transitions, game over) | Done |
| 9 | Visual polish (puck trail, ice spray, skate trails, goal burst, wall impact, body check, shot charge glow, speed lines) | Done |
| 10 | Playtester distribution (auto-versioned GitHub Releases + in-game update notifier) | Done |
| 11 | In-game team/position swap | Done |
| 12 | Pre-game lobby (slot picking + rule config) + in-game "Return to Lobby" | Done |
| 13 | Characters + abilities | Deferred — revisit when game feel is right |
| 14 | Networking refactor Phase 1 (bug fixes + reconcile smoothing) | Done |
| 15 | Networking refactor Phase 2 (telemetry pull model, puck buffer fix) | Done |
| 16 | Networking refactor Phase 3 (simulated lag — NetworkSim autoload, presets 0–5) | Done |
| 17 | Networking refactor Phase 4 (host clock sync — NTP-style RTT, input host_timestamp) | Done |
| 18 | Networking refactor Phase 5 (StateBufferManager host-side ring buffers; goalie keyed by team_id) | Done |
| 19 | Networking refactor Phase 6 (swept sphere interaction detection; puck pickup/poke/deflect moved to domain layer) | Done |
| 20 | Networking refactor Phase 7 (input redundancy, lag-compensated pickup claims, state-machine save/restore in reconcile, blade telemetry, remove gradual correction) | Done |
| 21 | Netcode fixes (segment-segment pickup/poke detection, blade_contact_world lag-comp path, reconcile mouse-seed + server shot authority, physics-thread contest window, latest_rtt_ms for rewind, blade/hand extrapolation, input queue depth cap) | Done |
| 22 | Netcode improvements I6–I8 (PackedByteArray quantized world state ~60% bandwidth reduction; rewind-based body check hit crediting + body check impulse replay in reconcile; lag-compensated shot release using latest blade position + kinematic RTT/2 advance) | Done |
| 23 | Netcode improvements I2–I5 + puck reconcile fix (clock sync 2s interval + symmetric outlier drop; input queue target depth 5; velocity quantization @0.02m/s; wall reconcile dead zone 0.05m; puck reconcile full-RTT correction; world state as single flat PackedByteArray fixing 1940→279 byte MTU issue; ENet peer timeout null-guard) | Done |
| 24 | MTU fix for input batch (PackedByteArray 23B/input, 279B at 12 inputs vs 1780B; InputState.to_bytes/from_bytes); puck release pos from current blade not stale pin (fixes 1-frame lag in snapback) | Done |
| 25 | Netcode audit (40 Hz world state, 75ms interpolation, board collision in replay, goalie reliable RPCs, trajectory prediction exits on contact, pickup timestamp fix, adaptive delay, Hermite puck interpolation, goalie quantization 10→8B) | Done |
| 26 | Netcode improvements (2-frame client input delay; hard-snap-only puck trajectory reconcile; full body check velocity delta capture via `body_check_impulse_applied`; input queue drain on locked/blocked phases) | Done |
| 27 | Goalie reactive saves (glove, body, stick poke) | Planned |

---

## Confusing Boundaries

**`GameStateMachine` vs `PhaseCoordinator` vs `GameManager`:** `GameStateMachine` is a domain `RefCounted` — pure state, no signals, no engine refs, lives on both host and client. `PhaseCoordinator` owns phase-entry side effects (puck lock, goalie reset, faceoff teleport), the goal pipeline, and the goal-replay cinematic (start/stop `GoalReplayDriver`, host-only state-machine advance on natural replay end); emits signals upward including `replay_started`/`replay_stopped`. `GameManager` owns `GoalReplayDriver` Node lifecycle (`add_child`/`queue_free`) and `ReplayFileWriter` lifecycle (open/close/rollover), but delegates cinematic driving to `PhaseCoordinator`. `GameManager` wires everything together and is the only one that **dispatches RPCs to / mutates state on** `NetworkManager`. Read-only timing queries (`estimated_host_time`, `get_latest_rtt_ms`, `is_clock_ready`, `estimated_input_stamp_time`) are an explicit exception — controllers call these directly so prediction / interpolation / input stamping can run without an orchestration hop. `LocalController.send_pickup_claim` is the one *write* exception: it dispatches an RPC directly because pickup-claim eligibility is checked on every physics tick and routing the call through GameManager would add a per-tick orchestration hop for a hot-path check. Do not extend this exception to other RPCs without revisiting the rule. `NetworkManager` holds no references to controllers: it pulls outbound input batches via a `Callable` provider set by GameManager (`set_input_batch_provider`), and emits `input_batch_received(peer_id, inputs)` for inbound batches which GameManager routes through `_registry`.

**`constants.gd` vs `game_rules.gd`:** `constants.gd` (autoload) holds engine-facing values: collision layers/masks, network port, input/state rates, physics tick. `game_rules.gd` (domain) holds game-rule values: rink geometry, icing duration, faceoff positions, ice friction.

**`WorldStateCodec`** is not a pure codec — it also emits `phase_changed` / `game_over_triggered` / `period_changed` / `clock_updated` / `shots_on_goal_changed` / `queue_depth_feedback` when decoding. GameManager connects to these so it can react to authoritative host updates on clients.

**`StateBufferManager`** lives in `Scripts/game/`, not `Scripts/networking/`. Host-only pre-allocated ring buffers (720 slots = 3s at 240 Hz) for all actors. Owned by GameManager; WorldStateCodec reads `latest_*()` for broadcasts; lag-comp rewinds use `get_state_at()`.

**`GameManager` wires six collaborators:** `PlayerRegistry`, `WorldStateCodec`, `ShotOnGoalTracker`, `HitTracker`, `PhaseCoordinator`, `SlotSwapCoordinator`.

**`SkaterController`'s five `RefCounted` collaborators live in `Scripts/controllers/`, not `domain/`.** `SkaterStateMachine` (current shot state, follow-through timer, locked aim direction), `SkaterAimingBehavior` (charge distance, sweep history, one-timer window), `SkaterPoseCoordinator` (facing, upper-body twist/lean, velocity lean, lower-body lag, head angle, angular-velocity bookkeeping), `SkaterShotPoseCoordinator` (slapper wind-up blade pose, wrister/slapper follow-through), and `SkaterIKCoordinator` (mouse → top-hand IK, bottom-hand IK, net/goalie/butterfly clamps, blade-Y geometry helpers) all carry controller-local mutable state that is tightly coupled to per-tick input processing. Domain rules are stateless static methods; these classes are stateful collaborators owned by `SkaterController` and set up in its `setup()`. The pose and shot-pose coordinators expose public state fields (`facing`, `upper_body_angle`, `lower_body_lag`, `ik_locked_side`) so `LocalController.reconcile` can snap them on replay entry/exit; `_blade_relative_angle` and `_do_release` stay on the controller because they cross multiple coordinator boundaries.

---

## Networking Invariants

Non-obvious constraints that cause subtle bugs if violated. Rates and wire format are in the Reference section above.

**A client's puck is always in one of three modes.** *Carried* — `_carrier_peer_id` is set, puck is pinned to the carrier's blade; no interpolation runs. *Trajectory prediction* — carrier has released; `PuckController` advances the puck forward from the release point using stored velocity and `ICE_FRICTION`, applying three-zone broadcast correction each tick (see below). *Interpolated* — no carrier, no prediction; client buffers host snapshots and renders from `estimated_host_time() - interpolation_delay`. The `carrier_idx` field decoded from world state is what `PuckController.apply_state` reads to switch non-carrier clients between prediction and interpolation modes.

**On clients, `_carrier_peer_id` is managed exclusively by reliable RPCs, never by world state.** Unreliable packet ordering conflicts with locally-predicted carrier transitions. On the server, `_carrier_peer_id` in `PuckController` is set by physics callbacks (`_on_puck_picked_up` / `_on_puck_released`). The world state does encode a `carrier_idx` field, but clients use it only to enter/exit trajectory-prediction mode — they do not write `_carrier_peer_id` from it.

**Lag-comp rewind goes through `LagCompRewind` — never reach into raw timestamps.** Two helpers encode the two view perspectives every claim handler needs: `self_view_time(host_timestamp)` for entities the claimant rendered via local prediction (their own skater body/blade), and `remote_view_time(host_timestamp, interp_delay_ms)` for entities they rendered via interpolation (other skaters, loose puck, remote-carried puck, goalie). Each claim resolver picks per entity — pickup/poke rewind the blade as self and puck as remote; hit rewinds the hitter as self and victim+puck as remote; shot-release rewinds the goalie as remote. Rewind depth is RTT-independent (depends only on `INPUT_LEAD_SEC` and the client-reported `interp_delay_ms`), so two players reaching for the same puck are arbitrated by their stamped view-times instead of by network luck. Open-coded `host_timestamp ± rtt/2` formulas are a class of bug — the wrong shift, and they couple validation to ping.

**`rtt_ms` in shot release claims** (`release_puck` / `release_puck_one_timer`) is the raw unaveraged latest sample (`latest_rtt_ms` from `ClockSync`), not the smoothed average. Used for the puck-position RTT/2 advance that aligns host's release point with the client's predicted puck, not for any rewind — claim chains dropped `rtt_ms` once the LagCompRewind helper landed.

**Trajectory prediction exits on post contact and puck-goalie contact**, not only on carrier-change RPCs. Both controllers call `end_trajectory_prediction()` directly on the relevant physics signal.

**Goalie state transitions and shot reactions are sent via reliable RPCs** (`state_transitioned`, `shot_reaction_started` on `GoalieController`). `apply_state_transition` directly sets the client state machine; `apply_shot_reaction` seeds `_shot_timer` so the butterfly cadence matches the host. The client runs a full copy of the goalie AI every frame — do not add interpolation logic or attempt to derive goalie state from unreliable broadcasts.

**Reconcile saves and restores only narrow shot-state fields** (`_state`, follow-through timers, one-timer window, `slapper_charge_timer`). Visual and charge fields come from replay output. The `slapper_charge_timer` save/restore is required because `_update_slapper_charge` ticks the timer inside the replay loop — without it each reconcile re-ticks the unconfirmed inputs and the timer inflates O(N) per broadcast, popping the blade above `slapper_wind_up_height`. Server authority on shot state: if `server_state.shot_state` differs after replay, server wins — `_state` and `_charge_distance` are overwritten. **Two symmetric guards protect in-flight shot transitions:**
- **`FOLLOW_THROUGH` → aim state blocked.** When the client is in `FOLLOW_THROUGH` it has already sent the release RPC; the host is processing-lag behind. Reverting would loop the follow-through animation every broadcast.
- **`WRISTER_AIM` / `SLAPPER_CHARGE_WITH_PUCK` → skating blocked when `has_puck = true`.** There is a ~23ms window between the client pressing shoot and the host processing that input (60Hz batch window + network transit). World states broadcast at 120Hz are very likely to fire during this window carrying `shot_state = SKATING_WITH_PUCK`. Without this guard reconcile resets the state machine on every broadcast; `shoot_pressed` has already fired once and `shoot_held` never re-enters aim, so the shot never releases. Gated on `has_puck` so a puck steal (which clears `has_puck` before the next reconcile) still overrides correctly.

**Mouse position is seeded from the first replayed input at replay start and the last at replay end.** Wrister-aim charge accumulation is a function of sweep distance; both endpoints must match for deterministic replay across reconcile.

**Board collision is clamped in the reconcile replay loop** via `GameRules.clamp_to_rink_inner` after each `global_position += velocity * delta` step. Without this, board-bounce divergence triggers a feedback loop of reconciles.

**Reconcile uses trajectory comparison, not position-snapshot comparison.** Every physics tick on `LocalController._physics_process`, after `_process_input` mutates skater state, a `PredictedState` snapshot is appended to `_prediction_history` keyed by the input's `host_timestamp` (capped at 480 entries ≈ 2s at 240Hz). When `reconcile(server_state)` fires, `PredictedState.find_at(_prediction_history, server_state.last_processed_host_timestamp)` returns the snapshot for that exact instant. The threshold check (`ReconciliationRules.skater_needs_reconcile`) compares **predicted-vs-server at the same `host_timestamp`** instead of current-client-vs-server, which subtracts the natural prediction lead (RTT/2 + `INPUT_LEAD_SEC` × velocity ≈ 0.33–0.6 m at skating speeds) out of the divergence. Thresholds can therefore stay tight (`reconcile_position_threshold = 0.05 m`, `reconcile_velocity_threshold = 0.3 m/s`) — only true non-determinism (body-check mis-replay, contested collision resolution) trips them. After the lookup, `_prediction_history` is trimmed by the same predicate as `_input_history` (`host_timestamp > last_processed_host_timestamp`), since future reconciles only ask about strictly later timestamps. Cleared alongside `_input_history` on `teleport_to` and dead-puck-frozen-stick drains. When no match is found (history capped before a reconcile catches up, post-teleport gap, NTP warmup) the comparison falls back to the live position so reconcile remains a safety net through edge cases.

**Blade and top-hand positions on remote skaters are extrapolated from the body velocity field**, not from derived position deltas. Dividing position deltas by client receive-time gaps amplifies jitter into visible blade jumps.

**Post-reconcile blade pose dispatches by state on the local controller.** After replay completes, `LocalController.reconcile` re-applies the blade based on the restored `_sm.get_state()`: slapper-charge states call `_apply_slapper_blade_position`, follow-through calls the matching `_apply_*_follow_through`, shot-blocking is a no-op (block stance owns the pose), everything else calls `_apply_blade_from_mouse`. Calling `_apply_blade_from_mouse` unconditionally would IK the blade to the mouse position every reconcile, popping it down from the slapper wind-up pose at the broadcast rate (120Hz) and producing a visible flicker against the next physics tick's slapper handler.

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

**Spectator slots use `team_id == GameRules.SPECTATOR_TEAM_ID` (-1) end-to-end.** Lobby keys spectators at `LobbySlotKey.SPECTATOR_KEY_BASE = 100` upward so they never collide with the 0..5 home/away keys; `LobbySlotKey.team_id`/`LobbySlotKey.slot` decode them. The `assign_player_slot` RPC carries `team_id = -1` for spectators (with zero-color tuples that the receiver ignores); `GameManager.on_slot_assigned` branches on this and calls `_become_local_spectator()` instead of `_registry.spawn`, mounting `SpectatorCamera` and emitting `local_spectator_state_changed(true)` for HUD chrome. Spectators are deliberately NOT in `_registry`, so every iterator that already loops `_registry.all()` (scoreboard, off-screen indicators, TOI accumulator, career stats reporter, world-state codec) excludes them naturally — do not add explicit spectator filters to those callsites. The host-only mirror for cross-peer queries is `GameManager._spectator_peers: Dictionary[int, bool]`, populated in `on_host_started` / `on_player_connected` / `_push_lobby_assignments_to_clients` and exposed via `is_spectator_peer(peer_id)` and `spectator_peer_count()`. ENet connection cap is `GameRules.MAX_CONNECTIONS = MAX_PLAYERS + MAX_SPECTATORS`; the player roster is still gated separately by `PlayerRules.MAX_PER_TEAM`.

**Mid-game spectator ↔ player swap routes through `_on_slot_swap_requested` with separate paths.** `SlotSwapCoordinator.try_swap_slot` only validates peers already in `_state_machine.players`, so promote/demote bypass it: `new_team_id == -1` runs `_demote_player_to_spectator` (drops puck if carrier, broadcasts `notify_spectator_demoted`), `_spectator_peers.has(peer_id)` runs `_promote_spectator_to_player` (validates slot/team capacity inline, spawns + RPCs the same as `_push_lobby_assignments_to_clients`). The demote RPC is a one-way "despawn this peer's skater everywhere"; promote reuses the existing `spawn_remote_skater` + `assign_player_slot` RPCs that mid-game joins use, so other peers see promotion as if a fresh peer joined. The promoted peer's `on_slot_assigned` detects mid-game by `_state_machine != null` and skips `_spawn_world()`. Demote of the local peer **must clear the input batch provider before** `_registry.remove` queue-frees the LocalController — otherwise NetworkManager's input pump would call into a freed object.

---

## Known Issues / Planned Work

**Performance, deferred until profiling shows them mattering:**
- **AI snapshot-level caching.** `GameManager._enrich_snapshot_for_ai` publishes `teammate_ids_by_team` + `closest_to_puck_by_team` on `current_snapshot` once per host physics frame; the two per-physics-tick hotspots (`_apply_steering`, `_is_closest_teammate_to_puck_at`) read from the cache. The 6 Hz brain-tick role behaviors (`carrier`, `finisher`, `role_helpers`, `role_slots.assign`) still re-partition `snapshot.skater_states` themselves — wins there are ~30× smaller than the physics-tick paths, so deferred until profiling motivates it.

**Maintainability, address opportunistically (don't refactor for its own sake):**
- **God classes.** `Scripts/game/game_manager.gd` (~2400 LOC), `Scripts/controllers/goalie_controller.gd` (~1100), `Scripts/ui/hud.gd` (~1000), `Scripts/ui/options_panel.gd` (~900). `PickupClaimResolver` and `GoalieBodyConfigBuilder` have already been extracted; per-popup splits from HUD remain a candidate. Refactor only when a concrete need arises.
- **Test coverage gaps.** No GUT tests for `skater_agent_state_machine`, `PhaseCoordinator`, `SlotSwapCoordinator` host paths, `FileReplayDriver`, `GoalReplayDriver`, `decode_for_replay`. Domain rules are well-covered; the stateful collaborators are not.
- **Type-safety drift.** Bare `Array` / `Dictionary` returns in `_compute_best_pass` / `_best_carry` action-pair tuples inside `skater_agent_state_machine`, and the replay engine path. Project rule says "strong typing everywhere"; fix when touching the file.

**Planned features, Tier 3 — larger scope:**
- **Free-look controllable camera for live spectators + `.mreplay` viewer.** Goal replays now ship a polished broadcast hard-cam + behind-net cut (see `SpectatorCamera`, `GoalReplayDriver`), but both `GameManager._become_local_spectator` and `ReplayViewer._mount_camera` reuse the same hard-cam preset, which is wrong for long-form viewing — the player wants to choose their angle. Wants a separate `FreeLookCamera` class (WASD-dolly + RMB-orbit + scroll-zoom, lockable to "follow puck" vs "free roam"); input gating + lack of cinematic noise/lead belong on a different class because they'd fight operator input on the broadcast preset. Goal-replay cinematic camera should stay on `SpectatorCamera`. Optional follow-up: cycle through additional replay angles (end-zone-low, overhead, skater-POV-trailing) for longer goal clips.
- **`GOAL_CELEBRATION` phase between PLAYING and GOAL_SCORED.** Right now the ~1.5 s between goal detection and replay start (`POST_GOAL_CAPTURE_WINDOW` in `PhaseCoordinator`) lives inside the GOAL_SCORED phase, which is in `PhaseRules.is_dead_puck_phase` — so every skater is frozen statue-like while the goal banner + VFX play. Real broadcasts show a celebration beat (raised sticks, glove taps, scorer mobbed) before the replay. Wants a new phase: movement allowed, puck still `pickup_locked = true`, lasts POST_GOAL_CAPTURE_WINDOW, then transitions to GOAL_SCORED for the replay freeze. State-machine + `PhaseRules` + codec changes; controllers + AI need to check the new phase explicitly. Pairs naturally with celebration animations (stick raises, etc.) when those land.
- **Reconnect / slot reservation:** When a peer drops, host marks the slot "reserved" for ~60 s. If the same player (matched by name) reconnects within the window, they reclaim their slot, stats, and team without restarting the game. Requires a pending-reconnect state in `GameManager` and a rejoin handshake in `NetworkManager`.
- **First-launch → tutorial:** Boot currently always drops the player into free play. First-time players should be routed to the tutorial instead. Wait on the in-flight tutorial rewrite before wiring; once the tutorial is in good shape, add a `PlayerPrefs.has_completed_tutorial` flag, have `Boot._bootstrap_free_play_and_change` consult it, and consider a "Skip Tutorial" affordance in the tutorial intro so impatient players don't get re-offered it every launch.

---

## Open Questions

- Slapshot pre/post release buffer window for one-timer timing feel
- Middle-zone puck reception: blade readiness check
- Aim assist
- Procedural skating animations
- CharacterStats resource design (universal vs per-character exports)
- Camera goal anchor flip speed on turnovers
- Rink size tuning (possible 2/3 scale)
- Extend visual-offset blend to remote skaters if/when remote prediction lands (today the blend is local-only because remotes are interpolated and never snap)
- Long-session f32 precision on session-relative timestamps

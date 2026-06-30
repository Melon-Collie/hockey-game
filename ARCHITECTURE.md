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
| World state (host → clients) | 120 Hz | Unreliable, ~349 bytes at 6 players + 2 goalies (single flat PackedByteArray, well under 1392-byte ENet MTU) |
| Events (pickup, spawn, goal, goalie transitions) | On event | Reliable |
| Stats sync | On change | Reliable |

Interpolation delay: 75ms baseline, adapts per-packet via `lerp(0.15)`, capped at +10ms / −1.5ms per packet. **One shared delay** drives every remote interpolator (remote skaters, loose puck, goalie): `NetworkManager._interp_delay`, advanced once per received world-state packet in `receive_world_state` and read via `get_interpolation_delay()`. Per-actor independently-adapting delays used to drift apart, skewing relative timing (puck-vs-stick on a pass, save-vs-puck); the single value renders them all at the same instant. `get_target_interpolation_delay()` is cached per physics frame (it sorts the jitter buffer).

Wire format: Skater 37B · Puck 13B · Goalie 35B (12 B root + 23 B pose). Quantized; ~50% reduction vs unquantized. Puck Y is s16 (not s8) so elevated/saucer shots above the s8 ±1.27 m range don't clip flat on the wire.

**Input timestamp lead:** Client inputs are stamped with `NetworkManager.estimated_input_stamp_time()` = `estimated_host_time() + INPUT_LEAD_SEC` (~25ms). `estimated_host_time()` already encodes the NTP-measured RTT/2, so inputs arrive at the host at approximately their timestamp. The 25ms lead = 16.7ms worst-case batch-send jitter + 8.3ms two-tick buffer, ensuring the host input queue never starves between 60Hz batches. The host gates consumption in `RemoteController._drive_from_input`: inputs are held until `host_timestamp <= estimated_host_time()`. The F3 overlay's host-only "Client input queue" section reports `Input lead` and `Starvations` — healthy values are lead ≈ 0–8ms, starvations = 0.

### F3 Network Debug Overlay

`Scripts/ui/network_debug_overlay.gd` — toggled with **F3**. Reads `NetworkTelemetry.instance` + `NetworkManager` every frame and renders a color-coded health readout. It's a diagnostic for "is this lag expected or is something actually broken?", not a raw number dump.

**Reading it:**
- **Header verdict** — `● OK / ● WATCH / ● PROBLEM` rolls up the worst single metric on screen. Green header = nothing needs attention.
- **Per-line dots** — green / yellow / red, thresholded against the documented healthy ranges. Each line also carries a plain-English label and its target range inline, so no separate legend is needed.
- **Info lines** (grey `·`) — context with no health judgment (clock offset, bandwidth, puck mode, buffer depths).

**Role-gated** — only the sections that apply to your role render, so you never read a misleading zero:

| Role | Detection | Sections shown |
|------|-----------|----------------|
| `SOLO (offline)` | `is_offline_mode` | local frame health only |
| `HOST` | `is_host && !is_offline_mode` | per-peer pings, client input queue, host frame health, upload bandwidth |
| `CLIENT` | otherwise | connection (RTT/loss/jitter/delay-spread), prediction/corrections, smoothing buffers, download bandwidth, watch metrics |

**Watch metrics** (client-only: stick jumps, puck hard-snaps, out-of-order drops, reconcile match) stay collapsed into a single `✓ Internals nominal` line and surface individually only when they leave the healthy band — they're the latent-bug tripwire. They are calibrated to **not** fire on normal play: "Stick jumps" counts only reconcile-induced blade teleports (fast stickhandling legitimately moves the blade >5 cm/tick and is no longer counted), and "Out-of-order drops" tolerates the occasional UDP reorder. The old "Prediction drift" line was removed — it measured the natural prediction lead (grows with RTT × speed), not a bug, so it cried wolf at speed; `reconcile_per_sec` + magnitude (Corrections) is the real divergence signal.

**The header verdict means "something is actually WRONG," not "your link is slow."** Only actual-problem metrics drive it (`_metric`): loss, Corrections, Guessing ahead, the watch tripwires, and host frame health. Connection **facts** — Ping/RTT, peer ping, Jitter, Delay spread — are colored for at-a-glance link quality but are **verdict-neutral** (`_context`): a far or jittery link is expected and the netcode compensates, so it shows red on its own line while the header stays green. The damage a bad link actually does surfaces through its own driving metrics (loss → rubber-banding, Guessing ahead → buffer overrun). So: glance at the header — green means nothing is wrong, even at 160 ms. Thresholds live in the overlay's health helpers and mirror the "Expected ranges" comments in `network_telemetry.gd` — keep the two in sync if either moves.

**`Jitter` vs `Delay spread` (the clumping tell):** `Jitter` is the p95 of raw packet *arrival-gap* deviation (IPDV) — it rises both for genuine path jitter and for relay **clumping** (several snapshots landing together, then a gap). `Delay spread` measures each packet's delay against the *synced host clock* (PDV — `estimated_host_time() − host_capture_time`, a de-clumped Jacobson EWMA of `mean + 4·dev` over a slow-rising floor), which clumping barely moves because each packet is timed against its own capture stamp. So: **`Jitter` high but `Delay spread` low ⇒ the link is clumping** (benign — packets just arrive early and fill the buffer), **both high ⇒ the path is genuinely jittery** and needs buffer depth. Read alongside `Packet spacing` (the arrival-gap histogram: bimodal low+high = clumping, a spread around ~8 ms = path jitter) for the full picture. `Delay spread` is not just a diagnostic — it **is** the jitter cushion in `Smoothing delay` (`rtt/2 + broadcast_interval + Delay spread`, at 1.0× since it already ignores clumping). The `Delay spread` floor also reads out the de-clumped one-way path delay (≈ RTT/2). **Canary:** if `Guessing ahead` (extrapolation /s) climbs past ~1–5/s on a clumpy link, the de-clumped cushion is under-sizing — the buffer underruns between clumps faster than the adaptive +10 ms/packet up-clamp can chase — and the conservative `jitter_p95 × 2.0` cushion should be restored (see Tier 2A).

### Playtesting telemetry (F4 markers + session collection)

F3 is a *live, local* diagnostic — only the player at that machine sees it, which is useless for remote playtesters. Two additions ship a tester's connection quality back for aggregation:

- **Always-on health dot** — `network_debug_overlay.gd` draws a small green/yellow/red `●` in the top-left at all times (the F3 verdict), so a tester notices a bad link without opening the panel. While the panel is closed the verdict is re-evaluated on a 2 Hz throttle (telemetry only refreshes at 1 Hz), avoiding the per-frame text build.
- **F4 felt-lag marker** — any tester (exported builds included, unlike the dev-only sim keys) presses **F4** the instant something feels bad. It snapshots the live telemetry + in-session time and appends a marker via `NetworkSessionSummary.record_felt_lag`, plus a transient toast. Correlating *felt* badness with the objective numbers is the signal raw rates miss.
- **Session collection → Supabase** — `NetworkSessionSummary` (`domain/state/`, pure, unit-tested) folds `NetworkTelemetry`'s per-second metrics into session-long **max / avg** (+ **min** for "lower is worse" metrics: sim rate, reconcile-match %), folded once per 1 s window in `NetworkTelemetry.tick` (GameManager refreshes live RTT/peer-count each frame for the fold to sample). `NetworkSessionReporter` (`game/`, mirrors `CareerStatsReporter`) POSTs one row per online game at game-over — gated by the same offline/privacy checks plus a 30 s floor, flagging `net_sim_active` dev sessions. The evolving aggregate set rides in a `metrics` jsonb column (like `bug_reports.telemetry`) so adding a metric never needs an `ALTER TABLE`; only identity/filter fields are typed columns. Schema + analysis view in `sql/network_sessions.sql`. Query `network_session_health` for "across all testers, what actually hurts."

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

**Authoritative host, no dedicated server.** One player hosts; the host runs all physics. Eliminates server costs and NAT complexity at the expense of host-advantage. Acceptable for a small-scale game like this.

**No pickup prediction for *contested* plays; visual-only optimistic attach for *uncontested* ones.** Authority and arbitration stay server-side — pickup is detected via lag-compensated rewind and only the grant confirmation travels to the client; carry state (`has_puck`, the shot state machine) never engages until that grant lands. The original blanket "no prediction" rule existed because rolling back a *contested* pickup feels worse than the round-trip. That objection is spatial: a pickup is only contestable when another skater is near the same puck. So `PuckController.try_provisional_pickup` pins the puck to the local blade immediately (visual only) when the pickup is **uncontested** — no other skater's blade within `contest_danger_radius` of the puck on the rendered view, puck grounded and below `pickup_max_speed` (a guaranteed catch, not a deflect), and not inside the post-loss reattach lockout. On the host's confirming `notify_local_pickup` the pin promotes seamlessly; on timeout (RTT-scaled deadline) or a different carrier it rolls back to interpolation. The contest gate keeps the rollback-prone case on the conservative round-trip path while making the common open-ice grab feel instant.

**Ghost mode over stoppages for offsides and icing.** Stoppages interrupt flow; ghost mode keeps the puck live and lets offending players correct their position. Downside: slightly less legible than a whistle. Acceptable for a game that prioritizes momentum.

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

**The goalie AI runs only on the host; clients are pure interpolators.** The host runs the full goalie state machine every physics tick. Clients do **not** run the AI — they buffer the host's broadcast goalie snapshots and render them at `now - interpolation_delay` via `GoalieController._interpolate_and_apply`, exactly like remote skaters and the loose puck. When `render_time` overshoots the newest snapshot, the root translation is dead-reckoned by the broadcast linear velocity (capped at `extrapolation_max_ms`) while the pose holds its newest value — a brief gap reads as a momentary freeze rather than wildly extrapolated sweep angles. This replaced the older "client runs the AI + soft position correction" model, which produced ghost saves and phantom goals whenever the client's local puck read disagreed with the host broadcast.

The full pose is on the wire, so the broadcast is the authoritative visual: butterfly drop, glove/blocker reach, RVH hug, and recovery all come straight from the interpolated host pose. Serialized per goalie (35 B quantized): root — position (x/z), rotation_y, state_enum, five_hole_openness, velocity (x/z); pose — body pitch/roll, each pad's offset + pitch/roll, glove and blocker offsets + yaw/pitch, head yaw. `_apply_interpolated` sets `_sm.current` directly from the snapshot enum (body/head height lookups in `apply_network_pose` key off it, and debug/telemetry readers see the host's state), and adopts `five_hole_openness` from the snapshot. There is **no** client-side goalie AI tick, reaction state machine, or goalie state/reaction RPC. The host's only reaction signal, `GoalieShotReaction.started`, is host-internal — `_on_reaction_started` consumes it to arm the slide event-lockout, and it is never fanned out to clients.

RVH triggers when `_is_puck_in_defensive_zone()` — either the puck is behind the goal line, or it is within `zone_post_z` of the goal line and the horizontal angle to the puck exceeds `rvh_early_angle` (default 60°). This matches the Buckley depth chart's "Defensive" corner zones, which extend slightly in front of the goal line at sharp angles.

**Tracking lag:** `GoalieController` maintains `_tracked_puck_position` that lerps toward the real puck at `tracking_speed` (default 6.0) each frame. All positioning logic — lateral target, depth, facing, and state transitions — reads from this tracked position rather than the real puck. `_on_puck_released` (shot detection, server only) reads the real puck position and velocity so butterfly reactions stay accurate. `tracking_speed` is the master difficulty export: lower = more positional lag.

### Puck Interactions (server-side)

All puck contact logic runs on the host via `PuckController._check_interactions` each physics tick using swept-segment distance tests in `PuckInteractionRules`:

- **Segment-segment detection:** both `check_pickup` and `check_poke` use an Eberly analytical segment-segment minimum distance test. The puck is swept `puck_prev → puck_curr`; the blade is swept `blade_prev → blade_curr` (`blade_prev` captured at the start of `SkaterController._process_input`, *before* the per-tick IK update mutates `blade.position` — so the segment spans both the IK swing and the post-`move_and_slide` body motion). This catches fast blade swings through the pickup zone even when the puck is nearly stationary — the old static-blade test would miss those.
- **Catch vs deflect:** the puck's absolute speed against `deflect_min_speed` (default 20, set above charged-pass speed ~19 so passes catch at any angle), plus an `alignment_receive_bonus` that raises the ceiling only when the blade face is square to the puck (hard shots care about angle; passes don't). Reception is **reactive** — it reads puck speed and blade angle at contact, nothing else; there is no blade-velocity / cushion term (it rewarded pre-loading a backswing, which felt fiddly and unintuitive). Below `pickup_max_speed` always catches. **Both detection paths run this decision:** present-time `_check_interactions` and the lag-compensated `PickupClaimResolver` (which reconstructs `should_receive` from the rewound snapshot — puck velocity off the snapshot, blade velocity finite-differenced over the rewind tick, blade face normal from the buffered `blade_contact_world`/`top_hand_world`). The claim path used to grant possession on blade overlap *alone*, so a remote player reaching for a too-fast/poorly-angled puck caught it magnetically; now a deflect verdict routes to `PuckController.apply_lag_comp_deflect` (cooldown-guarded against a double-deflect with the present-time path) instead. `Skater.get_blade_face_normal` and the resolver share one definition via `PuckReceptionRules.blade_face_normal`.
- **Deliberate deflect:** `skater.deflect_intent` (set in `SkaterController._wants_deflect` = human holds the shoot button without the puck; AI is exempt, overriding it to false) short-circuits the catch-vs-deflect decision and forces `apply_blade_deflect` — even an otherwise-catchable puck is tipped. The flag is a transient per-tick value derived from input (no replication / no snapshot — it recomputes from replayed inputs during reconcile), authoritative because the host runs `_process_input` for every skater it simulates. `LocalController` suppresses its speculative pickup claim + optimistic pin while the flag is set so the local player never predicts a catch the host will resolve as a deflect.
- **Deflect direction:** contact normal = `(puck_pos - blade_world_pos).normalized()` (billiard ball style). Physical reflection blended toward incoming direction via `deflect_blend`. Two effects ease with puck speed via one shared hardness factor (`speed / deflect_speed_ref`, clamped) so a soft puck is steerable and a hard one only glances: the turn off the incoming line is capped from `deflect_max_angle_deg` (soft — sharp redirect) toward `deflect_max_angle_deg_min` (hard — shallow tip; also tames wild caroms from a jittery near-perpendicular normal at high blend), and energy retained eases from `deflect_speed_retain` toward `deflect_speed_retain_min` so hard pucks don't pinball. If `skater.is_elevated`, outgoing direction is tilted upward by `deflect_elevation_angle`. Deliberate and natural deflects share this one path.
- **Poke check:** when any opposing blade's sweep path passes within radius of the puck while `carrier != null`, `_poke_check` strips the puck (teammates cannot strip each other — gated by `PuckCollisionRules.can_poke_check`). Strip direction = `checker_blade_vel + carrier_blade_vel * poke_carrier_vel_blend` (or spatial direction as fallback). Ex-carrier gets `reattach_cooldown`; checker gets brief `poke_checker_cooldown`. Pokes are also lag-compensated via a client-claim path — see `PokeClaimResolver`. Both detection paths run concurrently; idempotency guards on `PuckController.apply_lag_comp_poke` and the `puck.carrier != null` early-return in `_check_interactions` prevent double-strip.
- **Body check strip:** `SkaterController._on_body_checked_player` (server only) calls `puck.on_body_check(checker, victim, force, direction)`. If `force = weight × approach_speed ≥ body_check_strip_threshold` and `victim == carrier`, `_body_check_strip` clears the carrier and launches the puck in the hit direction. Emits `puck_stripped` + `puck_released` — same notification path as poke check. `Skater` also emits `body_check_impulse_applied(impulse)` with the total velocity delta from `_resolve_player_collisions()` each tick (attacker rebound + victim transfer from remote's check both included). `LocalController` connects to this signal and injects the complete delta into kinematic reconcile replay at the matching `host_timestamp`; the old `body_checked_player` approach captured only the attacker rebound, causing consistent under-correction and jitter. Body check VFX fires client-side from the sim — `SkaterVFX` connects to `body_checked_player` on every skater; no RPC needed.
- **Passive body block:** each `Skater` has a `BodyBlockArea` (`Area3D`, `collision_layer = 0`, `collision_mask = LAYER_PUCK`, sphere radius `body_block_radius`). On `body_entered`, Skater emits `body_block_hit`; `SkaterController._on_body_block_hit` (server only) calls `puck.on_body_block(blocker)`. Only fires on loose pucks (`carrier == null`). Reflects puck off body-center contact normal, multiplies speed by `body_block_dampen`, sets brief pickup cooldown on the blocker.
- **Per-skater cooldowns:** `_cooldown_timers: Dictionary` (Skater → float). Cooldown only applies to loose-puck pickups/deflects, not to poke checks. Lets two players race a loose puck — only the ex-carrier has a disadvantage.

### Why Not Predict Pickup?

Pickup is detected server-side via physics collision and the server arbitrates contested claims — that authority is never predicted. What *is* predicted is the **visual** attach on an **uncontested** grab: `try_provisional_pickup` pins the puck to the local blade before the grant arrives, but only when no other skater is near the puck (so there's nothing to arbitrate) and the catch is guaranteed (grounded, slow). The carry state machine still waits for the host grant, so a rolled-back optimistic pin is at most a brief visual pop, never a phantom shot. Contested pickups stay fully on the round-trip path. See the "No pickup prediction…" decision above for the gate detail.

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
- 120 Hz physics tick (Rocket League parity; the puck's Continuous CD handles tunnelling at this rate)
- **15 FPS host floor.** `max_physics_steps_per_frame` sits at Godot's default of 8 (P6 pinned it to 8 in `project.godot`, but 8 is the default so the editor strips it on save — it's a documented constraint, not a persisted setting). At the 120 Hz tick the host must render ≥ `120 / 8 = 15` FPS to keep physics real-time; below that, the sim dilates (slow-motion vs. the wall clock that clock-sync and broadcast cadence use) and every client interpolator extrapolates at once. Dropping the tick 240→120 Hz halved this floor (it was 30 FPS) and halved the per-tick host budget — per-actor allocation work and Jolt solver cost both scale with the rate. Raising the cap to tolerate even lower framerates risks a physics "spiral of death" (more catch-up steps make each frame slower still), so the floor is the deliberate failure mode. Keep the host comfortably above it via the per-tick perf budget; watch the F3 tick p95/p99 telemetry for transient dips (a GC hitch or heavy reconcile-replay frame can momentarily blow past it).
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

**`WorldStateCodec`** is not a pure codec — it also emits `phase_changed` / `game_over_triggered` / `period_synced` / `clock_updated` / `shots_on_goal_changed` / `queue_depth_feedback` when decoding. GameManager connects to these so it can react to authoritative host updates on clients.

**`StateBufferManager`** lives in `Scripts/game/`, not `Scripts/networking/`. Host-only pre-allocated ring buffers (`PHYSICS_TICK × 3` slots = 3 s of history) for all actors. Owned by GameManager; WorldStateCodec reads `latest_*()` for broadcasts; lag-comp rewinds use `get_state_at()`.

**`GameManager` wires six collaborators:** `PlayerRegistry`, `WorldStateCodec`, `ShotOnGoalTracker`, `HitTracker`, `PhaseCoordinator`, `SlotSwapCoordinator`.

**`SkaterController`'s five `RefCounted` collaborators live in `Scripts/controllers/`, not `domain/`.** `SkaterStateMachine` (current shot state, follow-through timer, locked aim direction), `SkaterAimingBehavior` (charge distance, sweep history, one-timer window), `SkaterPoseCoordinator` (facing, upper-body twist/lean, velocity lean, lower-body lag, head angle, angular-velocity bookkeeping), `SkaterShotPoseCoordinator` (slapper wind-up blade pose, wrister/slapper follow-through), and `SkaterIKCoordinator` (mouse → top-hand IK, bottom-hand IK, net/goalie/butterfly clamps, blade-Y geometry helpers) all carry controller-local mutable state that is tightly coupled to per-tick input processing. Domain rules are stateless static methods; these classes are stateful collaborators owned by `SkaterController` and set up in its `setup()`. The pose and shot-pose coordinators expose public state fields (`facing`, `upper_body_angle`, `lower_body_lag`, `ik_locked_side`) so `LocalController.reconcile` can snap them on replay entry/exit; `_blade_relative_angle` and `_do_release` stay on the controller because they cross multiple coordinator boundaries.

---

## Networking Invariants

Non-obvious constraints that cause subtle bugs if violated. Rates and wire format are in the Reference section above.

**A client's puck is always in one of these modes** (checked in this priority order in `PuckController._physics_process`): *Local carry* — the local player carries; puck pinned to their blade. *Provisional carry* — an uncontested optimistic pin to the local blade awaiting host confirmation (visual only; see "No pickup prediction…" decision); rolls back on timeout. *Remote carry* — a remote player carries; puck pinned to **that skater's interpolated blade** (`get_carry_target_global`) rather than interpolating from its own buffer, so the puck shares the carrier's render timeline and stays glued to the stick. *Trajectory prediction* — the local player released; `PuckController` advances the puck forward from the release point using stored velocity and `ICE_FRICTION`, applying three-zone broadcast correction each tick (see below). *Interpolated* — none of the above; client buffers host snapshots and renders from `estimated_host_time() - interpolation_delay × (1 − extrapolation_lead_fraction)` — i.e. led toward host-present like remote skaters (so a chasing skater and the loose puck share a timeline and the local pickup/poke proximity reads fire where the host has the puck), then run through the same velocity-feed-forward `_smooth_damp` position smoother (advanced by the puck's own velocity for zero steady-state lag — critical here, a fast loose puck would otherwise trail by metres on a shot/pass — with only the residual error damped). The smoother is **reseeded from the puck's live position on every fresh entry into interpolation** (carry / trajectory-prediction / extrapolation → loose), which is what makes those hand-offs seamless and **subsumes the former rejoin-blend** (the trajectory→interp seam included). **Smart (board-aware) extrapolation:** the forward dead-reckon is gated by `_crosses_board` (`stop_extrapolation_at_boards`) — if the projected position would land past the inner board boundary (`GameRules.clamp_to_rink_inner`, rounded corners exact), the lead is dropped for that frame and the puck holds at the newest authoritative position rather than projecting through the boards and snapping back on the host's reflected samples. The bounce is **not** predicted client-side (the host owns restitution/angle); goalie/net/skater bounces still rely on the smoother. All pin modes keep buffering host snapshots (`apply_state` early-returns only for the local-carry pin) so the buffer stays warm across the pin. The `carrier_idx` field decoded from world state switches non-carrier clients between prediction and interpolation; the reliable `notify_carrier_changed` RPC is what installs/clears the remote-carry pin (via `GameManager._on_remote_carrier_changed` → `notify_remote_pickup`).

**On clients, `_carrier_peer_id` is managed exclusively by reliable RPCs, never by world state.** Unreliable packet ordering conflicts with locally-predicted carrier transitions. On the server, `_carrier_peer_id` in `PuckController` is set by physics callbacks (`_on_puck_picked_up` / `_on_puck_released`). The world state does encode a `carrier_idx` field, but clients use it only to enter/exit trajectory-prediction mode — they do not write `_carrier_peer_id` from it.

**Lag-comp rewind goes through `LagCompRewind` — never reach into raw timestamps.** Two helpers encode the two view perspectives every claim handler needs: `self_view_time(host_timestamp)` for entities the claimant rendered via local prediction (their own skater body/blade), and `remote_view_time(host_timestamp, interp_delay_ms)` for entities they rendered via interpolation (other skaters, loose puck, remote-carried puck, goalie). Each claim resolver picks per entity — pickup/poke rewind the blade as self and puck as remote; hit rewinds the hitter as self and victim+puck as remote; shot-release rewinds only the **goalie** as remote — the firing **origin** is no longer a self-view buffer rewind (see *Shot lag compensation* below: the release pose lands in the buffer ~`INPUT_LEAD_SEC` ahead of the immediate release RPC, so the rewind read a stale pre-release blade), it is sent by the client and clamped server-side via `ShotReleaseRules.clamp_origin`. Rewind depth is RTT-independent (depends only on `INPUT_LEAD_SEC` and the client-reported `interp_delay_ms`), so two players reaching for the same puck are arbitrated by their stamped view-times instead of by network luck. Open-coded `host_timestamp ± rtt/2` formulas are a class of bug — the wrong shift, and they couple validation to ping.

**`rtt_ms` in shot release claims** (`release_puck` / `release_puck_one_timer`) is the raw unaveraged latest sample (`latest_rtt_ms` from `ClockSync`), not the smoothed average. It is **no longer** used to advance the puck forward (that release-time RTT/2 advance was removed — see *Shot lag compensation* below); on the host release path it now only gates "is this a lag-comp'd remote shot" (`rtt_ms > 0.0` distinguishes a client shot from the host's own `rtt_ms = 0` path). On the shooter's client it seeds `_shot_rtt_ms`, which the trajectory-reconcile (`PuckController.apply_state`) uses to project each host broadcast forward by the full RTT to "client present". It is not used for any rewind — claim chains dropped `rtt_ms` once the LagCompRewind helper landed. (Still on the wire; removing it would need a `PROTOCOL_VERSION` bump for no real saving.)

**Shot lag compensation has two independent pieces, with no release-time forward advance.** *Client-sent origin:* the host fires the authoritative puck from the release point the client sends in the `release_puck` / `release_puck_one_timer` RPC — its own locally-predicted blade contact (`PuckController.notify_local_release` returns it) — clamped to the shooter's stick reach of their host-live body (`ShotReleaseRules.clamp_origin`, `MAX_ORIGIN_REACH_M = 2.5`). This replaced a self-view state-buffer rewind that silently failed on a fast link: the shooter's release-pose blade is buffered at `host_timestamp + INPUT_LEAD_SEC` (~33 ms ahead), but the immediate release RPC is processed ~`rtt/2` after the client sent it, so `StateBufferManager._find_bracket` clamped the future query to the stale *pre-release* blade. Validation is *trust-but-clamp* — the host can't reconstruct the exact un-buffered future release pose, so it fences the client origin to the reachable area rather than pinning it. *Goalie reaction back-date + goalie-position rewind (remote-view):* the goalie's reaction timers are back-dated by the one-way trip so it gets the reaction window the shooter perceived, and the goalie is rewound to its interpolated render-time position for fair release geometry. *No RTT/2 advance:* the host (and the shooter's own client) does **not** shove the puck forward by `velocity * rtt/2` at release — the shooter's trajectory-reconcile (`PuckController.apply_state`) already projects each host broadcast forward by the full RTT, so prediction and authority line up without it; the old advance only bought close-shot rebound alignment at the cost of a visible 1-tick puck pop and a non-swept teleport that could skip the puck past a close goalie/boards. **Watch in playtest:** close shots at high RTT are where rebound divergence (client predicts a goalie hit ~rtt/2 before the host does) could surface a "hit → re-approach → hit" artifact; the contact-exit + post-contact suppression should absorb it.

**Trajectory prediction exits on post contact and puck-goalie contact**, not only on carrier-change RPCs. Both controllers call `end_trajectory_prediction()` directly on the relevant physics signal.

**The goalie AI is host-only; clients render the goalie purely from the interpolated host pose broadcast.** The full pose (root + body/pad/glove/blocker/head) is on the wire every world-state tick, so the broadcast carries the butterfly drop, glove/blocker reach, RVH, and recovery directly — there is no client-side goalie AI tick, reaction state machine, or per-event goalie RPC. Do not reintroduce client-side goalie AI or `apply_state_transition`/`apply_shot_reaction`-style reliable RPCs: the earlier client-AI-with-soft-correction model caused ghost saves and phantom goals when the client's local puck read disagreed with the host. The host's `GoalieShotReaction.started` signal stays host-internal (it arms the slide event-lockout via `_on_reaction_started`).

**Reconcile saves and restores only narrow shot-state fields** (`_state`, follow-through timers, one-timer window, `slapper_charge_timer`, and the wrister charge accumulator + sweep history). The `slapper_charge_timer` save/restore is required because `_update_slapper_charge` ticks the timer inside the replay loop — without it each reconcile re-ticks the unconfirmed inputs and the timer inflates O(N) per broadcast, popping the blade above `slapper_wind_up_height`. The wrister charge save/restore is the same shape (replay re-accumulates the unconfirmed sweep). Server authority on shot **state**: if `server_state.shot_state` differs after replay, server wins — `_state` is overwritten. Wrister charge (`charge_distance`) is **not** server-overwritten: it is a local control input (the player's precision sweep), so the host's lagged value is never imported — doing so rubber-banded the live charge and starved forehand shots into the quick-shot branch. (A later determinism pass will let the host re-derive the shot from inputs rather than round-trip charge through server state.) **Two symmetric guards protect in-flight shot transitions:**
- **`FOLLOW_THROUGH` → aim state blocked.** When the client is in `FOLLOW_THROUGH` it has already sent the release RPC; the host is processing-lag behind. Reverting would loop the follow-through animation every broadcast.
- **`WRISTER_AIM` / `SLAPPER_CHARGE_WITH_PUCK` → skating blocked when `has_puck = true`.** There is a ~23ms window between the client pressing shoot and the host processing that input (60Hz batch window + network transit). World states broadcast at 120Hz are very likely to fire during this window carrying `shot_state = SKATING_WITH_PUCK`. Without this guard reconcile resets the state machine on every broadcast; `shoot_pressed` has already fired once and `shoot_held` never re-enters aim, so the shot never releases. Gated on `has_puck` so a puck steal (which clears `has_puck` before the next reconcile) still overrides correctly.

**Mouse position is seeded from the first replayed input at replay start and the last at replay end.** Wrister-aim charge accumulation is a function of sweep distance; both endpoints must match for deterministic replay across reconcile.

**Board collision is clamped in the reconcile replay loop** via `GameRules.clamp_to_rink_inner` after each `global_position += velocity * delta` step. Without this, board-bounce divergence triggers a feedback loop of reconciles.

**Reconcile uses trajectory comparison, not position-snapshot comparison.** Every physics tick on `LocalController._physics_process`, after `_process_input` mutates skater state, a `PredictedState` snapshot is appended to `_prediction_history` keyed by the input's `host_timestamp` (capped at `PHYSICS_TICK × 2` entries ≈ 2 s). When `reconcile(server_state)` fires, `PredictedState.find_at(_prediction_history, server_state.last_processed_host_timestamp)` returns the snapshot for that exact instant. The threshold check (`ReconciliationRules.skater_needs_reconcile`) compares **predicted-vs-server at the same `host_timestamp`** instead of current-client-vs-server, which subtracts the natural prediction lead (RTT/2 + `INPUT_LEAD_SEC` × velocity ≈ 0.33–0.6 m at skating speeds) out of the divergence. Thresholds can therefore stay tight (`reconcile_position_threshold = 0.05 m`, `reconcile_velocity_threshold = 0.3 m/s`) — only true non-determinism (body-check mis-replay, contested collision resolution) trips them. After the lookup, `_prediction_history` is trimmed by the same predicate as `_input_history` (`host_timestamp > last_processed_host_timestamp`), since future reconciles only ask about strictly later timestamps. Cleared alongside `_input_history` on `teleport_to` and dead-puck-frozen-stick drains. When no match is found (history capped before a reconcile catches up, post-teleport gap, NTP warmup) the comparison falls back to the live position so reconcile remains a safety net through edge cases.

**Blade and top-hand positions on remote skaters are extrapolated from the body velocity field**, not from derived position deltas. Dividing position deltas by client receive-time gaps amplifies jitter into visible blade jumps.

**Remote skaters lead toward host-present, with critically-damped error smoothing to keep the advance safe.** `RemoteController._interpolate` renders at `render_time = estimated_host_time() − interpolation_delay × (1 − extrapolation_lead_fraction)`: at `extrapolation_lead_fraction = 0` this is the legacy "interpolate in the past" instant; at `1` it renders at the host's present position (the body dead-reckons the full ~`interp_delay`). The lead exists because remote bodies are what the *local* player's predicted `move_and_slide` collides against — rendering them `interp_delay + RTT/2` in the past meant the client predicted body checks against a stale victim while the host (`Skater._resolve_player_collisions`, un-lag-comp'd live physics) resolved them against the present victim, so the contact normal — "which side you end up on" — disagreed and reconcile snapped you. Leading the body shrinks that gap (and the chase-lag gap). **The naive version of this was retired once before** (a steady `interp_delay` forward-advance that overshot on direction changes and snapped back, `Guessing ahead` climbing). What makes it safe now is the **velocity-feed-forward smoothing stage**: after the lead/extrap target is computed, the collision body position is advanced by the target's *own* velocity each frame (**zero steady-state lag** — smoothing the absolute position instead trails a moving body by ~`velocity × smooth_time`, multi-metre on a fast puck) and only the *residual error* is critically damped toward the target (`_smooth_damp`, `position_smooth_time`). So when a contradicting snapshot lands (the lead's dead-reckon was wrong) or the interp↔extrap branch flips, the error blends out instead of snapping, while straight-line motion tracks exactly; `position_smooth_time` governs how fast the residual decays, not steady tracking. The smoother **subsumes the old extrapolation rejoin-blend** (it handles every seam, not just extrap→interp); a large per-tick delta (teleport / faceoff / goal reset) snaps the smoother rather than sliding the body across the rink. The packet-loss `is_extrapolating` branch (render_time past the newest sample, capped at `extrapolation_max_ms`) is unchanged. The lead is **skater-only** — puck and goalie still render on the shared past instant — because body checks don't involve them and the puck trajectory system is sensitive; `velocity` on the remote body stays the authoritative interpolated value (the smoother's internal velocity is display-only) so the host-side closing-velocity read is unaffected. **One scoped addition (Lever B, `start_knockback_lead`):** a credited body check adds a brief 0→peak→0 `sin(t·π)` position pulse along the hit direction (`_knockback_lead_*`, ≤~0.22 m over ~120 ms), applied as a final additive **after** the SmoothDamp so the punch stays sharp instead of being absorbed by the smoother.

**The shared interpolation-delay target is `rtt/2 + broadcast_interval + PDV spread`** (`network_manager.gd`, `_compute_target_interpolation_delay`), where the spread is `get_packet_delay_spread_ms()` — the de-clumped Jacobson PDV (`mean + 4·dev` of each packet's delay measured against its own host-capture stamp). It replaced a conservative `jitter_p95 × 2.0`: the old arrival-gap p95 couldn't tell genuine path jitter from Steam relay **clumping** (several snapshots land together, then a gap), so it needed a 2.0× bump that over-cushioned a *clean* link with pure render latency on every remote entity. The PDV spread times each packet against its host-capture stamp, so clumping barely moves it; it measures the steady path component at 1.0× and leans on the aggressive +10 ms/packet up-clamp in `adapt_interpolation_delay` to absorb transient clumps. **Watch on a real high-latency link:** `Guessing ahead` (extrapolation /s, F3) is the canary — if it climbs past the <1/s target the cushion is under-sizing (buffer underrunning between clumps faster than the up-clamp can chase, visible as rhythmic snap-back on remote skaters); the one-line revert is to restore `get_jitter_p95() * 2.0` in `_compute_target_interpolation_delay`.

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

**Wire timestamps are u32 in 0.1 ms units (`Constants.TIME_WIRE_SCALE`), not f32 seconds.** Applies to the world-state header, the skater block's `last_processed_ts`, input `host_timestamp`, and replay-file frame stamps. f32's ULP grows with host uptime (~1 ms at 2.3 h, ~2 ms at 4.6 h — at which point adjacent per-tick input stamps quantize equal and the dedupe drops real inputs); u32 @ 0.1 ms is constant-precision over ~119 h. Encode with `roundi` so grid round-trips are exact; `PredictedState.TS_MATCH_EPSILON` (1 ms) absorbs the ≤0.05 ms grid-vs-f64 error in reconcile lookups and history trims. Changing this representation means bumping `BuildInfo.PROTOCOL_VERSION` and `ReplayFileWriter.FORMAT_VERSION`.

**Claim stamps are validated against the host's own ping measurement at the RPC boundary.** `LagCompRewind.is_claim_stamp_plausible` (applied in `receive_pickup_claim` / `receive_poke_claim` / `receive_hit_claim`) rejects future stamps and stamps older than the peer's measured one-way + 100 ms slack. The resolvers' `MAX_CLAIM_AGE_S` (200 ms) remains the absolute bound, but inside that window the earlier stamp wins contested pickups outright — without the per-peer check, backdating ~190 ms wins essentially every 50/50 puck.

**All interpolators use host-capture timestamps, not client arrival time.** `apply_network_state` / `apply_state` on `RemoteController`, `PuckController`, and `GoalieController` each take a `host_ts: float` parameter decoded from the world-state header. `RemoteController` and `PuckController` buffer it as the snapshot timestamp (`render_time = NetworkManager.estimated_host_time() - interpolation_delay`). `GoalieController` uses it differently — `elapsed = estimated_host_time() - host_ts` drives position forward-prediction rather than buffer lookup. Using client arrival time instead of host-capture time causes same-frame world-state packets to silently clobber each other and decouples the render timeline from the simulation timeline. The interpolation delay subtracted from `estimated_host_time()` is a single shared value (`NetworkManager.get_interpolation_delay()`, advanced once per packet) across all three interpolators — not per-actor — so they render at the identical instant and relative timing never drifts between them.

**Spectator slots use `team_id == GameRules.SPECTATOR_TEAM_ID` (-1) end-to-end.** Lobby keys spectators at `LobbySlotKey.SPECTATOR_KEY_BASE = 100` upward so they never collide with the 0..5 home/away keys; `LobbySlotKey.team_id`/`LobbySlotKey.slot` decode them. The `assign_player_slot` RPC carries `team_id = -1` for spectators (with zero-color tuples that the receiver ignores); `GameManager.on_slot_assigned` branches on this and calls `_become_local_spectator()` instead of `_registry.spawn`, mounting `SpectatorCamera` and emitting `local_spectator_state_changed(true)` for HUD chrome. Spectators are deliberately NOT in `_registry`, so every iterator that already loops `_registry.all()` (scoreboard, off-screen indicators, TOI accumulator, career stats reporter, world-state codec) excludes them naturally — do not add explicit spectator filters to those callsites. The host-only mirror for cross-peer queries is `GameManager._spectator_peers: Dictionary[int, bool]`, populated in `on_host_started` / `on_player_connected` / `_push_lobby_assignments_to_clients` and exposed via `is_spectator_peer(peer_id)` and `spectator_peer_count()`. ENet connection cap is `GameRules.MAX_CONNECTIONS = MAX_PLAYERS + MAX_SPECTATORS`; the player roster is still gated separately by `PlayerRules.MAX_PER_TEAM`.

**Mid-game spectator ↔ player swap routes through `_on_slot_swap_requested` with separate paths.** `SlotSwapCoordinator.try_swap_slot` only validates peers already in `_state_machine.players`, so promote/demote bypass it: `new_team_id == -1` runs `_demote_player_to_spectator` (drops puck if carrier, broadcasts `notify_spectator_demoted`), `_spectator_peers.has(peer_id)` runs `_promote_spectator_to_player` (validates slot/team capacity inline, spawns + RPCs the same as `_push_lobby_assignments_to_clients`). The demote RPC is a one-way "despawn this peer's skater everywhere"; promote reuses the existing `spawn_remote_skater` + `assign_player_slot` RPCs that mid-game joins use, so other peers see promotion as if a fresh peer joined. The promoted peer's `on_slot_assigned` detects mid-game by `_state_machine != null` and skips `_spawn_world()`. Demote of the local peer **must clear the input batch provider before** `_registry.remove` queue-frees the LocalController — otherwise NetworkManager's input pump would call into a freed object.

**Reconnect reservations are host-authoritative, keyed by SteamID64, and count toward team totals.** When a non-bot peer with a Steam ID drops mid-match (not kicked — `NetworkManager.was_peer_kicked` gates it — and not at `GAME_OVER`), `GameManager._maybe_reserve_slot` snapshots their `{team_id, team_slot, stats, attributes}` into `_reserved_slots[steam_id]` and calls `_state_machine.reserve_slot`. The reserved `(team_id, team_slot)` counts in `count_players_on_team` (so the team plays short-handed rather than being backfilled) and is skipped by `_first_available_slot`. `request_join` carries the joiner's SteamID64 (added at `PROTOCOL_VERSION` 7; currently 8); on rejoin `on_player_connected` checks `_reserved_slots` **before** the spectator/roster-gate/auto-balance branches and routes a match to `_restore_reserved_player`, which re-locks the original attributes, respawns into the held slot, and carries the pre-drop stats forward. Expiry is a `RECONNECT_RESERVATION_S` (~60 s) `SceneTreeTimer` guarded by a monotonic token — `_expire_reservation` no-ops if the reservation was already claimed or re-reserved (token mismatch), so a re-drop's fresh timer can't tear down the new hold. Client side: a genuine mid-match connection loss (not a kick or graceful host shutdown) stashes `NetworkManager.pending_reconnect_lobby_id` (survives `reset()`), which `SideMenu` consumes on `_ready` to surface `LoadingScreen.show_reconnect` — Reconnect re-runs the join into the same lobby, Cancel falls back to free play.

---

## Known Issues / Planned Work

**Performance, deferred until profiling shows them mattering:**
- **AI snapshot-level caching.** `GameManager._enrich_snapshot_for_ai` publishes `teammate_ids_by_team` + `closest_to_puck_by_team` on `current_snapshot` once per host physics frame; the per-physics-tick hotspots (`_apply_steering`, `_is_closest_teammate_to_puck_at`) read from the cache. **Per-tick allocation cleanup — DONE.** A hot-path audit found and fixed the remaining 120 Hz host allocations: goalie `detect_shot` now fills a reused `_scratch_shot` via `detect_shot_into` (the plain `detect_shot` is kept as an allocating wrapper for tests); the puck cooldown-expiry sweep reuses a cleared `_expired_cooldowns` member instead of allocating an `Array[int]` every tick a cooldown is active; `_apply_steering` replaced `teammate_ids_by_team.get(_team_id, [])` (eager default-literal alloc) with a `has()` + shared `_empty_ids`; the carry-path roster walks (`_carry_has_open_lane`, `_stickhandle_offset`) read the cached opponent list via `_opponent_ids()` instead of re-partitioning; and `_step_mouse_internal` skips its two `randf_range` calls under the zero-noise baseline.
- **AI role-behavior dispatch allocation — DONE.** The role `decide()` path runs at the **~60 Hz dispatch rate** (full state handler every `DISPATCH_PERIOD_TICKS = PHYSICS_TICK/60 = 2` ticks), *not* the 6 Hz brain tick — the brain tick (`role_slots.assign`, `AIPossessionState.compute`) only chooses *which* slot each bot holds; the per-bot positioning math reruns at 60 Hz. That path used to allocate several `Array[Vector3]` plus a `RoleContext` per off-puck bot per dispatch. Now `SkaterAgentStateMachine` reuses one `RoleContext` (refilled each dispatch) carrying four scratch buffers, and `collect_teammates_excluding_self` / `collect_opp_team_excluding_carrier` fill caller-owned scratch like `collect_opponents` already did. Invariant the design relies on: each scratch buffer is consumed once per `decide()` and only value-type (`Vector3`) results escape — never a retained array reference — so reuse across dispatches is safe (see the `RoleContext` doc-comment). `RoleDecision.new()` is still allocated per dispatch (one small RefCounted; reusing it risks stale fields across the role files' early-returns for little gain).
- **6 Hz brain-tick re-partition.** `TeamBrain._compute_tick` (role-slot assignment, possession state) still partitions `snapshot.skater_states` itself at ~6 Hz — wins there are ~30× smaller than the physics-tick paths, so deferred until profiling motivates it.

**Maintainability, address opportunistically (don't refactor for its own sake):**
- **God classes.** `Scripts/game/game_manager.gd` (~2400 LOC), `Scripts/controllers/goalie_controller.gd` (~1100), `Scripts/ui/hud.gd` (~1000), `Scripts/ui/options_panel.gd` (~900). `PickupClaimResolver` and `GoalieBodyConfigBuilder` have already been extracted; per-popup splits from HUD remain a candidate. Refactor only when a concrete need arises.
- **Test coverage gaps.** Remaining: `FileReplayDriver` / `GoalReplayDriver` (both `extends Node`, drive live scene actors — integration-test territory, poor headless ROI), and `skater_agent_state_machine`'s **state handlers** (`_state_carry` / `_state_shoot_pressed` / … and the dispatch transitions between them — they run the `AIRoleCarrier` role behavior, so testing them headlessly needs a carrier intent stub). The agent SM's snapshot-driven predicates, mouse/aim + wind-up geometry, and dispatch guards/throttle are covered (`tests/unit/ai/`). `PhaseCoordinator`, `SlotSwapCoordinator` host paths, and `decode_for_replay` are covered. Domain rules remain well-covered.

- **Steam ownership validation on lobby join (anti-piracy) — post-launch, only if it manifests:** Online runs on Steam P2P under the real AppID (4892600), and Steam blocks `steamInitEx` for accounts that don't own the app — so a pirate / self-compiled build **cannot init under 4892600 and cannot join the legitimate playerbase.** It *can*, however, init under Spacewar (480, universally owned) and run a parallel pirate-vs-pirate scene in the 480 lobby space (degraded: 480 lobbies are global shared noise filtered only by metadata). The init-time AppID gate protects *our* lobbies; it does not prevent a separate pirate ecosystem. If that parallel scene ever becomes a visible problem, the host (already authority) can require each joiner to present a valid Steam auth session ticket (`GetAuthSessionTicket` / `BeginAuthSession`, `UserHasLicenseForApp`) proving ownership of 4892600 before admission — closing even AppID-spoofing. Belt-and-suspenders, not load-bearing for the legit community; defer until post-launch and only if it actually surfaces.

**UX / input experiments, smaller scope:**
- **Locked-mouse aiming mode (settings option):** An optional input mode that keeps the cursor pinned near the skater instead of free-roaming to the window edges — the cursor (and therefore the blade target) stays within a bounded radius of the player and recenters as they skate, so aim never drifts to a far corner of the screen. Would sit next to the existing "Confine Cursor to Window" input option (`PlayerPrefs.confine_mouse`). Implementation needs a capture-relative motion path — accumulate `InputEventMouseMotion.relative`, clamp the virtual aim point to a radius around the skater's screen position, and warp the OS cursor back each frame — rather than reading the absolute OS cursor position the way `local_input_gatherer._get_mouse_world_pos` does today. Floated as a feel experiment by a playtester; not scoped yet.

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

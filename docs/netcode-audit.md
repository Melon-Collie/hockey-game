# Netcode Audit — July 2026

An adversarial, implementation-level audit of the online play stack against an
"AAA netcode" bar (Overwatch / Rocket League / CS2-class expectations), per
request. Scope: clock sync, transport, wire format, host pipeline, lag
compensation / claims, prediction + reconcile, interpolation/smoothing,
fairness/anti-cheat, and performance of the networking hot paths. Out of scope
by request: the absence of a dedicated headless host (already planned).

Files read end-to-end: `network_manager.gd`, `clock_sync.gd`,
`state_buffer_manager.gd`, `lag_comp_rewind.gd`, `snapshot_event_log.gd`,
`buffered_state_interpolator.gd`, `reconciliation_rules.gd`,
`world_state_codec.gd`, `network_sim.gd`, `input_state.gd`,
`pickup_claim_resolver.gd`, plus the prediction/interp sections of
`local_controller.gd`, `remote_controller.gd`, `puck_controller.gd`,
`goalie_controller.gd`, and the relevant `game_manager.gd` wiring.

---

## Verdict

The architecture is genuinely strong — several subsystems are at or above what
big-budget titles ship (see "What clears the bar" below). The gaps are not in
the design philosophy; they are in **implementation drift from that design**
(the flagship one: the client-side poke/stick-lift claim path is dead code —
F1), **the time-sync foundation** (sparse, reliable-channel NTP on a 1 ms
clock), **a handful of cross-path races and silent failure modes**
(claim-vs-present-time pickups, silently rejected claims), **one tick of
shaveable pipeline latency**, and **scaling headroom** (120 Hz full-snapshot
unicast will strain a residential 5v5 host). None of these are rewrites; all
are addressable incrementally.

---

## Status (updated as fixes land on this branch)

- **Fixed — Phase 0:** D2's telemetry half (`claim_stamp_rejects` counter +
  session column; NACK still pending, Phase 2), B4 (reorder guard), C3
  (input-timer clamp), F7 (sub-tick remainder clamp), F8 (local-pin validity
  guard).
- **Fixed — Phase 1:** F1 (client carrier view; poke/stick-lift claims live
  again, carry-long pickup-claim spam gone), F2 (`is_ghost` in
  `sample_state_at`), F3 (offside carrier exemption via `has_puck`), F4
  (prediction history re-recorded during replay), F5 (replay seeded from the
  ack-time shot state).
- **Fixed — Phase 2 (PROTOCOL_VERSION 40):** D1 (present-time pickups now
  stamp-arbitrate against a pending claim via
  `PickupClaimResolver.arbitrate_present_grab`), D2's NACK
  (`notify_pickup_claim_rejected` — every no-grant pickup-claim outcome rolls
  the optimistic pin back ~one-way after the reject), D3 (host-ping seed on
  join), D4 (per-peer claim + input-batch rate caps).
- **Fixed — C1+C2:** capture + broadcast moved to an end-of-tick hook
  (`PostPhysicsNetHook`, physics priority 2): each snapshot now ships this
  tick's fully-integrated state the tick it was simulated (~8.3 ms off every
  client's world view), the velocity/position phase mix is gone, and the
  label skew the input-lead servo was padding over is removed (expect
  `input_lead_ms` to relax by ~a tick).
- **Open:** A1–A4 (clock foundation), B1–B3 (channels / replay-event
  packing / 5v5 bandwidth), E1–E3, F6, F9–F11.

## What clears the AAA bar (calibration — don't touch these)

- **Trajectory-comparison reconcile** with prediction history keyed by input
  stamp, stale-ack gating, and miss classification. This is the correct
  design; most shipped games compare against the live position and eat the
  false-positive churn.
- **Render == rewind discipline** via `LagCompRewind` as the single time-base
  seam, with per-entity self-view/remote-view perspectives. The invariant is
  documented, enforced, and test-pinned. This is better-structured than most
  production lag comp.
- **Client-authoritative blade with reach + continuity clamps** — exactly the
  usercmd-aim model AAA FPS lag comp uses, with two layered physical bounds
  instead of trust.
- **`SnapshotEventLog`** — redundant carrier events on every unreliable
  snapshot with a seq watermark deduping the reliable backstop. This is the
  Quake-3-style "events ride the stream" pattern; most indie netcode never
  gets here.
- **Host-measured RTT** backing claim-stamp plausibility (client can't forge
  its ping), bounded claim-carried interp delay and input lead.
- **Adaptive input-lead servo** measured from ack-overdue with zero extra wire
  bytes. Clever and correctly separated from the NTP offset.
- **PDV (de-clumped) jitter cushion** distinguishing relay clumping from path
  jitter — a real insight most netcode never encodes.
- **u32 0.1 ms wire timestamps** (constant precision over session length),
  quantized compact wire format under MTU, 12-frame input redundancy with
  loss-adaptive doubling.
- **Protocol + Steam-build gates** at join; coercion-only attribute
  validation; unit tests on the netcode primitives (`test_clock_sync`,
  `test_lag_comp_rewind`, `test_snapshot_event_log`, claim resolvers, codec,
  reconcile rules).
- **Telemetry** (F3 decomposed latency budget, F4 felt-lag markers, per-match
  host+client Supabase join) — better observability than many live-service
  titles.

---

## Findings

Ordered by expected impact on "buttery smooth online," most impactful first.
Severity: **H** = will visibly hurt feel or fairness in real matches,
**M** = measurable degradation or latent bug, **L** = polish/hardening.

### A. Clock sync is the weakest foundation everything else stands on

Every subsystem — interpolation render time, PDV cushion, claim stamps, input
lead, lag-comp rewinds — keys off `estimated_host_time()`. The current clock:

- **A1 (H). Clock-sync ping/pong rides the reliable channel.**
  `send_ping` / `receive_pong` are `@rpc(..., "reliable")`
  (`network_manager.gd:1272,1284`). A retransmitted ping/pong, or one queued
  behind other reliable traffic (goal events, `notify_replay_event`
  Dictionary bursts, faceoff positions — all share channel 0), inflates the
  RTT sample and skews the offset by half the added delay. The host's own
  `host_ping`/`host_pong` are correctly unreliable — the asymmetry looks like
  an oversight. Timing probes must be unreliable; a lost probe should be a
  skipped sample, not a poisoned one.
- **A2 (H). Cadence is too sparse to track a changing path.** 3 warmup pings
  at 0.5 s then one every 2 s, over an 8-sample window
  (`clock_sync.gd:3-6`) — the window spans ~16 s of history and the
  post-ready EMA (α=0.3 per pong at 0.5 Hz) needs ~6 s to move 63 % toward a
  new offset. Wi-Fi/relay path changes mid-match will leave the clock (and
  therefore render timing, claim stamping, PDV floor) wrong for seconds.
  AAA-style fix that costs almost nothing here: the world-state stream
  already carries a host capture stamp at 120 Hz, and `_record_packet_delay`
  already computes per-packet delay against it. Use that dense one-way stream
  to servo the offset (drift/steady-state), keeping the sparse RTT pings only
  to calibrate path asymmetry — and raise the ping rate during the first ~2 s
  (e.g. 10 pings at 100 ms) so the match doesn't start on a 3-sample clock.
- **A3 (M). The whole time base is 1 ms-grained under a 0.1 ms wire format.**
  `local_time()` and `ClockSync` are built on `Time.get_ticks_msec()`
  (`network_manager.gd:512`, `clock_sync.gd:114`). At a 8.33 ms tick, 1 ms
  quantization is 12 % of a tick riding on every capture stamp, PDV sample,
  ack-overdue measurement, and jitter estimate — it inflates the Jacobson dev
  terms (and therefore the interp cushion and lead servo) with pure
  quantization noise. `Time.get_ticks_usec()` is a drop-in; the 0.1 ms wire
  grid then actually carries information.
- **A4 (M). Offset corrections are steps, not slews.** Post-ready corrections
  apply up to 30 % of the error instantly, and the monotone floor in
  `estimated_host_time()` (`clock_sync.gd:113-116`) handles a downward
  correction by *freezing* time until real time catches up — during which
  every interpolator's `render_time` stalls (a visible hitch on all remote
  actors at once). The AAA pattern is a slew-limited clock: bound the rate at
  which `estimated_host_time()` may deviate from real elapsed time (e.g.
  ±2 ms per second), so corrections smear invisibly instead of stepping or
  freezing.

### B. Transport: everything shares one channel; one stream is fat

- **B1 (M).** No RPC in the project sets `transfer_channel` — all reliable
  traffic (carrier backstops, goals, faceoff positions, stats, replay
  events, clock pongs) serializes through channel 0. One lost reliable
  packet head-of-line blocks every other reliable stream for a retransmit
  RTT. `SnapshotEventLog` already rescues the carrier events; nothing rescues
  the rest. Split channels by concern (time-sync, game-flow events, cosmetic
  replay mirroring) — Godot supports per-RPC channels natively.
- **B2 (M).** `notify_replay_event` broadcasts a **Dictionary per gameplay
  event** (shots, pickups, board hits, body checks…) reliably to every peer
  (`network_manager.gd:1532-1543`). Variant-encoded Dictionaries with string
  keys are the fattest encoding in the codebase and it rides the same channel
  as everything else (see B1). Pack it (the event set is small and enumerable)
  or at minimum move it to its own channel — a cosmetic replay stream should
  never be able to delay a carrier-change backstop or a clock pong.
- **B3 (M). 120 Hz full-snapshot unicast has no scaling headroom for 5v5.**
  Per client: ~385 B payload (3v3) → ~575 B (5v5) + ~50 B UDP/SDR overhead at
  120 Hz ≈ 52–75 KB/s. A full-human 5v5 (9 remote peers) puts the host at
  **≈ 5.4 Mbps sustained upload** plus ~2.4 Mbps of inbound input batches.
  On a residential uplink (and through Steam Datagram Relay's default rate
  limiting) that's where the "mystery clumping" the PDV cushion fights will
  actually come from. Options, in increasing effort: (a) verify/raise
  `k_ESteamNetworkingConfig_SendRateMin/Max` on the peer; (b) drop
  `STATE_RATE` to 60 (the machinery exists — `set_broadcast_rate` — and the
  cost is one +8.3 ms step in the interp cushion; note the client jitter
  estimator's `expected_interval` hardcodes `1/STATE_RATE` and must follow);
  (c) delta-compress or LOD the goalie pose block (31 B of pose × 120 Hz per
  goalie is the biggest single line item after skaters). Measure (a)/(b) on
  real 5v5 lobbies before shipping the mode as default.
- **B4 (L).** `_on_ws_sequence_received` (`network_manager.gd:2271-2276`)
  computes loss as `(seq - last - 1) mod 65536`; a duplicated or reordered
  packet that somehow reaches the handler counts as ~65 k drops for that
  window. The real transport (`unreliable_ordered`) filters these today, but
  the dev `NetworkSimManager` reorders deliveries (independent per-packet
  jitter with no ordering for unreliable sends), so loss telemetry under the
  sim can read absurdly high and double the input batch size via the
  `> 10 %` gate. Guard `gap > 32768` → treat as reorder, count zero.

### C. Host pipeline: one tick of shaveable latency

- **C1 (M).** Capture + broadcast run in `GameManager._physics_process`
  (autoload, priority 0), which executes **before** the scene's
  `Skater.move_and_slide` (priority 0, tree-after-autoloads) and the puck
  step (priority +1). So the packet that leaves at tick N carries the
  positions produced by tick N−1 — every tick's sim result waits ~8.3 ms
  before departure. Broadcasting from a post-physics hook (a node with
  `process_physics_priority = 2`, after `PuckController`'s +1) ships each
  tick's result the same tick, cutting ~8.3 ms off every client's view of
  the world *and* off the measured ack-overdue that the input-lead servo is
  currently compensating (the playtest's "pops 25–40 ms overdue" plausibly
  contains this tick). The existing comment ("broadcast reads this tick's
  state") is true relative to `NetworkManager`'s ordering but not relative
  to the actors.
  Caveat if you do this: the reconcile pipeline is phase-consistent today
  (client prediction snapshots are taken post-move via
  `skater.post_move_integrated`, and host capture reads post-move positions
  of the prior tick) — moving the capture point keeps that consistency
  *only* if capture still happens after `move_and_slide` for the same tick,
  which the priority-2 placement gives you. Re-verify one skater's
  ack-compare telemetry (`reconcile_match %`) after the move.
- **C2 (L).** At capture time, `SkaterController` (priority −1) has already
  run for the *current* tick, so captured skater velocity can be one tick
  ahead of captured position (mixed-phase sample). Clients use that velocity
  as the Hermite derivative at the position sample. Sub-centimetre effect,
  disappears entirely with the C1 move.
- **C3 (L).** The client input pump lives in `_process`
  (`network_manager.gd:914-930`): send cadence degrades to render rate below
  120 fps (the servo absorbs the latency, but it's latency), and
  `_input_timer` only subtracts one `input_delta` per frame while
  accumulating unboundedly — after a long sub-120 fps stretch, a recovered
  client will send one batch *per render frame* (e.g. 240 Hz at 240 fps) for
  minutes until the backlog drains. Clamp the timer
  (`_input_timer = minf(_input_timer, input_delta)` after the send).

### D. Fairness: two real gaps in the claims system

- **D1 (H). The present-time pickup path silently beats a pending client
  claim.** While a client's pickup claim sits in the 50 ms contest window
  (`PickupClaimResolver.tick`), the host's present-time
  `_check_interactions` (`puck_controller.gd:434+`) can grant the puck to any
  host-live blade — the host player's own, or a remote's replayed one — via
  `puck.set_carrier`, after which `_on_server_puck_picked_up_by` calls
  `_pickup_claim.clear()` (`game_manager.gd:2625`) and the pending claim is
  discarded **without comparing stamps**. The squirt *resolution* is shared
  between the two paths (per CLAUDE.md), but the cross-path *contest
  detection* doesn't exist: claim-vs-claim races are stamp-arbitrated,
  present-vs-present races are contested same-tick, but claim-vs-present
  races always go to the present-time blade. Net effect: in tight scrambles
  the host player (and, second-order, whoever's replayed inputs land
  first) wins 50/50s that stamp-fairness says they should contest. Fix
  shape: before a present-time grant, check the resolver for a pending claim
  whose stamp is within `CONTEST_WINDOW_S` of now-minus-one-way (or simply:
  of the present grab's capture time); if so, route through
  `apply_contested_pickup` with the live kinematics vs the stored rewound
  ones — the machinery already exists on both sides.
- **D2 (M). Rejected claims are invisible — to telemetry and to the player.**
  `is_claim_stamp_plausible` failures return silently at the RPC boundary
  (`network_manager.gd:1383,1400,1417,1433`). The plausibility bound is the
  host's **EMA** ping (α=0.3 at a 2 s cadence — ~6 s to track an RTT ramp),
  plus 100 ms slack; a genuine RTT spike mid-match means several seconds
  where a legitimate claim's stamp reads as "too old" and is dropped with no
  `NetworkTelemetry` record and no NACK — the client's provisional pin just
  times out ("I reached the puck and nothing happened", indistinguishable
  from a loss). At minimum record a counter per rejection site (the
  session-telemetry pipeline is already there); ideally also send a NACK so
  the provisional pin can roll back immediately instead of waiting for the
  RTT-scaled deadline, and raise the host-ping cadence (A2 helps here too —
  the same probe stream can serve both).
- **D3 (L).** Warmup gap: the host's first RTT sample for a peer lands ~2 s
  after join (`_PING_INTERVAL`), during which claims validate against the
  conservative 150 ms default. Send a burst of host pings immediately on
  `peer_joined` rather than waiting for the timer.
- **D4 (L). No rate limiting on claim RPCs or input batches.** Each pickup
  claim costs the host two `get_state_at` world-snapshot reconstructions
  (allocating interpolated states for every actor); `receive_input_batch`
  will decode up to 120 inputs per packet at whatever rate a modified client
  sends. Steam's relay throttles eventually, but a per-peer claims/sec cap
  and an input-batch rate cap are cheap insurance for the host's tick
  budget.

### E. Allocation churn in the per-packet hot path

- **E1 (M).** The codec violates the project's own hot-path discipline at
  120 Hz. Encode (`world_state_codec.gd:102-152`): fresh header/id
  `PackedByteArray`s plus a per-skater buffer from `_encode_skater_quantized`
  every broadcast. Decode (client, 120 Hz): `data.slice()` per actor, a new
  `SkaterNetworkState`/`PuckNetworkState`/`GoalieNetworkState` per actor per
  packet, plus a `BufferedGoalieState`/`BufferedSkaterState`/… wrapper per
  buffer insert — order of ~1,500–2,000 heap objects/sec on a client during
  normal play, i.e. steady GC pressure on the machine whose frame stability
  the interpolation depends on. The packet buffer itself must be fresh
  (COW into the replay recorder), but everything else can be scratch: encode
  straight into the outgoing buffer at offsets (the quantize helpers already
  take offsets), and decode into per-slot reused state objects (the snapshot
  buffers are rings of fixed peers; `StateBufferManager` already demonstrates
  the pattern host-side).
- **E2 (M/L). Same churn at the buffer-intake seams.**
  `PredictedState.new()` + `InputState.new()` per tick on the client
  (`local_controller.gd:374`, `local_input_gatherer.gd`), a fresh slice per
  input-batch send, a Dictionary literal **and** a `sort_custom` lambda per
  incoming input batch per peer on the **host**
  (`remote_controller.gd:123-139` — the queue is nearly sorted; an insertion
  pass allocates nothing), and `BufferedSkaterState`/`BufferedPuckState`/
  `BufferedGoalieState` wrappers per snapshot per actor. All poolable; the
  fixed buffer caps make rings trivial. The inner interpolation/prediction
  loops themselves are exemplary — the churn is concentrated at intake.
- **E3 (L).** `get_jitter_p95()` duplicates + sorts per call — already
  mitigated by the per-physics-frame cache; fine. The 40-sample window
  (~0.33 s) makes the p95 twitchy and the first packet after a broadcast
  pause (goal replay, intermission) records a giant "gap" sample that
  poisons the window briefly. Cosmetic (the cushion uses PDV, not this), but
  it's the number people will screenshot — skip gap samples when
  `_replay_mode` was just active or gap > 1 s, mirroring the host's
  broadcast-interval guard.

### F. Client-side prediction & reconcile

(Findings surfaced by a dedicated pass over `local_controller.gd`,
`remote_controller.gd`, `puck_controller.gd`; each item below was re-verified
against the code before inclusion.)

- **F1 (H). The client-side poke / stick-lift claim path is dead code, and
  clients spam pickup claims while carrying.** On clients, `puck.carrier` is
  never set: every `puck.set_carrier()` call site is host-only
  (`puck_controller.gd:280,540`, `game_manager.gd:3057`); the client carrier
  paths (`notify_local_pickup` / `notify_remote_pickup`) set only the
  controller-internal `_local_carrier_skater` / `_remote_carrier_skater`,
  and `_carrier_peer_id` is written only in host-connected signal handlers.
  So in `LocalController._physics_process` (`local_controller.gd:267+`), the
  `if puck.carrier == null` branch is *always* taken on clients:
  - `send_poke_claim` / `send_stick_lift_claim` (`:350,:356`) are
    unreachable — `PokeClaimResolver` and `StickLiftClaimResolver` never run
    in live play. Pokes and stick-lifts work online only via the host's
    present-time `_check_interactions` against the checker's replayed blade.
    Today the *practical* aiming penalty is masked because
    `REMOTE_FORWARD_PREDICT_FRACTION = 1.0` renders carriers at
    ~host-present — but the moment that dial moves toward 0.5/0.0 (the
    documented fallback if overshoot reads badly), stick battles lose their
    lag comp entirely, silently. The claim architecture, its wire format,
    its resolvers and their tests are all built and inert.
  - While the local player carries, the pinned puck sits ~0 m from the blade,
    so the pickup-claim branch re-fires a reliable claim RPC every
    `_CLAIM_COOLDOWN_S` (0.3 s) for the whole carry — each one host-rewound
    and rejected (`PickupClaimResolver` line 101 `carrier != null` gate).
    Wasted reliable-channel traffic + resolver work, forever.
  - ARCHITECTURE's invariant "`_carrier_peer_id` is managed exclusively by
    carrier events on clients" describes wiring that does not exist — nothing
    on a client writes it at all. Here the **code** is the bug, not the doc:
    wire the carrier events (`remote_carrier_changed` etc., which already
    arrive redundantly via `SnapshotEventLog`) into a client-side carrier
    reference the claim gate can read.
- **F2 (H). Reconcile replay body-checks ghosted skaters the host ignored.**
  `RemoteController.sample_state_at` (`remote_controller.gd:287-314`) fills
  its scratch with only position / velocity / `brake_intent` /
  `hit_committed`; `GameManager._sample_historical_others`
  (`game_manager.gd:~4414`) then reads `state.is_ghost` — permanently the
  constructor default `false` — so `_replay_resolve_body_checks`' ghost gate
  never skips anyone. A local player overlapping a ghosted (offside)
  opponent gets separation + impulses in every replay that the host (and
  the client's own live tick) never applied → replayed trajectory diverges
  from authority → reconcile snap-loop for as long as the overlap persists,
  precisely at the blue line where ghosts and traffic cluster. The buffered
  `SkaterNetworkState` already carries `is_ghost`; copy it in both branches
  of `sample_state_at` (two lines).
- **F3 (M). Local offside prediction never sees the carrier exemption.**
  `_predict_offside` (`local_controller.gd:~838`) and the reconcile
  un-ghost hold-back (`:395`) both compute
  `is_carrier = puck.carrier == skater` — always false on clients (see F1).
  A client carrying the puck across the blue line with the body leading the
  blade self-ghosts, and the hold-back then *refuses the server's
  authoritative un-ghost* while the same wrong geometry holds. While falsely
  ghosted, all claims are gated off and body collision prediction is
  skipped. One-token fix: the controller already has `has_puck`.
- **F4 (M). Prediction history is not re-recorded during replay — one real
  divergence buys ~an RTT-window of redundant reconciles.** The replay loop
  (`local_controller.gd:571-596`) corrects the live body but the history
  capture only runs on `skater.post_move_integrated`, which never fires
  during replay (replay integrates manually). The stale pre-correction
  `PredictedState`s for the still-unacked span stay in `_prediction_history`,
  so each subsequent advanced ack in that window re-trips
  `skater_needs_reconcile` and re-runs a full save/snap/replay/restore
  (~12 redundant reconciles at 100 ms RTT), inflating the very
  `reconcile_per_sec` telemetry used to judge link health. AAA practice
  re-records the replayed states so one divergence costs one correction.
- **F5 (M). Replay runs unacked inputs under the *live* shot-machine state,
  not the state at ack time.** The pre-replay save (`:500`) captures the
  live `_sm` state and the loop replays all inputs under it (restored
  after) — so a replay window spanning a shot transition replays the
  pre-release ticks in the wrong movement branch (facing freeze /
  follow-through damping vs. aim), producing a slightly-wrong correction at
  exactly the shot moments the three reconcile guards show the design cares
  about. `PredictedState` already records `shot_state` per tick; it is never
  used to seed the replay.
- **F6 (M/L). Remote skater bodies still run full physics every tick, then
  get overwritten.** `Skater._physics_process` runs `move_and_slide()` +
  `_resolve_player_collisions()` unconditionally (`skater.gd:686-693`);
  controllers are spawned as *siblings after* the skater
  (`actor_spawner.gd:124-126`), so on clients the interpolator overwrites
  the moved position each tick and the work is discarded. Costs: wasted
  per-tick physics on every remote body (×120 Hz), and
  `body_check_impulse_applied` emissions sourced from interpolated state
  (side-effect channel worth auditing). Note the direction matters: because
  the controller runs *after* the body, this is waste rather than the
  render-lead that would break render == rewind — but gate it explicitly
  (`set_physics_process(false)` on remote-driven skaters, or an `is_local`
  gate around the move) so the invariant holds by construction, not by tree
  order.
- **F7 (L). `_run_prediction`'s sub-tick remainder skips the clamps.**
  `pos += vel * frac` after the whole-tick loop
  (`puck_controller.gd:954-955`) bypasses the step's board/goal clamps — a
  30 m/s predicted puck can render up to ~25 cm past a board plane for a
  frame on approach. The one un-clamped write in an otherwise
  contained-by-construction pipeline.
- **F8 (L).** The local-carry pin dereferences `_local_carrier_skater`
  without `is_instance_valid` (`puck_controller.gd:237-240`); the remote and
  provisional pins both guard. A despawn/demote racing the carrier-drop
  notification hits a freed object.
- **F9 (L).** A sub-one-way wrister tap can have its `FOLLOW_THROUGH`
  cancelled by a concurrent position reconcile: the guard set protects
  against server `WRISTER_AIM`/`SLAPPER_CHARGE_WITH_PUCK`, but a snap shot
  released before the host saw the *press* arrives as
  `SKATING_WITH_PUCK` and overrides mid-swing (visible blade pop). Narrow
  window; needs a threshold trip in the same frame.
- **F10 (M — tuning, not a bug). `REMOTE_FORWARD_PREDICT_FRACTION = 1.0`
  ships maximum aggressiveness on an experimental system.** Full-delay
  intent integration renders remote skaters at ~host-present; every hard cut
  is an overshoot the SmoothDamp must eat. Watch `extrapolation_pct` /
  hit-feel telemetry from real links before locking 1.0; 0.5 is the safer
  default — but note F1's masking effect above before dialing it down.
- **F11 (L).** `estimated_host_time()` returns `0.0` before clock-ready;
  every consumer must guard via `is_clock_ready()`. Current consumers do;
  consider a monotonic local fallback so future consumers fail gracefully by
  construction.

### G. Doc/code drift (fixed on this branch where the doc was the stale side)

Fixed in the audit commits:

- `world_state_codec.gd` header ("f32" → u32 capture time; skater offset map
  missing knockdown/intent bytes); `input_state.gd` layout ("f32 timestamp"
  → u32 @0.1 ms); `network_manager.gd` `update_lobby_attributes` (referenced
  the removed v3 point-buy budget).
- ARCHITECTURE.md → Networking Invariants: "Two symmetric guards" → three
  (the `SLAPPER_CHARGE_WITHOUT_PUCK` guard was undocumented); the
  mouse-position-seeding invariant described deleted machinery (superseded
  by the swing-state save/restore); "the resolvers send
  `get_target_interpolation_delay()`, the full value" — the code
  deliberately sends the **adapted** `get_interpolation_delay()`.
- `local_controller.gd` visual-offset decay comment claimed dilation
  compensation that Godot's constant physics delta makes a no-op.

**Deliberately NOT doc-fixed** (the code is the bug, doc states the intended
design): "`_carrier_peer_id` is managed exclusively by carrier events on
clients" and `local_controller.gd`'s "reliable-RPC-managed on clients"
comment — see F1.

---

## Priority order

1. **F1** — wire the client-side carrier reference from the carrier events
   (per the doc's own stated design). Resurrects the entire poke/stick-lift
   lag-comp path, stops the carry-long claim spam, and unblocks F3.
2. **F2** — copy `is_ghost` in `sample_state_at` (two lines) to kill the
   ghost-overlap reconcile loop.
3. **A1+A2+A3** — rebuild the clock's inputs: unreliable probes, denser
   warmup, µs time base, snapshot-stream-assisted offset. Everything else
   inherits the improvement.
4. **D1** — stamp-arbitrate claim-vs-present-time pickups. It's the fairness
   hole players will actually feel (and attribute to "host cheats").
5. **C1** — post-physics broadcast: ~8.3 ms off every client's world view,
   essentially free.
6. **D2** — make claim rejections observable (telemetry + NACK); the F4
   telemetry pipeline is already built for exactly this.
7. **F4+F5** — re-record prediction history during replay and seed replay
   from the ack-time shot state, so one divergence costs one correction.
8. **E1 + F6** — de-allocate the per-packet hot path and stop simulating
   remote bodies; client frame stability is part of perceived netcode
   quality.

Then B3 (measure 5v5 host upload on real links) before 5v5 ships as a
default online mode.

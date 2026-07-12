# Codebase Audit — Netcode + Bot Systems (July 2026)

Deep adversarial audit of the networking stack (transport / clock / interpolation /
prediction / reconcile / lag compensation) and both bot systems (skater agents,
goalie). Method: ARCHITECTURE.md and CLAUDE.md were treated as *claims to verify*,
not truth — four independent audit passes read every in-scope file in full, then
every high-severity finding was re-verified by a second read of the cited code
before inclusion. Baseline: full GUT suite green (1250/1250, 17 s) with all of the
bugs below present — they live in controller/serialization glue and the AI state
handlers, exactly the layers the suite doesn't cover.

Severity legend: **P0** ship-breaking for a documented mechanic · **P1** materially
wrong behavior or defeated security property · **P2** wrong constant / degraded
mechanic · **P3** latent, cosmetic, or hygiene.

---

## P0 — Critical

### 1. `stagger_timer` is documented as replicated but is not in the wire format
`Scripts/game/world_state_codec.gd:382-449` · `Scripts/controllers/local_controller.gd:444-447` · `Scripts/controllers/skater_controller.gd:597-601`

The quantized 38-byte skater block ends at `stamina` (offset 37). `stagger_timer`
exists on `SkaterNetworkState` (and in the replay-file array path), but the codec
never encodes it — so every decoded server state carries `stagger_timer = 0.0`.
Reconcile then does exactly what the docs promise:

```gdscript
# local_controller.gd:444-447 — "snap to the server value, then re-derive"
stagger_timer = server_state.stagger_timer   # ← always 0.0 off the wire
```

Failure: a client player absorbs a hard check; the client-side prediction
(`_on_body_check_received`) starts the stagger, but the check guarantees a
reconcile within ~one broadcast, which wipes the timer. The client then predicts
at full thrust while the host simulates up to −50% thrust for up to a second →
sustained divergence, a reconcile storm for the stagger duration, visible
rubber-banding — and the client player never *feels* the debuff. CLAUDE.md's
"replicated as `stagger_timer`, snapped and re-derived through reconcile" is false
on the live wire. The codec test round-trips stamina but never stagger, which is
how this shipped.

**Fix:** add a u8 quantized-seconds stagger field to the skater block, bump
`PROTOCOL_VERSION`, extend `test_world_state_codec.gd` to round-trip it (and any
future `SkaterNetworkState` field — consider a completeness assert).

### 2. Goalie reaction delays are zeroed whenever the goalie is not upright — instant saves in exactly the documented scoring windows
`Scripts/controllers/goalie_controller.gd:1040-1046` vs `:2066-2074` · `Scripts/controllers/goalie_shot_reaction.gd:60-74`

`_on_puck_released` was deliberately changed to start shot reactions from
BUTTERFLY / SLIDING / RECOVERING (the comment at :2069-2073 explains the old
`is_upright()` gate dropped those reactions entirely). But `_update_state` runs
every host tick and does:

```gdscript
if not _sm.is_upright():
    _reaction.shot_timer = 0.0
    _reaction.arm_timer = 0.0
```

`arm_timer` is the countdown *before* the glove/blocker reach engages
(`arm_reaction_delay + read_delay − back_date`). Zeroing it within one tick of
`start()` skips the arm reaction delay, the screen delay, the caught-moving
penalty, and the lag-comp back-date semantics for any reaction that begins while
the goalie is down or recovering. A reaction started during RECOVERING also
re-enters READY with `shot_timer` pre-zeroed, so the butterfly re-drop fires with
zero read delay. Net effect: rebound putbacks and shots against a down/moving
goalie — the situations CLAUDE.md/ARCHITECTURE name as the beatable windows —
face a *faster* goalie than a set one, and the `arm_reaction_delay_s` /
`move_read_max_delay_s` difficulty levers do nothing there.

**Fix:** the comment at :1041-1043 says the intent was to stop a *returning*
transition from instantly re-firing butterfly — that wants clearing on specific
state *transitions* (or only clearing `shot_timer` when no reaction is active),
not per-tick zeroing of both timers while down.

---

## P1 — High

### 3. Bot wrister wind-up handedness is inverted — bots charge every wrister/pass on the backhand
`Scripts/ai/skater_agent_state_machine.gd:2009-2010, 2130-2139, 884-888` vs `Scripts/controllers/skater_controller.gd:1044-1045` and the same SM file's own `:1576-1582`

The wind-up perpendicular is
`Vector3(aim_dir.z * s, 0, -aim_dir.x * s)` with `s = +1` for right-handed. For
aim `(0,0,−1)` that is `(−1,0,0)` — the skater's **left**. Every other convention
in the codebase defines RH forehand as the **right** (+X local): the release
classifier (`is_backhand ⟺ blade_local_x < 0` for RH), the top-hand marker
layout, and `_try_shot_reception` in the same file, whose comment even states
"RH forehand = −left_dir" — the exact negation of the wind-up formula.

Consequences: (a) bot charged wristers are classified backhand and pay
`backhand_power_coefficient` (~0.75) — the planner, goalie-slide prediction and
lane windows all assume full `WRISTER_SHOT_SPEED_M_S`; (b) charged passes launch
at ~75% of the speed the pass-lead solver used, so long bot passes systematically
arrive behind cutting receivers; (c) the defender-driven side flip
(:2016-2032) is inverted with it — a defender on the real backhand side flips the
wind-up onto the real forehand, the opposite of its intent.

**Fix:** negate `_handedness_perp_sign` (or the formula) and align the in-file
comment at :884-888, which currently contradicts both the formula and the rest of
the codebase.

### 4. AI dispatch throttle decrements physics-tick-sized counters at dispatch rate — every "brief" window stretches 2–9×
`Scripts/ai/skater_agent_state_machine.gd:1119-1127` (skip path) vs `:295-330` (constants sized in physics ticks), `:919-920`, `:2848-2855`, `:2969-2975` · `Scripts/domain/ai/role_behaviors/carrier.gd:177-181`

Non-press state handlers run once per `_dispatch_period_ticks` (2 Hard / 6 Normal
/ 9 Easy); skipped ticks replay the cached move vector and return at :1126. But
the poke-evade / poke-jab windows, the pre-aim bail timeout
(`_intent_max_wait_ticks`, computed from arc rate in *physics* ticks + 60), and
`AIRoleCarrier`'s re-eval cadence all count once per handler run while being sized
in physics ticks (`PHYSICS_TICK * 3 / 20  # ~150 ms`). At Normal/Easy: the 150 ms
evade cut becomes a 0.9–1.35 s right-angle sprint; the ~80 ms defensive jab
becomes ~0.5–0.7 s of stick-on-puck (the exact "sticky/cheap" feel the design
comment forbids); a non-converging pass pre-aim leaves the carrier braked and
holding the puck for ~6.5–11 s instead of ~0.5 s; the carrier's "~30 Hz" re-eval
runs at 4 Hz (Normal) / 2.7 Hz (Easy) and the hold-decay clock advances up to 11×
slower than designed. Much of "lower-difficulty bots feel weird" likely traces
here rather than to the intended pace knobs.

**Fix:** decrement these counters by `_dispatch_period_ticks` per handler run (or
convert them to seconds accumulated from real delta).

### 5. Lag-comp rewind ignores the interpolation lead — the host validates against a view clients no longer render
`Scripts/game/lag_comp_rewind.gd:66-67` vs `Scripts/controllers/puck_controller.gd:32, 795-797` and `Scripts/controllers/remote_controller.gd:8, 180-181` · claims at `Scripts/controllers/local_controller.gd:246-297`

Since the lead landed, clients render remote skaters and the loose puck at
`estimated_host_time() − interp_delay × (1 − 0.5)` — only *half* the delay in the
past. Claims still send the **full** `get_target_interpolation_delay()`, and
`remote_view_time` subtracts all of it, so the rewound "puck the client was
actually rendering" is ~interp_delay/2 (≈35–40 ms baseline, up to 100 ms at the
clamp) older than the client's actual render. At pickup speeds that's ~0.3 m
against a 0.5 m `PICKUP_RADIUS`; larger for poke/hit claims on fast carriers.
Legitimate contacts on the led view can fail the rewound test and stale-view
contacts can pass. Secondary skew: claims report the *target* delay while
rendering uses the *adapted* delay.

**Fix:** report `get_interpolation_delay() * (1.0 − extrapolation_lead_fraction)`
in claims (per entity class if leads ever diverge), and update the
`LagCompRewind` doc-comment — its model description predates the lead.

### 6. The anti-timestamp-shopping check trusts client-self-reported ping
`Scripts/networking/network_manager.gd:1323-1325` · `Scripts/game/lag_comp_rewind.gd:39-50` · consumed at `network_manager.gd:1140/1155/1170/1185` and `ShotReleaseRules.clamp_rtt_ms`

```gdscript
@rpc("any_peer", "unreliable")
func report_ping(rtt_ms: int) -> void:
    _peer_ping_ms[multiplayer.get_remote_sender_id()] = rtt_ms
```

No clamp, no host-side measurement — yet `is_claim_stamp_plausible` documents
this as "the host's own ping measurement". A modified client reporting a large
RTT (or ≤0, which disables the past-bound entirely per lag_comp_rewind.gd:48-49)
re-opens the ~200 ms backdating window (`MAX_CLAIM_AGE_S`) that the check exists
to close — ARCHITECTURE.md itself notes backdating ~190 ms "wins essentially
every 50/50 puck". Impact is bounded by the 200 ms cap, but the documented
security property does not exist.

**Fix:** measure RTT host-side (the clock-sync ping/pong round-trip already
exists — stamp and measure at the host) or clamp `report_ping` against a
host-side measurement; never trust `rtt_ms ≤ 0` from the wire.

### 7. Reconcile replay reads live world state — determinism holes in `_process_input`
`Scripts/controllers/skater_controller.gd:959-964` (shot-block facing from live puck), `:1146-1149, 1179` (one-timer zone/leniency from live puck), `Scripts/controllers/skater_ik_coordinator.gd:378-399` (goalie blade clamp from live goalie data)

The replay loop re-runs `_process_input` per unconfirmed input, but these paths
read the puck/goalie at their *current* positions rather than the values at the
original predicted tick. Shot-block entry snaps `_pose.facing` toward the live
puck — facing drives `move_and_slide` for every subsequent replayed input and is
not restored after replay, so blocking near a moving puck re-trips the 0.05 m
threshold and reconciles repeatedly. One-timer branch decisions and near-goalie
blade clamps (which feed wrister charge distance) can likewise diverge in replay.
This caps how honest the tight thresholds can be.

**Fix:** snapshot the few live reads into `PredictedState` (puck pos/vel at tick,
goalie clamp inputs) or restore `_pose.facing` with the other saved fields.

---

## P2 — Medium

### 8. Cross-crease push drives the goalie to net-center, not the far post
`Scripts/controllers/goalie_controller.gd:1980-1982` · `Scripts/controllers/goalie_slide_behavior.gd:238-241`. The standing cross-crease drive target is clamped with the *splayed-butterfly* pad extent (`pad_local_offset + butterfly_pad_half_width = 0.84`), leaving `±0.075 m` of travel — the committed 0.5 s push T-pushes to ~goal center, *tighter* than the arc target it overrides. Back-door one-timers are easier than tuned, at every difficulty.

### 9. Goalie `rotation_y` clamps at ±π on the wire instead of wrapping
`Scripts/game/world_state_codec.gd:503`. The −Z goalie's base facing is π; `_update_facing` (goalie_controller.gd:1868-1877) produces raw angles up to ~4.36 rad, which clamp to exactly π on encode. Clients (and the shot-release goalie rewind, which consumes `gs.rotation_y`) see that goalie stuck facing straight out whenever it turns one direction; the +Z goalie is unaffected. **Fix:** `wrapf` before encode.

### 10. Glove/blocker pose offsets clip at ±1.27 m while reach targets go to 1.55 m
`world_state_codec.gd:492, 565-569` (s8@1cm) vs `goalie_controller.gd:461` (`react_hand_y_max = 1.55`). Above-crossbar reaches render up to 28 cm low on clients and in replays — the same bug class already fixed for puck Y (s8→s16). The round-trip test only uses in-range values.

### 11. Body-check impulse replay: phase error + double-count window
`local_controller.gd:471-481` vs `skater.gd` collision resolve. Live, the transfer lands *after* `move_and_slide`; in replay it's added *before* that input's integration — ~5-7 cm displacement skew for a real check, at/above the 0.05 m threshold, so each hit buys at least one extra corrective reconcile. Separately, the client stamps the impulse with a led input timestamp; a broadcast acking a slightly earlier host resolve can import the hit in `server_state.velocity` *and* re-inject it in replay until trimmed — a small re-introduction of the oscillation the mechanism was built to remove.

### 12. FINISHER's blade lift strobes — `stick_lift_held` not cached across throttled ticks
`skater_agent_state_machine.gd:1119-1126` restores only move/sprint/mouse on skipped ticks, so `blade_up` is true 1-in-N ticks; the 12/s lift blend never reaches raised at Normal/Easy. `RoleDecision.lift_blade` (tip elevated shots) is effectively dead below Hard.

### 13. One-timer ready flag can pin a bot into a stall loop next to a loose puck
`skater_agent_state_machine.gd:1205-1210, 1234-1243, 2371-2373, 1433-1434`. The ready-preserve has no time bound and no "pass actually inbound" check (`carrier_peer_id == -1` keeps it alive), and the bot refuses to chase while ready — a dead pass leaves the trigger man frozen for the press budget, then a one-tick chase re-arms the same state.

### 14. Bot one-timers fire at ~minimum wrister power while the planner scores them at full power
`_state_one_timer_pressed` holds past `quick_shot_time`, so release takes the charged path with ~zero charge (`WRISTER_POWER_MIN` = 14 m/s, ×0.75 more on the backhand coin-flip), while carrier pass-scoring values the receiver's one-timer at 24 m/s (carrier.gd:581-596). The AI systematically overvalues one-timer feeds relative to what leaves the blade.

### 15. Hit crediting uses inconsistent impulse scales between host-local and claimed hits
`hit_claim_resolver.gd:150-169` (raw approach speed; comment assumes uniform weight 1.0) vs `game_manager.gd:1819-1821` (weight × approach). Since Size scales weight ±18%, remote-claimed hits by heavy players are held to a stricter bar than the identical host-side hit. Stats-only, but skews by build and by who hosts.

### 16. Contested pickups on the claim path resolve with present-time blade state
`pickup_claim_resolver.gd:159` → `puck_controller.gd:293-303`. The contest *verdict* uses rewound snapshots, but `apply_contested_pickup` reads blade velocity/positions at apply time (up to 50 ms contest window + RTT later), so the "stronger blade wins" bias is computed from kinematics neither player saw — and host-tick vs claim-path scrambles don't actually "resolve identically" as documented.

### 17. Client telemetry is structurally corrupted during 5 Hz dead-puck phases
`network_manager.gd:1073` assumes 8.3 ms expected interval while `set_broadcast_rate(5.0)` is host-only knowledge — every faceoff/celebration records ~192 ms "jitter" and near-constant extrapolation, flipping the F3 header to PROBLEM via "Guessing ahead" and polluting the Supabase session aggregates. The documented canary metric cries wolf on every whistle. (Related: dead-puck 5 Hz isn't in the Network Rates table.)

---

## P3 — Low / latent / hygiene

- **`SteamManager.leave_lobby()` on Nil at every app quit** — `network_manager.gd:630`; autoloads free in reverse init order, SteamManager (initialized after NetworkManager) is already gone in `_exit_tree`. Guard with `is_instance_valid`. Reproduced on every headless run.
- **u16 sequence-gap accounting explodes on reordered delivery** — `network_manager.gd:1889-1910`: a one-behind packet computes gap = 65534 → loss ≈100% for the window → input batch size doubles for ~4 s. Currently mostly shielded because `receive_world_state` is `unreliable_ordered` (transport drops late packets), but the code is wrong and the echo path shares it; treat gap > 32768 as a late duplicate.
- **`receive_input_batch` / `report_ping` lack `is_host` guards** (`any_peer`, reachable client→client) — no gameplay impact (GameManager routes by sender id), but inconsistent with every other guarded RPC at the trust boundary.
- **`_mirror_hands` reverses elevated saves for a right-catching goalie** — `goalie_body_config_builder.gd:184-186, 340-346`: mirror applied after the reach, swaps the lunge to the wrong side of the net and copies rotations unmirrored. Dead today (`catches_left` always true) — an armed landmine for the first right-catch goalie.
- **`self_view_time` future-clamps on fast links** — one-way < INPUT_LEAD collapses the rewound blade segment to a point, disabling the swept test exactly on the lowest-latency links (present-time detection covers it).
- **Peer-disconnect cleanup misses `_peer_ping_ms`, `_peer_last_echoed`, `_peer_echo_drop_window`, `_peer_echo_recv_window`, `_peer_loss_rates`** — host 1 Hz loss loop iterates stale peers forever; `reset()` also keeps `_peer_ping_ms` across sessions.
- **Interpolated remote skaters get an extra `move_and_slide` advance per tick** (`remote_controller.gd:286-288` sets state at priority −1, `Skater._physics_process` then slides) — constant ~8.3 ms bias, arguably part of the collision-lead design, but undocumented.
- **Goalie pad toe-out yaw is not on the wire** — clients render pads flat and client-predicted rebounds come off flatter than the host's angled pad (contained by trajectory-prediction exit on goalie contact).
- **Slide body lean sign leans away from the slide direction** (`goalie_body_config_builder.gd:286-287`, cosmetic 6°).
- **Equal-timestamp snapshot handling differs between actor types** — remote skater appends zero-span duplicates (`<`), goalie drops (`<=`); with a ms-resolution `local_time()` source, equal stamps occur during host catch-up (also: the "distinct host_timestamps" stall-resilience claim doesn't hold at ms resolution; `get_ticks_usec` would fix both).
- **`_state_quick_shot_pressed` presses shoot before checking possession** — a puck lost in the same window produces a phantom-shot follow-through.
- **Role-slot gaps**: unfilled CARRIER (fast loose puck in sticky possession) yields two SUPPORT / two BREAKOUT_WEAK; <3-a-side leaves later slots unassigned falling to stand-still anchor-follow.
- **Bot press of dead code**: `_shoot_aim_dir`, `_clamp_anchor`, `_teammate_has_puck`, write-only `_ticks_in_state`, `AIRoleSlots.slots_for_state`, effectively-dead `ctx.anchor`; goalie: dead client branches (`_is_threat_pressing` client arm, `_move_along_arc` guards, `_puck_approach_velocity` computed per-tick for an unreachable consumer), dead `get_state()`, dead `ThreatConfig`; netcode: dead `lerp_facing`.
- **`_pending_reaction_back_date` clear-contract comment is wrong** and the field isn't cleared on `reset_to_crease` (both current call sites are safe; the contract isn't).

---

## Documentation drift (docs vs code)

ARCHITECTURE.md / CLAUDE.md statements that are currently false. The invariants
section is load-bearing for future work — several of the bugs above were *hidden*
by trusting these lines.

| Doc says | Code does |
|---|---|
| "replicated as `stagger_timer`" (CLAUDE.md) | not in the wire codec (P0 #1) |
| Skater 37 B, ~349 B total | 38 B, 355 B (codec's own comment agrees) |
| "well under 1392-byte ENet MTU" | transport is Steam P2P; real bound is the ~1200 B unreliable cap, documented only in the codec, enforced nowhere |
| Input lead "~25 ms" (also clock_sync.gd:18 comment) | 33.3 ms at the 120 Hz tick (1/60 + 2/120) |
| "validated against the host's own ping measurement" | client-self-reported (P1 #6) |
| "lead is skater-only — puck … still renders on the shared past instant" | puck leads at 0.5 too (puck_controller.gd:32); ARCHITECTURE contradicts itself (line 320 vs 346) |
| "Mouse position is seeded from the first replayed input…" | mechanism no longer exists; equivalents are `reset_blade_smoothing()` + final `apply_blade_from_mouse` |
| "blade velocity finite-differenced" in the pickup resolver | no blade-velocity term exists in reception |
| `end_trajectory_prediction()` | phantom API — exits are contact signals + RTT-scaled suppression window |
| "release_puck RPC … client-sent origin" for regular shots | regular shots have no release RPC; origin is host-live blade (one-timers match the doc) |
| Decisions: "Goalie state transitions and shot reactions via reliable RPCs" | removed model; contradicted by the invariant section and the code |
| Goalie `apply_state` "drives position forward-prediction rather than buffer lookup" | buffers + bracket-search like the others |
| `rvh_early_angle` default 60° / `tracking_speed` default 6.0 / `_tracked_puck_position` / "master difficulty export" | 80° / 8.0 / `_tracked_threat_position` / not in `GoalieSkillProfile`; state transitions read the raw puck, loose pucks tracked instantly |
| "threat tracking weighted toward the carrier's body" | standing weight is 0.40 (puck-dominant); only butterfly is carrier-weighted (in-code comment admits the rebias) |
| Build Status stage 25 "40 Hz world state" | 120 Hz (historical note, reads as current) |
| codec comment "Goalies: u8 count + n × 8B" / "f32 host_capture_time" / input_state "f32 timestamp" | 35 B / u32 / u32 |
| `_stamina_config` "flat (not attribute-scaled)" comment | Physical scales drain/regen and the invalidation exists — comment invites breaking it |
| AISteering "inverse-square falloff" | linear |
| carrier.gd "~30 Hz re-eval" / "skip ROM-unreachable receivers" | ≤24 Hz ÷ dispatch period; filter doesn't exist |
| skater.gd:645-647/720-727 line refs in invariants | drifted (now ~:427-500) |

## What checked out (verified true)

Worth stating, because most of the architecture is genuinely as documented:

- **Rates & codec**: 120 Hz state / 60 Hz input, 12-frame redundancy (24 above
  10% loss), offset-symmetric encode/decode, sane quantization headroom, u32
  0.1 ms timestamps with `roundi`, no NaN off the wire.
- **Shared interp delay**: single `_interp_delay` advanced once per packet;
  target `rtt/2 + broadcast_interval + PDV spread` with the documented clamps;
  Jacobson PDV as described (minor nit: dev updated against post-update mean).
- **ClockSync**: pure NTP, 8 samples, 2 outliers dropped, EMA 0.3, monotone
  floor, 2 s resync — stable by construction.
- **Reconcile**: trajectory comparison via `PredictedState.find_at` exactly as
  documented; save/restore set and both shot-state guards match the doc
  verbatim; charge never server-imported; board clamp in the replay loop; visual
  offset blend implemented precisely as described.
- **Puck modes**: priority chain, remote-carry pin to interpolated blade,
  three-zone trajectory reconcile with full-RTT projection, board-aware
  extrapolation gate, smoother reseed on every interpolation entry — all real.
- **Carrier identity via reliable RPCs only** — confirmed end-to-end.
- **Provisional pickup**: all documented gates present, including
  deflect-intent suppression.
- **Contested pickup math**: one shared function, never awards possession.
- **Goalie networking**: genuinely host-only AI; clients are pure pose
  interpolators; no leftover state/reaction RPCs; 35 B block symmetric;
  reaction back-date + goalie rewind exist as documented.
- **Goalie mechanisms**: butterfly commit timer, screen-intensity read
  (geometric, shooter self-excluded), lateral accel ramp, crease sweep,
  pose-based rebound steering (pad toe-out + material, no physics override) —
  all present with correct math in the rules layer.
- **Skater bots**: host-only, drive the human `InputState → _process_input`
  path with no state pokes; honest movement (stamina/sprint via
  `BotSprintRules`, one documented body-check exception); deflect-intent
  exemption; all 24 `bot_identities.json` entries sum to exactly the 18-point
  budget; all eight `BotSkillProfile` knobs consumed; scoring/trajectory math
  NaN-guarded and team-symmetric (no hardcoded ±Z); AI friction model
  single-sourced from `GameRules.ICE_FRICTION`.
- **Claim-stamp validation, view-time helpers, resolver structure** — shaped as
  documented (modulo P1 #5/#6).
- **F3 overlay thresholds** in sync with telemetry comments (spot-checked).

## Hot-path allocation status

The claimed "120 Hz allocation audit complete" holds for everything it names
(ring buffers, scratch interpolation states, `RoleContext` collect buffers,
goalie `detect_shot_into` + `GoalieBodyConfigBuilder._scratch`, cooldown sweep,
cached configs, alloc-free `_smooth_damp`). It does **not** cover:

- **WorldStateCodec, both directions, 120 Hz** — the big one. Host encode: fresh
  PackedByteArray per actor per broadcast (+header/game-state PBAs, keys Array),
  and `_broadcast_state` re-serializes per peer. Client decode: `slice()` per
  actor + one `*NetworkState.new()` per actor per packet (~20 heap objects/packet).
  Decoding at offsets into per-actor scratch states would eliminate most of it.
- **Client receive**: `get_jitter_p95()` copies + sorts 40 samples per packet
  (the per-frame cache on the *target* shows the cost was known); `NetworkSim`
  wraps every packet in a lambda + args Array even when the sim is off.
- **AI `decide()`** (60 Hz × bots at Hard): fresh `RoleDecision` per call,
  fresh candidate arrays, and `teammates.duplicate()` **inside the 10-candidate
  loop** in PRESSURE/COVER/ANCHOR/BACKCHECK/FORECHECK — order of 5–10 k
  short-lived arrays/sec; `_state_carry` discards the returned `RoleDecision`
  every carry tick; `AITrajectory.predict_at` allocates per call (~40/carrier
  re-eval).
- Minor: `ChargeTracking.accumulate` returns a fresh Dictionary per tick during
  WRISTER_AIM (multiplied by reconcile replay exactly when the network is bad);
  `PredictedState.new()` per tick (single actor, by design); per-batch dedupe
  Dictionary + sort lambda on the host input path.

## Suggested fix order

1. **Stagger wire field** (P0 #1) — one byte + protocol bump + codec test.
2. **Goalie not-upright timer zeroing** (P0 #2) — scope the clear to its stated
   intent.
3. **Bot handedness sign** (P1 #3) — one-line sign fix + comment correction.
4. **Dispatch-throttle units** (P1 #4) — decrement by period (fixes #12's cache
   gap too while in there).
5. **Lead-aware claim delay** (P1 #5) — multiply reported delay by
   `(1 − lead_fraction)`.
6. **Host-measured ping for plausibility** (P1 #6).
7. **Replay determinism holes** (P1 #7) — snapshot/restore the live reads.
8. P2 batch: cross-crease clamp constant, `wrapf` rotation_y, s16 (or wider s8
   scale) hand offsets, impulse replay phasing, hit-credit scale, telemetry
   phase-gating, one-timer power model, finisher lift cache, one-timer-ready
   bound.
9. Documentation pass over the drift table above — the invariants section
   misleads exactly the work it exists to protect.
10. Codec + AI allocation cleanups when profiling motivates (wire path first —
    it's 120 Hz on every machine).

---
---

# Part Two — Game Flow, Physics, Backend, Lobby (July 2026, follow-up)

Second sweep covering the systems the first audit deliberately left out: host
game-flow orchestration (the full 3,568-line `GameManager` + phase machinery),
goal detection / rink geometry / puck physics, the Supabase backend + prefs
persistence, and the lobby / session-lifecycle distributed flows. Same method —
docs treated as claims, four independent passes, every P0/P1 re-verified by a
second read of the cited code. This sweep was chartered specifically to look
where the first one's pattern predicted bugs would hide (stateful orchestration
glue and serialization, not the pure domain layer) and to hunt the standing
"puck escapes the rink" mystery. It found the escape's mechanism.

Same severity legend as Part One.

---

## P0 — Critical

### P2-1. The puck-escape mystery: the altitude clamp sits ~10 cm above the top of the glass
`Scripts/actors/puck.gd:60, 487-490` vs `Scripts/actors/hockey_rink.gd:203-206, 246-248` · `puck.gd:209-212` + `Scripts/domain/rules/puck_collision_rules.gd`

Verified arithmetic: the perimeter collision (boards + glass) tops out at
`wall_height 1.07 + GLASS_LIFT 0.001 + glass_height 1.83 = 2.901 m`
(`_add_perimeter_collision(..., 0.0, glass_y_top)`). The puck's vertical clamp is
`ice_height 0.0125 + max_height 3.0 = 3.0125 m`, and it doesn't merely permit that
height — it *pins* the puck there and zeroes upward velocity, creating a flat
cruise ~10 cm above the highest collision triangle:

```gdscript
if state.transform.origin.y > ice_height + max_height:
    state.transform.origin.y = ice_height + max_height
    if state.linear_velocity.y > 0.0:
        state.linear_velocity.y = 0.0
```

Elevated **deflections** have no apex cap (shots do, via `max_apex_above_blade`).
A 35° tip (`apply_deflection_elevation`, speed-preserving) of a hard shot reaches
v_y ≈ 9.6 m/s → natural apex ~4.7 m, so it pegs the ceiling; a tip within ~2–3.5 m
of the boards heading outward crosses the perimeter in the 2.901–3.0125 m gap
where **no collision geometry exists**. CCD is irrelevant — there's nothing to
collide with. This is the standing "puck occasionally escapes" bug, and it
**falsifies the CLAUDE.md "velocity/reflection compounding or Jolt edge case"
theory**: the auditor confirmed every reflection path is strictly energy-losing
(deflect retain ≤ 0.7/0.5 multiplicative — chains *cannot* compound; poke/squirt/
strip clamped ≤ 9 m/s), the 38 m/s speed clamp runs every `_integrate_forces`
substep on host and client, and the corner collision is a seamless backface-
enabled 256-segment loop (no tunneling seam). The escape is pure geometry.

**Fix:** raise the collision `y_top` above `ice_height + max_height` (e.g. 3.2), or
lower `max_height` so the clamp acts below the glass line. Pair it with a
height-aware out-of-bounds whistle (see P2-9) to also catch the soft-lock variant
where the puck rests *on top* of the boards.

### P2-2. Any goal scored during the FACEOFF phase is silently and permanently voided
`Scripts/domain/state/game_state_machine.gd:129-131` · `Scripts/game/game_manager.gd:1906-1907, 2185-2245` · `Scripts/game/phase_coordinator.gd:166-168`

`on_goal_scored` hard-gates on phase:

```gdscript
func on_goal_scored(defending_team_id: int) -> int:
    if current_phase != GamePhase.Phase.PLAYING:
        return -1
```

FACEOFF exits to PLAYING only through `on_faceoff_puck_picked_up`, which fires
solely from `PhaseCoordinator.on_pickup` — the normal `_on_puck_picked_up` carry
path. But several scoring paths never produce a pickup and so never leave FACEOFF:
one-timers (`_host_release_one_timer` calls `puck.set_carrier` + `puck.release`
directly, bypassing the pickup flow entirely), deliberate deflects/redirects, and
a **contested draw** (`apply_contested_pickup` awards no possession by design —
the puck squirts free). A puck that crosses the line while the FSM is still in
FACEOFF returns −1: no horn, no score, and because the goal sensor is
edge-triggered `body_entered`, the puck then rests inside the net un-awarded; the
10 s timeout flips to PLAYING without re-triggering it. Players see a clean score
that doesn't count with the puck lying in the goal.

Calibration note: the *most common* draw outcome is a normal pickup, which does
exit FACEOFF, so this is a latent edge case rather than an every-faceoff event —
but "win the draw and one-time it," a set play the docs celebrate, is exactly the
possession-less path that hits it, and end-zone faceoff dots sit close enough to
the net to make it reachable. **Fix:** advance FACEOFF→PLAYING on any puck contact
(touch/deflect/one-timer), or accept goals during FACEOFF in `on_goal_scored`.

### P2-3. `career_stats` is world-rewritable by every shipped client — and the dangerous grant is dead code
`sql/career_stats.sql:44-47` · client: `Scripts/game/career_stats_reporter.gd` (POST/GET only)

The anon (publishable) key ships as a constant in every export
(`supabase_config.gd:5-6`) and the RLS policies grant it, on the full player
table keyed by unauthenticated client-supplied `steam_id`:

```sql
create policy "anon select" on public.career_stats for select to anon using (true);
create policy "anon update" on public.career_stats for update to anon using (true);
```

`UPDATE using(true)` with no `WITH CHECK` lets any key holder `PATCH` any column of
any row — inflate their own career, zero a rival's, reassign rows to their own
steam_id (career theft), or set `steam_id = null` on every row, which the
`career_totals` view (`WHERE steam_id IS NOT NULL`) reads as a **total wipe of
everyone's career screen** (UPDATE is delete-equivalent; DELETE isn't even
needed). The kicker verified by grep: **no client code issues any PATCH/PUT** —
`CareerStatsReporter` only POSTs and GETs. The single most dangerous policy in the
schema guards a slot-swap-merge feature that was never built. `anon select
using(true)` separately exposes every player's steam_id + name + game history to
anyone with the key.

**Fix (zero product impact):** drop the UPDATE policy outright. Decide
deliberately whether career data is public (if not, move reads behind an RPC that
returns only rostered/aggregate shapes). Add server-side CHECK/size constraints
(P2-11). Correct the "restricts to INSERT/SELECT/UPDATE" comments in
`supabase_config.gd:4` and `bug_reporter.gd:10` (bug_reports/network_sessions are
INSERT-only — their PII posture is actually correct; the problem is career_stats
specifically). This is survivable for a closed test with known testers; fix before
any wider release.

---

## P1 — High

### P2-4. Reconnect SteamID64 is client-supplied and never authenticated
`Scripts/networking/network_manager.gd:902, 933` · `Scripts/game/game_manager.gd:647-650`

`request_join` carries `steam_id` as an ordinary RPC argument; the host stores it
verbatim (`_peer_steam_ids[sender_id] = steam_id`) and keys the reservation
restore on it. Nothing cross-checks it against the SteamMultiplayerPeer's
authenticated identity — `getSteam64*` is never called anywhere in the codebase
(the only Steam-identity call is `getLobbyOwner`, used client-side to find the
host). A modified client can put any SteamID64 in the payload: within the 60 s
reservation window it hijacks a dropped player's held slot — inheriting their
team, slot, **locked attributes, and carried-forward stats** — and erases the
reservation so the real player is auto-balanced elsewhere on reconnect. The same
forgery lets a client impersonate any steam_id in every backend row (compounding
P2-3). **Fix:** resolve the peer's real SteamID64 from the transport host-side;
treat the RPC value only as a non-Steam fallback.

### P2-5. Reserved reconnect slots are ignored by slot-swap and spectator-promote → two skaters in one slot
`Scripts/domain/state/game_state_machine.gd:458-476` · `Scripts/game/game_manager.gd:1412-1435`

`is_slot_reserved` exists (game_state_machine.gd:441) but `try_swap_slot`'s
collision scan loops only `players`, and `_promote_spectator_to_player` checks
only `players` + aggregate `count_players_on_team` — neither consults it.
Auto-balance and the roster gate honor reservations; swap and promote don't (3 of
5 slot-granting paths respect the invariant, 2 don't; rematch is the third — see
P2-8). Reproduces with no malice: player B drops from HOME/C (slot reserved) → a
teammate change-positions into HOME/C (allowed) → B reconnects within 60 s →
`_restore_reserved_player` force-registers B into HOME/C, so two records claim the
same `(team_id, team_slot)`. Both then teleport to the identical `FACEOFF_OFFSETS`
dot each faceoff (physics shoves them apart) and slot-keyed logic aliases them.
**Fix:** reject a swap/promote target where `is_slot_reserved(team_id, slot)`.

### P2-6. Migration can leave a player over the attribute budget, and the host never validates its own build
`Scripts/game/player_prefs.gd:978-990` · `Scripts/networking/network_manager.gd:343/353/468/592/686 vs 940-942`

`_migrate_four_to_six` only trims Hands then Physical (max 4 points removable), so
a legacy all-3s save migrates to 5/5/5/5 (four-attr) + 3/3 seed = 26 and the trim
loop exits at **22 > BUDGET(18)** — falsifying CLAUDE.md's "trimmed to fit
BUDGET." Worse, `is_within_budget` is only checked for *remote joiners*
(network_manager.gd:941); the host's own `_peer_attributes[1] =
PlayerPrefs.get_player_attributes()` is assigned at five sites with no budget
check, so that over-budget player *hosting* plays a 22-point build all match,
while the same player *joining* is silently reset to all-medium. A hand-edited cfg
(5/5/5/5/5/5) survives identically — per-level clamped on load but never
budget-checked. **Fix:** budget-enforce in `_load()` (trim all attrs round-robin so
it always terminates at budget) and validate `_peer_attributes[1]` through the
same path as joiners. (No migration test exists — a pure-function extraction +
budget-invariant assert would have caught this.)

---

## P2 — Medium

### P2-7. Icing team-wide ghost is dead code in every ruleset — the documented mechanic does not exist
`game_state_machine.gd:184-216, 522` · `game_manager.gd:483-493`. `icing_team_id` is set only in `check_icing_for_loose_puck` (NHL-only), and the caller runs `check_icing → _consume_pending_faceoff → _whistle_and_faceoff → begin_faceoff_prep` **in one synchronous call stack**; `begin_faceoff_prep`'s first line is `icing_team_id = -1`, clearing it before `_apply_ghost_state` (now in FACEOFF_PREP) ever reads it. So `ICING_GHOST_DURATION`, `_tick_icing`, and the opponent-pickup clear are all unreachable, and ARCADE/OFF never detect icing at all. CLAUDE.md's "Icing ghosts the whole offending team briefly" is false everywhere. The domain SM test passes because it drives the SM without the orchestration — the project's signature failure pattern. **Fix:** persist `icing_team_id` through `begin_faceoff_prep`, or delete the dead ghost path and the doc claim.

### P2-8. Rematch desyncs the two reservation stores and carries stale stats forward
`game_state_machine.gd:500` (`reset_all` clears domain `reserved_slots`) vs `game_manager.gd:2807` (`_reserved_slots` cleared only on scene exit). After a rematch the slot is genuinely free (retakeable), yet a reconnecting peer still matches `_reserved_slots` and is force-registered — and `rec.stats = res.stats` injects the **previous match's** goals/assists into a fresh 0-0 game while everyone else was reset. **Fix:** clear `_reserved_slots` in `_apply_reset`.

### P2-9. Puck resting on top of the boards soft-locks — OOB whistle is XZ-only
`game_manager.gd:402-416`. `_check_puck_out_of_bounds` whistles only when the XZ projection is > 0.2 m outside `clamp_to_rink_inner`; a puck settled on the 0.3 m-thick wall cap (from a P2-1 ceiling-window trajectory) is within that band and never whistled, and the net-stuck check doesn't cover it. The puck floats untouchable at glass-top height until the period clock forces a faceoff (up to 4 min). **Fix:** add a height term (`pos.y > wall_height` while outside/atop the band ⇒ whistle) — also cleanly whistles P2-1's escapees the instant they clear the glass.

### P2-10. `_pending_elevation_vel` survives `reset()`/`drop()` — a faceoff puck can inherit a full shot velocity
`puck.gd:347-368, 391-407, 453-461, 477-484`. If `release()` and a phase-change `drop()`/`reset()` land in the same tick (shot fired the instant a whistle processes — both run in `_physics_process` before the physics step, so `_integrate_forces` never consumed the pending vector), the reset teleports the puck to the dot and the *next* step writes the stored shot velocity (up to 38 m/s) into it — the faceoff puck rockets off the dot, elevated if the shot was. One-tick race, rare, but a "puck did something inexplicable" generator. **Fix:** zero `_pending_elevation_vel`/`_pending_elevation` in `reset()` and `drop()`.

### P2-11. INSERT `with check(true)` + zero server-side constraints on all three tables
`career_stats.sql:43`, `bug_reports.sql:28`, `network_sessions.sql:40`. No CHECK constraints (`goals integer` accepts −2^31), no length/size caps (the 2000-char/8000-char limits live only in `bug_reporter.gd` where a hostile client deletes them by definition), no rate limiting, and career rows insertable for *any* steam_id (forging a victim's games corrupts their totals as effectively as UPDATE). A griefer floods any table until the free tier pauses and all telemetry silently 4xx's. **Fix:** CHECK + `pg_column_size` constraints; a usage alert at minimum.

### P2-12. Crash auto-report bypasses the privacy opt-out
`crash_watch.gd:56-58, 145-148` · `bug_reporter.gd:54-72`. `share_gameplay_stats = false` suppresses career + network-session rows, but CrashWatch POSTs steam_id, player name, breadcrumb, and a 6 KB log tail (whatever was printed — peer names, lobby ids) on the launch after any unclean shutdown, including routine force-kills, with no gate and no user-visible indication. Manual reports being ungated is fine (explicit action); the crash path is non-consensual telemetry. **Fix:** gate on `share_gameplay_stats` or give it its own opt-out.

### P2-13. Every pass/shot release fires the *board-hit* sound, VFX, and an RPC — the ice is classified as "boards"
`puck.gd:440-451`. The ice collision body is a plain `StaticBody3D` child of `HockeyRink`, so it falls through to `elif body is StaticBody3D and linear_velocity.length() >= 1.0: puck_hit_boards.emit()`. A carried puck is frozen (no contact pairs), so every release re-enters the ice contact and fires — `game_manager.gd:1114` then plays the board thud, spawns board-chip VFX, **RPCs `send_board_hit_to_all`**, and logs a `"puck_boards"` replay event, on every pass and every landing, network-replicated, at the wrong place. **Fix:** exclude the ice body (parent-is-HockeyRink-root, name, group, or meta check).

### P2-14. Promote-of-departed-peer race spawns a phantom skater
`game_manager.gd:1412-1435`. `_promote_spectator_to_player` has no `peer_id in connected_peer_ids()` guard. A spectator's `request_slot_swap` RPC in flight when they disconnect can be processed the same frame `on_player_disconnected` erased them, spawning + broadcasting a full skater for a gone peer — an uncontrolled phantom on all clients until match end (no disconnect will clean it; the registry add happened after the disconnect handler). **Fix:** gate promote on connection liveness.

### P2-15. Kicked player can rejoin immediately — no SteamID ban
`network_manager.gd:959-964, 578`. `kick_peer` marks `_kicked_peers[peer_id]` purely to gate that one disconnect's reservation, then erases it; there's no persistent ban. The kicked griefer re-joins the still-open lobby seconds later with a fresh peer_id and is re-seated by auto-balance. **Fix:** a host-side kicked-SteamID set for the session (depends on P2-4 for a spoof-proof id).

### P2-16. AI trajectory bounce model treats the rink as a rectangle — up to ~3.5 m of phantom corner ice
`Scripts/domain/ai/trajectory.gd:48-54`. With `bounce_factor > 0` (the puck path) reflection fires only at `|x| > INNER_HALF_WIDTH` / `|z| > INNER_HALF_LENGTH` — flat walls — while the real rink and the model's own non-bounce branch four lines down (and the client `_crosses_board`) use the 8.37 m corner arcs. The model routes predicted pucks through ~3.47 m of non-existent corner ice and predicts bounces off absent walls, and ignores the boards' μ=0.3 capstan loss on rim-arounds. AI-only, and worst exactly in the corners where dump-and-chase reads happen. **Fix:** reuse the rounded-rect the same file already has.

### P2-17. Double-transition / re-entrancy in the online entry points
> **Partially resolved by the menu consolidation (2026-07):** the `_on_host_pressed` / `start_host()` half is gone — hosting now starts offline from the unified Play lobby, and `attach_online` runs behind the visibility selector, which disables itself while the create is in flight. Still open: the **join** flow (`side_menu.gd` `_on_join_pressed`, also reachable from an invite accept) still runs `reset()` + `start_client_lobby()` with no op-in-progress gate, and the pause-menu / HUD double-teardown below is untouched.

`side_menu.gd:711-758` · `pause_menu.gd:244-256` · `hud.gd:1337-1350`. `_on_host_pressed` runs `reset()` + `start_host()` unconditionally with no "op in progress" flag; a Steam invite accepted mid-host-flow re-enters and races `SteamManager` state (the first host's `lobby_created` one-shot gets disconnected by the second `reset()`). Separately, the "Return to Free Play" / "Exit Game" confirms `await announce_match_end()` (0.5 s) while staying interactive, so a double-click fires two overlapping teardown chains and can double-`change_scene`. **Fix:** a single `_lobby_op_pending` gate; disable confirm buttons before the await.

---

## P3 — Low / latent / hygiene

- **`reset()` never wakes a sleeping puck** — `puck.gd:399-407` defers the faceoff teleport to `_integrate_forces`, which doesn't run on a slept body; `can_sleep` is never disabled, and the code already knows this hazard (`apply_goalie_sweep` sets `sleeping = false` first). A puck slept in a corner through a long celebration may ignore the faceoff teleport. One `sleeping = false` line removes the ambiguity.
- **Goal sensor safety is implicit** — detection window (~0.56 m) is 1.8× max per-tick displacement (0.317 m at 38 m/s / 120 Hz), so no phantom-miss *today*, but there's no swept/backup goal-line check: raising `max_speed` past ~60 or dropping to 60 Hz silently breaks it. Document/assert the invariant. (The margin partly rests on the accidentally AABB-inflated net-back collision — P3 below.)
- **Goal fires on leading-edge line-touch, and entry is one-shot with a strict `> 0` gate** — `hockey_goal.gd:617-632`: sensor front is exactly on the goal line, so a puck held half-over counts; conversely a puck dead-stopped exactly at entry (`vel.z == 0`) or sliding laterally along the line scores nothing and sits live in the net. Goal-mouth-scramble edge cases; common case correct. (No double-signal risk — goal signal is host-only wired.)
- **Net-back collision is AABB-inflated** — `hockey_goal.gd:585-606` collides each net panel by its bounding box, so a puck along the ice dies ~0.46 m short of the visible mesh (shots visibly stop in mid-air inside the net). Cosmetic (goal counted 0.56 m earlier), but the most visible physics/visual mismatch in the game.
- **Goal frame has no PhysicsMaterial → dead posts** — restitution 0 (ADD combine, `game_rules.gd:138`), so a post hit drops dead instead of pinging out, inconsistent with the boards' 0.4 and with `fire_post_ping_vfx` playing over a flopped puck. If intended, comment it; if not, a 3-line `.tres` + mirror test.
- **Slot swap teleports to the center-ice faceoff layout regardless of active dot/phase** — `slot_swap_coordinator.gd:121-123` uses the default (center) dot; a swap during an end-zone FACEOFF_PREP parks the skater center-relative, possibly wrong side, for the draw.
- **Restored reconnect stats never sync to clients** — `game_manager.gd:766-775` assigns `rec.stats` *after* the spawn-time stat sync and issues no further RPC (the comment's "world state carries stats" is false — stats ride only the reliable event RPC), so scoreboards show the reconnected player as zeros until the next goal/hit anywhere.
- **Unanimous skip-vote broadcasts (0, N) instead of (N, N)** — `game_manager.gd:1502` reads the count *after* `register_skip_vote` already `stop()`-cleared it; the documented client "(current ≥ total)" teardown path is dead and the HUD flashes "(0/N)" at unanimity. Read the count first.
- **Replay footer TOI wrong for everyone but the recording peer** — `toi_seconds` accrues only for the local record, but `_build_replay_footer` writes it for all under a "complete on any peer" comment (career reporting unaffected).
- **Reporter HTTPRequests have no timeout; `CareerStatsScreen` fetch callbacks lack a liveness guard** — a scene change mid-fetch calls a Callable on a freed Control (error spam); `BugReportDialog` got the `is_inside_tree()` guard right — mirror it.
- **NaN/inf in a telemetry metric silently 400s the row** — `JSON.stringify` emits bare `nan`/`inf`; realistic vector is an upstream physics NaN feeding a metric — exactly the sessions you most want. Sanitize in `NetworkSessionSummary.observe`.
- **`cfg.save()` result ignored** (`player_prefs.gd:405`) — disk-full/read-only loses settings silently and `_push_to_cloud` then propagates the stale file; non-atomic writes corrupt to all-defaults on power loss. **Hand-edited cfg with wrong *types*** (not ranges — those clamp) aborts `_load()` mid-function, leaving everything after the bad key at defaults.
- **`request_color_vote` accepts any slot int** (`network_manager.gd:1660`) — resolves to default on unknown, so low blast radius, but add a membership check.
- **Cross-session field bleed** (consistent with Part One's `reset()`-under-covers theme): `_peer_ping_ms`, `pending_num_periods`/`pending_period_duration`/`pending_ot_enabled`/`pending_rule_set` (last-match lobby settings pre-fill), and `_in_replay_locally` are not cleared by `reset()`/`on_scene_exit`; `_crease_dwell` and `_reservation_token` leak on disconnect. Recommend one audited "reset every session-scoped field" pass.
- **`reset_game()` lacks an `is_host` guard** (`game_manager.gd:2851`) — a stray client call forks its local SM from the host (the RPC itself is authority-gated, so no remote harm). Cheap symmetry fix.
- **`deploy.yml` version-rewrite failure is non-fatal** — a reformatted `build_info.gd:9` no-ops the anchored sed and the follow-up grep still exits 0, shipping a build stamped `dev` (pollutes cohort analysis; join-gating is unaffected — it keys on Steam BuildID).
- **`GameStateMachine.compute_ghost_state` returns a fresh Dictionary every 120 Hz tick** (`game_state_machine.gd:219`), and `_enrich_snapshot_for_ai` allocates two `[]` per tick (`game_manager.gd:1860`) — both have caller-owned-scratch fixes demonstrated elsewhere in the same files.

---

## Documentation drift (Part Two)

| Doc says | Code does |
|---|---|
| Phase FSM table: `FACEOFF_PREP` = 0.5 s | 2.0 s (+4.0 s opening intro) — `game_rules.gd:13,17` |
| `GOAL_SCORED` 2 s celebration freeze | table omits `GOAL_CELEBRATION`; GOAL_SCORED duration is the replay-clip length (2 s only as no-replay fallback) |
| "if last period → GAME_OVER" | omits the OT branch (tied + ot_enabled → extra period, repeats) |
| "Icing ghosts the whole offending team briefly" | dead code in every ruleset (P2-7) |
| "Client world spawn triggered by `client_connected`" | `on_connected_to_server` is `pass`; spawn is driven by `assign_player_slot` → `on_slot_assigned` |
| Reconnect invariant "counts toward totals so not backfilled" | honored by auto-balance + roster gate; **bypassed** by swap, promote, rematch (P2-5, P2-8) |
| `_restore_reserved_player` "next world-state broadcast propagates stats" | stats ride only the reliable stat RPC; none sent after restore (P2-7 low) |
| PhaseCoordinator "nothing here reaches NetworkManager" | `NetworkManager.is_drill_mode()` at `phase_coordinator.gd:177` |
| `supabase_config.gd` / `bug_reporter.gd` "authorizes INSERT/SELECT/UPDATE" | bug_reports/network_sessions are INSERT-only; career_stats UPDATE is unused dead grant (P2-3) |
| CLAUDE.md "puck escape = velocity/reflection compounding or Jolt edge case" | falsified — it's the altitude-clamp/glass geometry gap (P2-1) |
| `GameRules.NET_BACK_HALF_WIDTH` "trapezoid wider end" | skirt is built rectangular at ±0.915 (geometry drift, ~10 cm slack, no live bug) |
| prefs "trimmed to fit BUDGET" | can exit 4 points over budget (P2-6) |

## What checked out (Part Two)

- **Signal-lifecycle sweep of `GameManager`: clean** — a notable divergence from Part One. Every `.connect(` reachable more than once per process was checked; no double-connect or leak. Persistent vs per-match sound sets are guard-flagged; per-world collaborators are freshly `new()`ed so old connections die with the RefCounted; goal-node and per-skater signals are freed with their scene nodes; teardown ordering in `on_scene_exit` (writer → registry → phase-coord SM-null before driver stop) is correct as commented.
- **Goal pipeline ordering** (carrier captured before drop; carrier_changed(-1) → notify_puck_dropped → notify_goal, all reliable; host-only sensor wiring; phase-machine dedup on re-entry) — confirmed.
- **Rink geometry is genuinely single-sourced** — GameRules ↔ builder defaults ↔ scene (scene overrides colors only); goal line, blue lines, faceoff dots, corner-clamp margin-invariance all check out. `ICE_FRICTION` / `PUCK_BOARD_BOUNCE` single-sourced and CI-mirrored.
- **Puck speed is genuinely bounded** — 38 m/s clamp every substep on host *and* client-prediction; no injector (deflect/poke/squirt/strip/sweep) exceeds it; deflect chains are strictly energy-losing.
- **Backend reporter/consumer layer is well built** — correct fire-and-forget lifecycle (queue_free on completion *and* request error), null-tolerant readers (`_safe_int`, jsonb `->>`), single edge-triggered game-over (rematch resets stats + mints a fresh game_id — no double-count), consistent offline/privacy gating for career + net-session rows, sound steam_id=0 semantics, jsonb-metrics design avoiding ALTER churn. `bug_reports` / `network_sessions` are INSERT-only — **no player can read another's reports or telemetry** (their PII posture is correct).
- **Prefs migration is crash-safe** — pure in-memory, file untouched until next `save()`, deterministic re-run from source keys; `new = 2·old − 1` mapping and Hands-first trim order verified; future-version downgrade clamps without crashing; well-formed v4 game UUIDs.
- **Steam achievements/stats** are client-side and mode-gated as documented — fine within Steam's own trust model (any Steam client can call setAchievement directly regardless).
- **Dead-puck enforcement, spectator invariant, promote/demote-before-free ordering, join validation order (version/build/duplicate/budget), token-guarded reservation expiry** — all verified as documented.

## Combined fix priority (both parts)

1. **P0s, in order of player impact:** stagger wire field (Part One #1) · goalie not-upright timer zeroing (Part One #2) · puck altitude-clamp/glass gap + height-aware OOB whistle (P2-1/P2-9) · faceoff-phase goal void (P2-2) · drop the `career_stats` UPDATE policy (P2-3, one line).
2. **Security/integrity cluster:** authenticate SteamID64 host-side (P2-4) — unblocks kick-ban (P2-15) and de-spoofs backend rows · reserved-slot check in swap/promote + `_reserved_slots` clear on rematch (P2-5/P2-8) · host self-attribute + migration budget enforcement (P2-6) · backend CHECK/size constraints (P2-11) · crash-report privacy gate (P2-12).
3. **Part One P1s:** bot handedness sign · dispatch-throttle units · lead-aware lag-comp rewind · host-measured ping · replay determinism holes.
4. **Feel/correctness mediums:** icing ghost decision (implement or delete P2-7) · pending-elevation-vel clear (P2-10) · ice-as-boards misclassification (P2-13) · promote liveness guard (P2-14) · online double-transition gates (P2-17) · AI corner bounce model (P2-16) · the Part One P2 batch.
5. **Hygiene sweep:** one audited session-field reset pass; the two documentation-drift tables; codec + per-tick allocation cleanups (wire path first).

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

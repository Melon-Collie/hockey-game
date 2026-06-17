# Technical Audit — June 2026

Pre-go-live audit covering four areas: netcode correctness/robustness vs. industry standard for
host-authoritative action games, scene/session-flow routing, performance, and production readiness.
Findings already documented in `ARCHITECTURE.md` (Known Issues, deliberate decisions like
host-advantage, no pickup prediction, deferred shot lag comp) are excluded — everything below is
undocumented, and every finding was verified in code, not inferred from docs.

Severity legend: **Blocker** = will produce cheats/crashes/corruption in any public release.
**High** = must fix before Steam / open distribution; tolerable for coordinated playtests.
**Medium** = real but bounded. **Low** = hygiene.

---

## 1. Blockers

### B1. The shot-release RPC family trusts the client completely

The claim resolvers (pickup/poke/hit) are properly hardened — sender identity from
`multiplayer.get_remote_sender_id()`, rewind depth clamped to 0–200 ms (`lag_comp_rewind.gd:25,42`),
`MAX_CLAIM_AGE_S = 0.2`, range gates, server-side cooldowns. The shot-release path skips **all** of
those safeguards:

- **One-timer release is completely unvalidated.** `game_manager.gd:1668-1678`
  (`on_remote_one_timer_release`) → `_host_release_one_timer` (`:1681`) does
  `puck.set_carrier(skater); puck.release(direction, power)` with no check that the puck is loose,
  near the shooter, that the phase allows it, or that the shooter isn't ghosted. `puck.release()`
  snaps the puck to the shooter's blade — so any client can send one RPC at any moment (including
  during a faceoff, including while an **opponent is carrying**) and the puck teleports to their
  blade and fires at client-chosen power. Even without a hacked client, a pickup race silently
  steals the puck. Contrast `on_remote_puck_release` (`game_manager.gd:1734-1740`), which correctly
  validates sender == carrier.
- **Client-supplied `rtt_ms` forward-teleports the puck.** `game_manager.gd:1748,1786-1787` and
  `:1690,1714-1716`: `puck.set_puck_position(pos + (direction * power + skater_vel) * rtt_ms/2000.0)`
  with `rtt_ms` taken verbatim from the RPC. Claiming `rtt_ms = 3000` at power ≈ 25 m/s advances the
  puck ~37 m — past the goalie, into the net, on every shot. The host already tracks
  `_peer_ping_ms[peer_id]` and never cross-checks.
- **Goalie reaction back-date is unclamped.** `game_manager.gd:1761` / `:1693`:
  `release_back_date = maxf(estimated_host_time() - host_timestamp, 0.0)` with a client-supplied
  `host_timestamp`, and `GoalieController.set_pending_reaction_back_date` only clamps to ≥ 0
  (`goalie_controller.gd:520-521`). There is no claim-age check on this path (unlike the 200 ms gate
  everywhere else). `host_timestamp = 0` back-dates the goalie's reaction by the whole session —
  every shot beats the goalie. Note a legit client also stamps 0 before NTP warmup
  (`network_manager.gd:917-918`), so this can misfire innocently too.

**Fix (one unit of work):** a `ShotReleaseValidator` applying the existing `LagCompRewind`
conventions to both release RPCs: require `puck.carrier == null` / sender == carrier as appropriate,
`not pickup_locked`, not movement-locked, not ghosted; validate the rewound puck position against
the shooter's slapper zone (machinery exists in `PickupClaimResolver`); clamp `rtt_ms` to
`min(claimed, host-measured RTT × 1.5, 300 ms)`; clamp back-date to ~250 ms and reject stale stamps;
`direction.normalized()`; clamp `power` to max slapper power × max strength multiplier.

### B2. No protocol/version handshake + the update checker is dead code

Two halves of the same failure mode:

- `request_join` (`network_manager.gd:654-671`) carries no version field; the host accepts any
  client unconditionally. `BuildInfo.VERSION` is checked nowhere in the connection flow. The wire
  format is positional binary (37 B skater / 12 B puck / 35 B goalie at fixed offsets) — any format
  change between releases means an old client decodes garbage **that passes the size checks**:
  teleporting players, phantom phases, or script-error spam (`decode_stats` at
  `world_state_codec.gd:321-344` does `data[-1]` plus an unguarded index walk and will error
  outright on shape mismatch). These will be reported as "haunted netcode bugs".
- `UpdateChecker` (`Scripts/ui/update_checker.gd`) is **never instantiated**. No scene references
  it, nothing calls `UpdateChecker.new()` — it died when the main menu was replaced by the Boot
  title card (`boot.gd:7`). So nothing ever tells players an update exists, which guarantees
  mixed-version sessions. (CLAUDE.md still claims the main menu polls it — doc drift.)

**Fix:** `const PROTOCOL_VERSION: int` in `build_info.gd`, sent as the first arg of `request_join`;
host replies with a reliable `notify_version_mismatch` RPC then disconnects; surface via the loading
screen. Bump manually on any wire/RPC change. Plus one `add_child(UpdateChecker.new())` in
`Boot._build_ui()` — the checker itself is already well-designed (single request, 5 s timeout,
silent failure, dev-skipped). Ironically `replay_file_reader.gd` already has magic + format-version
checking — the network format should be held to the standard the replay format already meets.

### B3. Mid-game 7th connection overflows the roster and breaks the host

`GameRules.MAX_CONNECTIONS = 10` (6 players + 4 spectators), but joining-as-spectator is lobby-only —
"Mid-game joiners always come in as players" (`game_manager.gd:487`). `GameStateMachine.on_player_connected`
never rejects, and `_first_available_slot` returns `occupied.size()` (= 3) when a team is full
(`game_state_machine.gd:330-333`). A 7th mid-game connection becomes a player with `team_slot = 3`;
the next faceoff indexes `GameRules.FACEOFF_OFFSETS[team][3]` (`player_rules.gd:23`) — out of
bounds, host-side script error, broken faceoff for everyone. **`ARCHITECTURE.md:342` claims "the
player roster is still gated separately by `PlayerRules.MAX_PER_TEAM`" — that gate does not exist on
this path** (doc-vs-code mismatch). **Fix:** in `on_player_connected`, if both teams are at
`MAX_PER_TEAM`, assign the joiner as a spectator (plumbing exists) or disconnect with "match full".

---

## 2. High — scene/session flow

### S1. Cancelling a join leaves a half-torn-down free-play world

`side_menu.gd:628-646`: `_on_join_pressed` runs `GameManager.on_scene_exit()` (nulls
`_state_machine`, `_registry`, `_phase_coord`, puck refs) and `NetworkManager.reset()` **before**
connecting, but never changes scene — the old free-play world keeps simulating behind the loading
screen. `_on_join_cancelled` just hides the loading screen. Result after Join (bad IP) → Cancel: you
can skate, but `is_host` is false so `PuckController._check_interactions` never runs — **the puck
can never be picked up again**; HUD/clock dead; Escape opens the wrong menu; and the rink goal
sensors are still wired to `_phase_coord.on_goal_scored_into(team)` with `_phase_coord == null` —
puck drifting into a net script-errors. Connect-timeout and connection-failed paths recover via
`return_to_free_play()`; only Cancel is broken. **Fix:** `_on_join_cancelled` →
`GameManager.return_to_free_play()`.

### S2. Join-in-progress from free play spawns the world into a dying scene (near-deterministic)

`network_manager.gd:971-977` stashes `assign_player_slot` into `pending_join_slot` only when the
client is *not* in the Hockey scene — but a client joining **from free play is already in
`Hockey.tscn`**. The host's mid-game join burst (`join_in_progress` → `sync_existing_players` →
`assign_player_slot`, all reliable, ~1 RTT) lands while `LoadingScreen.close_when_ready` is still
enforcing `MIN_DISPLAY_SECS = 1.0` (`loading_screen.gd:14,85-90`) before the scene reload — so
`on_slot_assigned` runs `_spawn_world()` into the **old scene that is about to be freed**. After the
reload, `pending_join_slot` is already consumed, the new scene never spawns, and broadcasts decode
against freed instances. The 1 s minimum-display timer makes this the common case, not a race.
**Fix:** set a "scene transition pending" flag in `_on_join_got_game` that forces the stash path
regardless of scene check (or change scene immediately and let the loading screen persist across it).

### S3. Connection errors are never shown; `start_host()` failure is swallowed

- `pending_error` (`network_manager.gd:223`) is written in three places ("Connection failed.",
  "Lost connection to server.", "Connection timed out.") and **read by nothing** (repo-wide grep).
  Every failure silently dumps the player into free play with no explanation. With direct-IP
  joining, failure is the *common* case. **Fix:** on free-play re-entry, toast
  `NetworkManager.pending_error` via the existing `ToastStack`, then clear it. Also: "server full"
  has no handling at all — a 7th joiner just sees the generic 10 s timeout.
- `start_host` (`network_manager.gd:354-367`): on `create_server` failure it `push_error`s and
  returns, but `is_host = true` / `game_initiated = true` are already set and `SideMenu`
  unconditionally changes to the lobby scene — the host sits in a lobby nobody can join (realistic
  trigger: port 7777 already bound by a second instance). `start_client` has the same shape and
  additionally never arms `_connect_timer` on failure → loading screen spins forever. **Fix:**
  return `Error`, roll back flags on failure, check before changing scene.

### S4. `spawn_remote_skater` has no scene-transition stash (its sibling RPCs do)

`network_manager.gd:979-985` emits unconditionally; the GameManager handler drops it silently when
`_state_machine == null` (`game_manager.gd:575-576`). A client whose Hockey load completes after the
host's spawn burst permanently loses those skaters (bots from `_spawn_bots_from_lobby`, and any peer
spawned after them in `_push_lobby_assignments_to_clients` — each peer's `existing` snapshot only
covers peers spawned before it). No later re-sync exists. **Fix:** queue spawns when
`_state_machine == null` and flush in `on_slot_assigned`, exactly like `_pending_existing_players`.

---

## 3. High — go-live / Steam

### G1. Direct-IP + hardcoded port 7777 is not viable for a public audience

`constants.gd:23`, `network_manager.gd:362-377`, `online_popup.gd` (bare IP field, no port). No
UPnP/STUN/relay; host must port-forward, impossible under CGNAT. Fine while distribution is
"playtesters you talk to"; not for a Steam page implying click-and-play multiplayer.

**The Steam migration surface is pleasantly small.** ENet-specific code is exactly three sites:
`start_host()` (`:362`), `start_client()` (`:372`), and the `as ENetMultiplayerPeer` /
`set_timeout` cast in `request_join` (`:666-670`). Everything else goes through the generic
`multiplayer` / `@rpc` API, which GodotSteam's `SteamMultiplayerPeer` implements as a drop-in
`MultiplayerPeer` (free relay + NAT traversal). Touch list: those three sites, the `OnlinePopup` IP
UI (→ lobby browser / friend invite), `CONNECT_TIMEOUT`/`pending_error` plumbing,
`MAX_CONNECTIONS` → lobby max_members, the per-peer `set_timeout` (Steam manages its own), and
`CareerStatsReporter.migrate_to_steam_id` (already scaffolded). The loss/jitter telemetry keeps
working — it uses your own u16 sequence, not ENet's.

### G2. Supabase: anon UPDATE on `career_stats` lets anyone poison anyone's career

`career_stats_reporter.gd:30-36` PATCHes `career_stats?uuid=eq.X` with the anon key — which
confirms anon UPDATE is enabled. The filter is client-supplied; anyone extracting the publishable
key from the .pck (or this repo) can PATCH arbitrary rows: rewrite outcomes, zero out stats, claim
rows via the `steam_id` column. There's no auth, so RLS can't row-scope this. Identity is a
self-asserted plaintext uuid, so targeted INSERT spoofing is also possible. **Fix:** drop the anon
UPDATE policy now (5 minutes in the dashboard; nothing else PATCHes); when Steam lands, do the
steam_id migration in an Edge Function that validates a Steam auth session ticket. INSERT spam is
accepted indie risk; consider a per-uuid rate-limit policy. (Bug-report telemetry is clean PII-wise:
name, uuid, version, OS name, six net floats.)

---

## 4. Medium

### Netcode robustness / anti-cheat

- **M1. Joiner attributes/jersey unvalidated.** `network_manager.gd:654-662`: `PlayerAttributes`
  clamps each level 1–3, but nothing enforces the strength+weakness spread — a modified client
  sends 3/3/3/3 and gets +7% speed, +10% agility, +18% size, +25% strength. `jersey_number` is
  stored raw. Fix: reject/normalize any spread that isn't {≤ one 3, ≤ one 1, rest 2};
  `clampi(jersey, 0, 99)`.
- **M2. `move_vector` magnitude unvalidated.** `input_state.gd:70-71` decodes up to length ≈ 32.7
  and `SkaterMovementRules.apply_movement` (`skater_movement_rules.gd:31,41`) uses it unnormalized
  as thrust direction. Speed is capped post-thrust, but a hacked client gets 0→max in one tick and
  instant 180° flips — a real edge in a momentum-skating game. Fix: `limit_length(1.0)` host-side.
- **M3. Contested-pickup timestamp shopping.** `pickup_claim_resolver.gd:154`: outside the 50 ms
  contest window, the earlier `host_timestamp` wins outright, and stamps up to 200 ms in the past
  are accepted with no future-bound check. Backdating every claim ~190 ms wins essentially all
  50/50 pucks. Fix: validate stamps against the host's expectation for that peer
  (`now − one_way ± slack` from `_peer_ping_ms`); reject future stamps.
- **M4. `request_join` not idempotent; no handshake timeout.** A duplicate `request_join` re-emits
  `peer_joined` → second `_registry.spawn` for the same peer overwrites the record and leaks the
  first skater node (`player_registry.gd:68-88` has no `has(peer_id)` guard). A peer that connects
  but never joins holds an ENet slot forever. Fix: early-return if registered; kick non-joining
  peers after ~10 s.
- **M5. f32 wire timestamps degrade on long host sessions** (quantifies the documented open
  question). Session-relative f32 in the world-state header (`world_state_codec.gd:101`),
  `last_processed_ts` (`:375`), and input stamps (`input_state.gd:47`). ULP: 0.49 ms @ 68 min,
  ~1 ms @ 2.3 h, ~2 ms @ 4.6 h. Onset: ~2–3 h → ~12% interpolation-alpha noise (visible remote
  micro-jitter); ~4.6 h → consecutive 240 Hz inputs quantize equal and the dedupe/ack filters
  (`remote_controller.gd:57-59`) start dropping real inputs; ~9 h → every other input dropped.
  `_session_start_ms` survives rematches, so this is host *process* uptime. Fix: u32 wire
  timestamps in 0.1 ms units (~119 h, constant precision), or rebase the epoch each game reset.
- **M6. `decode_stats` crashes on malformed input.** `world_state_codec.gd:321-344`: `data[-1]` on
  an untrusted Array, then an index walk from the untrusted value. Authority-only today, so it fires
  on version skew — turning "mixed versions" into script-error spam. Guard sizes, bail with
  `push_warning`.
- **M7. `on_game_reset` has no null guards.** `game_manager.gd:2124-2146` dereferences
  `_state_machine`/`_hit_claim`/`_registry`/`_shot_tracker` unguarded; every sibling RPC handler
  guards. Rematch RPC landing while a client is mid scene-transition script-errors. One-line fix.
- **M8. Prefs corruption orphans career identity.** `player_prefs.gd`: corruption handling is
  otherwise good (defaults + clamps + type checks), but `player_uuid` lives in this one file and
  `_ready()` regenerates it on any load failure, overwriting the corrupt file. `ConfigFile.save()`
  isn't atomic — a crash mid-write permanently severs the player from their career stats. Fix:
  write-temp-then-rename, or persist the uuid in a second tiny file.

### Performance (host = 6 skaters + 2 goalies + puck @ 240 Hz; broadcast 120 Hz)

Top five by payoff:

- **P1. Top-hand IK allocates ~10k objects/s on the host** — the hottest site.
  `skater_ik_coordinator.gd:112-119`: the 3-pass loop builds a fresh `TopHandIK.Config` per
  iteration (`_ik_config()`, `:356`) and `TopHandIK.solve` returns a fresh Dictionary per iteration
  (`top_hand_ik.gd:78,131`); `update_bottom_hand` adds another Config (`:368`). ≈ 7 allocs × 6
  skaters × 240 Hz. Fix: cache Configs on the coordinator (rebuild only in `apply_attributes`;
  `blade_y` is the only per-tick field), have `solve()` fill a caller-provided result.
- **P2. Cosmetic mesh/arm IK runs at 240 Hz and again per reconcile-replay input.**
  `skater_controller.gd:499-501` → `skater.gd:656-693`: ~20 Node3D transform writes + 3–5 `look_at`
  per skater per tick (~30k transform-dirty writes/s host-side, only ~25% ever rendered), none
  feeding gameplay (pickup/poke use the `blade` Marker3D). The block also runs for **every replayed
  input** in `LocalController.reconcile` (`local_controller.gd:346`; `is_replaying` only skips
  skating-apply) — a 100 ms-RTT reconcile does ~24 invisible full mesh/IK passes, a guaranteed
  hitch exactly when the network is bad. Fix: gate mesh updates on `not is_replaying` + one final
  pass post-replay (reconcile already re-applies the blade); move arm/cuff visuals to `_process`.
- **P3. Skater-getter Callables rebuild Arrays per call, several times per tick.**
  `game_manager.gd:655-661,702-706`; called by `PuckController._check_interactions` (240/s) and 3–5
  goalie predicates × 2 goalies × 240 Hz (`goalie_controller.gd:1128,1571-1574`). Fix: cached
  `Array[Skater]` on `PlayerRegistry` invalidated on roster change — the same pattern
  `team_id_by_skater` already uses for exactly this reason (`puck_controller.gd:61-64`). Also hoist
  `_opposing_shooter_near_puck` to once per goalie tick.
- **P4. StateBufferManager defeats its own pre-allocated rings.**
  `state_buffer_manager.gd:62-81`: `get_network_state()` / `get_state()` allocate a fresh state
  that's copied into the ring slot and discarded — 9 allocs/tick ≈ 2,160/s, contradicting the
  file's own header. Fix: `fill_network_state(slot)` variants writing into the slot.
- **P5. Reconcile does three `Array.filter()` rebuilds per broadcast (120 Hz) before the threshold
  check.** `local_controller.gd:258-279`; up to ~115k lambda invocations/s at high RTT, and it runs
  even when no snap fires. Both arrays are timestamp-sorted — replace with front-trim `pop_front()`
  loops; cap pathological replay lengths (480-input worst case ≈ 3,400 allocs + ~10k node writes in
  one frame).

Also worth doing:

- **P6. `max_physics_steps_per_frame` unconfigured.** `project.godot` sets only
  `physics_ticks_per_second=240`; the default cap of 8 means a host below 30 FPS silently dilates
  sim time against the wall clock that clock-sync uses — every client interpolator extrapolates
  simultaneously. Set it explicitly, document the 30 FPS host floor, watch the existing tick
  p95/p99 telemetry.
- **P7. Misc per-tick churn:** `MovementConfig` rebuilt per skater per tick
  (`skater_controller.gd:910-926` — goalie controller already fixed this pattern);
  `state in [array-literal]` allocates per check (~6k/s; `skater_controller.gd:483-485,899,907`,
  `skater_pose_coordinator.gd:103,143`); interpolation allocates 2–3 objects per actor per tick
  client-side (`buffered_state_interpolator.gd:29,39,94`, `remote_controller.gd:145`,
  `puck_controller.gd:447`, `goalie_controller.gd:1840,1873`) and could run at render rate;
  codec encode/decode PBA churn (~2.2k allocs/s host — encode into one persistent buffer, decode
  at offsets without `slice`); GameManager per-tick Dictionaries (`game_manager.gd:384-393`,
  `player_registry.gd:319-323`, snapshot brackets at `state_buffer_manager.gd:112-120`);
  `Puck._physics_process` allocates two arrays per tick even idle (`puck.gd:360-370`);
  `clock_updated` emitted per packet → HUD label + theme-cache dirty at 120 Hz on clients
  (`world_state_codec.gd:227`, `hud.gd:896-902` — emit on integer-second change like `_last_period`).
- **P8. Goalie cosmetic arm IK recomputes unconditionally every rendered frame.**
  `goalie.gd:65-66` calls `_update_connectors()` from `_process` — correctly render-rate, *not* the
  240 Hz tick (this is the P2 pattern already applied) — which runs two `TwoBoneIK.solve_elbow` plus
  four `_update_arm_bone` passes (each a `look_at` + two `to_global`) plus connectors and shoulder
  spheres, per goalie per frame (`goalie.gd:334-354`). It's value-type math (`Vector3`/`Basis`), so
  it is **not** allocation churn and **not** a P1–P5-class issue — but it runs for both goalies every
  frame with no dirty-skip (a goalie idle in its stance recomputes the full rig 60×/s for zero visual
  change) and no visibility cull (the off-camera goalie still solves). Fix: cache last-applied
  `_body`/`_glove`/`_block_arm` transforms and bail when unchanged (the big win — goalies are
  stationary most of the time); gate on `is_visible_in_tree()` or a `VisibleOnScreenNotifier3D`.
  Tagged distinctly — render-rate, client-side, value-type — so it isn't mistaken for a host-tick
  regression or lumped in with the allocation-churn work.

### Standalone bug

- **M9. Goal replays are silently truncated to ~3 s.** `replay_recorder.gd:14`:
  `MEMORY_SIZE = 360  # ~9 s at 40 Hz` — but broadcast is now 120 Hz (`constants.gd:25`), so the
  ring holds 3 s and the 8 s clip extraction can't fill. Resize to ~1080 (and fix the stale 40 Hz
  comments here, `world_state_codec.gd:11`, `network_telemetry.gd:99`).

---

## 5. Low / hygiene

- **L1. Any-peer lobby RPCs missing the host guard** (`request_join:653`, `request_slot_swap:1133`,
  `request_player_ready:1176`, `request_rematch_vote:1192`, `request_color_vote:1287`): a malicious
  client can invoke them peer→peer on a victim client, spoofing local lobby UI signals. One
  `if not is_host: return` per handler, matching `receive_pickup_claim`.
- **L2. `_on_peer_disconnected` fan-out runs on clients** (`network_manager.gd:402-411`): ENet
  relays disconnects to everyone, so clients attempt authority-RPC sends (refused, error spam) and
  process the disconnect twice (idempotent, harmless). Gate on `is_host`.
- **L3. Claims report *target* interp delay, not the rendered delay** (`local_controller.gd:218-238`,
  `hit_claim_resolver.gd:100-101`): during adaptive-delay transients the rewind queries a puck tens
  of ms from what the claimant saw → legit pickups falsely rejected exactly when the network is
  rough. Pass the controller's live `interpolation_delay`.
- **L4. Clock-sync pings ride the shared reliable channel** — retransmitted/queued pings feed
  inflated RTT samples into the offset (outlier-drop mitigates). Standard practice: unreliable
  pings, ideally a dedicated channel.
- **L5. `on_scene_exit` misses fields**: `_pending_existing_players` (stale roster can spawn into
  the next session via `on_slot_assigned:463-466`), `_last_ghost_state` (bot ids are deterministic,
  can garble the next bots match's first ghost RPC), plus cosmetic ones. `NetworkManager.reset()`
  never clears `_peer_ping_ms`, and disconnects don't erase per-peer telemetry entries — slow
  unbounded growth across sessions.
- **L6. Host's own name bypasses `NameFilter`** (`network_manager.gd:359`; enforcement is host-side
  for joiners — correctly — but never re-checked for the host), and Supabase POSTs use raw
  `PlayerPrefs` names. Revisit when career totals are visible to others.
- **L7. Release pipeline rolls forward only**: `deploy.yml` force-moves `latest` and deletes
  artifacts — no way to roll back a bad build. Push a `v0.1.N` tag per release too. Note every push
  to `main` auto-publishes: `main` *is* prod.
- **L8. Committed editor junk**: `Scenes/Main.tscn11808881489.tmp` and
  `Scenes/Main.tscn11815209883.tmp` are tracked; `Main.tscn` no longer exists. Delete, gitignore
  `*.tmp`.
- **L9. Doc drift**: CLAUDE.md Launch Modes describes `MainMenu.tscn` which doesn't exist (real
  flow: `Boot.tscn` → free-play `Hockey.tscn`, `SideMenu` + `Lobby.tscn`); CLAUDE.md claims the
  main menu runs `UpdateChecker`; `ARCHITECTURE.md:342` claims a roster gate that doesn't exist
  (B3); stale "40 Hz" comments; `world_state_codec.gd:36-38` and `lag_comp_rewind.gd:17-19` still
  describe the retired client-side-goalie-AI model; `_spawn_bots_from_lobby` comment says bot ids
  are "[-6,-1]" (they're 10000+). `replay_file_writer.gd:163` "~40 syscalls/sec" comment is stale.
- **L10. `_on_connection_failed`/`_on_server_disconnected` use `push_error`** for expected
  user-facing conditions — invisible in release. Cosmetic once S3 lands.
- **L11. Game-over popup isn't Escape-closable** (`hud.gd:146-147`) — deviates from the project's
  ui_cancel rule; decide deliberately (Escape is also the route to Options at game-over).
- **L12. Stall-catch-up broadcasts share one wall-millisecond timestamp** (`network_manager.gd:240-246`),
  so the documented "distinct timestamps to interpolate through" doesn't hold — clients still see a
  snap after a host hitch. Also `RemoteController` drops out-of-order with `<` while
  `GoalieController` uses `<=` — harmless inconsistency.
- **L13. Minor perf**: IceScratchMap renders the 5.6 MP target every frame even with zero strokes
  (`UPDATE_ALWAYS`, `ice_scratch_map.gd:59`); host input-batch decode allocates ~2/3 throwaway
  InputStates before the dedupe drops them; name-label follow could ride `_process`.

---

## 6. What's already solid (verified, no action)

- **Reconcile implementation matches every documented invariant** — shot-state guards, mouse
  seeding, board clamp inside replay, impulse injection at matching timestamps,
  prediction-history trajectory comparison. No doc-vs-code drift found in the reconcile path.
- **Claim-path validation is genuinely good**: sender identity never client-supplied; hit impulses
  re-derived from rewound host snapshots with range gates + cooldowns; rewind depth clamped;
  `MAX_CLAIM_AGE_S` enforced (everywhere except shots — B1).
- **Input ingestion hardened end-to-end**: size/count caps, per-input bounds checks, plausibility
  window, dedupe, timestamp-gated consumption, host's own delta (no time-dilation), post-thrust
  speed caps (no speed hack). Sequence wraparound handled both directions.
- **Codec truncation defense**: header/min-size/per-block checks, carrier-idx sentinel,
  `decode_for_replay` validates claimed counts. Replay *file* reading is exemplary (magic, version,
  allocation caps vs. malicious length claims).
- **Disconnect handling**: puck dropped before despawn, buffers/registry/state machine cleaned,
  pending claims re-resolve at use-time, clients routed back cleanly, generous ENet timeouts.
- **ClockSync** honors the pure-NTP invariant: outlier drop, EMA, monotone floor.
- **Scene plumbing fundamentals**: autoload↔autoload wired once; per-match wiring targets recreated
  objects (no double-connect on rematch); teardown ordering in `on_scene_exit` careful and
  idempotent; ENet lifecycle correct across host→lobby→host; `get_tree().paused` never used, so
  menus can't desync prediction; ready-ordering races mostly covered by the stash/queue pattern
  (S2/S4 are the two gaps).
- **Performance fundamentals**: zero per-tick physics queries (everything analytic); pre-allocated
  rings with binary-search lookup; goalie configs cached; AI layer reuses scratch objects and reads
  the once-per-frame enriched snapshot; HUD/scoreboard event-driven; broadcast drops to 5 Hz in
  dead-puck phases; replay I/O on a worker thread; telemetry near-free when F3 closed.
- **Release pipeline**: release templates, test-gated deploy, artifact verification, anchored
  version baking. NetworkSim lag presets correctly dev-gated (`network_sim.gd:62`) — players cannot
  enable artificial lag in live matches. Logging hygiene clean (4 `print`s, all flag-gated).
- **Supabase reporters**: fire-and-forget with warnings, offline-safe, bug-report rate limiting +
  size caps, no PII beyond name/uuid/OS-name.

---

## 7. Addendum: GodotSteam port review (merged from main after the audit)

The ENet → Steam P2P migration (`steam_manager.gd`, `SteamMultiplayerPeer`, lobby browser) landed
on main and is merged into this branch. Review verdict: **the port is well-built** — `SteamManager`
is a clean isolation layer (only file touching the `Steam` singleton), degrades gracefully when
Steam/the GDExtension is absent (CI-safe), has an op-timeout so the spinner can't hang, filters the
lobby browser on `"game" == "mitts"` (necessary on the shared SpaceWar app id 480), arms the
connect timeout only after the peer exists, and `_close()` orders P2P shutdown before
`leaveLobby`. The shipped binaries are the MultiplayerPeer flavor (symbol verified). **G1 is now
largely resolved**; the remaining items there are swapping `APP_ID` 480 for the real app id and
the audit's untouched findings. New findings from the port:

- **A1 (HIGH). Cold-launch invites are silently lost.** `SteamManager._check_launch_invite`
  emits `lobby_invite_accepted` deferred during autoload init (`steam_manager.gd:92-98`), but the
  only listener is `SideMenu` (`side_menu.gd:366`), which is built inside the Hockey scene's HUD —
  the Boot title card is still up when the deferred emit fires. Accepting a Steam invite while the
  game is closed (`+connect_lobby`) launches to the title card and does nothing. Same loss for an
  overlay "Join Game" accepted before free play loads. **Fix:** stash
  `pending_invite_lobby_id: int` in `SteamManager` instead of (or in addition to) emitting;
  `SideMenu` consumes it when it wires up (and Boot could fast-path past the title card when an
  invite is pending).
- **A2 (HIGH, widens S1).** The new failure paths inherit the join-cancel dead-world bug. The
  loading screen's Cancel on `show_error` routes to `_on_join_cancelled` (`side_menu.gd:376`),
  which only `reset()`s — and `_on_host_lobby_failed` / `_on_join_lobby_failed` likewise reset
  without rebuilding. Since `_on_host_pressed` / `_on_join_pressed` run `GameManager.on_scene_exit()`
  *before* the async lobby op, every failure or cancel now strands the player in the half-dead
  free-play world (S1's symptoms: unpickable puck, null `_phase_coord` goal sensors). The
  "Steam isn't running" pre-checks are safe (they error out before teardown). **Fix is unchanged
  and now triply justified:** route cancel/failure dismissal through
  `GameManager.return_to_free_play()`.
- **A3 (MEDIUM). `reset()` doesn't clear pending Steam one-shots, and a cancelled join leaks
  lobby membership.** Cancel while a `joinLobby` is in flight: the
  `SteamManager.lobby_joined → _on_steam_lobby_joined` one-shot survives `reset()`, so the next
  `start_client_lobby` `connect()` hits "already connected" (error spam; functionally survivable).
  Worse: `leave_lobby()` no-ops (`current_lobby_id == 0`) and when Steam's join callback then
  lands, `_on_lobby_joined` early-returns on the `_pending_op` guard without leaving — the player
  stays a member of that lobby on Steam's backend until app exit, occupying a member slot and
  showing in the browser count. **Fix:** disconnect the four lobby one-shots in `reset()`; in
  `SteamManager._on_lobby_joined`, when `_pending_op != 2` but the join succeeded, immediately
  `Steam.leaveLobby(lobby_id)`.
- **A4 (LOW). Dead ENet-era code:** `Constants.PORT`, `PlayerPrefs.last_ip` (+ its save/load
  lines), `LoadingScreen.show_joining(ip)` are now unreferenced. Delete on the next pass.
- **A5 (note).** B2 (version handshake) is still open and Steam makes a cheap second layer
  available: set a `"version"` lobby-data key at create and filter/annotate the browser on it.
  Keep the `request_join` protocol check as the authoritative gate either way. B3 (mid-game 7th
  joiner crash) is unchanged — the Steam lobby caps members at 10, which is exactly the
  configuration that triggers it.

---

## 8. Suggested order of attack

1. **B1** — `ShotReleaseValidator` (one-timer gate + rtt/back-date/power clamps). Closes all three
   shot exploits in one consistent unit.
2. **B2** — protocol version in `request_join` + instantiate `UpdateChecker` (~a day, one workflow).
3. **B3 + M4** — mid-game roster gate + join idempotence/timeout (same code area).
4. **S1/A2 + S2 + S3 + A1/A3** — join-cancel/failure recovery via `return_to_free_play()`,
   transition-pending stash flag, surface `pending_error`, invite stash, one-shot cleanup. All
   small; together they cover every "playtester hits a bad join" path.
5. **G2** — drop the anon UPDATE policy (5 minutes, do it now).
6. **M9** — replay ring resize (trivial, user-visible win).
7. **P1–P5** when convenient — biggest wins are IK config caching and gating mesh updates out of
   reconcile replay.
8. **G1 (Steam networking)** is the big rock, but the code is well-positioned: three ENet call
   sites + the join UI.

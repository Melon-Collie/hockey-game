extends Node

# AI bots are tracked in PlayerRegistry alongside human peers but never
# correspond to an ENet connection — synthesizing a peer_id from a high
# range keeps PlayerRecord keys unique without colliding with either real
# ENet ids (1..MAX_CONNECTIONS, well under 1000) or domain "no peer / not
# found" sentinels (commonly -1, 0). Code that dispatches per-peer RPCs
# must use is_bot_peer / is_real_peer to gate routing — peer_id sign is
# NOT a bot indicator and must not be assumed.
const BOT_ID_BASE: int = 10_000
const BOT_ID_MAX: int = BOT_ID_BASE + 9  # 10 bots max (5 per team, 5v5 capacity)

# Re-exported from ClockSync so lag-comp resolvers can reference it without
# loading the script directly. Single source of truth lives in clock_sync.gd.
# Used by pickup/poke claim rewind to find the host's snapshot whose blade
# state matches what the client predicted at view-time — the input that
# produced the client's blade at host_timestamp T was stamped T + INPUT_LEAD_SEC
# and the host's gated processing produced its snapshot at host wall T + INPUT_LEAD_SEC.
const _ClockSyncScript: GDScript = preload("res://Scripts/networking/clock_sync.gd")
const INPUT_LEAD_SEC: float = _ClockSyncScript.INPUT_LEAD_SEC


func is_bot_peer(peer_id: int) -> bool:
	return peer_id >= BOT_ID_BASE and peer_id <= BOT_ID_MAX


# True iff peer_id is a real ENet connection (positive, not a bot, not the
# -1/0 "no peer" sentinel). Use this when iterating PlayerRegistry to
# decide whether rpc_id can target the peer.
#
# IMPORTANT: ENet peer ids in Godot 4 come from MultiplayerPeer.generate_unique_id(),
# which returns a random 31-bit int — typically in the billions, almost never
# below 10_000. So a "peer_id < BOT_ID_BASE" check excludes nearly every real
# human client. Excluding only the tight bot window is what makes this correct.
# (Probability of an ENet-assigned id colliding with one of the six bot slots
# is 6 / 2^31, i.e. negligible.)
func is_real_peer(peer_id: int) -> bool:
	return peer_id > 0 and not is_bot_peer(peer_id)

# ── Outbound signals (application layer listens) ─────────────────────────────
# NetworkManager observes ENet + RPC traffic; GameManager connects to these in
# _ready and executes the corresponding orchestration work. Keeps the upward
# call discipline — infrastructure never calls into application directly.
signal host_ready
# Host: the Steam lobby is up and the SteamMultiplayerPeer is assigned — the
# menu waits on this before changing to the Lobby scene (Steam lobby creation
# is async, unlike ENet's instant create_server). Failure path mirrors it.
signal host_lobby_ready
signal host_lobby_failed(reason: String)
# Client: lobby join failed before the connection handshake even began (Steam
# couldn't enter the lobby). Post-join handshake failures still surface via the
# existing connection_failed / CONNECT_TIMEOUT paths.
signal client_lobby_failed(reason: String)
signal client_connected
signal disconnected_from_server
# Client: the host refused our request_join (version mismatch, match full).
# Fires before the host drops the connection so the join UI can show the
# reason instead of a generic timeout.
signal join_rejected(reason: String)
signal peer_joined(peer_id: int)
signal peer_disconnected(peer_id: int)
signal world_state_received(data: PackedByteArray)
signal slot_assigned(team_slot: int, team_id: int, jersey_color: Color, helmet_color: Color, pants_color: Color)
signal remote_skater_spawn_requested(peer_id: int, team_slot: int, team_id: int, jersey_color: Color, helmet_color: Color, pants_color: Color, is_left_handed: bool, player_name: String, jersey_number: int, attributes: PlayerAttributes)
signal existing_players_synced(player_data: Array)
signal local_puck_pickup_confirmed
signal local_puck_stolen(was_stick_lift: bool)
signal one_timer_release_received(direction: Vector3, power: float, peer_id: int, host_timestamp: float, rtt_ms: float, interp_delay_ms: float, client_origin: Vector3)
signal carrier_puck_dropped
signal remote_carrier_changed(new_carrier_peer_id: int)
signal ghost_state_received(peer_id: int, is_ghost: bool)
signal goal_received(scoring_team_id: int, score0: int, score1: int, scorer_name: String, assist1_name: String, assist2_name: String)
signal puck_out_of_play_received
signal icing_called_received
signal goalie_freeze_called_received
signal offside_called_received
signal faceoff_positions_received(positions: Array)
signal game_reset_received(new_game_id: String)
signal stats_received(data: Array)
signal slot_swap_requested(peer_id: int, new_team_id: int, new_slot: int)
signal slot_swap_confirmed(peer_id: int, old_team_id: int, old_slot: int, new_team_id: int, new_slot: int, jersey: Color, helmet: Color, pants: Color)
signal game_started(config: Dictionary)
signal lobby_roster_synced(roster: Array)
signal color_vote_changed(peer_id: int, color_slot: int)
signal color_votes_synced(votes: Dictionary)
signal team_colors_changed(home_slot: int, away_slot: int)
signal lobby_settings_synced(num_periods: int, period_duration: float, ot_enabled: bool, rule_set: int, team_size: int, bot_difficulty: int, goalie_difficulty: int)
signal return_to_lobby_received(roster: Array)
signal player_ready_changed(peer_id: int, is_ready: bool)
# Lobby per-slot bot toggle. Slot keys follow LobbyManager._slot_key (team*3+slot).
# Host authoritative; clients mirror. Phase 1 only emits on host-driven changes.
signal bot_slot_changed(slot_key: int, is_bot: bool)
signal bot_slots_synced(bot_slots: Dictionary)
signal rematch_vote_changed(peer_id: int, vote: int)
signal rematch_voters_changed(total: int)
signal clock_ready
signal pickup_claim_received(peer_id: int, host_timestamp: float, interp_delay_ms: float, blade_curr: Vector3, blade_prev: Vector3, top_hand: Vector3)
signal poke_claim_received(peer_id: int, host_timestamp: float, interp_delay_ms: float, expected_carrier_peer_id: int, blade_curr: Vector3, blade_prev: Vector3)
signal stick_lift_claim_received(peer_id: int, host_timestamp: float, interp_delay_ms: float, expected_carrier_peer_id: int, blade_curr: Vector3)
signal hit_claim_received(hitter_peer_id: int, victim_peer_id: int, host_timestamp: float, interp_delay_ms: float)
signal board_hit_received(position: Vector3)
signal goal_body_hit_received(position: Vector3)
signal post_hit_received(position: Vector3)
signal goalie_hit_received(position: Vector3)
signal deflection_received(position: Vector3)
signal body_block_received(position: Vector3)
signal puck_strip_received(position: Vector3)
signal stick_lift_received(position: Vector3)
# Distinct from stick_lift_received on purpose: a nudge (self-tap) is its own
# gameplay event, so it carries its own cue and can be re-sounded independently
# later without disturbing the opponent stick-lift strip.
signal nudge_received(position: Vector3)
signal shot_sound_received(position: Vector3, is_slapper: bool)
# Host-authoritative body-check impact (Lever A). Fired on every client (and
# self-emitted on the host) when a hit is credited, so impact VFX/sound — and
# the hitter's check-delivery body pose — are consistent everywhere instead of
# relying on each client's non-authoritative local collision detection.
# `force` is the VFX-scale impact force.
signal body_check_landed(hitter_peer_id: int, victim_peer_id: int, force: float, hit_dir: Vector3)
# Smart ping (context-sensitive team message). Fired on every peer (host
# self-emits) with the sender's resolved ping; GameManager filters display to
# the sender's team and — host-only — routes the bot directive. `ping_type`
# is PingRules.Type; `target_peer_id` / `world_pos` meaning depends on it.
signal smart_ping_received(sender_peer_id: int, ping_type: int, target_peer_id: int, world_pos: Vector3)
signal input_batch_received(peer_id: int, inputs: Array[InputState])
# Mid-game player → spectator transition. Host broadcasts to all peers; every
# receiver despawns the demoted peer's skater locally (registry.remove handles
# state-machine cleanup, queue_free, etc.). The demoted peer's local
# GameManager additionally tears down its LocalController and mounts
# SpectatorCamera. The opposite direction (spectator → player) reuses the
# existing assign_player_slot + spawn_remote_skater RPCs and needs no new
# broadcast.
signal spectator_demoted_received(peer_id: int)

# Vote-to-skip goal replay (Rocket-League style). Clients send their vote via
# request_skip_replay; host counts and broadcasts the running tally back to
# everyone. Drivers tear down when current == total. Bots never have an ENet
# connection so they're not in the voter total; spectators are.
signal skip_replay_request_received(peer_id: int)
signal skip_replay_vote_updated(current: int, total: int)

# Replay-recorder events (shot, puck_pickup, puck_boards, body_check, etc.).
# Host records each event into its own ring buffer AND broadcasts it so every
# client / spectator mirrors the same event timeline. Without this clients'
# in-memory clip would have only frames (no events), so their goal replays
# would miss the adaptive clip-start logic, the shot-anchored slow-mo cut, the
# behind-net cam's lateral offset, and the audio cue dispatch during playback.
signal replay_event_received(host_ts: float, event: Dictionary)

# Host entered (true) or left (false) the goal-replay cinematic. Mirrored to
# clients via notify_replay_mode so they can start / stop their own local
# GoalReplayDriver in lockstep with the host. The world-state phase never
# carries GOAL_SCORED to clients (the host stops broadcasting the instant it
# enters replay mode), so this flag edge is the client's trigger.
signal replay_mode_changed(active: bool)

# Local player edited their identity (name / jersey number / handedness)
# while a session is live (e.g. from the SideMenu's player card during free
# play). GameManager listens and pushes the change to the local skater
# without a respawn.
signal local_identity_changed(player_name: String, jersey_number: int, is_left_handed: bool)

# Local player picked a different attribute spread (Speed/Agility/Size/Skill).
# Fires after the new picks land in PlayerPrefs and _peer_attributes[1] is
# updated. GameManager listens and re-applies the multipliers to the local
# skater's controller. Only emitted in offline play — online matches lock
# attributes at join time.
signal local_attributes_changed(attributes: PlayerAttributes)

# Local player picked a different favorite team palette. Fired by
# apply_preferred_color (which writes PlayerPrefs.preferred_color_slot).
# GameManager re-tints the home team's local actors and, if the new home
# now collides with the current away, re-rolls the away color too.
signal local_preferred_color_changed(home_color_slot: int, away_color_slot: int)

# ── State ─────────────────────────────────────────────────────────────────────
var is_host: bool = false
var game_initiated: bool = false
var local_is_left_handed: bool = true
var local_player_name: String = "Player"
var local_jersey_number: int = 10
var pending_game_config: Dictionary = {}
var pending_lobby_slots: Dictionary = {}  # peer_id → { team_id, team_slot, player_name, is_left_handed }
var pending_lobby_roster: Array = []
var pending_join_slot: Dictionary = {}   # { team_slot, team_id, jersey_color, helmet_color, pants_color }
var is_offline_mode: bool = false
var is_tutorial_mode: bool = false
# Which offline practice drill is running ("" when none) — see DrillRegistry
# for the catalogue. Like tutorial mode, a drill is a single-local-player
# offline session whose flow is owned by a dedicated manager (spawned by
# game_scene.gd from the registry) rather than the normal match orchestration.
var drill_id: String = ""
# Which tutorial to run. game_scene.gd reads this when instantiating
# TutorialManager. Empty when not in tutorial mode.
var tutorial_id: String = ""
# Free play is the boot mode: offline, no bots, direct entry to Hockey.tscn,
# Escape opens the SideMenu instead of the in-match PauseMenu. Set true by
# Boot and by return-to-free-play; cleared by reset() and whenever any other
# activity (host, client, lobby-with-bots, tutorial) is started.
var is_free_play_mode: bool = false
var pending_home_color_slot: int = TeamColorRegistry.DEFAULT_HOME_SLOT
var pending_away_color_slot: int = TeamColorRegistry.DEFAULT_AWAY_SLOT
var pending_color_votes: Dictionary = {}  # peer_id → color_slot (int; host authoritative; all peers mirror)
# slot_key (team*3+slot, matching LobbyManager._slot_key) → bool. Empty slots
# marked true get an AI bot at game start. Host authoritative; clients mirror.
var pending_bot_slots: Dictionary[int, bool] = {}
# Parallel to pending_bot_slots: the curated identity (name / number /
# handedness) chosen for each bot slot at toggle time. Host picks via
# BotIdentityRegistry and broadcasts so the lobby UI can show the actual
# bot that will spawn instead of a generic "BOT" placeholder.
var pending_bot_identities: Dictionary[int, Dictionary] = {}
# Integer physics-tick counter on the host. Used by AI/perception code as a
# deterministic salt for per-tick RNG. Clients do not maintain or consume
# this — they read estimated_host_time() instead.
var host_tick: int = 0
var pending_num_periods: int = GameRules.NUM_PERIODS
var pending_period_duration: float = GameRules.PERIOD_DURATION
var pending_ot_enabled: bool = GameRules.OT_ENABLED
var pending_rule_set: int = GameRules.DEFAULT_RULE_SET
var pending_team_size: int = GameRules.DEFAULT_TEAM_SIZE
# Host's AI difficulty picks, mirrored to clients for lobby DISPLAY only —
# the AI itself is host-simulated from the host's PlayerPrefs, so clients
# never feed these back into gameplay (and never write them to their own
# prefs).
var pending_bot_difficulty: int = BotSkillProfile.Difficulty.NORMAL
var pending_goalie_difficulty: int = GoalieSkillProfile.Difficulty.NORMAL
var pending_join_players: Array = []     # sync_existing_players data for join-in-progress

# Client: true between learning that a Hockey-scene (re)load is coming
# (join-in-progress / game-start RPC) and the new scene's on_game_scene_ready.
# Forces assign_player_slot / sync_existing_players into their stash path —
# the scene-path check alone passes when joining FROM free play (the dying
# scene is also Hockey.tscn), which spawned the world into a scene about to
# be freed.
var scene_swap_pending: bool = false
# Path to a .mreplay set by the main-menu replay browser before changing scene
# to the viewer. Cleared by ReplayViewer._ready after consumption.
var pending_replay_path: String = ""
var _peer_handedness: Dictionary = {}     # peer_id -> bool (host only)
var _peer_names: Dictionary = {}          # peer_id -> String (host only)
var _peer_numbers: Dictionary = {}        # peer_id -> int (host only)
# peer_id -> SteamID64 (host only), captured from request_join. Stable across a
# reconnect (the peer_id is not), so GameManager keys reserved slots by it to
# restore a returning player's team/slot/stats. 0 when the joiner sent no Steam
# ID (pre-v7 build, or a non-Steam transport).
var _peer_steam_ids: Dictionary[int, int] = {}
# peer_ids the host intentionally kicked (host only). Read during the
# peer_disconnected emit so GameManager skips the reconnect reservation — a
# kicked player must not be able to reclaim a held slot by rejoining. Erased
# after the emit / on reset.
var _kicked_peers: Dictionary[int, bool] = {}
# peer_id -> PlayerAttributes. Populated from request_join on the host and
# from sync_existing_players / spawn_remote_skater on clients. The host's
# own entry (key 1) is seeded from PlayerPrefs at startup and updated when
# the local player edits attributes in offline play.
var _peer_attributes: Dictionary[int, PlayerAttributes] = {}
# peer_id -> Shot Power Sensitivity (0.25..4.0), from request_join. The host
# reads it for a remote human's RemoteController so their authoritative wrister
# power matches what the client predicted with its own sensitivity.
var _peer_shot_sensitivity: Dictionary[int, float] = {}
var _peer_ping_ms: Dictionary[int, int] = {}  # peer_id -> latest RTT in ms (all peers)
# Host-only: EMA of the host's OWN round-trip measurement to each peer
# (host_ping/host_pong). Backs _peer_ping_ms on the host — the trusted RTT that
# lag-comp claim validation reads via get_peer_ping_ms — so a modified client
# can't forge the value (the old client-self-reported report_ping). Float here
# for smoothing; the rounded int is mirrored into _peer_ping_ms for consumers.
var _peer_rtt_ema_ms: Dictionary[int, float] = {}
const _PEER_RTT_EMA_ALPHA: float = 0.3

# Host: peers that have connected but not yet sent request_join, keyed to
# their connect time (local_time()). Swept in _process — a peer that never
# completes the handshake within _HANDSHAKE_TIMEOUT_S is dropped so it can't
# hold a lobby slot forever.
var _pending_handshake: Dictionary[int, float] = {}
const _HANDSHAKE_TIMEOUT_S: float = 10.0
const _KICK_FLUSH_DELAY_S: float = 0.5
# Host: last time (local_time()) each connected peer sent us anything — input
# batches (~input rate) or clock-sync pings (every 2s). Swept in _process; a peer
# silent past _PEER_LIVENESS_TIMEOUT_S is force-disconnected. ENet's per-peer
# timeout used to cover this; Steam's relay keepalive does eventually, but ~2x
# slower, so a hard-crashed or network-yanked peer's skater lingers frozen on
# everyone's screen. This detects it app-side from the traffic that's already
# flowing. Bots never enter here (no real connection); offline mode stays empty.
var _peer_last_seen: Dictionary[int, float] = {}
const _PEER_LIVENESS_TIMEOUT_S: float = 5.0
# Callable () -> Array. Set by GameManager at startup so the broadcast loop
# can pull world state without reaching up into the application layer.
var _world_state_provider: Callable = Callable()
# Callable (batch_frames: int) -> Array[InputState]. Set by GameManager when the
# local player spawns; the input-tick poll uses it to gather a batch without
# holding a controller reference.
var _input_batch_provider: Callable = Callable()
var _clock_sync: RefCounted = null  # ClockSync instance, client only
# Carrier-event redundancy (see SnapshotEventLog): the host records each carrier
# event and appends the recent set to every unreliable world-state packet in
# `_broadcast_state`; clients apply the block in `receive_world_state` and gate
# the reliable backstop RPCs through the same seq watermark. Connection-scoped:
# replaced only in reset() — deliberately NOT in prepare_for_new_game(), because
# a rematch keeps client connections (and their watermarks) alive, and a seq
# restart would make them silently drop every event of the next match.
var _event_log: SnapshotEventLog = SnapshotEventLog.new()
# Stored once so the 120 Hz client receive path doesn't allocate a bound
# Callable per packet.
var _snapshot_event_dispatch: Callable = _dispatch_snapshot_event
var _session_start_ms: int = 0
var _replay_mode: bool = false
var _replay_clock: float = 0.0

# ── Packet-loss tracking ──────────────────────────────────────────────────────
# Client-side: gap detection from received WS sequence numbers.
var _last_ws_seq_received: int = -1
var _ws_drop_window: int = 0
var _ws_recv_window: int = 0
var _ws_loss_window_timer: float = 0.0
var packet_loss_pct: float = 0.0
# Host-side: per-peer downstream (host->client) loss %. The client measures its OWN
# world-state loss from gaps in the seq numbers it received (the accurate signal —
# _ws_drop_window below) and reports it in each input-batch header; the host stores
# it here verbatim. This replaced an echo-gap estimator that re-derived loss from
# the client's last-received seq: because the client echoed only its LATEST seq
# once per batch while world state broadcasts at STATE_RATE, any WS packet the
# client received-but-didn't-echo (Steam delivers clumpy) was miscounted as
# dropped, inflating a clean link to ~50%. Read by get_peer_loss_rate.
var _peer_loss_rates: Dictionary = {}
# Jitter measurement (client side)
var _jitter_samples: Array[float] = []
var _last_ws_arrival_time: float = -1.0
# Packet delay (PDV) measurement — see _record_packet_delay. Each packet's delay
# vs the synced host clock, NOT the raw inter-arrival gap, so relay clumping
# barely moves it. This de-clumped spread is the jitter cushion fed into the
# interp-delay target (_compute_target_interpolation_delay) as well as the F3
# "Delay spread" readout.
var _pdv_floor: float = -1.0
var _pdv_mean: float = 0.0
var _pdv_dev: float = 0.0
# get_target_interpolation_delay() per-physics-frame cache (see that function).
var _target_interp_cached: float = -1.0
var _target_interp_frame: int = -1

# ── Timers ────────────────────────────────────────────────────────────────────
var pending_error: String = ""
# Set when a client loses an established connection mid-match (not a kick or a
# graceful host shutdown) so the rebuilt free-play SideMenu can offer a
# Reconnect button into the same Steam lobby — the host may be holding the slot
# open. Deliberately NOT cleared by reset() (it must survive the
# return_to_free_play teardown); SideMenu consumes and clears it on _ready.
var pending_reconnect_lobby_id: int = 0
# Why the online session is ending, for the network_sessions telemetry row.
# Set by the abnormal-end handlers just before they trigger teardown
# ("host_lost" / "host_ended" / "kicked"); consumed one-shot by
# GameManager.on_scene_exit via take_session_end_reason(). Empty means the
# local player left on their own (reported as "quit") or the game completed
# (the game-over path reports "completed" first and wins the double-post
# guard). Cleared by reset() so a reason from an aborted join can't leak
# into the next session's row.
var pending_session_end_reason: String = ""

var _input_timer: float = 0.0
# Broadcast cadence. Counter ticks here every physics frame (see
# `_physics_process`); the broadcast call itself fires from `try_broadcast`,
# invoked by GameManager._physics_process after StateBufferManager.capture so
# the broadcast reads this tick's state. `_last_broadcast_us` tracks wall-clock
# for telemetry.
var _state_tick_counter: int = 0
var _last_broadcast_us: int = 0
var _ping_timer: float = 0.0
const _PING_INTERVAL: float = 2.0
var _connect_timer: float = -1.0
var input_delta: float = 1.0 / Constants.INPUT_RATE
var state_delta: float = 1.0 / Constants.STATE_RATE
# Number of physics ticks between broadcasts. PHYSICS_TICK / STATE_RATE
# (120/120 = 1 — every tick). Recomputed by `set_broadcast_rate`, a runtime
# knob with no callers today (the per-phase dead-puck downshift was removed:
# stoppage phases are seconds long so it saved nothing meaningful, starved
# client interpolation buffers right before the faceoff drop, and polluted
# the client jitter window, which assumes STATE_RATE packet spacing); kept
# for future congestion response. Stall resilience:
# on a host main-thread freeze, Godot's physics catch-up fires multiple
# back-to-back physics ticks. The counter increments in NetworkManager._physics_process
# for each, and GameManager._physics_process invokes try_broadcast() per tick,
# so back-to-back broadcasts fire at the cadence threshold — clients get the
# multiple distinct host_timestamps they need to interpolate through the gap
# instead of one snap.
var _state_tick_divisor: int = Constants.PHYSICS_TICK / Constants.STATE_RATE
const CONNECT_TIMEOUT: float = 10.0

func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	# Seed local identity from saved prefs. PlayerSettingsPopup writes both
	# PlayerPrefs and these fields on Apply, but on a fresh launch nothing
	# else copies the saved values across, so without this the menu shows
	# the user's name/number while spawn falls back to "Player"/10/true.
	local_player_name = PlayerPrefs.player_name
	local_jersey_number = PlayerPrefs.jersey_number
	local_is_left_handed = PlayerPrefs.is_left_handed
	_peer_attributes[1] = PlayerPrefs.get_player_attributes()

# ── Connection ────────────────────────────────────────────────────────────────
func start_offline() -> void:
	is_host = true
	game_initiated = true
	is_offline_mode = true
	_peer_handedness[1] = local_is_left_handed
	_peer_names[1] = local_player_name
	_peer_numbers[1] = local_jersey_number
	_peer_attributes[1] = PlayerPrefs.get_player_attributes()
	pending_game_config = {"num_periods": 1, "period_duration": 0.0, "ot_enabled": false, "ot_duration": 0.0,
			"rule_set": GameRules.DEFAULT_RULE_SET,
			"team_size": GameRules.DEFAULT_TEAM_SIZE}


# Entry point that wraps start_offline with the free-play-specific seeding:
# home color = the player's saved favorite (or DEFAULT_HOME_SLOT if none picked
# yet), away color = a random non-home slot from the registry, and the
# player is always pinned to team 0 / slot 0 so they spawn as the home team
# instead of whichever side the state machine's host-registration happens
# to pick. Used by both Boot (initial launch) and
# GameManager.return_to_free_play.
func start_free_play() -> void:
	pending_home_color_slot = _resolve_preferred_home_slot()
	pending_away_color_slot = _pick_random_away_slot(pending_home_color_slot)
	pending_lobby_slots[1] = {"team_id": 0, "team_slot": 0}
	start_offline()
	# Free play is a casual warmup/practice mode — no infraction whistles getting
	# in the way. OFF disables offside + crease protection (icing is already off
	# in the default ARCADE set). Overrides the rule_set start_offline seeded.
	pending_game_config["rule_set"] = GameRules.RuleSet.OFF
	is_free_play_mode = true


# Update PlayerPrefs.preferred_color_slot and broadcast the change. Re-rolls
# the away color if the new home matches the current away so the player
# never faces a team wearing the same palette.
func apply_preferred_color(color_slot: int) -> void:
	PlayerPrefs.preferred_color_slot = color_slot
	PlayerPrefs.save()
	pending_home_color_slot = color_slot
	if pending_away_color_slot == color_slot:
		pending_away_color_slot = _pick_random_away_slot(color_slot)
	local_preferred_color_changed.emit(pending_home_color_slot, pending_away_color_slot)


func _resolve_preferred_home_slot() -> int:
	var saved: int = PlayerPrefs.preferred_color_slot
	if saved < 0:
		return TeamColorRegistry.DEFAULT_HOME_SLOT
	# Defensive: if the user's saved slot was removed from the registry (e.g.
	# team list edited between releases), fall back to the default rather
	# than crashing downstream lookups.
	if not TeamColorRegistry.get_all_slots().has(saved):
		return TeamColorRegistry.DEFAULT_HOME_SLOT
	return saved


func _pick_random_away_slot(home_slot: int) -> int:
	var slots: Array[int] = TeamColorRegistry.get_all_slots()
	var candidates: Array[int] = []
	for slot: int in slots:
		if slot != home_slot:
			candidates.append(slot)
	if candidates.is_empty():
		return TeamColorRegistry.DEFAULT_AWAY_SLOT
	return candidates[randi() % candidates.size()]


# Single entry point for in-session identity edits. PlayerSettingsPopup
# writes both PlayerPrefs and these fields on Apply; routing through here
# lets GameManager (and any future peer-broadcast) react to the change
# without each call site having to know about every listener.
func apply_local_identity(p_name: String, p_number: int, p_is_left: bool) -> void:
	local_player_name = p_name
	local_jersey_number = p_number
	local_is_left_handed = p_is_left
	_peer_names[1] = p_name
	_peer_numbers[1] = p_number
	_peer_handedness[1] = p_is_left
	local_identity_changed.emit(p_name, p_number, p_is_left)


func start_tutorial(id: String = TutorialRegistry.MOVEMENT_ID) -> void:
	is_tutorial_mode = true
	tutorial_id = id
	# Pre-assign team 0, slot 0 so the player always spawns as the home team.
	# on_host_started reads pending_lobby_slots[1] and skips the random assignment path.
	pending_lobby_slots[1] = {"team_id": 0, "team_slot": 0}
	start_offline()


# Offline practice drill (see DrillRegistry). Mirrors start_tutorial: one
# local player on team 0, no bots, no clock; the drill's registered manager
# (spawned by game_scene.gd) owns the staging, scoring, and score-X-of-N loop.
# Forces RuleSet.OFF so offsides/crease whistles can't interrupt an attempt.
func start_drill(id: String) -> void:
	drill_id = id
	pending_lobby_slots[1] = {"team_id": 0, "team_slot": 0}
	start_offline()
	pending_game_config["rule_set"] = GameRules.RuleSet.OFF


# True for the single-local-player scripted offline modes (tutorial, practice
# drills) where a dedicated manager owns puck placement and scoring, so the
# normal match machinery — out-of-bounds whistles, goal celebrations — must
# stand down.
func is_drill_mode() -> bool:
	return is_tutorial_mode or not drill_id.is_empty()


func local_time() -> float:
	return (Time.get_ticks_msec() - _session_start_ms) / 1000.0

# Lobby-phase transport attach: turns the running offline host session into an
# online one. Every hosted session now starts via start_offline (the unified
# Play flow) and goes online only when the lobby's visibility selector leaves
# Offline — this kicks off async Steam lobby creation and installs the host
# peer once the lobby_created callback lands. Callers wait on host_lobby_ready
# / host_lobby_failed (the selector shows a busy state meanwhile). Only valid
# from the lobby scene while no remote peers exist — there is no session state
# to migrate then, the offline session already runs the full host simulation.
# Host is still peer id 1, so all downstream RPC / slot / spawn code is
# unchanged.
func attach_online(public: bool) -> void:
	_session_start_ms = Time.get_ticks_msec()
	SteamManager.lobby_created.connect(_on_steam_lobby_created, CONNECT_ONE_SHOT)
	SteamManager.lobby_create_failed.connect(_on_steam_lobby_create_failed, CONNECT_ONE_SHOT)
	SteamManager.create_lobby(GameRules.MAX_CONNECTIONS, public)


# Inverse of attach_online, for the visibility selector's Offline position:
# drop the host peer and the Steam lobby and return to a pure offline session.
# The selector locks Offline out while human peers are connected, so there is
# nobody to announce to — teardown is silent. Lobby state (slots, bots,
# settings, votes) lives on the host and is untouched.
func detach_online() -> void:
	# A create still in flight (selector flipped back mid-spinner) must not
	# land a stale SteamMultiplayerPeer into the now-offline session.
	if SteamManager.lobby_created.is_connected(_on_steam_lobby_created):
		SteamManager.lobby_created.disconnect(_on_steam_lobby_created)
	if SteamManager.lobby_create_failed.is_connected(_on_steam_lobby_create_failed):
		SteamManager.lobby_create_failed.disconnect(_on_steam_lobby_create_failed)
	if multiplayer.multiplayer_peer != null and multiplayer.multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_DISCONNECTED:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = null
	SteamManager.leave_lobby()
	is_offline_mode = true
	_session_start_ms = 0

func _on_steam_lobby_created(_lobby_id: int) -> void:
	if SteamManager.lobby_create_failed.is_connected(_on_steam_lobby_create_failed):
		SteamManager.lobby_create_failed.disconnect(_on_steam_lobby_create_failed)
	# create_host's first arg is a virtual port (0 is fine); the optional second
	# arg is an ESteamNetworkingConfigValue options array (empty is fine).
	var peer := SteamMultiplayerPeer.new()
	var error := peer.create_host(0)
	if error != OK:
		push_error("Failed to start Steam host: " + str(error))
		host_lobby_failed.emit("Failed to create the host peer.")
		return
	_disable_nagle(peer)
	multiplayer.multiplayer_peer = peer
	is_offline_mode = false
	host_lobby_ready.emit()

func _on_steam_lobby_create_failed(reason: String) -> void:
	if SteamManager.lobby_created.is_connected(_on_steam_lobby_created):
		SteamManager.lobby_created.disconnect(_on_steam_lobby_created)
	host_lobby_failed.emit(reason)

# Client startup is two async phases: (1) join the Steam lobby, then (2) the
# normal connection handshake. Phase 1 resolves via SteamManager.lobby_joined;
# phase 2 is identical to the old ENet path (connected_to_server →
# _on_connected_to_server → client_connected + request_join).
func start_client_lobby(lobby_id: int) -> void:
	is_host = false
	game_initiated = true
	SteamManager.lobby_joined.connect(_on_steam_lobby_joined, CONNECT_ONE_SHOT)
	SteamManager.lobby_join_failed.connect(_on_steam_lobby_join_failed, CONNECT_ONE_SHOT)
	SteamManager.join_lobby(lobby_id)

func _on_steam_lobby_joined(_lobby_id: int, owner_steam_id: int) -> void:
	if SteamManager.lobby_join_failed.is_connected(_on_steam_lobby_join_failed):
		SteamManager.lobby_join_failed.disconnect(_on_steam_lobby_join_failed)
	var peer := SteamMultiplayerPeer.new()
	var error := peer.create_client(owner_steam_id, 0)
	if error != OK:
		push_error("Failed to connect to Steam host: " + str(error))
		client_lobby_failed.emit("Failed to create the client peer.")
		return
	_disable_nagle(peer)
	multiplayer.multiplayer_peer = peer
	# Arm the handshake timeout only now that the peer exists, so a slow lobby
	# join can't false-trip it.
	_connect_timer = 0.0

# Disable Steam's Nagle batching so each send flushes immediately instead of
# being coalesced up to the Nagle timer (~ms scale). Steam's default coalescing
# clumps the steady 120 Hz world-state stream into bursts, which the client sees
# as irregular arrivals → interpolation-buffer dry-outs → extrapolation snaps on
# remote actors. Applied to both peers: the host's flag governs its world-state
# sends, the client's governs its input-batch sends. Guarded by has_method so a
# GodotSteam build without the accessor degrades to default behaviour rather
# than crashing — watch for the warning in the log if smoothing doesn't improve.
func _disable_nagle(peer: SteamMultiplayerPeer) -> void:
	if peer.has_method("set_no_nagle"):
		peer.set_no_nagle(true)
	else:
		push_warning("SteamMultiplayerPeer.set_no_nagle unavailable; Nagle stays on (snapshot arrival may clump).")

func _on_steam_lobby_join_failed(reason: String) -> void:
	if SteamManager.lobby_joined.is_connected(_on_steam_lobby_joined):
		SteamManager.lobby_joined.disconnect(_on_steam_lobby_joined)
	client_lobby_failed.emit(reason)

func on_game_scene_ready() -> void:
	scene_swap_pending = false
	if is_host:
		host_ready.emit()

# Local peer id, safe to call when no multiplayer peer is assigned (offline mode):
# returns 1 since the local player acts as the host.
func local_peer_id() -> int:
	if multiplayer.multiplayer_peer == null:
		return 1
	return multiplayer.get_unique_id()

# Connected remote peer ids, safe to call when no multiplayer peer is assigned:
# returns an empty array in offline mode.
func connected_peer_ids() -> PackedInt32Array:
	if multiplayer.multiplayer_peer == null:
		return PackedInt32Array()
	return multiplayer.get_peers()

# ── Network Signals ───────────────────────────────────────────────────────────
func _on_peer_connected(id: int) -> void:
	if is_host:
		_pending_handshake[id] = local_time()
		# Start the liveness clock at connect so the grace window covers the
		# handshake; the first clock-sync ping (within ~0.5s) refreshes it.
		_peer_last_seen[id] = local_time()

func _on_peer_disconnected(id: int) -> void:
	_pending_handshake.erase(id)
	_peer_last_seen.erase(id)
	_peer_handedness.erase(id)
	_peer_names.erase(id)
	_peer_numbers.erase(id)
	_peer_attributes.erase(id)
	pending_color_votes.erase(id)
	# NOTE: _peer_steam_ids is deliberately NOT erased before the emit below —
	# GameManager.on_player_disconnected (a synchronous listener) reads
	# get_peer_steam_id(id) to key the reconnect reservation. Erased after.
	peer_disconnected.emit(id)
	_peer_steam_ids.erase(id)
	_kicked_peers.erase(id)
	# Per-peer telemetry books, else a stale peer's ping lingers on scoreboards.
	_peer_ping_ms.erase(id)
	_peer_rtt_ema_ms.erase(id)
	_peer_loss_rates.erase(id)
	# Notify all remaining clients so they remove the stale skater. Host-only:
	# the transport relays peer disconnects to clients too, and a client
	# attempting this authority RPC would just be refused with error spam.
	if is_host:
		for peer_id in connected_peer_ids():
			notify_player_disconnected.rpc_id(peer_id, id)

func _on_connected_to_server() -> void:
	_connect_timer = -1.0
	_session_start_ms = Time.get_ticks_msec()
	_clock_sync = _ClockSyncScript.new()
	_clock_sync.init_session(_session_start_ms)
	var local_attrs: PlayerAttributes = PlayerPrefs.get_player_attributes()
	# Stamp the local peer's OWN entry, not [1] (which is the host from a
	# client's view). on_slot_assigned spawns the local skater via
	# get_peer_attributes(local_peer_id()); keying at 1 here made that lookup
	# miss and fall back to all-medium, so the client's own matchup card and
	# local-prediction build showed defaults while every host-sourced view was
	# correct. Valid here — the unique id is assigned before connected_to_server.
	_peer_attributes[local_peer_id()] = local_attrs
	request_join.rpc_id(1, local_is_left_handed, local_player_name, local_jersey_number,
			local_attrs.height, local_attrs.weight, local_attrs.profile,
			local_attrs.curve, local_attrs.flex, local_attrs.length,
			SteamManager.steam_id, BuildInfo.PROTOCOL_VERSION,
			SteamManager.get_app_build_id(), PlayerPrefs.shot_power_sensitivity)
	client_connected.emit()

func _on_connection_failed() -> void:
	push_error("Connection failed")
	pending_error = "Connection failed."
	GameManager.return_to_free_play()

func _on_server_disconnected() -> void:
	push_error("Server disconnected")
	# Telemetry end-reason: an unexpected transport loss is "host_lost" unless a
	# more specific handler (match ended, kicked) already claimed the session.
	if pending_session_end_reason.is_empty():
		pending_session_end_reason = "host_lost"
	# Keep a more specific reason (host ended the match, kicked) if one
	# arrived just before the transport closed.
	if pending_error.is_empty():
		# Genuine, unexpected loss — offer a reconnect into the same lobby instead
		# of a toast. The host's reservation window may still be holding our slot.
		# Captured before reset()/_close() leaves the lobby and clears the id.
		if not is_host and SteamManager.current_lobby_id != 0:
			pending_reconnect_lobby_id = SteamManager.current_lobby_id
		else:
			pending_error = "Lost connection to server."
	disconnected_from_server.emit()
	GameManager.return_to_free_play()

func _exit_tree() -> void:
	_close()

func _close() -> void:
	if multiplayer.multiplayer_peer != null and multiplayer.multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_DISCONNECTED:
		multiplayer.multiplayer_peer.close()
	# Close P2P sessions (above) before leaving the lobby that owns them.
	# Idempotent — a no-op in offline/free-play/tutorial where no lobby exists.
	# Every teardown path (reset, _exit_tree, return_to_free_play, join-cancel)
	# funnels through here, so this one call covers them all. The validity
	# guard matters only on process quit: autoloads free in reverse
	# registration order, so SteamManager (registered after us) is already
	# gone when our _exit_tree fires — SteamManager._exit_tree owns the
	# quit-path leave instead.
	if is_instance_valid(SteamManager):
		SteamManager.leave_lobby()

func prepare_for_new_game() -> void:
	_input_batch_provider = Callable()
	_peer_ping_ms.clear()
	_peer_rtt_ema_ms.clear()
	_peer_loss_rates.clear()
	_input_timer = 0.0
	state_delta = 1.0 / Constants.STATE_RATE
	_state_tick_divisor = Constants.PHYSICS_TICK / Constants.STATE_RATE
	_state_tick_counter = 0
	_last_broadcast_us = 0
	_last_ws_seq_received = -1
	_ws_drop_window = 0
	_ws_recv_window = 0
	_ws_loss_window_timer = 0.0
	packet_loss_pct = 0.0
	_jitter_samples.clear()
	_last_ws_arrival_time = -1.0
	_pdv_floor = -1.0
	_pdv_mean = 0.0
	_pdv_dev = 0.0
	_interp_delay = Constants.NETWORK_INTERPOLATION_DELAY

func reset() -> void:
	_close()
	# Pending Steam lobby one-shots from an aborted host/join attempt must not
	# survive the reset — a late lobby callback would otherwise assign a stale
	# SteamMultiplayerPeer into whatever session comes next.
	if SteamManager.lobby_created.is_connected(_on_steam_lobby_created):
		SteamManager.lobby_created.disconnect(_on_steam_lobby_created)
	if SteamManager.lobby_create_failed.is_connected(_on_steam_lobby_create_failed):
		SteamManager.lobby_create_failed.disconnect(_on_steam_lobby_create_failed)
	if SteamManager.lobby_joined.is_connected(_on_steam_lobby_joined):
		SteamManager.lobby_joined.disconnect(_on_steam_lobby_joined)
	if SteamManager.lobby_join_failed.is_connected(_on_steam_lobby_join_failed):
		SteamManager.lobby_join_failed.disconnect(_on_steam_lobby_join_failed)
	multiplayer.multiplayer_peer = null
	is_host = false
	game_initiated = false
	pending_session_end_reason = ""
	is_offline_mode = false
	is_free_play_mode = false
	is_tutorial_mode = false
	drill_id = ""
	tutorial_id = ""
	_input_batch_provider = Callable()
	_pending_handshake.clear()
	_peer_last_seen.clear()
	_peer_handedness.clear()
	_peer_names.clear()
	_peer_numbers.clear()
	_peer_steam_ids.clear()
	_kicked_peers.clear()
	_peer_attributes.clear()
	_peer_attributes[1] = PlayerPrefs.get_player_attributes()
	pending_game_config = {}
	pending_lobby_slots = {}
	pending_lobby_roster = []
	pending_join_slot = {}
	pending_join_players = []
	scene_swap_pending = false
	pending_home_color_slot = TeamColorRegistry.DEFAULT_HOME_SLOT
	pending_away_color_slot = TeamColorRegistry.DEFAULT_AWAY_SLOT
	pending_color_votes = {}
	pending_bot_slots.clear()
	pending_bot_identities.clear()
	# Lobby match settings are session-scoped — reset to defaults so a new host
	# session doesn't pre-fill the previous match's period/rule config.
	pending_num_periods = GameRules.NUM_PERIODS
	pending_period_duration = GameRules.PERIOD_DURATION
	pending_ot_enabled = GameRules.OT_ENABLED
	pending_rule_set = GameRules.DEFAULT_RULE_SET
	pending_team_size = GameRules.DEFAULT_TEAM_SIZE
	pending_bot_difficulty = BotSkillProfile.Difficulty.NORMAL
	pending_goalie_difficulty = GoalieSkillProfile.Difficulty.NORMAL
	_input_timer = 0.0
	state_delta = 1.0 / Constants.STATE_RATE
	_state_tick_divisor = Constants.PHYSICS_TICK / Constants.STATE_RATE
	_state_tick_counter = 0
	_last_broadcast_us = 0
	_connect_timer = -1.0
	_clock_sync = null
	_session_start_ms = 0
	_last_ws_seq_received = -1
	_replay_mode = false
	_replay_clock = 0.0
	_ws_drop_window = 0
	_ws_recv_window = 0
	_ws_loss_window_timer = 0.0
	packet_loss_pct = 0.0
	_peer_ping_ms.clear()
	_peer_rtt_ema_ms.clear()
	_peer_loss_rates.clear()
	_jitter_samples.clear()
	_last_ws_arrival_time = -1.0
	_pdv_floor = -1.0
	_pdv_mean = 0.0
	_pdv_dev = 0.0
	_interp_delay = Constants.NETWORK_INTERPOLATION_DELAY
	_event_log = SnapshotEventLog.new()
	NetworkSimManager.clear_pending()

# ── Process ───────────────────────────────────────────────────────────────────
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_WINDOW_FOCUS_IN:
		if is_host:
			# Immediately resync clients — they've been without world state for the
			# duration of the OS freeze.
			_broadcast_state()
		else:
			# Reset the input timer so we don't burst-send stale inputs.
			_input_timer = 0.0

func _physics_process(_delta: float) -> void:
	# Single source of truth for the host-side integer tick counter. Increments
	# at the engine's physics rate (120 Hz). AI agents salt their per-tick RNG
	# with this value; consumers must tolerate the counter being zero before
	# the host starts ticking and must not assume monotonicity across host
	# transfers (Phase 1 has no host transfer support anyway).
	#
	# `_state_tick_counter` also ticks here so the broadcast cadence keeps
	# pace with the engine's physics rate independent of whether GameManager
	# captured this tick (replay mode, missing puck, etc.). The actual
	# broadcast call is invoked by GameManager via try_broadcast() right
	# after StateBufferManager.capture(), so the world-state packet always
	# reads this tick's fresh state instead of the prior tick's snapshot.
	if is_host:
		host_tick += 1
		_state_tick_counter += 1

func _process(delta: float) -> void:
	# NetworkManager is an autoload, so _process fires every frame from launch —
	# including before any session starts and in headless GUT runs. Every block
	# below is session-only maintenance (connect timeout, clock sync, handshake /
	# liveness, pings, input batches, loss telemetry); none of it is meaningful
	# without a session, and game_initiated is set at the very start of every
	# start path (offline / host / client) before _connect_timer arms, so this
	# guard never suppresses the connection-timeout path. It also silences the
	# headless-test log noise from NetworkTelemetry.* static calls firing with no
	# active session. Cleared on leave (return to free play), so it re-gates.
	if not game_initiated:
		return
	# Cap delta to avoid timer bursting on the first frame after an OS freeze
	# (e.g. title bar right-click holding the message pump for several seconds).
	var capped_delta: float = minf(delta, 0.5)
	if _connect_timer >= 0.0:
		_connect_timer += capped_delta
		if _connect_timer >= CONNECT_TIMEOUT:
			push_error("Connection timed out after %ds" % CONNECT_TIMEOUT)
			pending_error = "Connection timed out."
			GameManager.return_to_free_play()

	if not is_host and _clock_sync != null:
		if _clock_sync.tick(capped_delta):
			send_ping.rpc_id(1, local_time())

	if is_host and not _pending_handshake.is_empty():
		var now_s: float = local_time()
		for pid: int in _pending_handshake.keys():
			if now_s - _pending_handshake[pid] >= _HANDSHAKE_TIMEOUT_S:
				_pending_handshake.erase(pid)
				push_warning("Dropping peer %d: no request_join within %ds" % [pid, int(_HANDSHAKE_TIMEOUT_S)])
				if multiplayer.multiplayer_peer != null:
					multiplayer.multiplayer_peer.disconnect_peer(pid)

	if is_host and not _peer_last_seen.is_empty():
		var live_now: float = local_time()
		for pid: int in _peer_last_seen.keys():
			if live_now - _peer_last_seen[pid] >= _PEER_LIVENESS_TIMEOUT_S:
				_peer_last_seen.erase(pid)
				push_warning("Dropping peer %d: silent for %ds (liveness timeout)" % [pid, int(_PEER_LIVENESS_TIMEOUT_S)])
				if multiplayer.multiplayer_peer != null and pid in multiplayer.get_peers():
					multiplayer.multiplayer_peer.disconnect_peer(pid)

	_ping_timer += capped_delta
	if _ping_timer >= _PING_INTERVAL:
		_ping_timer = 0.0
		if is_host and not is_offline_mode:
			_send_host_pings()      # host times each peer's RTT itself
			_broadcast_all_pings()  # distribute the measured pings (display)
		# Clients no longer self-report their RTT (report_ping removed) — the host
		# measures it via host_ping/host_pong, so the ping backing lag-comp claim
		# validation can't be forged by a modified client.

	if not is_host and _input_batch_provider.is_valid():
		_input_timer += capped_delta
		if _input_timer >= input_delta:
			_input_timer -= input_delta
			var batch_frames: int = 24 if get_peer_loss_rate() > 10.0 else 12
			var batch: Array[InputState] = _input_batch_provider.call(batch_frames)
			var buf := PackedByteArray(); buf.resize(3)
			# u16 client-measured downstream loss in basis points (0..10000 = 0..100%),
			# u8 count. The client's own WS-seq-gap loss is authoritative for the
			# host->client link, so the host stores it directly instead of re-deriving
			# loss from an undersampled seq echo (see _peer_loss_rates).
			buf.encode_u16(0, clampi(roundi(packet_loss_pct * 100.0), 0, 65535))
			buf.encode_u8(2, batch.size())
			for s: InputState in batch:
				buf.append_array(s.to_bytes())
			NetworkTelemetry.record_input_sent()
			receive_input_batch.rpc_id(1, buf)

	if not is_host:
		_ws_loss_window_timer += capped_delta
		if _ws_loss_window_timer >= 1.0:
			var total: int = _ws_recv_window + _ws_drop_window
			var measured: float = (float(_ws_drop_window) / float(total) * 100.0) if total > 0 else 0.0
			# EMA smoothing (α=0.3, ~3s memory) prevents a single bad second
			# from swinging the batch-size threshold.
			packet_loss_pct = lerpf(packet_loss_pct, measured, 0.3)
			NetworkTelemetry.record_packet_loss(packet_loss_pct)
			_ws_drop_window = 0
			_ws_recv_window = 0
			_ws_loss_window_timer = 0.0

# Runtime broadcast-rate knob. No callers today — see the `_state_tick_divisor`
# doc-comment for why the per-phase dead-puck downshift was removed — retained
# as the hook for future congestion response.
func set_broadcast_rate(hz: float) -> void:
	state_delta = 1.0 / maxf(hz, 1.0)
	# `_physics_process` fires the broadcast every Nth physics tick. Round to
	# the nearest integer so any hz that doesn't divide PHYSICS_TICK evenly
	# (5, 10, 20, 30, 40, 48, 60, 80, 120) still produces the closest cadence.
	# At 120 Hz → every tick; at 60 Hz → every 2nd tick.
	_state_tick_divisor = maxi(int(round(float(Constants.PHYSICS_TICK) / maxf(hz, 1.0))), 1)
	# Reset the counter so the new cadence starts cleanly from the next tick.
	_state_tick_counter = 0

# Called by GameManager._physics_process right after
# StateBufferManager.capture() so the broadcast reads this tick's state
# instead of the prior tick's snapshot. The cadence counter is incremented
# in `_physics_process` regardless of whether this runs, so on a host stall
# Godot's physics catch-up still produces back-to-back broadcasts (one per
# eligible call) with distinct host_timestamps — clients get the multiple
# snapshots they need to interpolate through the catch-up window.
#
# Routing through here (rather than firing the broadcast from
# NetworkManager._physics_process directly) is necessary because autoload
# tree order puts NetworkManager ahead of GameManager: a broadcast from
# NetworkManager._physics_process would always read last tick's capture,
# adding a one-physics-tick (~4.17ms) latency floor to every client.
func try_broadcast() -> void:
	if not is_host:
		return
	if _state_tick_counter < _state_tick_divisor:
		return
	_state_tick_counter = 0
	var now_us: int = Time.get_ticks_usec()
	if _last_broadcast_us != 0:
		NetworkTelemetry.record_broadcast_interval_us(now_us - _last_broadcast_us)
	_last_broadcast_us = now_us
	_broadcast_state()

func _broadcast_state() -> void:
	if not _world_state_provider.is_valid():
		return
	var state: PackedByteArray = _world_state_provider.call()
	if state.is_empty():
		return
	if is_offline_mode:
		return
	# Redundant carrier events ride the tail of every snapshot (SnapshotEventLog).
	# PackedByteArray is copy-on-write, so this append can't mutate the replay
	# recorder/file-writer copies taken inside get_world_state — replay frames
	# stay event-free and decode_for_replay never sees the block.
	_event_log.append_block(state, local_time())
	for peer_id in connected_peer_ids():
		receive_world_state.rpc_id(peer_id, state)
		NetworkTelemetry.record_bytes_sent(state.size())

# ── RPCs ──────────────────────────────────────────────────────────────────────
@rpc("any_peer", "reliable")
func request_join(is_left_handed: bool, player_name: String, jersey_number: int = 10,
		attr_height: int = PlayerAttributes.HEIGHT_MEDIUM, attr_weight: int = 0,
		attr_profile: int = PlayerAttributes.GEAR_BALANCED,
		attr_curve: int = PlayerAttributes.GEAR_BALANCED,
		attr_flex: int = PlayerAttributes.GEAR_BALANCED,
		attr_length: int = PlayerAttributes.GEAR_BALANCED,
		steam_id: int = 0, protocol_version: int = 0, build_id: int = 0,
		shot_power_sensitivity: float = 1.0) -> void:
	if not is_host:
		return
	var sender_id: int = multiplayer.get_remote_sender_id()
	# Protocol gate: the wire format is positional binary, so a mixed-version
	# session decodes garbage that passes the size checks. `protocol_version`
	# sits last with a default so a pre-handshake build (which omits the arg)
	# decodes as 0 and gets a clean rejection instead of a silent desync.
	if protocol_version != BuildInfo.PROTOCOL_VERSION:
		push_warning("Rejected join from peer %d: protocol %d, host expects %d"
				% [sender_id, protocol_version, BuildInfo.PROTOCOL_VERSION])
		kick_peer(sender_id, "Game version mismatch (host is on v%s).\nUpdate to the latest build to play together." % BuildInfo.VERSION)
		return
	# Build gate: a matching protocol only proves the wire decodes. A physics or
	# tuning change with the same wire format still desyncs the joiner's local
	# prediction against host authority. The Steam BuildID bumps on every upload
	# so it catches that automatically — no manual version discipline. Skipped
	# when either side is a dev / non-Steam build (BuildID 0), which manages its
	# own compatibility.
	var host_build_id: int = SteamManager.get_app_build_id()
	if build_id != 0 and host_build_id != 0 and build_id != host_build_id:
		push_warning("Rejected join from peer %d: build %d, host on build %d"
				% [sender_id, build_id, host_build_id])
		kick_peer(sender_id, "Build mismatch — you and the host are on different builds.\nUpdate to the latest build to play together.")
		return
	# Duplicate request_join (lost-ack resend or forged repeat) would re-emit
	# peer_joined and double-spawn the peer's skater — first join wins.
	if _peer_names.has(sender_id):
		return
	_pending_handshake.erase(sender_id)
	_peer_handedness[sender_id] = is_left_handed
	_peer_steam_ids[sender_id] = steam_id
	var sanitized_name: String = player_name.strip_edges().left(10)
	_peer_names[sender_id] = sanitized_name if NameFilter.is_alphanumeric(sanitized_name) and NameFilter.is_clean(sanitized_name) else "Player"
	_peer_numbers[sender_id] = clampi(jersey_number, 0, 99)
	# v4 builds have no power economy to validate — every axis is lateral, so
	# validation is pure coercion: the constructor clamps height/gear into range
	# and weight into the height's BMI band. A forged extreme build lands on the
	# nearest legal body instead of being rejected.
	_peer_attributes[sender_id] = PlayerAttributes.new(attr_height, attr_weight,
			attr_profile, attr_curve, attr_flex, attr_length)
	_peer_shot_sensitivity[sender_id] = clampf(shot_power_sensitivity, 0.25, 4.0)
	# (ENet per-peer disconnect-timeout tuning lived here; SteamMultiplayerPeer
	# manages its own keepalive over Steam's relay, so there's nothing to set.)
	peer_joined.emit(sender_id)


# Host → rejected peer: carries the human-readable reason ahead of the
# disconnect so the join UI can show it (the disconnect alone is just a
# generic timeout from the client's perspective).
@rpc("authority", "reliable")
func notify_join_rejected(reason: String) -> void:
	pending_error = reason
	pending_session_end_reason = "kicked"
	join_rejected.emit(reason)


# Send a reject reason to a peer, then drop them. The reliable RPC needs a
# beat to flush before the disconnect, hence the deferred kick.
func kick_peer(peer_id: int, reason: String) -> void:
	_kicked_peers[peer_id] = true
	notify_join_rejected.rpc_id(peer_id, reason)
	get_tree().create_timer(_KICK_FLUSH_DELAY_S).timeout.connect(func() -> void:
		if multiplayer.multiplayer_peer != null and peer_id in multiplayer.get_peers():
			multiplayer.multiplayer_peer.disconnect_peer(peer_id))


# Host announces the match is over before tearing the session down, so clients
# toast "Host ended the match." instead of a generic connection-loss message.
# Await it before reset()/quit() — the reliable RPC needs a beat to flush
# before the peer closes, same as kick_peer.
func announce_match_end() -> void:
	if not is_host or is_offline_mode or multiplayer.multiplayer_peer == null:
		return
	var sent: bool = false
	for peer_id: int in connected_peer_ids():
		notify_match_ended.rpc_id(peer_id)
		sent = true
	if sent:
		await get_tree().create_timer(_KICK_FLUSH_DELAY_S).timeout


# Client side of the graceful host shutdown: same routing as
# _on_server_disconnected, but with a reason that doesn't read like a crash.
@rpc("authority", "reliable")
func notify_match_ended() -> void:
	pending_error = "Host ended the match."
	pending_session_end_reason = "host_ended"
	GameManager.return_to_free_play()

func get_peer_handedness(peer_id: int) -> bool:
	return _peer_handedness.get(peer_id, true)

func get_peer_name(peer_id: int) -> String:
	return _peer_names.get(peer_id, "Player")

func get_peer_number(peer_id: int) -> int:
	return _peer_numbers.get(peer_id, 10)

func get_peer_steam_id(peer_id: int) -> int:
	return _peer_steam_ids.get(peer_id, 0)

# True if the host kicked this peer (vs. a voluntary/network drop). Valid only
# during the peer_disconnected emit; gates the reconnect reservation.
func was_peer_kicked(peer_id: int) -> bool:
	return _kicked_peers.has(peer_id)

# One-shot read of the abnormal-end reason for the telemetry row ("" if the
# session is ending voluntarily — the caller maps that to "quit"). Clears on
# read so a reason can never leak into a later session's report.
func take_session_end_reason() -> String:
	var reason: String = pending_session_end_reason
	pending_session_end_reason = ""
	return reason

func get_peer_attributes(peer_id: int) -> PlayerAttributes:
	var attrs: PlayerAttributes = _peer_attributes.get(peer_id, null)
	if attrs == null:
		return PlayerAttributes.all_average()
	return attrs

# A peer's replicated Shot Power Sensitivity (host-side). Defaults to 1.0 for a
# peer that predates the setting or hasn't sent one.
func get_peer_shot_sensitivity(peer_id: int) -> float:
	return _peer_shot_sensitivity.get(peer_id, 1.0)

# Host-side override of a peer's locked attributes. Used by the reconnect path
# to restore the build the player held at their original join, so a mid-match
# drop + prefs edit + rejoin can't swap to a different attribute spread.
func set_peer_attributes(peer_id: int, attrs: PlayerAttributes) -> void:
	if attrs != null:
		_peer_attributes[peer_id] = attrs

# True only during an active online match. Used by the player-settings popup
# to gate mid-match attribute edits: offline / free-play / lobby allows the
# pick to apply live; online play locks attributes at join time so all peers
# simulate the same numbers without a runtime attribute-change RPC.
func is_in_online_match() -> bool:
	return game_initiated and not is_offline_mode

# Single entry point for in-session attribute edits, mirroring
# apply_local_identity. Offline / free-play only — the picker UI is
# responsible for gating its Apply button via is_in_online_match().
func apply_local_attributes(attrs: PlayerAttributes) -> void:
	if attrs == null:
		return
	_peer_attributes[1] = attrs
	local_attributes_changed.emit(attrs)


# Lobby-time build change. Distinct from apply_local_attributes (free-play live
# re-apply): here we're in the pre-match lobby, no skater exists yet, so this
# only updates the value the host spawns from at game start. We stamp the local
# peer's own entry (host = 1) so the local spawn path reads it directly; a
# client also forwards the build to the host, which re-validates the point-buy
# budget before storing it as authority. No live re-apply, no reconcile.
func update_lobby_attributes(attrs: PlayerAttributes) -> void:
	if attrs == null:
		return
	_peer_attributes[local_peer_id()] = attrs
	if not is_host:
		request_update_attributes.rpc_id(1, attrs.height, attrs.weight,
				attrs.profile, attrs.curve, attrs.flex, attrs.length)


# Client → host: update the sender's locked build from the lobby. The host
# re-validates the legal shape (a modified client can send an illegal all-strong
# build) and ignores a peer that never completed the join handshake.
#
# No match-in-progress gate: _peer_attributes is consulted only at spawn, so a
# stray mid-match edit can't perturb a live simulation, and a mid-match
# reconnect restores the original build via set_peer_attributes regardless.
# (game_initiated is unusable as a gate here — it's set true at start_offline /
# start_client_lobby, i.e. throughout the pre-match lobby, not just in-game.)
@rpc("any_peer", "reliable")
func request_update_attributes(attr_height: int, attr_weight: int, attr_profile: int,
		attr_curve: int, attr_flex: int, attr_length: int) -> void:
	if not is_host:
		return
	var sender_id: int = multiplayer.get_remote_sender_id()
	if not _peer_names.has(sender_id):
		return
	# Coerce-construct — same lateral-axes validation as request_join.
	_peer_attributes[sender_id] = PlayerAttributes.new(attr_height, attr_weight,
			attr_profile, attr_curve, attr_flex, attr_length)

# Cap on inputs per RPC. Matches the host queue depth in RemoteController so a
# malicious peer can't force the loop into hundreds of failed decode iterations
# by claiming count=255 with a short payload.
const _MAX_INPUTS_PER_BATCH: int = 120

@rpc("any_peer", "unreliable_ordered")
func receive_input_batch(data: PackedByteArray) -> void:
	var sender_id: int = multiplayer.get_remote_sender_id()
	# Liveness: stamp actual receipt time (before any NetworkSimManager delay).
	if is_host and _peer_last_seen.has(sender_id):
		_peer_last_seen[sender_id] = local_time()
	NetworkSimManager.send(
		func(d: PackedByteArray, sid: int) -> void:
			if d.size() < 3:
				return
			# Client-reported downstream loss (basis points) — stored verbatim as
			# this peer's link loss (see _peer_loss_rates).
			_peer_loss_rates[sid] = float(d.decode_u16(0)) / 100.0
			var count: int = d.decode_u8(2)
			if count > _MAX_INPUTS_PER_BATCH:
				push_warning("oversized input batch from peer %d: count=%d" % [sid, count])
				return
			var inputs: Array[InputState] = []
			for i: int in count:
				var off: int = 3 + i * InputState.BYTES_SIZE
				if off + InputState.BYTES_SIZE > d.size():
					break
				inputs.append(InputState.from_bytes(d, off))
			input_batch_received.emit(sid, inputs),
		[data, sender_id], false)

@rpc("authority", "unreliable_ordered")
func receive_world_state(data: PackedByteArray) -> void:
	if is_host:
		return
	NetworkSimManager.send(
		func(s: PackedByteArray) -> void:
			var now: float = local_time()
			if _last_ws_arrival_time > 0.0:
				var expected_interval: float = 1.0 / Constants.STATE_RATE
				var gap: float = now - _last_ws_arrival_time
				var jitter: float = absf(gap - expected_interval)
				_jitter_samples.append(jitter)
				if _jitter_samples.size() > 40:
					_jitter_samples.pop_front()
				NetworkTelemetry.record_jitter_p95(get_jitter_p95() * 1000.0)
				# Raw inter-arrival gap histogram: distinguishes Steam Nagle
				# clumping (bimodal — a cluster of near-0 gaps then a big one)
				# from smooth path/relay jitter (spread around the 8.3ms interval).
				NetworkTelemetry.record_ws_arrival_gap(gap * 1000.0)
			_last_ws_arrival_time = now
			# PDV delay vs the synced host clock (header host_capture_time at bytes
			# 2..5, u32 0.1ms units). Clumping barely moves this, unlike the gap above.
			if is_clock_ready() and s.size() >= 6:
				_record_packet_delay(estimated_host_time() - float(s.decode_u32(2)) / Constants.TIME_WIRE_SCALE)
			if s.size() >= 2:
				_on_ws_sequence_received(s.decode_u16(0))
			# Advance the shared interpolation delay once per packet, before the
			# decode applies state to actors — so every interpolator this frame
			# reads the same freshly-adapted value.
			advance_interpolation_delay()
			# Apply the snapshot's trailing carrier-event block BEFORE the
			# world-state decode below, so a carrier change and the state it
			# corresponds to land in the same frame (a stronger ordering
			# guarantee than the reliable-RPC-vs-unreliable-snapshot race).
			_event_log.apply_block(s, multiplayer.get_unique_id(), _snapshot_event_dispatch)
			NetworkTelemetry.record_world_state()
			NetworkTelemetry.record_bytes_received(s.size())
			world_state_received.emit(s),
		[data], false)

# ── Clock Sync ────────────────────────────────────────────────────────────────
@rpc("any_peer", "reliable")
func send_ping(client_send_time: float) -> void:
	if not is_host:
		return
	var peer_id := multiplayer.get_remote_sender_id()
	if _peer_last_seen.has(peer_id):
		_peer_last_seen[peer_id] = local_time()
	NetworkSimManager.send(
		func(cst: float, pid: int) -> void:
			receive_pong.rpc_id(pid, cst, local_time()),
		[client_send_time, peer_id], true)

@rpc("authority", "reliable")
func receive_pong(client_send_time: float, host_time: float) -> void:
	if is_host or _clock_sync == null:
		return
	NetworkSimManager.send(
		func(cst: float, ht: float) -> void:
			var was_ready: bool = _clock_sync.is_ready
			_clock_sync.record_pong(cst, ht, local_time())
			if not was_ready and _clock_sync.is_ready:
				clock_ready.emit(),
		[client_send_time, host_time], true)

# ── Host-measured peer RTT ────────────────────────────────────────────────────
# The host times a round trip to each peer ITSELF so lag-comp claim validation
# (is_claim_stamp_plausible, via get_peer_ping_ms) reads a ping the host measured
# rather than one the client self-reported. The old report_ping let a modified
# client forge a large RTT — or never report at all — to widen its claim-stamp
# "timestamp-shopping" window. Unreliable + routed through the net sim like the
# clock-sync pings: a dropped probe just skips one sample (the EMA tolerates gaps)
# and the dev latency sim is folded into the measurement.
func _send_host_pings() -> void:
	var t: float = local_time()
	for peer_id: int in connected_peer_ids():
		host_ping.rpc_id(peer_id, t)

@rpc("authority", "unreliable")
func host_ping(host_send_time: float) -> void:
	if is_host:
		return
	# Echo the host's own timestamp straight back so it can measure the round trip.
	NetworkSimManager.send(
		func(t: float) -> void:
			host_pong.rpc_id(1, t),
		[host_send_time], false)

@rpc("any_peer", "unreliable")
func host_pong(host_send_time: float) -> void:
	if not is_host:
		return
	# Capture the sender before the sim defers the callable (it loses RPC context).
	var peer_id: int = multiplayer.get_remote_sender_id()
	NetworkSimManager.send(
		func(pid: int, sent: float) -> void:
			_record_host_measured_rtt(pid, (local_time() - sent) * 1000.0),
		[peer_id, host_send_time], false)

func _record_host_measured_rtt(peer_id: int, sample_ms: float) -> void:
	if sample_ms < 0.0 or not is_finite(sample_ms):
		return
	var prev: float = _peer_rtt_ema_ms.get(peer_id, -1.0)
	var ema: float = sample_ms if prev < 0.0 else lerpf(prev, sample_ms, _PEER_RTT_EMA_ALPHA)
	_peer_rtt_ema_ms[peer_id] = ema
	_peer_ping_ms[peer_id] = int(roundf(ema))

# Client-authoritative blade geometry rides the claim: the client sends the blade
# it actually reached with (blade_curr + one-tick-prior blade_prev for the swept
# test, plus the top-hand grip for the pickup reception face-normal), so the host
# validates against what the client saw instead of reconstructing the blade from
# its lossy self-view snapshot. World-space; the host reach-clamps each point to
# the claimant's server-authoritative body (LagCompRewind.clamp_client_blade).
func send_pickup_claim(host_timestamp: float, interp_delay_ms: float,
		blade_curr: Vector3, blade_prev: Vector3, top_hand: Vector3) -> void:
	NetworkSimManager.send(
		func(ts: float, idms: float, bc: Vector3, bp: Vector3, th: Vector3) -> void:
			receive_pickup_claim.rpc_id(1, ts, idms, bc, bp, th),
		[host_timestamp, interp_delay_ms, blade_curr, blade_prev, top_hand], true)

@rpc("any_peer", "reliable")
func receive_pickup_claim(host_timestamp: float, interp_delay_ms: float,
		blade_curr: Vector3, blade_prev: Vector3, top_hand: Vector3) -> void:
	if not is_host:
		return
	var peer_id: int = multiplayer.get_remote_sender_id()
	# Stamp plausibility against the host's own ping for this peer — closes
	# the timestamp-shopping window the absolute age cap leaves open (see
	# LagCompRewind). Applied at the trust boundary so all claim resolvers
	# inherit it.
	if not LagCompRewind.is_claim_stamp_plausible(local_time(), host_timestamp, float(get_peer_ping_ms(peer_id))):
		return
	pickup_claim_received.emit(peer_id, host_timestamp, interp_delay_ms, blade_curr, blade_prev, top_hand)

func send_poke_claim(host_timestamp: float, interp_delay_ms: float, expected_carrier_peer_id: int,
		blade_curr: Vector3, blade_prev: Vector3) -> void:
	NetworkSimManager.send(
		func(ts: float, idms: float, cpid: int, bc: Vector3, bp: Vector3) -> void:
			receive_poke_claim.rpc_id(1, ts, idms, cpid, bc, bp),
		[host_timestamp, interp_delay_ms, expected_carrier_peer_id, blade_curr, blade_prev], true)

@rpc("any_peer", "reliable")
func receive_poke_claim(host_timestamp: float, interp_delay_ms: float, expected_carrier_peer_id: int,
		blade_curr: Vector3, blade_prev: Vector3) -> void:
	if not is_host:
		return
	var peer_id: int = multiplayer.get_remote_sender_id()
	if not LagCompRewind.is_claim_stamp_plausible(local_time(), host_timestamp, float(get_peer_ping_ms(peer_id))):
		return
	poke_claim_received.emit(peer_id, host_timestamp, interp_delay_ms, expected_carrier_peer_id, blade_curr, blade_prev)

func send_stick_lift_claim(host_timestamp: float, interp_delay_ms: float, expected_carrier_peer_id: int,
		blade_curr: Vector3) -> void:
	NetworkSimManager.send(
		func(ts: float, idms: float, cpid: int, bc: Vector3) -> void:
			receive_stick_lift_claim.rpc_id(1, ts, idms, cpid, bc),
		[host_timestamp, interp_delay_ms, expected_carrier_peer_id, blade_curr], true)

@rpc("any_peer", "reliable")
func receive_stick_lift_claim(host_timestamp: float, interp_delay_ms: float, expected_carrier_peer_id: int,
		blade_curr: Vector3) -> void:
	if not is_host:
		return
	var peer_id: int = multiplayer.get_remote_sender_id()
	if not LagCompRewind.is_claim_stamp_plausible(local_time(), host_timestamp, float(get_peer_ping_ms(peer_id))):
		return
	stick_lift_claim_received.emit(peer_id, host_timestamp, interp_delay_ms, expected_carrier_peer_id, blade_curr)

func send_hit_claim(victim_peer_id: int, host_timestamp: float, interp_delay_ms: float) -> void:
	NetworkSimManager.send(
		func(vpid: int, ts: float, idms: float) -> void:
			receive_hit_claim.rpc_id(1, vpid, ts, idms),
		[victim_peer_id, host_timestamp, interp_delay_ms], true)

@rpc("any_peer", "reliable")
func receive_hit_claim(victim_peer_id: int, host_timestamp: float, interp_delay_ms: float) -> void:
	if not is_host:
		return
	var hitter_peer_id: int = multiplayer.get_remote_sender_id()
	if not LagCompRewind.is_claim_stamp_plausible(local_time(), host_timestamp, float(get_peer_ping_ms(hitter_peer_id))):
		return
	hit_claim_received.emit(hitter_peer_id, victim_peer_id, host_timestamp, interp_delay_ms)

func start_replay_mode(initial_ts: float) -> void:
	_replay_mode = true
	_replay_clock = initial_ts
	# Mirror the flag onto every connected client so their recorder + .mreplay
	# writer gate identically, and so they start their own GoalReplayDriver in
	# lockstep (see GameManager._on_remote_replay_mode_changed). The host stops
	# broadcasting world state for the duration of the cinematic
	# (GameManager._physics_process bails while is_replay_mode), so clients
	# receive no frames during replay — each peer drives its own clip locally.
	if is_host:
		for peer_id: int in connected_peer_ids():
			notify_replay_mode.rpc_id(peer_id, true)


func stop_replay_mode() -> void:
	_replay_mode = false
	_replay_clock = 0.0
	if is_host:
		for peer_id: int in connected_peer_ids():
			notify_replay_mode.rpc_id(peer_id, false)


# Toggle replay mode on THIS peer only, with no RPC mirror. The networked
# start/stop_replay_mode pair drives the live goal cinematic in lockstep across
# peers (host stops broadcasting, clients spin up their own GoalReplayDriver).
# The post-game background replay is different: the game is already over, each
# peer loops its OWN captured goals purely cosmetically, and there's nothing to
# synchronize — so it just needs the local flag (host: stop broadcasting/
# capturing; client: skip applying any stray frame in decode_world_state).
func set_replay_mode_local(active: bool, initial_ts: float = 0.0) -> void:
	_replay_mode = active
	_replay_clock = initial_ts if active else 0.0


@rpc("authority", "reliable")
func notify_replay_mode(active: bool) -> void:
	# Mirror other authority RPCs (receive_world_state, receive_pong, …)
	# that early-return on the host. Authority RPCs are only delivered to
	# remote peers, so the host wouldn't receive this in normal flow, but
	# the guard is defense-in-depth and matches the file's existing pattern.
	if is_host:
		return
	_replay_mode = active
	if not active:
		_replay_clock = 0.0
	# Drive the client's local cinematic off this edge. The host's GOAL_SCORED
	# phase never reaches clients via world state, so this is where their
	# GoalReplayDriver starts (active) and is torn down (inactive).
	replay_mode_changed.emit(active)


func set_replay_clock(t: float) -> void:
	_replay_clock = t


func is_replay_mode() -> bool:
	return _replay_mode


# Client → host: register one vote-to-skip for the current goal replay.
# Offline / host calls register the vote locally; no RPC needed there.
func send_skip_replay_request() -> void:
	if is_host:
		return
	receive_skip_replay_request.rpc_id(1)


@rpc("any_peer", "reliable")
func receive_skip_replay_request() -> void:
	if not is_host:
		return
	skip_replay_request_received.emit(multiplayer.get_remote_sender_id())


# Host → all clients: latest unanimous-skip tally. Sent on every accepted vote
# so the HUD prompt can show "(2/3)" → "(3/3)" live; clients also use the
# final (current == total) update as their cue to stop the local driver.
func notify_skip_replay_vote_to_all(current: int, total: int) -> void:
	if not is_host:
		return
	for peer_id in connected_peer_ids():
		notify_skip_replay_vote.rpc_id(peer_id, current, total)


@rpc("authority", "reliable")
func notify_skip_replay_vote(current: int, total: int) -> void:
	skip_replay_vote_updated.emit(current, total)


# Mirror a recorded replay event to every connected peer so client / spectator
# recorders carry the same event timeline as the host (shot release, puck
# pickups, body checks, audio cues). Called once per event from
# GameManager._record_replay_audio_event right after the host's local
# record_event(). Reliable because event timestamps drive replay-trim logic
# and we'd rather a dropped event delay slightly than be lost.
func notify_replay_event_to_all(host_ts: float, event: Dictionary) -> void:
	if not is_host:
		return
	for peer_id in connected_peer_ids():
		notify_replay_event.rpc_id(peer_id, host_ts, event)


@rpc("authority", "reliable")
func notify_replay_event(host_ts: float, event: Dictionary) -> void:
	if is_host:
		return  # authority RPCs are delivered only to remote peers; defense-in-depth
	replay_event_received.emit(host_ts, event)


func estimated_host_time() -> float:
	if _replay_mode:
		return _replay_clock
	if is_host:
		return local_time()
	if _clock_sync == null or not _clock_sync.is_ready:
		return 0.0
	return _clock_sync.estimated_host_time()

func estimated_input_stamp_time() -> float:
	if is_host:
		return local_time()
	if _clock_sync == null or not _clock_sync.is_ready:
		return 0.0
	return _clock_sync.estimated_input_stamp_time()

func is_clock_ready() -> bool:
	return is_host or (_clock_sync != null and _clock_sync.is_ready)

func get_rtt_ms() -> float:
	if _clock_sync == null:
		return 0.0
	return _clock_sync.rtt_ms

func get_latest_rtt_ms() -> float:
	if _clock_sync == null:
		return 0.0
	return _clock_sync.latest_rtt_ms

func get_peer_ping_ms(peer_id: int) -> int:
	return _peer_ping_ms.get(peer_id, 0)

func get_clock_offset_ms() -> float:
	if _clock_sync == null:
		return 0.0
	return _clock_sync._offset * 1000.0

# Magnitude of the last post-ready clock-offset correction (ms) — the clock
# stability signal the session telemetry folds. ~0 when settled.
func get_clock_correction_ms() -> float:
	if _clock_sync == null:
		return 0.0
	return _clock_sync.last_correction_ms

func _broadcast_all_pings() -> void:
	var pings: Dictionary[int, int] = {}
	for pid: int in _peer_ping_ms:
		pings[pid] = _peer_ping_ms[pid]
	for peer_id: int in connected_peer_ids():
		receive_all_pings.rpc_id(peer_id, pings)

@rpc("authority", "unreliable")
func receive_all_pings(pings: Dictionary) -> void:
	for pid: int in pings:
		_peer_ping_ms[pid] = pings[pid]

func on_queue_depth_received(depth: int) -> void:
	if is_host:
		return
	NetworkTelemetry.record_queue_depth(depth)

@rpc("authority", "reliable")
func assign_player_slot(team_slot: int, team_id: int, jersey_color: Color, helmet_color: Color, pants_color: Color) -> void:
	var scene := get_tree().current_scene
	if not is_host and (scene_swap_pending or scene == null or scene.scene_file_path != Constants.SCENE_HOCKEY):
		pending_join_slot = { "team_slot": team_slot, "team_id": team_id,
			"jersey_color": jersey_color, "helmet_color": helmet_color, "pants_color": pants_color }
		return
	slot_assigned.emit(team_slot, team_id, jersey_color, helmet_color, pants_color)

@rpc("authority", "reliable")
func spawn_remote_skater(peer_id: int, team_slot: int, team_id: int, jersey_color: Color, helmet_color: Color, pants_color: Color, is_left_handed: bool, player_name: String, jersey_number: int = 10,
		attr_height: int = PlayerAttributes.HEIGHT_MEDIUM, attr_weight: int = 0,
		attr_profile: int = PlayerAttributes.GEAR_BALANCED,
		attr_curve: int = PlayerAttributes.GEAR_BALANCED,
		attr_flex: int = PlayerAttributes.GEAR_BALANCED,
		attr_length: int = PlayerAttributes.GEAR_BALANCED) -> void:
	var attrs := PlayerAttributes.new(attr_height, attr_weight,
			attr_profile, attr_curve, attr_flex, attr_length)
	_peer_attributes[peer_id] = attrs
	remote_skater_spawn_requested.emit(peer_id, team_slot, team_id, jersey_color, helmet_color, pants_color, is_left_handed, player_name, jersey_number, attrs)

@rpc("authority", "reliable")
func sync_existing_players(player_data: Array) -> void:
	var scene := get_tree().current_scene
	if not is_host and (scene_swap_pending or scene == null or scene.scene_file_path != Constants.SCENE_HOCKEY):
		pending_join_players = player_data
		return
	existing_players_synced.emit(player_data)

func send_puck_picked_up(peer_id: int) -> void:
	# AI bots have no ENet connection — rpc_id would fail. Bots are driven
	# directly by the host's AIController, so no client-side notification
	# is needed.
	if not is_real_peer(peer_id):
		return
	var seq: int = _event_log.record(
			SnapshotEventLog.EventType.PICKED_UP, peer_id, 0, local_time())
	notify_puck_picked_up.rpc_id(peer_id, seq)

@rpc("authority", "reliable")
func notify_puck_picked_up(event_seq: int) -> void:
	NetworkSimManager.send(
		func(seq: int) -> void:
			if _event_log.try_apply_reliable(seq):
				local_puck_pickup_confirmed.emit(),
		[event_seq], true)

func send_ghost_state_to_all(peer_id: int, is_ghost: bool) -> void:
	for remote_id: int in connected_peer_ids():
		notify_ghost_state.rpc_id(remote_id, peer_id, is_ghost)

@rpc("authority", "reliable")
func notify_ghost_state(peer_id: int, is_ghost: bool) -> void:
	NetworkSimManager.send(
		func(pid: int, g: bool) -> void: ghost_state_received.emit(pid, g),
		[peer_id, is_ghost], true)

func send_carrier_changed_to_all(new_carrier_peer_id: int) -> void:
	var seq: int = _event_log.record(
			SnapshotEventLog.EventType.CARRIER_CHANGED, SnapshotEventLog.TARGET_ALL,
			new_carrier_peer_id, local_time())
	for peer_id: int in connected_peer_ids():
		notify_carrier_changed.rpc_id(peer_id, seq, new_carrier_peer_id)
	remote_carrier_changed.emit(new_carrier_peer_id)

@rpc("authority", "reliable")
func notify_carrier_changed(event_seq: int, new_carrier_peer_id: int) -> void:
	NetworkSimManager.send(
		func(seq: int, id: int) -> void:
			if _event_log.try_apply_reliable(seq):
				remote_carrier_changed.emit(id),
		[event_seq, new_carrier_peer_id], true)

func send_puck_stolen(victim_peer_id: int, was_stick_lift: bool = false) -> void:
	if not is_real_peer(victim_peer_id):
		return  # AI bot or sentinel — see send_puck_picked_up rationale.
	var seq: int = _event_log.record(
			SnapshotEventLog.EventType.STOLEN, victim_peer_id,
			1 if was_stick_lift else 0, local_time())
	notify_puck_stolen.rpc_id(victim_peer_id, seq, was_stick_lift)

@rpc("authority", "reliable")
func notify_puck_stolen(event_seq: int, was_stick_lift: bool) -> void:
	NetworkSimManager.send(
		func(seq: int, wsl: bool) -> void:
			if _event_log.try_apply_reliable(seq):
				local_puck_stolen.emit(wsl),
		[event_seq, was_stick_lift], true)

func send_one_timer_release(direction: Vector3, power: float, origin: Vector3) -> void:
	# Adapted interp delay (get_interpolation_delay), the value that actually
	# positioned the rendered puck — the host rewinds to it (remote_view_time) for
	# the "did I connect with the puck I saw" range gate. Matches the pickup / poke /
	# stick-lift / hit claim sends; target would lead it mid-jitter.
	release_puck_one_timer.rpc_id(1, direction, power,
			estimated_host_time(), get_latest_rtt_ms(),
			get_interpolation_delay() * 1000.0, origin)

@rpc("any_peer", "reliable")
func release_puck_one_timer(direction: Vector3, power: float, host_timestamp: float, rtt_ms: float, interp_delay_ms: float, client_origin: Vector3) -> void:
	var sender: int = multiplayer.get_remote_sender_id()
	NetworkSimManager.send(
		func(d: Vector3, p: float, ts: float, rtt: float, idms: float, org: Vector3, sid: int) -> void:
			one_timer_release_received.emit(d, p, sid, ts, rtt, idms, org),
		[direction, power, host_timestamp, rtt_ms, interp_delay_ms, client_origin, sender], true)

func notify_goal_to_all(scoring_team_id: int, score0: int, score1: int, scorer_name: String, assist1_name: String, assist2_name: String) -> void:
	for peer_id in connected_peer_ids():
		notify_goal.rpc_id(peer_id, scoring_team_id, score0, score1, scorer_name, assist1_name, assist2_name)

func notify_puck_dropped_to_carrier(carrier_peer_id: int) -> void:
	if not is_real_peer(carrier_peer_id):
		return  # AI bot or sentinel — see send_puck_picked_up rationale.
	var seq: int = _event_log.record(
			SnapshotEventLog.EventType.DROPPED, carrier_peer_id, 0, local_time())
	notify_puck_dropped.rpc_id(carrier_peer_id, seq)

@rpc("authority", "reliable")
func notify_puck_dropped(event_seq: int) -> void:
	NetworkSimManager.send(
		func(seq: int) -> void:
			if _event_log.try_apply_reliable(seq):
				carrier_puck_dropped.emit(),
		[event_seq], true)

# Snapshot-path twin of the four reliable handlers above: SnapshotEventLog
# dispatches each fresh, targeted event from a packet's trailing block here.
# Emits the exact same signals, so the application layer can't tell (and
# doesn't care) which channel won the race.
func _dispatch_snapshot_event(type: int, arg: int) -> void:
	match type:
		SnapshotEventLog.EventType.CARRIER_CHANGED:
			remote_carrier_changed.emit(arg)
		SnapshotEventLog.EventType.PICKED_UP:
			local_puck_pickup_confirmed.emit()
		SnapshotEventLog.EventType.STOLEN:
			local_puck_stolen.emit(arg != 0)
		SnapshotEventLog.EventType.DROPPED:
			carrier_puck_dropped.emit()

@rpc("authority", "reliable")
func notify_player_disconnected(peer_id: int) -> void:
	peer_disconnected.emit(peer_id)

@rpc("authority", "reliable")
func notify_goal(scoring_team_id: int, score0: int, score1: int, scorer_name: String, assist1_name: String, assist2_name: String) -> void:
	NetworkSimManager.send(
		func(tid: int, s0: int, s1: int, sn: String, a1: String, a2: String) -> void:
			goal_received.emit(tid, s0, s1, sn, a1, a2),
		[scoring_team_id, score0, score1, scorer_name, assist1_name, assist2_name], true)

func notify_puck_out_of_play_to_all() -> void:
	for peer_id: int in connected_peer_ids():
		notify_puck_out_of_play.rpc_id(peer_id)

@rpc("authority", "reliable")
func notify_puck_out_of_play() -> void:
	NetworkSimManager.send(func() -> void: puck_out_of_play_received.emit(), [], true)

func notify_icing_called_to_all() -> void:
	for peer_id: int in connected_peer_ids():
		notify_icing_called.rpc_id(peer_id)

@rpc("authority", "reliable")
func notify_icing_called() -> void:
	NetworkSimManager.send(func() -> void: icing_called_received.emit(), [], true)

func notify_goalie_freeze_called_to_all() -> void:
	for peer_id: int in connected_peer_ids():
		notify_goalie_freeze_called.rpc_id(peer_id)

@rpc("authority", "reliable")
func notify_goalie_freeze_called() -> void:
	NetworkSimManager.send(func() -> void: goalie_freeze_called_received.emit(), [], true)

func notify_offside_called_to_all() -> void:
	for peer_id: int in connected_peer_ids():
		notify_offside_called.rpc_id(peer_id)

@rpc("authority", "reliable")
func notify_offside_called() -> void:
	NetworkSimManager.send(func() -> void: offside_called_received.emit(), [], true)

func send_faceoff_positions(positions: Array) -> void:
	for peer_id in connected_peer_ids():
		notify_faceoff_positions.rpc_id(peer_id, positions)

@rpc("authority", "reliable")
func notify_faceoff_positions(positions: Array) -> void:
	NetworkSimManager.send(func(p: Array) -> void: faceoff_positions_received.emit(p), [positions], true)

func notify_reset_to_all(new_game_id: String = "") -> void:
	for peer_id in connected_peer_ids():
		notify_game_reset.rpc_id(peer_id, new_game_id)

@rpc("authority", "reliable")
func notify_game_reset(new_game_id: String = "") -> void:
	game_reset_received.emit(new_game_id)

func send_stats_to_all(data: Array) -> void:
	for peer_id in connected_peer_ids():
		receive_stats.rpc_id(peer_id, data)

@rpc("authority", "call_remote", "reliable")
func receive_stats(data: Array) -> void:
	stats_received.emit(data)

@rpc("any_peer", "reliable")
func request_slot_swap(new_team_id: int, new_slot: int) -> void:
	if not is_host:
		return
	slot_swap_requested.emit(multiplayer.get_remote_sender_id(), new_team_id, new_slot)

@rpc("authority", "reliable")
func confirm_slot_swap(peer_id: int, old_team_id: int, old_slot: int,
		new_team_id: int, new_slot: int,
		jersey: Color, helmet: Color, pants: Color) -> void:
	slot_swap_confirmed.emit(peer_id, old_team_id, old_slot, new_team_id, new_slot, jersey, helmet, pants)

# ── Sending ───────────────────────────────────────────────────────────────────
func send_slot_assignment(peer_id: int, team_slot: int, team_id: int, jersey_color: Color, helmet_color: Color, pants_color: Color) -> void:
	assign_player_slot.rpc_id(peer_id, team_slot, team_id, jersey_color, helmet_color, pants_color)

func send_spawn_remote_skater(peer_id: int, team_slot: int, team_id: int, jersey_color: Color, helmet_color: Color, pants_color: Color, is_left_handed: bool, player_name: String, jersey_number: int = 10, attributes: PlayerAttributes = null) -> void:
	# Offline mode: no peers to broadcast to, and rpc() with no
	# multiplayer peer pushes an error. Bot spawn still happens locally
	# via _registry.spawn_bot in the caller; this RPC is purely the
	# fan-out so connected clients see the bot.
	if is_offline_mode:
		return
	var attrs: PlayerAttributes = attributes if attributes != null else PlayerAttributes.all_average()
	spawn_remote_skater.rpc(peer_id, team_slot, team_id, jersey_color, helmet_color, pants_color, is_left_handed, player_name, jersey_number,
			attrs.height, attrs.weight, attrs.profile, attrs.curve, attrs.flex, attrs.length)

func send_sync_existing_players(peer_id: int, player_data: Array) -> void:
	sync_existing_players.rpc_id(peer_id, player_data)

func send_request_slot_swap(new_team_id: int, new_slot: int) -> void:
	if is_host:
		slot_swap_requested.emit(local_peer_id(), new_team_id, new_slot)
	else:
		request_slot_swap.rpc_id(1, new_team_id, new_slot)

func send_confirm_slot_swap(peer_id: int, old_team_id: int, old_slot: int,
		new_team_id: int, new_slot: int,
		jersey: Color, helmet: Color, pants: Color) -> void:
	for remote_id: int in connected_peer_ids():
		confirm_slot_swap.rpc_id(remote_id, peer_id, old_team_id, old_slot,
				new_team_id, new_slot, jersey, helmet, pants)
	slot_swap_confirmed.emit(peer_id, old_team_id, old_slot, new_team_id, new_slot, jersey, helmet, pants)

@rpc("any_peer", "reliable")
func request_player_ready(is_ready: bool) -> void:
	if not is_host:
		return
	var peer_id: int = multiplayer.get_remote_sender_id()
	for remote_id: int in connected_peer_ids():
		notify_player_ready.rpc_id(remote_id, peer_id, is_ready)
	player_ready_changed.emit(peer_id, is_ready)

@rpc("authority", "reliable")
func notify_player_ready(peer_id: int, is_ready: bool) -> void:
	player_ready_changed.emit(peer_id, is_ready)

func send_player_ready(is_ready: bool) -> void:
	if is_host:
		player_ready_changed.emit(local_peer_id(), is_ready)
	else:
		request_player_ready.rpc_id(1, is_ready)

# `vote` is a RematchVoteRules.Choice — NONE withdraws, REMATCH/LOBBY are the
# two flavors of the shared end-of-game "play again" vote (HUD resolves the
# pool via RematchVoteRules; the host acts on the outcome).
@rpc("any_peer", "reliable")
func request_rematch_vote(vote: int) -> void:
	if not is_host:
		return
	var peer_id: int = multiplayer.get_remote_sender_id()
	for remote_id: int in connected_peer_ids():
		notify_rematch_vote.rpc_id(remote_id, peer_id, vote)
	rematch_vote_changed.emit(peer_id, vote)

@rpc("authority", "reliable")
func notify_rematch_vote(peer_id: int, vote: int) -> void:
	rematch_vote_changed.emit(peer_id, vote)

func send_rematch_vote(vote: int) -> void:
	if is_host:
		var peer_id: int = local_peer_id()
		for remote_id: int in connected_peer_ids():
			notify_rematch_vote.rpc_id(remote_id, peer_id, vote)
		rematch_vote_changed.emit(peer_id, vote)
	else:
		request_rematch_vote.rpc_id(1, vote)

# Voter-pool size for the end-of-game vote, host-broadcast (the skip-replay
# pattern: host counts, peers display). Clients can't compute it themselves —
# from-lobby spectators are only ever tracked host-side, so a client-local
# "peers minus spectators" undercounts the subtraction.
@rpc("authority", "reliable")
func notify_rematch_voters(total: int) -> void:
	rematch_voters_changed.emit(total)

func send_rematch_voters_to_all(total: int) -> void:
	for peer_id: int in connected_peer_ids():
		notify_rematch_voters.rpc_id(peer_id, total)
	rematch_voters_changed.emit(total)

signal join_in_progress(config: Dictionary)

@rpc("authority", "reliable")
func notify_join_in_progress(p_num_periods: int, p_period_duration: float,
		p_ot_enabled: bool, p_ot_duration: float,
		p_home_color_slot: int = TeamColorRegistry.DEFAULT_HOME_SLOT,
		p_away_color_slot: int = TeamColorRegistry.DEFAULT_AWAY_SLOT,
		p_rule_set: int = GameRules.DEFAULT_RULE_SET,
		p_game_id: String = "",
		p_team_size: int = GameRules.DEFAULT_TEAM_SIZE) -> void:
	pending_home_color_slot = p_home_color_slot
	pending_away_color_slot = p_away_color_slot
	pending_rule_set = p_rule_set
	pending_team_size = p_team_size
	# The Hockey scene is about to be (re)loaded for this join — stash any
	# slot/roster RPCs that land before the new scene's _ready.
	scene_swap_pending = true
	join_in_progress.emit({
		"num_periods": p_num_periods,
		"period_duration": p_period_duration,
		"ot_enabled": p_ot_enabled,
		"ot_duration": p_ot_duration,
		"home_color_slot": p_home_color_slot,
		"away_color_slot": p_away_color_slot,
		"rule_set": p_rule_set,
		"game_id": p_game_id,
		"team_size": p_team_size,
	})

func send_join_in_progress(peer_id: int, config: Dictionary) -> void:
	var hslot: int = int(config.get("home_color_slot", pending_home_color_slot))
	var aslot: int = int(config.get("away_color_slot", pending_away_color_slot))
	var rs: int = config.get("rule_set", pending_rule_set)
	var gid: String = config.get("game_id", "")
	var ts: int = config.get("team_size", pending_team_size)
	notify_join_in_progress.rpc_id(peer_id,
		config.num_periods, config.period_duration,
		config.ot_enabled, config.ot_duration, hslot, aslot, rs, gid, ts)

@rpc("authority", "reliable")
func notify_game_start(p_num_periods: int, p_period_duration: float,
		p_ot_enabled: bool, p_ot_duration: float,
		p_home_color_slot: int = TeamColorRegistry.DEFAULT_HOME_SLOT,
		p_away_color_slot: int = TeamColorRegistry.DEFAULT_AWAY_SLOT,
		p_rule_set: int = GameRules.DEFAULT_RULE_SET,
		p_game_id: String = "",
		p_team_size: int = GameRules.DEFAULT_TEAM_SIZE) -> void:
	pending_home_color_slot = p_home_color_slot
	pending_away_color_slot = p_away_color_slot
	pending_rule_set = p_rule_set
	pending_team_size = p_team_size
	# Lobby → Hockey transition incoming; same stash-forcing as join-in-progress.
	scene_swap_pending = true
	game_started.emit({
		"num_periods": p_num_periods,
		"period_duration": p_period_duration,
		"ot_enabled": p_ot_enabled,
		"ot_duration": p_ot_duration,
		"home_color_slot": p_home_color_slot,
		"away_color_slot": p_away_color_slot,
		"rule_set": p_rule_set,
		"game_id": p_game_id,
		"team_size": p_team_size,
	})

@rpc("authority", "reliable")
func sync_lobby_roster(roster: Array) -> void:
	pending_lobby_roster = roster
	lobby_roster_synced.emit(roster)

func send_game_start(config: Dictionary) -> void:
	var hslot: int = int(config.get("home_color_slot", TeamColorRegistry.DEFAULT_HOME_SLOT))
	var aslot: int = int(config.get("away_color_slot", TeamColorRegistry.DEFAULT_AWAY_SLOT))
	var rs: int = config.get("rule_set", GameRules.DEFAULT_RULE_SET)
	var gid: String = config.get("game_id", "")
	var ts: int = config.get("team_size", GameRules.DEFAULT_TEAM_SIZE)
	pending_home_color_slot = hslot
	pending_away_color_slot = aslot
	pending_rule_set = rs
	pending_team_size = ts
	for peer_id: int in connected_peer_ids():
		notify_game_start.rpc_id(peer_id,
			config.num_periods, config.period_duration,
			config.ot_enabled, config.ot_duration, hslot, aslot, rs, gid, ts)
	game_started.emit(config)

func send_lobby_roster(peer_id: int, roster: Array) -> void:
	sync_lobby_roster.rpc_id(peer_id, roster)

@rpc("any_peer", "reliable")
func request_color_vote(color_slot: int) -> void:
	if not is_host:
		return
	# Host receives a peer's vote, mirrors it locally, then fans out to all
	# peers (including the sender) so everyone holds the same vote map.
	var peer_id: int = multiplayer.get_remote_sender_id()
	pending_color_votes[peer_id] = color_slot
	for remote_id: int in connected_peer_ids():
		notify_color_vote.rpc_id(remote_id, peer_id, color_slot)
	color_vote_changed.emit(peer_id, color_slot)

@rpc("authority", "reliable")
func notify_color_vote(peer_id: int, color_slot: int) -> void:
	pending_color_votes[peer_id] = color_slot
	color_vote_changed.emit(peer_id, color_slot)

@rpc("authority", "reliable")
func sync_color_votes(votes: Dictionary) -> void:
	pending_color_votes = votes.duplicate()
	color_votes_synced.emit(pending_color_votes)

func send_color_vote(color_slot: int) -> void:
	if is_host:
		var pid: int = local_peer_id()
		pending_color_votes[pid] = color_slot
		for remote_id: int in connected_peer_ids():
			notify_color_vote.rpc_id(remote_id, pid, color_slot)
		color_vote_changed.emit(pid, color_slot)
	else:
		request_color_vote.rpc_id(1, color_slot)

func send_color_votes_to(peer_id: int, votes: Dictionary) -> void:
	sync_color_votes.rpc_id(peer_id, votes)

# ── Host-picked team colors ──────────────────────────────────────────────────
# The lobby's dynamic teams column lets the host set a team's palette directly
# while no human occupies it (occupied teams resolve from votes instead).
# Broadcast so clients' lobby previews track the host's pick; the colors that
# actually ship are still resolved host-side into the game_start config.

@rpc("authority", "reliable")
func notify_team_colors(home_slot: int, away_slot: int) -> void:
	pending_home_color_slot = home_slot
	pending_away_color_slot = away_slot
	team_colors_changed.emit(home_slot, away_slot)

func send_team_colors(home_slot: int, away_slot: int) -> void:
	if not is_host:
		return
	pending_home_color_slot = home_slot
	pending_away_color_slot = away_slot
	for remote_id: int in connected_peer_ids():
		notify_team_colors.rpc_id(remote_id, home_slot, away_slot)

func send_team_colors_to(peer_id: int, home_slot: int, away_slot: int) -> void:
	notify_team_colors.rpc_id(peer_id, home_slot, away_slot)

# ── Bot slot toggles ─────────────────────────────────────────────────────────
# Phase 1 keeps authoring host-only: only the host UI calls send_bot_slot. The
# RPC plumbing mirrors color votes so clients stay in sync and a future phase
# can let clients request toggles (request_bot_slot) without redesigning.

@rpc("authority", "reliable")
func notify_bot_slot(slot_key: int, is_bot: bool, identity: Dictionary = {}) -> void:
	if is_bot:
		pending_bot_slots[slot_key] = true
		pending_bot_identities[slot_key] = identity
	else:
		pending_bot_slots.erase(slot_key)
		pending_bot_identities.erase(slot_key)
	bot_slot_changed.emit(slot_key, is_bot)

@rpc("authority", "reliable")
func sync_bot_slots(bot_slots: Dictionary, identities: Dictionary = {}) -> void:
	pending_bot_slots = {}
	pending_bot_identities = {}
	for k: int in bot_slots:
		if bot_slots[k]:
			pending_bot_slots[k] = true
			if identities.has(k):
				pending_bot_identities[k] = identities[k]
	bot_slots_synced.emit(pending_bot_slots)

func send_bot_slot(slot_key: int, is_bot: bool) -> void:
	# Host-authored. Client-side calls are silently dropped in Phase 1 to
	# match the host-only design; the surrounding UI gates the button on
	# is_host so this branch shouldn't fire under normal flow.
	if not is_host:
		return
	var identity: Dictionary = {}
	if is_bot:
		pending_bot_slots[slot_key] = true
		# Pick a fresh identity that isn't already in use in another bot slot.
		var used_names: Array[String] = []
		for k: int in pending_bot_identities:
			used_names.append(pending_bot_identities[k].get("name", ""))
		identity = BotIdentityRegistry.pick_for_slot(slot_key, used_names)
		pending_bot_identities[slot_key] = identity
	else:
		pending_bot_slots.erase(slot_key)
		pending_bot_identities.erase(slot_key)
	for remote_id: int in connected_peer_ids():
		notify_bot_slot.rpc_id(remote_id, slot_key, is_bot, identity)
	bot_slot_changed.emit(slot_key, is_bot)

func send_bot_slots_to(peer_id: int, bot_slots: Dictionary, identities: Dictionary = {}) -> void:
	sync_bot_slots.rpc_id(peer_id, bot_slots, identities)

@rpc("authority", "reliable")
func notify_lobby_settings(num_periods: int, period_duration: float, ot_enabled: bool,
		rule_set: int = GameRules.DEFAULT_RULE_SET,
		team_size: int = GameRules.DEFAULT_TEAM_SIZE,
		bot_difficulty: int = BotSkillProfile.Difficulty.NORMAL,
		goalie_difficulty: int = GoalieSkillProfile.Difficulty.NORMAL) -> void:
	pending_num_periods = num_periods
	pending_period_duration = period_duration
	pending_ot_enabled = ot_enabled
	pending_rule_set = rule_set
	pending_team_size = team_size
	pending_bot_difficulty = bot_difficulty
	pending_goalie_difficulty = goalie_difficulty
	lobby_settings_synced.emit(num_periods, period_duration, ot_enabled, rule_set, team_size,
			bot_difficulty, goalie_difficulty)

func send_lobby_settings(num_periods: int, period_duration: float, ot_enabled: bool, rule_set: int,
		team_size: int, bot_difficulty: int, goalie_difficulty: int) -> void:
	pending_num_periods = num_periods
	pending_period_duration = period_duration
	pending_ot_enabled = ot_enabled
	pending_rule_set = rule_set
	pending_team_size = team_size
	pending_bot_difficulty = bot_difficulty
	pending_goalie_difficulty = goalie_difficulty
	for peer_id: int in connected_peer_ids():
		notify_lobby_settings.rpc_id(peer_id, num_periods, period_duration, ot_enabled, rule_set,
				team_size, bot_difficulty, goalie_difficulty)

func send_lobby_settings_to(peer_id: int, num_periods: int, period_duration: float, ot_enabled: bool,
		rule_set: int, team_size: int, bot_difficulty: int, goalie_difficulty: int) -> void:
	notify_lobby_settings.rpc_id(peer_id, num_periods, period_duration, ot_enabled, rule_set,
			team_size, bot_difficulty, goalie_difficulty)

@rpc("authority", "reliable")
func notify_return_to_lobby(roster: Array) -> void:
	pending_lobby_roster = roster
	return_to_lobby_received.emit(roster)

func send_return_to_lobby_to_all(roster: Array) -> void:
	for peer_id: int in connected_peer_ids():
		notify_return_to_lobby.rpc_id(peer_id, roster)
	pending_lobby_roster = roster
	return_to_lobby_received.emit(roster)

func get_jitter_p95() -> float:
	if _jitter_samples.is_empty():
		return 0.0
	var sorted: Array = _jitter_samples.duplicate()
	sorted.sort()
	return sorted[NetworkTelemetry.percentile_index(sorted.size(), 0.95)]

# Records one world-state packet's delay vs the synced host clock. floor is the
# de-clumped path delay (drops instantly to a better delay, rises slowly toward
# worse); mean/dev are Jacobson EWMAs of the excess over floor. Because each
# packet is timed against its own capture stamp, a burst of packets landing
# together does NOT inflate the spread — that's what separates clumping from
# genuine path jitter.
func _record_packet_delay(d: float) -> void:
	const GAIN: float = 0.125       # Jacobson 1/8: ~8-sample memory, spike decays geometrically
	const FLOOR_RISE: float = 0.01
	if _pdv_floor < 0.0 or d < _pdv_floor:
		_pdv_floor = d
	else:
		_pdv_floor += (d - _pdv_floor) * FLOOR_RISE
	var excess: float = maxf(0.0, d - _pdv_floor)
	_pdv_mean += (excess - _pdv_mean) * GAIN
	_pdv_dev += (absf(excess - _pdv_mean) - _pdv_dev) * GAIN

# PDV jitter estimate (ms): EWMA mean excess + 4×mean-deviation (the
# Jacobson/RFC-6298 safety multiple) over the de-clumped delay.
func get_packet_delay_spread_ms() -> float:
	return (_pdv_mean + 4.0 * _pdv_dev) * 1000.0

func get_packet_delay_floor_ms() -> float:
	return maxf(_pdv_floor, 0.0) * 1000.0

func get_target_interpolation_delay() -> float:
	# Cached once per physics frame: get_jitter_p95() duplicates + sorts the sample
	# buffer, and this is read by the per-packet shared-delay advance and the F3
	# overlay. (Claim-sends report the ADAPTED get_interpolation_delay instead —
	# the value that actually positioned the rendered entity — so the host's
	# remote-view rewind matches what the client saw.) The target drifts slowly
	# (adapt clamps ±1.5/+10 ms per packet), so a frame of staleness is irrelevant.
	var frame: int = Engine.get_physics_frames()
	if frame != _target_interp_frame:
		_target_interp_frame = frame
		_target_interp_cached = _compute_target_interpolation_delay()
	return _target_interp_cached

func _compute_target_interpolation_delay() -> float:
	if not is_clock_ready():
		return Constants.NETWORK_INTERPOLATION_DELAY
	var rtt: float = get_rtt_ms() / 1000.0
	var rtt_half: float = rtt / 2.0
	var broadcast_interval: float = 1.0 / Constants.STATE_RATE
	# Minimum is RTT/2 + one full broadcast interval so render_time always has
	# a buffered state ahead of it between packet arrivals. Jitter margin on top.
	#
	# The margin is the DE-CLUMPED packet-delay spread (Jacobson mean + 4x mean-
	# deviation of each packet's delay vs the host clock — get_packet_delay_spread_ms).
	# Because every packet is timed against its own host-capture stamp, relay
	# clumping (several snapshots landing together, then a gap) barely moves it:
	# it measures genuine PATH jitter, not arrival bunching. So it needs no clump-
	# compensation multiplier and is used at 1.0x — lower baseline render latency
	# on every remote entity than the old arrival-gap "jitter_p95 x 2.0" cushion,
	# which over-cushioned a clean link to absorb clumps it couldn't tell apart
	# from jitter. Transient clumps are absorbed by the asymmetric +10ms/packet
	# up-clamp in adapt_interpolation_delay instead of by a fat static baseline.
	#
	# Canary if this under-cushions a real link: "Guessing ahead" (extrapolation
	# /s, F3) climbing past the <1/s target — the buffer is underrunning between
	# clumps faster than the up-clamp can chase, visible as rhythmic snap-back on
	# remote skaters during fast play. If that shows up, swap the margin back to
	# the conservative `get_jitter_p95() * 2.0`. See ARCHITECTURE.md -> Tier 2A.
	var jitter_margin: float = get_packet_delay_spread_ms() / 1000.0
	var target: float = rtt_half + broadcast_interval + jitter_margin
	return clampf(target, maxf(rtt_half + broadcast_interval, 0.016), 0.200)

func adapt_interpolation_delay(current: float) -> float:
	var target: float = get_target_interpolation_delay()
	var change: float = lerpf(current, target, 0.15) - current
	# Asymmetric clamp: react fast to sustained jitter, relax gently from one-offs.
	# Effective recovery rate = per-packet × broadcast rate. At the current 120Hz:
	#   +10ms/packet up: 1200ms/sec, catches a 150ms sustained RTT spike in ~125ms.
	#     Without this aggressive up-rate, extrapolation fires every ~50ms on
	#     all remote skaters during the catch-up window (visible micro-stutter).
	#   -1.5ms/packet down: 180ms/sec, recovers a 60ms buffer over-inflation in
	#     ~330ms. The two earlier-shipped tunings here were sized for different
	#     broadcast rates and don't carry forward: the original -1ms/packet was
	#     40ms/sec at 40Hz (slow — buffer stayed inflated ~10s); the interim
	#     -3ms/packet became 360ms/sec at 120Hz (too aggressive, risks
	#     undershoot if jitter returns inside the window). -1.5ms/packet at
	#     120Hz lands at 180ms/sec — slightly faster than the original 40Hz
	#     target (120ms/sec) and well clear of industry norms (~80-150 ms/sec).
	return current + clampf(change, -0.0015, 0.010)

# ── Shared interpolation delay ──────────────────────────────────────────────
# One delay drives every remote interpolator (remote skaters, loose puck,
# goalie) so they all render at estimated_host_time() - _interp_delay — the SAME
# instant — keeping relative timing (puck-on-stick, save-vs-puck) exact instead
# of letting independently-adapting per-actor delays drift apart. Advanced once
# per received world-state packet in receive_world_state (the per-packet cadence
# the adapt rates are tuned for; multiple actors reading the same value cost
# nothing).
var _interp_delay: float = Constants.NETWORK_INTERPOLATION_DELAY

func advance_interpolation_delay() -> void:
	_interp_delay = adapt_interpolation_delay(_interp_delay)

func get_interpolation_delay() -> float:
	return _interp_delay

func get_peer_loss_rate(peer_id: int = -1) -> float:
	if is_host:
		return _peer_loss_rates.get(peer_id, 0.0)
	return packet_loss_pct

func _on_ws_sequence_received(seq: int) -> void:
	if _last_ws_seq_received >= 0:
		var gap: int = (seq - _last_ws_seq_received - 1 + 65536) % 65536
		_ws_drop_window += gap
	_ws_recv_window += 1
	_last_ws_seq_received = seq

# ── Registration ──────────────────────────────────────────────────────────────
func set_world_state_provider(provider: Callable) -> void:
	_world_state_provider = provider

func set_input_batch_provider(provider: Callable) -> void:
	_input_batch_provider = provider

func send_board_hit_to_all(position: Vector3) -> void:
	for peer_id: int in connected_peer_ids():
		notify_board_hit.rpc_id(peer_id, position)

@rpc("authority", "unreliable")
func notify_board_hit(position: Vector3) -> void:
	NetworkSimManager.send(func(pos: Vector3) -> void: board_hit_received.emit(pos), [position], false)

func send_goal_body_hit_to_all(position: Vector3) -> void:
	for peer_id: int in connected_peer_ids():
		notify_goal_body_hit.rpc_id(peer_id, position)

@rpc("authority", "unreliable")
func notify_goal_body_hit(position: Vector3) -> void:
	NetworkSimManager.send(func(pos: Vector3) -> void: goal_body_hit_received.emit(pos), [position], false)

func send_post_hit_to_all(position: Vector3) -> void:
	for peer_id: int in connected_peer_ids():
		notify_post_hit.rpc_id(peer_id, position)

@rpc("authority", "unreliable")
func notify_post_hit(position: Vector3) -> void:
	NetworkSimManager.send(func(pos: Vector3) -> void: post_hit_received.emit(pos), [position], false)

func send_goalie_hit_to_all(position: Vector3) -> void:
	for peer_id: int in connected_peer_ids():
		notify_goalie_hit.rpc_id(peer_id, position)

@rpc("authority", "unreliable")
func notify_goalie_hit(position: Vector3) -> void:
	NetworkSimManager.send(func(pos: Vector3) -> void: goalie_hit_received.emit(pos), [position], false)

func send_deflection_to_all(position: Vector3) -> void:
	for peer_id: int in connected_peer_ids():
		notify_deflection.rpc_id(peer_id, position)

@rpc("authority", "unreliable")
func notify_deflection(position: Vector3) -> void:
	NetworkSimManager.send(func(pos: Vector3) -> void: deflection_received.emit(pos), [position], false)

func send_body_block_to_all(position: Vector3) -> void:
	for peer_id: int in connected_peer_ids():
		notify_body_block.rpc_id(peer_id, position)

@rpc("authority", "unreliable")
func notify_body_block(position: Vector3) -> void:
	NetworkSimManager.send(func(pos: Vector3) -> void: body_block_received.emit(pos), [position], false)

func send_puck_strip_to_all(position: Vector3) -> void:
	for peer_id: int in connected_peer_ids():
		notify_puck_strip.rpc_id(peer_id, position)

@rpc("authority", "unreliable")
func notify_puck_strip(position: Vector3) -> void:
	NetworkSimManager.send(func(pos: Vector3) -> void: puck_strip_received.emit(pos), [position], false)

func send_body_check_to_all(hitter_peer_id: int, victim_peer_id: int,
		force: float, hit_dir: Vector3) -> void:
	for peer_id: int in connected_peer_ids():
		notify_body_check.rpc_id(peer_id, hitter_peer_id, victim_peer_id, force, hit_dir)

# hitter_peer_id on the wire since PROTOCOL_VERSION 19: the check-delivery
# body pose (the hitter's shoulder drive) fires from this same broadcast so it
# lands the identical frame as the burst/thud on every machine.
@rpc("authority", "unreliable")
func notify_body_check(hitter_peer_id: int, victim_peer_id: int,
		force: float, hit_dir: Vector3) -> void:
	NetworkSimManager.send(
			func(hid: int, vid: int, f: float, d: Vector3) -> void:
				body_check_landed.emit(hid, vid, f, d),
			[hitter_peer_id, victim_peer_id, force, hit_dir], false)

func send_stick_lift_to_all(position: Vector3) -> void:
	for peer_id: int in connected_peer_ids():
		notify_stick_lift.rpc_id(peer_id, position)

@rpc("authority", "unreliable")
func notify_stick_lift(position: Vector3) -> void:
	NetworkSimManager.send(func(pos: Vector3) -> void: stick_lift_received.emit(pos), [position], false)

# Nudge (self-tap) cue. Host-authoritative, like the shot cue: the nudger already
# played it locally the instant they tapped, so the host excludes them and every
# other peer hears it here. `except_peer_id` is the nudger (host's own nudges
# and bots pass -1).
func send_nudge_to_all(position: Vector3, except_peer_id: int = -1) -> void:
	for peer_id: int in connected_peer_ids():
		if peer_id == except_peer_id:
			continue
		notify_nudge.rpc_id(peer_id, position)

@rpc("authority", "unreliable")
func notify_nudge(position: Vector3) -> void:
	NetworkSimManager.send(func(pos: Vector3) -> void: nudge_received.emit(pos), [position], false)

# Shot SFX (wrister/slapper). Unlike puck-collision SFX, the shooter already
# plays the cue locally the instant they release (LocalController path), so the
# host excludes them from the broadcast to avoid a double-hit; every other peer
# hears it here. `except_peer_id` is the shooter (host's own shots pass -1).
func send_shot_to_all(position: Vector3, is_slapper: bool, except_peer_id: int = -1) -> void:
	for peer_id: int in connected_peer_ids():
		if peer_id == except_peer_id:
			continue
		notify_shot.rpc_id(peer_id, position, is_slapper)

@rpc("authority", "unreliable")
func notify_shot(position: Vector3, is_slapper: bool) -> void:
	NetworkSimManager.send(
		func(pos: Vector3, slap: bool) -> void: shot_sound_received.emit(pos, slap),
		[position, is_slapper], false)

func send_spectator_demoted_to_all(peer_id: int) -> void:
	for remote_id: int in connected_peer_ids():
		notify_spectator_demoted.rpc_id(remote_id, peer_id)
	spectator_demoted_received.emit(peer_id)

@rpc("authority", "reliable")
func notify_spectator_demoted(peer_id: int) -> void:
	spectator_demoted_received.emit(peer_id)

# ── Smart ping (context-sensitive team message) ──────────────────────────────
# Vote-shaped relay: a client sends its resolved ping to the host, the host
# validates (type range + per-peer cooldown) and fans out to ALL peers
# including the sender, then self-emits — so offline / free play degrades to
# the local emit (connected_peer_ids() is empty) and bots still obey.
# Reliable: a ping is a discrete message; a dropped one is a lost order.
# Display filtering (team-only) and bot directives live in GameManager.

var _last_smart_ping_ms: Dictionary = {}   # peer_id -> Time.get_ticks_msec()


func send_smart_ping(ping_type: int, target_peer_id: int, world_pos: Vector3) -> void:
	if is_host:
		var pid: int = local_peer_id()
		if not _smart_ping_allowed(pid) or not PingRules.is_valid_type(ping_type):
			return
		for remote_id: int in connected_peer_ids():
			notify_smart_ping.rpc_id(remote_id, pid, ping_type, target_peer_id, world_pos)
		smart_ping_received.emit(pid, ping_type, target_peer_id, world_pos)
	else:
		# Client-side cooldown mirror so a spammed key doesn't even hit the wire;
		# the host re-checks against its own clock regardless.
		if not _smart_ping_allowed(local_peer_id()):
			return
		request_smart_ping.rpc_id(1, ping_type, target_peer_id, world_pos)


@rpc("any_peer", "reliable")
func request_smart_ping(ping_type: int, target_peer_id: int, world_pos: Vector3) -> void:
	if not is_host:
		return
	var peer_id: int = multiplayer.get_remote_sender_id()
	if not _smart_ping_allowed(peer_id) or not PingRules.is_valid_type(ping_type):
		return
	for remote_id: int in connected_peer_ids():
		notify_smart_ping.rpc_id(remote_id, peer_id, ping_type, target_peer_id, world_pos)
	smart_ping_received.emit(peer_id, ping_type, target_peer_id, world_pos)


@rpc("authority", "reliable")
func notify_smart_ping(sender_peer_id: int, ping_type: int,
		target_peer_id: int, world_pos: Vector3) -> void:
	NetworkSimManager.send(
			func(pid: int, t: int, tgt: int, pos: Vector3) -> void:
				smart_ping_received.emit(pid, t, tgt, pos),
			[sender_peer_id, ping_type, target_peer_id, world_pos], true)


# Per-peer anti-spam gate; passing records the attempt. Wall clock is fine
# here — pings are cosmetic-plus-directive events, not simulation inputs.
func _smart_ping_allowed(peer_id: int) -> bool:
	var now_ms: int = Time.get_ticks_msec()
	var last_ms: int = _last_smart_ping_ms.get(peer_id, -(1 << 30))
	if now_ms - last_ms < int(PingRules.COOLDOWN_S * 1000.0):
		return false
	_last_smart_ping_ms[peer_id] = now_ms
	return true

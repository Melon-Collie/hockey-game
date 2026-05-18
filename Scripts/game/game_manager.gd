extends Node

# Orchestrator. Owns the GameStateMachine and wires together six focused
# collaborators, each in its own file:
#
#   PlayerRegistry       — players dict, spawn/despawn, resolvers
#   WorldStateCodec      — RPC-wire serialization for world state + stats
#   ShotOnGoalTracker    — pending-shot state machine + assist crediting
#   HitTracker           — cross-team hit validation + stat crediting
#   PhaseCoordinator     — phase-entry side effects, goal pipeline, replay cinematic
#   SlotSwapCoordinator  — mid-game slot swap request/confirm
#
# The public signals below are re-exposed from collaborators so HUD / Camera /
# Scoreboard / Controllers continue to receive the same events.

# ── Signals ───────────────────────────────────────────────────────────────────
signal goal_scored(scoring_team: Team, scorer_name: String, assist1_name: String, assist2_name: String)
signal score_changed(score_0: int, score_1: int)
signal phase_changed(new_phase: GamePhase.Phase)
signal period_changed(new_period: int)
signal clock_updated(time_remaining: float)
signal game_over()
signal game_reset()
signal player_joined(player_name: String, team_color: Color)
signal player_left(player_name: String, team_color: Color)
signal stats_updated
signal shots_on_goal_changed(sog_0: int, sog_1: int)
signal team_colors_ready(home_primary: Color, home_secondary: Color, away_primary: Color, away_secondary: Color)
signal local_player_hit(magnitude: float)
signal replay_started
signal replay_stopped
# Live tally of unanimous skip-replay votes (emitted on every accepted vote and
# at replay start with current=0). HUD listens to keep the "[SPACE] TO SKIP
# (X/Y)" prompt current.
signal skip_replay_vote_updated(current: int, total: int)
# Emitted on the local peer when a spectator-slot assignment lands. HUD / camera /
# input subsystems listen so they can flip spectator chrome on/off without
# polling. Only ever fires once per session right now (lobby → game transition);
# mid-game player ↔ spectator swap is deferred.
signal local_spectator_state_changed(is_spectator: bool)
# Emitted on every peer the moment an out-of-play puck is confirmed (after the
# grace window). HUD listens to flash the "PUCK OUT OF PLAY" toast; the
# FACEOFF_PREP phase change drives the countdown banner separately.
signal puck_out_of_play()

# ── Domain state ──────────────────────────────────────────────────────────────
var _state_machine: GameStateMachine = null
var _last_emitted_clock_secs: int = -1
var _last_ghost_state: Dictionary = {}  # peer_id -> bool, host only
var _input_blocked: bool = false
var _puck_oob_timer: float = 0.0
# Mirrors the local GoalReplayDriver._active. Gates the skip_replay action so
# we don't fire stray vote RPCs outside of the cinematic window.
var _in_replay_locally: bool = false
# Holds an existing-players sync that arrived before _spawn_world ran. The
# host sends sync_existing_players just before assign_player_slot; if the
# RPCs land after the scene has changed but before on_slot_assigned has
# created _state_machine, the sync would otherwise be dropped and the host
# (only delivered through this path) would never spawn on the client.
var _pending_existing_players: Array = []

# ── Infrastructure ────────────────────────────────────────────────────────────
var _spawner: ActorSpawner = null
var teams: Array[Team] = []
var puck: Puck = null
# One TeamBrain per team, host-only. Allocated in _spawn_world. Bots read
# their role from here via SkaterAgent. Indexed by team_id (0=home, 1=away).
# AI consumes WorldSnapshots via get_state_at() rather than a separate
# perception buffer — the lag-comp ring already captures the same data.
var team_brains: Array[TeamBrain] = []
# Shared "current frame" world snapshot, refreshed once per host physics
# frame after StateBufferManager.capture. AIControllers and TeamBrains
# read from here instead of each fetching their own — saves redundant
# interpolation work and per-tick allocations.
var current_snapshot: WorldSnapshot = null
var goals: Array[HockeyGoal] = []
var goalies: Array[Goalie] = []
var goalie_controllers: Array[GoalieController] = []
var puck_controller: PuckController = null

# Cached snapshot of goalie pose for skater IK clamping. Refreshed once per
# physics tick from `goalies` / `goalie_controllers`. Without the cache,
# `get_goalie_data()` allocates a fresh `Array[Dictionary]` of two dict
# literals on every call — `SkaterIKCoordinator.clamp_blade_from_goalies`
# calls it on every skater per tick (~12 calls × 240 Hz = ~5760 dict allocs/s).
var _cached_goalie_data: Array[Dictionary] = []

# ── Subsystems ────────────────────────────────────────────────────────────────
var _registry: PlayerRegistry = null
var _codec: WorldStateCodec = null
var _shot_tracker: ShotOnGoalTracker = null
var _hit_tracker: HitTracker = null
var _pickup_claim: PickupClaimResolver = null
var _hit_claim: HitClaimResolver = null
var _phase_coord: PhaseCoordinator = null
var _swap_coord: SlotSwapCoordinator = null
var _telemetry: NetworkTelemetry = null
var _debug_overlay: NetworkDebugOverlay = null
var _state_buffer_manager: StateBufferManager = null
var _recorder: ReplayRecorder = null
var _goal_replay_driver: GoalReplayDriver = null
var _career_reporter: CareerStatsReporter = null
# Streams broadcast frames to user://replays/<game_id>.mreplay on a worker
# thread. Lives on every peer (host + client + spectator) for any session
# with a non-empty _game_id and PlayerPrefs.replay_recording_enabled. Opens
# once the registry has stabilized (post-_push_lobby_assignments_to_clients
# on host, post-sync_existing_players on clients) and closes on scene exit.
var _replay_file_writer: ReplayFileWriter = null
# Tracks the phase of the most recent .mreplay frame so movement-locked
# phases (GOAL_SCORED, FACEOFF_PREP, END_OF_PERIOD, GAME_OVER) record their
# first transition frame and skip the duplicate-static frames that follow.
# The transition frame at GOAL_SCORED entry captures puck-in-net, which the
# previous broadcast (still PLAYING) usually missed. -1 = nothing recorded
# yet this game; reset on scene exit + rematch rollover.
var _last_recorded_phase: int = -1

# ── Spectator state ───────────────────────────────────────────────────────────
# Host-side: peer_ids of connected spectators. Used to gate `_registry.spawn`
# and the `send_spawn_remote_skater` broadcast on join.  Locally cleared on
# scene exit. Spectators are NOT in `_registry`, so any path that iterates
# `_registry.all()` already excludes them naturally.
var _spectator_peers: Dictionary[int, bool] = {}
# Client-side: true when the local peer was assigned a spectator slot. Drives
# the SpectatorCamera mount and HUD chrome hiding. Also gates the local-skater
# spawn path in on_slot_assigned.
var _is_local_spectator: bool = false
var _spectator_camera: SpectatorCamera = null

# ── Game identity ─────────────────────────────────────────────────────────────
# Minted by the host in LobbyManager._on_start_pressed and broadcast via
# game_start. Used as the .mreplay filename and (planned for Feature C) stored
# on career_stats rows so a single game can be reconstructed across players.
# **Empty in offline / tutorial mode** — those sessions don't write replays
# or career stats. Downstream consumers must treat empty as "skip recording".
var _game_id: String = ""

# Sound wiring is split between persistent (NetworkManager autoload, GameManager
# self-signals — wire once for the lifetime of the process) and per-game (puck /
# puck_controller / _phase_coord — recreated each match in _spawn_world). The
# guard prevents duplicate connections to the persistent set on rematch.
var _persistent_sound_signals_wired: bool = false


func _ready() -> void:
	randomize()
	# Make Manrope the engine-wide fallback font so every Control that
	# doesn't set its own font picks it up automatically — saves us from
	# touching every popup, dialog, and HUD label by hand. Explicit font
	# overrides (DISPLAY_FONT on the scorebug, player card, etc.) still
	# win since they're per-control theme overrides on top of the fallback.
	ThemeDB.fallback_font = MenuStyle.UI_FONT
	_career_reporter = CareerStatsReporter.new()
	game_over.connect(_on_game_over)
	_wire_network_signals()


func _wire_network_signals() -> void:
	NetworkManager.set_world_state_provider(get_world_state)
	NetworkManager.host_ready.connect(on_host_started)
	NetworkManager.client_connected.connect(on_connected_to_server)
	NetworkManager.disconnected_from_server.connect(on_scene_exit)
	NetworkManager.peer_joined.connect(on_player_connected)
	NetworkManager.peer_disconnected.connect(on_player_disconnected)
	NetworkManager.world_state_received.connect(_on_world_state_received)
	NetworkManager.slot_assigned.connect(on_slot_assigned)
	NetworkManager.remote_skater_spawn_requested.connect(spawn_remote_skater)
	NetworkManager.existing_players_synced.connect(sync_existing_players)
	NetworkManager.local_puck_pickup_confirmed.connect(on_local_player_picked_up_puck)
	NetworkManager.local_puck_stolen.connect(on_local_player_puck_stolen)
	NetworkManager.remote_carrier_changed.connect(_on_remote_carrier_changed)
	NetworkManager.remote_puck_release_received.connect(on_remote_puck_release)
	NetworkManager.one_timer_release_received.connect(on_remote_one_timer_release)
	NetworkManager.carrier_puck_dropped.connect(on_carrier_puck_dropped)
	NetworkManager.goal_received.connect(_on_goal_received)
	NetworkManager.puck_out_of_play_received.connect(_on_puck_out_of_play_received)
	NetworkManager.faceoff_positions_received.connect(_on_faceoff_positions_received)
	NetworkManager.game_reset_received.connect(on_game_reset)
	NetworkManager.stats_received.connect(_on_stats_received)
	NetworkManager.slot_swap_requested.connect(_on_slot_swap_requested)
	NetworkManager.slot_swap_confirmed.connect(_on_slot_swap_confirmed)
	NetworkManager.return_to_lobby_received.connect(_on_return_to_lobby)
	NetworkManager.local_identity_changed.connect(_on_local_identity_changed)
	NetworkManager.local_preferred_color_changed.connect(_on_local_preferred_color_changed)
	NetworkManager.pickup_claim_received.connect(_on_pickup_claim_received)
	NetworkManager.ghost_state_received.connect(_on_ghost_state_received)
	NetworkManager.hit_claim_received.connect(_on_hit_claim_received)
	NetworkManager.goalie_state_transition_received.connect(_on_goalie_state_transition_received)
	NetworkManager.goalie_shot_reaction_received.connect(_on_goalie_shot_reaction_received)
	NetworkManager.goalie_reaction_cleared_received.connect(_on_goalie_reaction_cleared_received)
	NetworkManager.input_batch_received.connect(_on_input_batch_received)
	NetworkManager.spectator_demoted_received.connect(_on_spectator_demoted_received)
	NetworkManager.skip_replay_request_received.connect(_on_remote_skip_replay_request)
	NetworkManager.skip_replay_vote_updated.connect(_on_remote_skip_replay_vote)
	NetworkManager.replay_event_received.connect(_on_replay_event_received)
	replay_started.connect(_on_local_replay_started)
	replay_stopped.connect(_on_local_replay_stopped)


# ── Process ───────────────────────────────────────────────────────────────────
func _process(delta: float) -> void:
	if _telemetry != null:
		_telemetry.tick(delta)
		_observe_telemetry()
	if not NetworkManager.is_host or _state_machine == null:
		return
	if NetworkManager.is_replay_mode():
		return
	if _state_machine.tick(delta):
		_phase_coord.handle_phase_entered()
	if _state_machine.current_phase == GamePhase.Phase.PLAYING:
		var secs: int = int(_state_machine.time_remaining)
		if secs != _last_emitted_clock_secs:
			_last_emitted_clock_secs = secs
			clock_updated.emit(_state_machine.time_remaining)


func _physics_process(delta: float) -> void:
	if _state_machine != null and _registry != null:
		var local: PlayerRecord = _registry.get_local()
		if local != null and not PhaseRules.is_dead_puck_phase(_state_machine.current_phase):
			local.stats.toi_seconds += delta
	# Refresh goalie pose cache once per tick — read by skater IK on every
	# blade-from-mouse call. Runs on host AND clients before the host gate
	# below since IK clamping happens everywhere.
	_refresh_goalie_data_cache()
	if not NetworkManager.is_host or puck == null or _state_machine == null:
		return
	# Goal replay temporarily owns actor positions on the host. Skip the live
	# simulation tick so authoritative state buffer captures, ghost checks, etc.
	# don't fight (or pollute the recorder with) replay positions.
	if NetworkManager.is_replay_mode():
		return
	if _state_buffer_manager != null and puck_controller != null:
		_state_buffer_manager.capture(_registry, puck_controller, goalie_controllers)
	# Build the shared "current frame" snapshot once after capture. AI
	# controllers and team brains both read from current_snapshot rather
	# than each calling get_state_delayed independently — at 6 bots + 2
	# brains that's 8 redundant interpolation passes per frame, each
	# allocating ~10 RefCounted state objects.
	if _state_buffer_manager != null:
		current_snapshot = get_state_delayed(0.0)
	if not team_brains.is_empty() and current_snapshot != null:
		for brain: TeamBrain in team_brains:
			brain.tick(delta, current_snapshot)
	_update_host_puck_tracking()
	_check_puck_out_of_bounds(delta)
	_apply_ghost_state()
	_shot_tracker.tick(delta)
	_pickup_claim.tick(delta)


func _check_puck_out_of_bounds(delta: float) -> void:
	if _state_machine.current_phase != GamePhase.Phase.PLAYING:
		_puck_oob_timer = 0.0
		return
	if puck.carrier != null:
		_puck_oob_timer = 0.0
		return
	var pos := puck.global_position
	var pos2d := Vector2(pos.x, pos.z)
	var clamped := GameRules.clamp_to_rink_inner(pos2d)
	if pos2d.distance_to(clamped) > 0.2:
		_puck_oob_timer += delta
		if _puck_oob_timer >= GameRules.PUCK_OOB_GRACE_DURATION:
			_puck_oob_timer = 0.0
			# Use the boundary projection — how far past the boards the puck
			# travelled shouldn't sway dot selection.
			var dot: Vector2 = GameRules.nearest_faceoff_dot(clamped)
			puck_out_of_play.emit()
			NetworkManager.notify_puck_out_of_play_to_all()
			SoundManager.play_sfx(SoundManager.Sound.FACEOFF_WHISTLE)
			_state_machine.begin_faceoff_prep(dot)
			_phase_coord.handle_phase_entered()
	else:
		_puck_oob_timer = 0.0


func _update_host_puck_tracking() -> void:
	if puck.carrier != null:
		var carrier_team: Team = _registry.resolve_team(puck.carrier)
		if carrier_team != null:
			_state_machine.notify_puck_carried(carrier_team.team_id, puck.carrier.global_position.z)
	elif _state_machine.current_phase == GamePhase.Phase.PLAYING:
		_state_machine.check_icing_for_loose_puck(
				puck.global_position.z, _registry.positions_by_peer_id())


func _apply_ghost_state() -> void:
	var positions: Dictionary = {}
	var carrier_peer_id: int = -1
	for peer_id: int in _registry.all():
		var record: PlayerRecord = _registry.get_record(peer_id)
		positions[peer_id] = record.skater.global_position
		if puck.carrier != null and record.skater == puck.carrier:
			carrier_peer_id = peer_id
	var ghosts: Dictionary = _state_machine.compute_ghost_state(
			positions, carrier_peer_id, puck.global_position)
	for peer_id in ghosts:
		var r: PlayerRecord = _registry.get_record(peer_id)
		if r != null:
			var new_ghost: bool = ghosts[peer_id]
			r.skater.set_ghost(new_ghost)
			if new_ghost != _last_ghost_state.get(peer_id, false):
				_last_ghost_state[peer_id] = new_ghost
				NetworkManager.send_ghost_state_to_all(peer_id, new_ghost)


# ── Network Callbacks ─────────────────────────────────────────────────────────
func on_host_started() -> void:
	_spawn_world()
	if not NetworkManager.pending_lobby_slots.is_empty():
		var my_slot: Dictionary = NetworkManager.pending_lobby_slots.get(1, {})
		var team_id: int = my_slot.get("team_id", 0)
		var team_slot: int = my_slot.get("team_slot", 0)
		if team_id == GameRules.SPECTATOR_TEAM_ID:
			_spectator_peers[1] = true
			_become_local_spectator()
		else:
			_state_machine.register_remote_assigned_player(1, team_slot, team_id)
			_spawn_local(1, team_slot, teams[team_id])
		_push_lobby_assignments_to_clients()
	else:
		var assignment: Dictionary = _state_machine.register_host(1)
		_spawn_local(1, assignment.team_slot, teams[assignment.team_id])
	_spawn_bots_from_lobby()
	# Registry is fully populated by this point — capture roster + open file.
	_open_replay_file_writer()
	# Open the match with a faceoff countdown rather than dropping straight
	# into PLAYING. Tutorial scripts its own intro; free play is a casual
	# warmup that shouldn't gate the player behind a countdown — both stay
	# in PLAYING from the start.
	if not NetworkManager.is_tutorial_mode and not NetworkManager.is_free_play_mode:
		_state_machine.begin_faceoff_prep()
		_phase_coord.handle_phase_entered()


func on_connected_to_server() -> void:
	pass


func on_slot_assigned(team_slot: int, team_id: int, jersey_color: Color, helmet_color: Color, pants_color: Color) -> void:
	# `_state_machine != null` means the world is already spawned → this is a
	# mid-game spectator-to-player promotion, not the initial scene load.
	var is_mid_game_promote: bool = _state_machine != null
	if not is_mid_game_promote:
		_spawn_world()
	var peer_id: int = NetworkManager.local_peer_id()
	if team_id == GameRules.SPECTATOR_TEAM_ID:
		_become_local_spectator()
		return
	if _is_local_spectator:
		_teardown_spectator_camera()
	var colors: Dictionary = TeamColorRegistry.get_colors(teams[team_id].color_id, team_id)
	_state_machine.register_remote_assigned_player(peer_id, team_slot, team_id)
	_registry.spawn(peer_id, team_slot, teams[team_id],
			jersey_color, helmet_color, pants_color,
			colors.jersey_stripe, colors.gloves, colors.pants_stripe, colors.socks, colors.socks_stripe,
			colors.secondary, colors.text, colors.text_outline,
			NetworkManager.local_is_left_handed, NetworkManager.local_player_name, true,
			NetworkManager.local_jersey_number)
	# Flush any sync_existing_players payload that landed before _spawn_world
	# ran. Both the GameManager queue (RPC arrived after scene load, while
	# _state_machine was null) and NetworkManager.pending_join_players (RPC
	# arrived during scene transition but pending_join_slot was empty when
	# game_scene._ready ran) are drained here so the host record always lands.
	if not _pending_existing_players.is_empty():
		var queued: Array = _pending_existing_players
		_pending_existing_players = []
		sync_existing_players(queued)
	if not NetworkManager.pending_join_players.is_empty():
		var deferred: Array = NetworkManager.pending_join_players
		NetworkManager.pending_join_players = []
		sync_existing_players(deferred)


func on_player_connected(peer_id: int) -> void:
	if not NetworkManager.is_host or _state_machine == null:
		return
	var config: Dictionary = {
		"num_periods": _state_machine.num_periods,
		"period_duration": _state_machine.period_duration,
		"ot_enabled": _state_machine.ot_enabled,
		"ot_duration": _state_machine.ot_duration,
		"home_color_id": NetworkManager.pending_home_color_id,
		"away_color_id": NetworkManager.pending_away_color_id,
		"rule_set": _state_machine.rule_set,
	}
	# Spectator branch: declared via pending_lobby_slots[peer_id].team_id == -1.
	# Mid-game joiners always come in as players (existing auto-balance flow);
	# joining-as-spectator is a lobby-only choice for v1.
	var pending_slot: Dictionary = NetworkManager.pending_lobby_slots.get(peer_id, {})
	if pending_slot.get("team_id", 0) == GameRules.SPECTATOR_TEAM_ID:
		_spectator_peers[peer_id] = true
		NetworkManager.send_join_in_progress(peer_id, config)
		NetworkManager.send_slot_assignment(peer_id,
				pending_slot.get("team_slot", 0), GameRules.SPECTATOR_TEAM_ID,
				Color(0, 0, 0, 0), Color(0, 0, 0, 0), Color(0, 0, 0, 0))
		NetworkManager.send_sync_existing_players(peer_id, _collect_existing_player_data())
		return
	var assignment: Dictionary = _state_machine.on_player_connected(peer_id)
	NetworkManager.send_join_in_progress(peer_id, config)
	NetworkManager.send_sync_existing_players(peer_id, _collect_existing_player_data())
	_spawn_player_and_broadcast(peer_id, assignment.team_id, assignment.team_slot,
			NetworkManager.get_peer_handedness(peer_id),
			NetworkManager.get_peer_name(peer_id),
			NetworkManager.get_peer_number(peer_id),
			false)


func on_player_disconnected(peer_id: int) -> void:
	_spectator_peers.erase(peer_id)
	var record: PlayerRecord = _registry.get_record(peer_id) if _registry != null else null
	if record == null:
		return
	# Drop the puck before freeing the controller so puck_released fires while
	# the record is still intact.
	if NetworkManager.is_host and puck != null and puck.carrier == record.skater:
		puck.drop()
	_despawn_skater_for_peer(peer_id)


# Tears down host/client-side actor state for a peer whose skater is going
# away (disconnect or mid-game demote). Caller is responsible for any
# host-only side effects that happen *before* the skater is queue_freed
# (puck drop, pending-claim clear) — those need the live record.
func _despawn_skater_for_peer(peer_id: int) -> void:
	if _registry == null or not _registry.has(peer_id):
		return
	var record: PlayerRecord = _registry.get_record(peer_id)
	if puck != null and record.skater != null:
		puck.remove_skater_cooldown(record.skater)
	if _state_buffer_manager != null:
		_state_buffer_manager.remove_player(peer_id)
	_registry.remove(peer_id)


func sync_existing_players(player_data: Array) -> void:
	if _state_machine == null:
		# RPC arrived between scene-load and on_slot_assigned (which builds
		# _state_machine via _spawn_world). Stash; on_slot_assigned will flush
		# once the world is up. Without this the host record (only delivered
		# through this path) is silently dropped on clients.
		_pending_existing_players = player_data
		return
	for entry: Array in player_data:
		var peer_id: int = entry[0]
		var team_slot: int = entry[1]
		var team_id: int = entry[2]
		var jersey_color: Color = entry[3]
		var helmet_color: Color = entry[4]
		var pants_color: Color = entry[5]
		var is_left: bool = entry[6] if entry.size() > 6 else true
		var p_name: String = entry[7] if entry.size() > 7 else "Player"
		var p_number: int = entry[8] if entry.size() > 8 else 10
		var colors: Dictionary = TeamColorRegistry.get_colors(teams[team_id].color_id, team_id)
		_state_machine.register_remote_assigned_player(peer_id, team_slot, team_id)
		_registry.spawn(peer_id, team_slot, teams[team_id],
				jersey_color, helmet_color, pants_color,
				colors.jersey_stripe, colors.gloves, colors.pants_stripe, colors.socks, colors.socks_stripe,
				colors.secondary, colors.text, colors.text_outline,
				is_left, p_name, false, p_number)
	# Client / spectator: registry is now populated with all players the host
	# knew about at the moment we joined. Open the replay file so subsequent
	# world-state broadcasts get recorded. Idempotent — short-circuits if a
	# previous sync already opened it.
	_open_replay_file_writer()


func spawn_remote_skater(peer_id: int, team_slot: int, team_id: int,
		jersey_color: Color, helmet_color: Color, pants_color: Color,
		is_left_handed: bool, player_name: String, jersey_number: int = 10) -> void:
	if peer_id == NetworkManager.local_peer_id() or _state_machine == null:
		return
	var colors: Dictionary = TeamColorRegistry.get_colors(teams[team_id].color_id, team_id)
	_state_machine.register_remote_assigned_player(peer_id, team_slot, team_id)
	_registry.spawn(peer_id, team_slot, teams[team_id],
			jersey_color, helmet_color, pants_color,
			colors.jersey_stripe, colors.gloves, colors.pants_stripe, colors.socks, colors.socks_stripe,
			colors.secondary, colors.text, colors.text_outline,
			is_left_handed, player_name, false, jersey_number)


# ── World Spawn ───────────────────────────────────────────────────────────────
func _spawn_world() -> void:
	_state_machine = GameStateMachine.new()
	if not NetworkManager.pending_game_config.is_empty():
		var cfg: Dictionary = NetworkManager.pending_game_config
		_state_machine.apply_config(cfg.num_periods, cfg.period_duration, cfg.ot_enabled, cfg.ot_duration,
				cfg.get("rule_set", GameRules.DEFAULT_RULE_SET))
		var cfg_id: String = cfg.get("game_id", "")
		if cfg_id.is_empty() or _is_valid_game_id(cfg_id):
			_game_id = cfg_id
		else:
			push_warning("rejected game_id from config: %s" % cfg_id)
		NetworkManager.pending_game_config = {}
	# Offline / tutorial sessions intentionally leave _game_id empty — they
	# don't broadcast (no other peer would see the id) and downstream consumers
	# (ReplayFileWriter, CareerStatsReporter) treat empty as "don't record".
	_spawner = ActorSpawner.new()
	_spawner.setup(get_tree().current_scene)
	_create_teams()
	goals = _spawner.find_goals()
	_assign_goals_to_teams()
	_spawn_puck()
	_spawn_goalies()
	_wire_subsystems()
	if NetworkManager.is_host:
		var is_human_resolver := func(peer_id: int) -> bool:
			return NetworkManager.is_real_peer(peer_id)
		team_brains = [
				TeamBrain.new(0, _registry.team_id_by_peer, is_human_resolver),
				TeamBrain.new(1, _registry.team_id_by_peer, is_human_resolver),
		]
		_connect_goal_signals()


func _create_teams() -> void:
	var t0 := Team.new()
	t0.team_id = 0
	t0.color_id = NetworkManager.pending_home_color_id
	var t1 := Team.new()
	t1.team_id = 1
	t1.color_id = NetworkManager.pending_away_color_id
	teams = [t0, t1]


func _assign_goals_to_teams() -> void:
	for goal: HockeyGoal in goals:
		# facing=+1 → positive-Z end → Team 0 defends it
		# facing=-1 → negative-Z end → Team 1 defends it
		var defending_team_id: int = 0 if goal.facing == 1 else 1
		teams[defending_team_id].defended_goal = goal
		goal.defending_team_id = defending_team_id


func _connect_goal_signals() -> void:
	for team: Team in teams:
		team.defended_goal.goal_scored.connect(func() -> void: _phase_coord.on_goal_scored_into(team))


func _spawn_puck() -> void:
	var result: Dictionary = _spawner.spawn_puck_with_controller(NetworkManager.is_host)
	puck = result.puck
	puck_controller = result.controller
	puck.set_team_resolver(_resolve_skater_team_id)
	puck_controller.set_peer_id_resolver(_resolve_skater_peer_id)
	# team_id_by_skater dict is owned by PlayerRegistry, which doesn't
	# exist yet — wired in `_wire_subsystems` below.
	puck_controller.set_skater_getter(func() -> Array:
		if _registry == null:
			return []
		var skaters: Array = []
		for r: PlayerRecord in _registry.all().values():
			skaters.append(r.skater)
		return skaters)
	puck_controller.puck_picked_up_by.connect(_on_server_puck_picked_up_by)
	puck_controller.puck_released_by_carrier.connect(_on_server_puck_released_by_carrier)
	puck_controller.puck_stripped_from.connect(_on_server_puck_stripped_from)
	puck_controller.puck_touched_while_loose.connect(_on_server_puck_touched_while_loose)
	puck_controller.puck_touched_by_goalie.connect(_on_puck_touched_by_goalie)


func _spawn_goalies() -> void:
	var result: Dictionary = _spawner.spawn_goalie_pair(puck, NetworkManager.is_host)
	goalies = [result.top_goalie as Goalie, result.bottom_goalie as Goalie]
	goalie_controllers = [result.top_controller, result.bottom_controller]
	result.top_controller.team_id = 1
	result.bottom_controller.team_id = 0
	teams[1].goalie_controller = result.top_controller
	teams[0].goalie_controller = result.bottom_controller
	for team_id: int in [0, 1]:
		var goalie: Goalie = result.bottom_goalie if team_id == 0 else result.top_goalie
		var colors: Dictionary = TeamColorRegistry.get_colors(teams[team_id].color_id, team_id)
		goalie.set_goalie_color(colors.jersey, colors.helmet, colors.goalie_pads)


func _wire_subsystems() -> void:
	_registry = PlayerRegistry.new()
	_registry.setup(_spawner, _state_machine, teams,
			get_puck, self, _on_player_spawned)
	# Hand the puck controller a live reference to the registry's
	# Skater -> team_id dict so its poke-check loop can do O(1) lookups
	# instead of going through a Callable that re-scans `_players`.
	if puck_controller != null:
		puck_controller.set_team_id_by_skater(_registry.team_id_by_skater)
	_registry.player_joined.connect(player_joined.emit)
	_registry.player_left.connect(player_left.emit)
	_registry.player_added.connect(_on_registry_player_added)
	# Replay file roster events — fire whenever the registry changes after
	# the writer is open. The initial roster is captured in the file header
	# so these handlers no-op until _open_replay_file_writer has run, which
	# is only after the registry's initial population (host_started /
	# sync_existing_players) — no double-fire risk.
	_registry.player_added.connect(_on_replay_player_joined_event)
	_registry.player_removed.connect(_on_replay_player_left_event)

	_state_buffer_manager = StateBufferManager.new()
	_state_buffer_manager.setup(_registry, goalie_controllers)

	# Goal-replay cinematic: every peer has its own recorder ring-buffer and
	# driver so host and clients all see the same 8-second instant-replay.
	# Driver is a Node so GameManager owns add_child / queue_free; cinematic
	# logic (start/stop, signal wiring) lives in PhaseCoordinator.
	_recorder = ReplayRecorder.new()
	_recorder.setup()
	_goal_replay_driver = GoalReplayDriver.new()
	add_child(_goal_replay_driver)

	_codec = WorldStateCodec.new()
	_codec.setup(_registry, _state_machine,
			get_puck, _get_puck_controller, _get_goalie_controllers, _state_buffer_manager)
	_codec.phase_changed.connect(_on_remote_phase_changed)
	_codec.game_over_triggered.connect(game_over.emit)
	_codec.period_changed.connect(period_changed.emit)
	_codec.clock_updated.connect(_on_clock_updated_externally)
	_codec.shots_on_goal_changed.connect(shots_on_goal_changed.emit)
	_codec.queue_depth_feedback.connect(NetworkManager.on_queue_depth_received)

	_shot_tracker = ShotOnGoalTracker.new()
	_shot_tracker.setup(_registry, _state_machine)
	_shot_tracker.shots_on_goal_changed.connect(shots_on_goal_changed.emit)

	_hit_tracker = HitTracker.new()
	_hit_tracker.setup(_registry)
	_hit_tracker.hit_credited.connect(_sync_stats_to_clients)

	_pickup_claim = PickupClaimResolver.new()
	_pickup_claim.setup(_registry, _state_buffer_manager, get_puck, _get_puck_controller)

	_hit_claim = HitClaimResolver.new()
	_hit_claim.setup(_registry, _state_buffer_manager, _hit_tracker, get_puck, _get_puck_controller)

	_phase_coord = PhaseCoordinator.new()
	var force_record: Callable = Callable()
	if NetworkManager.is_host:
		force_record = func() -> void:
			var goal_frame: PackedByteArray = _codec.encode_world_state()
			if goal_frame.is_empty():
				return
			var ts: float = NetworkManager.local_time()
			_recorder.record_frame(goal_frame, ts)
			# Also enqueue to the .mreplay file so the puck-in-net moment
			# lands in the recording deterministically. Without this, the
			# next 5 Hz dead-puck broadcast (the only frame `_should_record_to_file`
			# admits while movement-locked) is what represents "goal" in the
			# file — up to 200 ms after the actual entry. Update
			# `_last_recorded_phase` so the natural broadcast pipeline doesn't
			# duplicate this frame on its next tick.
			if _replay_file_writer != null and _should_record_to_file():
				_replay_file_writer.enqueue_frame(ts, goal_frame)
				if _state_machine != null:
					_last_recorded_phase = _state_machine.current_phase
	_phase_coord.setup(_state_machine, _registry, teams,
			get_puck, _get_goalie_controllers, _shot_tracker, _drop_puck_if_carried,
			_recorder, _goal_replay_driver, _codec,
			get_tree(), NetworkManager.is_host, force_record)
	_phase_coord.goal_scored.connect(goal_scored.emit)
	_phase_coord.goal_scored.connect(_on_goal_for_replay_event)
	_phase_coord.score_changed.connect(score_changed.emit)
	_phase_coord.phase_changed.connect(phase_changed.emit)
	_phase_coord.replay_started.connect(replay_started.emit)
	_phase_coord.replay_stopped.connect(replay_stopped.emit)
	_phase_coord.period_changed.connect(period_changed.emit)
	_phase_coord.clock_updated.connect(_on_clock_updated_externally)
	_phase_coord.game_over.connect(game_over.emit)
	_phase_coord.stats_need_sync.connect(_sync_stats_to_clients)
	_phase_coord.faceoff_positions_ready.connect(NetworkManager.send_faceoff_positions)
	_phase_coord.goal_broadcast_needed.connect(NetworkManager.notify_goal_to_all)

	_swap_coord = SlotSwapCoordinator.new()
	_swap_coord.setup(_registry, _state_machine, teams)
	_swap_coord.stats_updated.connect(stats_updated.emit)
	_swap_coord.carrier_swap_needs_drop.connect(_drop_puck_if_carried)

	if NetworkManager.is_host:
		for gc: GoalieController in goalie_controllers:
			gc.state_transitioned.connect(NetworkManager.send_goalie_state_transition_to_all)
			gc.shot_reaction_started.connect(NetworkManager.send_goalie_shot_reaction_to_all)
			gc.reaction_cleared.connect(NetworkManager.send_goalie_reaction_cleared_to_all)
		_phase_coord.phase_changed.connect(_on_phase_for_broadcast_rate)

	_telemetry = NetworkTelemetry.new()
	NetworkTelemetry.instance = _telemetry
	_debug_overlay = NetworkDebugOverlay.new()
	add_child(_debug_overlay)

	var _home_c := TeamColorRegistry.get_colors(teams[0].color_id, 0)
	var _away_c := TeamColorRegistry.get_colors(teams[1].color_id, 1)
	team_colors_ready.emit(_home_c.primary, _home_c.secondary, _away_c.primary, _away_c.secondary)

	_wire_sound_signals()


func _wire_sound_signals() -> void:
	# Per-game connections: puck / puck_controller / _phase_coord are recreated
	# each match by _spawn_world, so these always get freshly wired here.
	_phase_coord.goal_scored.connect(
		func(_t: Team, _s: String, _a1: String, _a2: String) -> void:
			SoundManager.play_sfx(SoundManager.Sound.GOAL_HORN, -6.0))
	if NetworkManager.is_host:
		puck.puck_hit_boards.connect(func() -> void:
			var spd: float = puck.linear_velocity.length()
			SoundManager.play_world(SoundManager.Sound.PUCK_BOARDS, puck.get_puck_position(), _puck_speed_volume(spd), 0.05)
			NetworkManager.send_board_hit_to_all(puck.get_puck_position())
			_record_replay_audio_event("puck_boards", puck.get_puck_position(), spd))
		puck.puck_hit_goal_body.connect(func() -> void:
			var spd: float = puck.linear_velocity.length()
			SoundManager.play_world(SoundManager.Sound.PUCK_GOAL_BODY, puck.get_puck_position(), _puck_speed_volume(spd), 0.06)
			NetworkManager.send_goal_body_hit_to_all(puck.get_puck_position())
			_record_replay_audio_event("puck_goal_body", puck.get_puck_position(), spd))
		puck.puck_touched_loose.connect(func(_s: Skater) -> void:
			var spd: float = puck.linear_velocity.length()
			SoundManager.play_world(SoundManager.Sound.PUCK_DEFLECTION, puck.get_puck_position(), _puck_speed_volume(spd), 0.06)
			NetworkManager.send_deflection_to_all(puck.get_puck_position())
			_record_replay_audio_event("puck_deflection", puck.get_puck_position(), spd))
		puck.puck_body_blocked.connect(func(_s: Skater) -> void:
			var spd: float = puck.linear_velocity.length()
			SoundManager.play_world(SoundManager.Sound.PUCK_BODY_BLOCK, puck.get_puck_position(), _puck_speed_volume(spd), 0.07)
			NetworkManager.send_body_block_to_all(puck.get_puck_position())
			_record_replay_audio_event("puck_body_block", puck.get_puck_position(), spd))
		puck_controller.puck_stripped_from.connect(func(_pid: int) -> void:
			var spd: float = puck.linear_velocity.length()
			SoundManager.play_world(SoundManager.Sound.PUCK_STRIP, puck.get_puck_position(), _puck_speed_volume(spd), 0.06)
			NetworkManager.send_puck_strip_to_all(puck.get_puck_position())
			_record_replay_audio_event("puck_strip", puck.get_puck_position(), spd))
	puck.puck_touched_goalie.connect(
		func(_g: Goalie) -> void:
			var spd: float = puck.linear_velocity.length()
			SoundManager.play_world(SoundManager.Sound.PUCK_GOALIE, puck.get_puck_position(), _puck_speed_volume(spd), 0.05)
			if NetworkManager.is_host:
				_record_replay_audio_event("puck_goalie", puck.get_puck_position(), spd))
	puck.puck_touched_post.connect(
		func() -> void:
			var spd: float = puck.linear_velocity.length()
			SoundManager.play_world(SoundManager.Sound.PUCK_POST, puck.get_puck_position(), _puck_speed_volume(spd), 0.04)
			if NetworkManager.is_host:
				_record_replay_audio_event("puck_post", puck.get_puck_position(), spd))

	# Persistent connections: NetworkManager autoload + GameManager self-signals
	# survive across rematches; wire once.
	if _persistent_sound_signals_wired:
		return
	_persistent_sound_signals_wired = true
	NetworkManager.local_puck_pickup_confirmed.connect(_on_local_pickup_sound)
	NetworkManager.remote_carrier_changed.connect(_on_remote_carrier_sound)
	NetworkManager.goal_received.connect(
		func(_tid: int, _s0: int, _s1: int, _sn: String, _a1: String, _a2: String) -> void:
			SoundManager.play_sfx(SoundManager.Sound.GOAL_HORN, -6.0))
	NetworkManager.board_hit_received.connect(
		func(pos: Vector3) -> void: SoundManager.play_world(SoundManager.Sound.PUCK_BOARDS, pos, _puck_speed_volume(puck.linear_velocity.length() if puck != null else 0.0), 0.05))
	NetworkManager.goal_body_hit_received.connect(
		func(pos: Vector3) -> void: SoundManager.play_world(SoundManager.Sound.PUCK_GOAL_BODY, pos, _puck_speed_volume(puck.linear_velocity.length() if puck != null else 0.0), 0.06))
	NetworkManager.deflection_received.connect(
		func(pos: Vector3) -> void: SoundManager.play_world(SoundManager.Sound.PUCK_DEFLECTION, pos, _puck_speed_volume(puck.linear_velocity.length() if puck != null else 0.0), 0.06))
	NetworkManager.body_block_received.connect(
		func(pos: Vector3) -> void: SoundManager.play_world(SoundManager.Sound.PUCK_BODY_BLOCK, pos, _puck_speed_volume(puck.linear_velocity.length() if puck != null else 0.0), 0.07))
	NetworkManager.puck_strip_received.connect(
		func(pos: Vector3) -> void: SoundManager.play_world(SoundManager.Sound.PUCK_STRIP, pos, _puck_speed_volume(puck.linear_velocity.length() if puck != null else 0.0), 0.06))
	period_changed.connect(func(_p: int) -> void: SoundManager.play_sfx(SoundManager.Sound.PERIOD_BUZZER))
	game_over.connect(func() -> void: SoundManager.play_sfx(SoundManager.Sound.PERIOD_BUZZER))


func _on_local_pickup_sound() -> void:
	var record := _registry.get_local() if _registry != null else null
	if record != null and record.skater != null:
		SoundManager.play_world(SoundManager.Sound.PUCK_PICKUP, record.skater.global_position, 0.0, 0.05)
		if NetworkManager.is_host:
			_record_replay_audio_event("puck_pickup", record.skater.global_position, 0.0)


func _on_remote_carrier_sound(new_carrier_peer_id: int) -> void:
	if _registry == null:
		return
	var record: PlayerRecord = _registry.get_record(new_carrier_peer_id)
	if record != null and record.skater != null:
		SoundManager.play_world(SoundManager.Sound.PUCK_PICKUP, record.skater.global_position, 0.0, 0.05)
		if NetworkManager.is_host:
			_record_replay_audio_event("puck_pickup", record.skater.global_position, 0.0)


# Host-only: shadow a transient audio/VFX event into the in-memory recorder
# AND the .mreplay file writer so both replay paths (post-goal cinematic +
# offline file viewer) can re-fire the sound/VFX at the right virtual time.
# Audio-only events use kind ∈ { puck_boards, puck_goal_body, puck_deflection,
# puck_body_block, puck_strip, puck_goalie, puck_post, puck_pickup, shot };
# body_check carries extra payload via _record_body_check_replay_event.
func _record_replay_audio_event(kind: String, position: Vector3, speed: float,
		extra: Dictionary = {}) -> void:
	if not NetworkManager.is_host:
		return
	# Don't shadow live events into the replay buffer while a replay is
	# actively playing — the cinematic is the consumer, not the producer.
	# Same gate for GOAL_CELEBRATION: those events belong to live gameplay,
	# not the clip (which ends at the goal-moment frame).
	if NetworkManager.is_replay_mode() or _is_celebration_phase():
		return
	var ts: float = NetworkManager.local_time()
	var event: Dictionary = {
		"kind": kind,
		"pos": [position.x, position.y, position.z],
		"speed": speed,
	}
	for k: Variant in extra:
		event[k] = extra[k]
	if _recorder != null:
		_recorder.record_event(ts, event)
	if _replay_file_writer != null and _should_record_to_file():
		_replay_file_writer.enqueue_event(ts, JSON.stringify(event).to_utf8_buffer())
	# Mirror the event onto every client / spectator so their recorders see
	# the same timeline. Required for the goal-replay cinematic to use the
	# same shot anchor + adaptive clip start everywhere.
	NetworkManager.notify_replay_event_to_all(ts, event)


# Client / spectator side: host broadcast each event it recorded; we mirror
# it into our local recorder so our goal-replay clip carries the same
# timeline (shot anchor, pickup chain, audio cues). Same gates the host
# applies to its own recording — skip while a cinematic is already playing.
func _on_replay_event_received(host_ts: float, event: Dictionary) -> void:
	if _recorder == null:
		return
	if NetworkManager.is_replay_mode() or _is_celebration_phase():
		return
	_recorder.record_event(host_ts, event)


# Recorder-recording gate. During GOAL_CELEBRATION we skip writing to the
# recorder (both frames and events) so the clip ends cleanly at the puck-
# in-net moment captured via PhaseCoordinator._capture_goal_moment_frame.
# The celebration itself is live gameplay; its frames don't belong in the
# replay clip.
func _is_celebration_phase() -> bool:
	return is_in_goal_celebration()


# Public phase query for controllers (the AIController uses this to drop
# bot input during the celebration beat — bots coast on residual velocity
# instead of trying to play during a stopped puck). Same value as the
# internal _is_celebration_phase recorder gate.
func is_in_goal_celebration() -> bool:
	return _state_machine != null \
			and _state_machine.current_phase == GamePhase.Phase.GOAL_CELEBRATION


func _record_body_check_replay_event(checker_peer_id: int, victim: Skater,
		force: float, hit_dir: Vector3) -> void:
	var victim_peer_id: int = _registry.resolve_peer_id(victim) if _registry != null and victim != null else -1
	var checker_pos: Vector3 = Vector3.ZERO
	if _registry != null:
		var rec: PlayerRecord = _registry.get_record(checker_peer_id)
		if rec != null and rec.skater != null:
			checker_pos = rec.skater.global_position
	_record_replay_audio_event("body_check", checker_pos, force, {
		"checker_peer_id": checker_peer_id,
		"victim_peer_id": victim_peer_id,
		"hit_dir": [hit_dir.x, hit_dir.y, hit_dir.z],
	})


# Local peer is a spectator. Set the flag so HUD chrome can hide local-only
# elements, and mount a SpectatorCamera tracking the puck. No skater is
# created — the spectator renders the active 6 via the existing remote-controller
# path that all clients already use.
func _become_local_spectator() -> void:
	_is_local_spectator = true
	if _spectator_camera == null:
		_spectator_camera = SpectatorCamera.new()
		get_tree().current_scene.add_child(_spectator_camera)
		_spectator_camera.setup(func() -> Vector3:
			return puck.global_position if puck != null else Vector3.ZERO)
		_spectator_camera.activate()
	local_spectator_state_changed.emit(true)


func is_local_spectator() -> bool:
	return _is_local_spectator


func get_game_id() -> String:
	return _game_id


# Host-only accurate. Clients only know their own spectator status (via
# is_local_spectator), so callers iterating peer IDs should be host-gated.
func is_spectator_peer(peer_id: int) -> bool:
	return _spectator_peers.has(peer_id)


func spectator_peer_count() -> int:
	return _spectator_peers.size()


# ── Mid-game spectator ↔ player swap ─────────────────────────────────────────
# Both directions branch out of `_on_slot_swap_requested` (host-only). The
# demote path despawns the skater everywhere via `notify_spectator_demoted`;
# the promote path spawns a fresh skater everywhere by reusing the
# spawn_remote_skater + assign_player_slot RPCs that mid-game joins use.

func _demote_player_to_spectator(peer_id: int) -> void:
	if _registry == null or not _registry.has(peer_id):
		return
	var record: PlayerRecord = _registry.get_record(peer_id)
	# Drop the puck before broadcasting so the carrier change goes out while
	# the controller still exists (mirrors on_player_disconnected). The
	# pending pickup claim self-cleans at apply time via registry lookup,
	# so no extra mirror-clear is needed here.
	if puck != null and puck.carrier == record.skater:
		puck.drop()
	NetworkManager.send_spectator_demoted_to_all(peer_id)


# Runs on every peer (host + clients) when a demotion is broadcast. Despawns
# the demoted peer's skater locally; the demoted peer additionally tears down
# its LocalController and mounts SpectatorCamera.
func _on_spectator_demoted_received(peer_id: int) -> void:
	var is_local_demote: bool = peer_id == NetworkManager.local_peer_id()
	if is_local_demote:
		# Stop input batches before the controller is queue_freed — the Callable
		# would otherwise reference a dead object.
		NetworkManager.set_input_batch_provider(Callable())
	_despawn_skater_for_peer(peer_id)
	_spectator_peers[peer_id] = true
	if is_local_demote:
		_become_local_spectator()


# Host-only. Spawns a skater for a peer that's currently a spectator and tells
# every peer to do the same (clients via spawn_remote_skater, the promoted peer
# via assign_player_slot). Validation is inline because `try_swap_slot` only
# operates on peers already in `_state_machine.players`.
func _promote_spectator_to_player(peer_id: int, new_team_id: int, new_slot: int) -> void:
	if _state_machine == null or _registry == null:
		return
	if new_team_id < 0 or new_team_id > 1:
		return
	if new_slot < 0 or new_slot >= PlayerRules.MAX_PER_TEAM:
		return
	for other_id: int in _state_machine.players:
		var p: Dictionary = _state_machine.players[other_id]
		if p.team_id == new_team_id and p.team_slot == new_slot:
			return
	if _state_machine.count_players_on_team(new_team_id) >= PlayerRules.MAX_PER_TEAM:
		return
	_spectator_peers.erase(peer_id)
	var is_local: bool = peer_id == NetworkManager.local_peer_id()
	if is_local and _is_local_spectator:
		# Host promoting itself: tear down the spectator camera before the
		# LocalController spawns its own camera.
		_teardown_spectator_camera()
	_spawn_player_and_broadcast(peer_id, new_team_id, new_slot,
			NetworkManager.get_peer_handedness(peer_id),
			NetworkManager.get_peer_name(peer_id),
			NetworkManager.get_peer_number(peer_id),
			is_local)


func _teardown_spectator_camera() -> void:
	if _spectator_camera != null:
		_spectator_camera.deactivate()
		_spectator_camera.queue_free()
		_spectator_camera = null
	if _is_local_spectator:
		_is_local_spectator = false
		local_spectator_state_changed.emit(false)


# ── Goal-replay vote-to-skip ──────────────────────────────────────────────────
# Rocket-League-style unanimous skip. On the local skip_replay press, route the
# vote to the host (or register it locally if we are the host / offline). The
# host counts, broadcasts the tally, and the driver auto-stops on unanimity —
# clients mirror by stopping their own driver when they receive (N, N). In
# offline / free-play the local player is the only voter, so a single press
# instantly resolves to (1, 1) → stop.

func _on_local_replay_started() -> void:
	_in_replay_locally = true
	# Reset HUD prompt immediately. On the host this is also the first
	# authoritative broadcast of the voter total so clients see (0/N) right
	# when their own driver starts.
	if NetworkManager.is_host:
		var total: int = _total_skip_voters()
		NetworkManager.notify_skip_replay_vote_to_all(0, total)
		skip_replay_vote_updated.emit(0, total)


func _on_local_replay_stopped() -> void:
	_in_replay_locally = false


func is_in_replay_locally() -> bool:
	return _in_replay_locally


# HUD entry point. Called from _unhandled_input when the player presses
# skip_replay during the cinematic.
func request_local_skip_vote() -> void:
	if not _in_replay_locally:
		return
	if NetworkManager.is_host:
		_register_skip_vote(NetworkManager.local_peer_id())
	else:
		NetworkManager.send_skip_replay_request()


func _on_remote_skip_replay_request(peer_id: int) -> void:
	_register_skip_vote(peer_id)


# Host-only: hands the vote to the driver, broadcasts the new tally so
# clients can update their prompt and (on unanimity) tear down their own
# driver. Bots aren't in connected_peer_ids() so they never count toward the
# total; spectators do (they have an ENet connection).
func _register_skip_vote(peer_id: int) -> void:
	if not NetworkManager.is_host:
		return
	# Late votes (driver stopped naturally before the RPC landed) are dropped
	# silently — broadcasting (0, total) here would reset client HUDs that
	# are already transitioning to FACEOFF.
	if _goal_replay_driver == null or not _goal_replay_driver.is_active():
		return
	var total: int = _total_skip_voters()
	_goal_replay_driver.register_skip_vote(peer_id, total)
	var current: int = _goal_replay_driver.get_skip_vote_count()
	NetworkManager.notify_skip_replay_vote_to_all(current, total)
	skip_replay_vote_updated.emit(current, total)


# Client-side handler for the host's tally broadcast. Forwards to HUD via the
# local signal; on unanimity, also stops the local driver so every peer leaves
# the cinematic at the same wall-clock moment.
func _on_remote_skip_replay_vote(current: int, total: int) -> void:
	if NetworkManager.is_host:
		return  # host emits locally in _register_skip_vote
	skip_replay_vote_updated.emit(current, total)
	if total > 0 and current >= total and _goal_replay_driver != null:
		_goal_replay_driver.stop()


func _total_skip_voters() -> int:
	return 1 + NetworkManager.connected_peer_ids().size()


# ── Replay file recording ────────────────────────────────────────────────────
# Opened once per game on every peer, after the registry has been populated
# from lobby assignments / sync_existing_players. Idempotent — safe to call
# repeatedly from both the host and client setup paths; the second call
# short-circuits.
func _open_replay_file_writer() -> void:
	if _replay_file_writer != null:
		return
	if _game_id.is_empty():
		return  # offline / tutorial — see _spawn_world
	if not PlayerPrefs.replay_recording_enabled:
		return
	# Purge oldest first so the new file is never the one we delete next game.
	# keep_count - 1 because we're about to add a new file.
	ReplayFileIndex.purge_oldest(ReplayFileIndex.REPLAY_DIR,
			maxi(PlayerPrefs.replay_keep_count - 1, 0))
	var path: String = ReplayFileIndex.REPLAY_DIR.path_join(_game_id + ReplayFileIndex.REPLAY_EXT)
	var writer := ReplayFileWriter.new()
	if not writer.open(path, _build_replay_header()):
		return
	_replay_file_writer = writer


func _close_replay_file_writer() -> void:
	if _replay_file_writer == null:
		return
	_replay_file_writer.close_async(_build_replay_footer())
	_replay_file_writer = null


# Rematch path: close the current .mreplay (writes its footer with the
# previous game's final scores) and open a new one against new_game_id so
# the rematch lands in a separate file. Empty new_game_id (offline /
# tutorial / recording disabled) is a no-op — there's no writer to roll.
# Note: between the host's notify_reset_to_all and the client receiving
# it, a couple of post-reset world-state frames may land in the OLD file
# instead of the new one. They're recorded with reset state (0-0, period
# 1) and show up as a brief "score-reset glitch" at the very end of the
# old file's playback. Acceptable for v1; the alternative is throttling
# host broadcasts during rollover, which adds complexity for marginal
# benefit.
func _rollover_replay_file_to(new_game_id: String) -> void:
	if new_game_id.is_empty():
		return
	if not _is_valid_game_id(new_game_id):
		push_warning("rejected new_game_id: %s" % new_game_id)
		return
	_close_replay_file_writer()
	_last_recorded_phase = -1
	_game_id = new_game_id
	_open_replay_file_writer()


# Game IDs are UUIDs minted by PlayerPrefs.generate_uuid (hex + dashes). This
# guard runs on the path concatenation surface so a malicious host can't ship
# `../etc/passwd` via notify_game_reset and have a client write outside the
# replays folder. Belt-and-braces: the only legitimate source is already
# UUIDs, but the wire format permits arbitrary strings.
const _MAX_GAME_ID_LEN: int = 64
static func _is_valid_game_id(s: String) -> bool:
	if s.is_empty() or s.length() > _MAX_GAME_ID_LEN:
		return false
	for i: int in s.length():
		var c: String = s.substr(i, 1)
		if not (c >= "a" and c <= "z") \
				and not (c >= "A" and c <= "Z") \
				and not (c >= "0" and c <= "9") \
				and c != "-" and c != "_":
			return false
	return true


# Roster captured at game-start; mid-game joiners aren't in here but the viewer
# can still observe them appearing in later world-state packets.
func _build_replay_header() -> Dictionary:
	var roster: Array[Dictionary] = []
	if _registry != null:
		for peer_id: int in _registry.all():
			var r: PlayerRecord = _registry.get_record(peer_id)
			roster.append({
				"peer_id": peer_id,
				"player_name": r.player_name,
				"jersey_number": r.jersey_number,
				"team_id": r.team.team_id if r.team != null else 0,
				"team_slot": r.team_slot,
				"is_left_handed": r.is_left_handed,
				"is_local": peer_id == NetworkManager.local_peer_id(),
			})
	return {
		"game_id": _game_id,
		"started_at": Time.get_unix_time_from_system(),
		"build_version": BuildInfo.VERSION,
		"num_periods": _state_machine.num_periods if _state_machine != null else GameRules.NUM_PERIODS,
		"period_duration": _state_machine.period_duration if _state_machine != null else GameRules.PERIOD_DURATION,
		"ot_enabled": _state_machine.ot_enabled if _state_machine != null else GameRules.OT_ENABLED,
		"rule_set": _state_machine.rule_set if _state_machine != null else GameRules.DEFAULT_RULE_SET,
		"home_color_id": NetworkManager.pending_home_color_id,
		"away_color_id": NetworkManager.pending_away_color_id,
		"recorded_by_peer_id": NetworkManager.local_peer_id(),
		"roster": roster,
	}


func _build_replay_footer() -> Dictionary:
	var footer: Dictionary = {}
	if _state_machine != null:
		footer["final_score_home"] = _state_machine.scores[0]
		footer["final_score_away"] = _state_machine.scores[1]
	footer["ended_at"] = Time.get_unix_time_from_system()
	return footer


# Goals don't appear in the world-state packet (they're broadcast via the
# notify_goal RPC on a separate channel), so the viewer has no way to render
# the goal banner / jump-to-goal buttons unless we capture them as events
# alongside the frame stream. Fires on every peer when phase_coord re-emits
# goal_scored locally — host detects + emits, clients receive notify_goal +
# emit. JSON payload because goals are infrequent (~10/game) and the field
# set is small enough that the byte overhead doesn't matter.
func _on_goal_for_replay_event(scoring_team: Team, scorer: String,
		assist1: String, assist2: String) -> void:
	if _replay_file_writer == null or _state_machine == null:
		return
	var ts: float = NetworkManager.local_time() if NetworkManager.is_host \
			else NetworkManager.estimated_host_time()
	var payload: PackedByteArray = JSON.stringify({
		"kind": "goal",
		"scoring_team_id": scoring_team.team_id,
		"score0": _state_machine.scores[0],
		"score1": _state_machine.scores[1],
		"period": _state_machine.current_period,
		"scorer": scorer,
		"assist1": assist1,
		"assist2": assist2,
	}).to_utf8_buffer()
	_replay_file_writer.enqueue_event(ts, payload)


# Roster events for the .mreplay viewer. Header captures the initial roster;
# these fire only for mid-game changes (joins, demotes, promotes,
# disconnects) so the viewer can spawn / despawn actors instead of leaving
# them stuck or invisible. _replay_file_writer is null during the initial
# registry-population pass (writer opens AFTER registry stabilizes), so the
# `if _replay_file_writer == null: return` guard naturally suppresses the
# initial spawns.
func _on_replay_player_joined_event(record: PlayerRecord) -> void:
	if _replay_file_writer == null:
		return
	var ts: float = NetworkManager.local_time() if NetworkManager.is_host \
			else NetworkManager.estimated_host_time()
	var payload: PackedByteArray = JSON.stringify({
		"kind": "player_joined",
		"peer_id": record.peer_id,
		"player_name": record.player_name,
		"jersey_number": record.jersey_number,
		"team_id": record.team.team_id if record.team != null else 0,
		"team_slot": record.team_slot,
		"is_left_handed": record.is_left_handed,
	}).to_utf8_buffer()
	_replay_file_writer.enqueue_event(ts, payload)


func _on_replay_player_left_event(record: PlayerRecord) -> void:
	if _replay_file_writer == null:
		return
	var ts: float = NetworkManager.local_time() if NetworkManager.is_host \
			else NetworkManager.estimated_host_time()
	var payload: PackedByteArray = JSON.stringify({
		"kind": "player_left",
		"peer_id": record.peer_id,
	}).to_utf8_buffer()
	_replay_file_writer.enqueue_event(ts, payload)


# Common path shared by every host-side player-spawn site:
#   - register the slot in the state machine
#   - send_slot_assignment to the joining peer (skipped if the peer is the
#     local host, who already has its slot)
#   - broadcast spawn_remote_skater to all peers (handler short-circuits
#     for the local peer)
#   - _registry.spawn locally
#
# Returns the resolved colors dict so callers can reuse it for adjacent
# bookkeeping (e.g. _push_lobby_assignments_to_clients's `existing` array).
# Adjacent RPCs that vary by call site (send_join_in_progress,
# send_sync_existing_players, spectator-camera teardown) stay inline at
# the caller — this helper owns only the shared shape.
func _spawn_player_and_broadcast(peer_id: int, team_id: int, team_slot: int,
		is_left: bool, p_name: String, p_number: int, is_local: bool) -> Dictionary:
	var team: Team = teams[team_id]
	var colors: Dictionary = TeamColorRegistry.get_colors(team.color_id, team_id)
	_state_machine.register_remote_assigned_player(peer_id, team_slot, team_id)
	if not is_local:
		NetworkManager.send_slot_assignment(peer_id, team_slot, team_id,
				colors.jersey, colors.helmet, colors.pants)
	NetworkManager.send_spawn_remote_skater(peer_id, team_slot, team_id,
			colors.jersey, colors.helmet, colors.pants, is_left, p_name, p_number)
	_registry.spawn(peer_id, team_slot, team,
			colors.jersey, colors.helmet, colors.pants,
			colors.jersey_stripe, colors.gloves, colors.pants_stripe,
			colors.socks, colors.socks_stripe,
			colors.secondary, colors.text, colors.text_outline,
			is_left, p_name, is_local, p_number)
	return colors


func _spawn_local(peer_id: int, team_slot: int, team: Team) -> void:
	var colors: Dictionary = TeamColorRegistry.get_colors(team.color_id, team.team_id)
	_registry.spawn(peer_id, team_slot, team,
			colors.jersey, colors.helmet, colors.pants,
			colors.jersey_stripe, colors.gloves, colors.pants_stripe, colors.socks, colors.socks_stripe,
			colors.secondary, colors.text, colors.text_outline,
			NetworkManager.local_is_left_handed, NetworkManager.local_player_name, true,
			NetworkManager.local_jersey_number)


# ── Spawn wire-up (callback invoked by PlayerRegistry after spawn) ───────────
func _on_player_spawned(record: PlayerRecord) -> void:
	if record.is_local:
		var local_ctrl: LocalController = record.controller as LocalController
		local_ctrl.set_goal_context(
				teams[0].defended_goal, teams[1].defended_goal, _get_puck_carrier_team_id)
		local_ctrl.puck_release_requested.connect(_on_puck_release_requested)
		local_ctrl.hit_received.connect(func(mag: float) -> void: local_player_hit.emit(mag))
		NetworkManager.set_input_batch_provider(local_ctrl.get_input_batch)
	# AI bots release shots through the same signal as humans, but they live
	# only on the host (record.is_local is false). Without this connection
	# the wrister state machine transitions to FOLLOW_THROUGH but the puck
	# never leaves the blade — _do_release emits puck_release_requested
	# into the void.
	if record.is_bot:
		record.controller.puck_release_requested.connect(_on_puck_release_requested)
	record.controller.one_timer_release_requested.connect(
			_on_one_timer_release_requested.bind(record.skater))
	var pid: int = record.peer_id
	record.skater.body_checked_player.connect(
		func(v: Skater, f: float, _d: Vector3) -> void: _on_hit_landed(pid, v, f)
	)
	record.skater.body_checked_player.connect(
		func(_v: Skater, _f: float, _d: Vector3) -> void:
			SoundManager.play_world(SoundManager.Sound.BODY_CHECK, record.skater.global_position, 0.0, 0.08)
	)
	if NetworkManager.is_host:
		record.skater.body_checked_player.connect(
			func(v: Skater, f: float, d: Vector3) -> void:
				_record_body_check_replay_event(record.peer_id, v, f, d)
		)
	var snd := SkaterSoundController.new()
	record.skater.add_child(snd)
	snd.setup(record.skater)


func _on_registry_player_added(record: PlayerRecord) -> void:
	stats_updated.emit()
	if NetworkManager.is_host:
		_sync_stats_to_clients()
	if _state_buffer_manager != null:
		_state_buffer_manager.add_player(record.peer_id)


# ── Puck / Puck controller signal handlers ───────────────────────────────────
func _resolve_skater_team_id(skater: Skater) -> int:
	return _registry.resolve_team_id(skater) if _registry != null else -1


func _get_puck_carrier_team_id() -> int:
	if puck_controller != null:
		var local_carrier: Skater = puck_controller.get_local_carrier()
		if local_carrier != null:
			return _resolve_skater_team_id(local_carrier)
	if puck != null:
		var carrier: Skater = puck.get_carrier()
		if carrier != null:
			return _resolve_skater_team_id(carrier)
	return -1


func _resolve_skater_peer_id(skater: Skater) -> int:
	return _registry.resolve_peer_id(skater) if _registry != null else -1


func _on_server_puck_picked_up_by(peer_id: int) -> void:
	_pickup_claim.clear()
	var record: PlayerRecord = _registry.get_record(peer_id)
	if record == null:
		return
	_shot_tracker.on_pickup(peer_id)
	_phase_coord.on_pickup(peer_id)
	record.controller.on_puck_picked_up_network()
	if not record.is_local:
		NetworkManager.send_puck_picked_up(peer_id)
	NetworkManager.send_carrier_changed_to_all(peer_id)
	# Carrier just changed — force both team brains to recompute
	# possession state + role assignments on the next physics frame
	# instead of waiting up to TeamBrain.TICK_PERIOD (~166 ms). The
	# natural cadence is fine for steady-state, but a pickup flips
	# both teams' possession state and the previous-carrier-team's
	# CARRIER slot is now stale.
	_force_retick_team_brains()


func _on_ghost_state_received(peer_id: int, is_ghost: bool) -> void:
	if _registry == null:
		return
	var record: PlayerRecord = _registry.get_record(peer_id)
	if record == null or record.skater == null or record.is_local:
		return
	(record.controller as RemoteController).apply_ghost_rpc(is_ghost)


func _on_pickup_claim_received(peer_id: int, host_timestamp: float, rtt_ms: float, interp_delay_ms: float) -> void:
	if not NetworkManager.is_host:
		return
	_pickup_claim.receive_claim(peer_id, host_timestamp, rtt_ms, interp_delay_ms)


func _on_server_puck_released_by_carrier(peer_id: int) -> void:
	var record: PlayerRecord = _registry.get_record(peer_id)
	if record == null:
		return
	record.controller.on_puck_released_network()
	NetworkManager.send_carrier_changed_to_all(-1)
	# Carrier released — possession state likely flips (TRANS_DO →
	# NEUTRAL or TRANS_DO → TRANS_OD on a steal). See pickup hook
	# for rationale.
	_force_retick_team_brains()


# Forces both team brains to re-evaluate possession state + role
# assignments on the next physics frame, bypassing the natural
# TeamBrain.TICK_PERIOD rate-limit. Called from the puck pickup /
# release hooks where the carrier change makes the current role
# assignment immediately stale. Both teams re-tick because a carrier
# change affects both possession states symmetrically.
func _force_retick_team_brains() -> void:
	for brain: TeamBrain in team_brains:
		brain.force_retick()


func _on_server_puck_stripped_from(peer_id: int) -> void:
	var record: PlayerRecord = _registry.get_record(peer_id)
	if record == null:
		return
	_state_machine.notify_icing_contact()
	if not record.is_local:
		NetworkManager.send_puck_stolen(peer_id)


func _on_server_puck_touched_while_loose(peer_id: int) -> void:
	_state_machine.notify_icing_contact()
	if _shot_tracker.on_block(peer_id):
		_sync_stats_to_clients()
		return
	_shot_tracker.on_deflection(peer_id)


func _on_goalie_state_transition_received(team_id: int, new_state: int) -> void:
	for gc: GoalieController in goalie_controllers:
		if gc.team_id == team_id:
			gc.apply_state_transition(new_state)
			return


func _on_goalie_shot_reaction_received(team_id: int, impact_x: float, impact_y: float, is_elevated: bool) -> void:
	for gc: GoalieController in goalie_controllers:
		if gc.team_id == team_id:
			gc.apply_shot_reaction(impact_x, impact_y, is_elevated)
			return


func _on_goalie_reaction_cleared_received(team_id: int) -> void:
	for gc: GoalieController in goalie_controllers:
		if gc.team_id == team_id:
			gc.apply_reaction_cleared()
			return


func _on_puck_touched_by_goalie(goalie: Goalie) -> void:
	if not NetworkManager.is_host:
		return
	var defending_team_id: int = _defending_team_id_for_goalie(goalie)
	_shot_tracker.on_goalie_touch(defending_team_id)
	_sync_stats_to_clients()


func _defending_team_id_for_goalie(goalie: Goalie) -> int:
	for team: Team in teams:
		if team.goalie_controller != null and team.goalie_controller.goalie == goalie:
			return team.team_id
	return -1


# ── Puck release / one-timer ─────────────────────────────────────────────────
func _on_puck_release_requested(direction: Vector3, power: float, is_slapper: bool) -> void:
	var sound: SoundManager.Sound = SoundManager.Sound.SHOT_SLAPPER if is_slapper else SoundManager.Sound.SHOT_WRISTER
	SoundManager.play_world(sound, puck.get_puck_position(), 0.0, 0.04)
	if NetworkManager.is_host:
		_record_replay_audio_event("shot", puck.get_puck_position(), power, {"is_slapper": is_slapper})
	if NetworkManager.is_host:
		_start_pending_shot_from_carrier()
		puck.release(direction, power)
	else:
		var record := _registry.get_local()
		if record != null:
			record.controller.on_puck_released_network()
		var shot_rtt_ms: float = NetworkManager.get_latest_rtt_ms()
		puck_controller.notify_local_release(direction, power, shot_rtt_ms, record.skater.velocity)
		NetworkManager.send_puck_release(direction, power, is_slapper)


func _on_one_timer_release_requested(direction: Vector3, power: float, skater: Skater) -> void:
	if not NetworkManager.is_host:
		# Client path: seed local puck prediction, then tell the host.
		if puck_controller != null:
			var record := _registry.get_local()
			if record != null:
				var rtt_ms: float = NetworkManager.get_latest_rtt_ms()
				puck_controller.notify_local_release(direction, power, rtt_ms, record.skater.velocity)
		NetworkManager.send_one_timer_release(direction, power)
		return
	_host_release_one_timer(direction, power, skater, 0.0, 0.0)


func on_remote_one_timer_release(direction: Vector3, power: float, peer_id: int,
		host_timestamp: float, rtt_ms: float) -> void:
	if not NetworkManager.is_host or puck == null or _registry == null:
		return
	var record: PlayerRecord = _registry.get_record(peer_id)
	if record == null or record.skater == null:
		return
	_host_release_one_timer(direction, power, record.skater, host_timestamp, rtt_ms)


func _host_release_one_timer(direction: Vector3, power: float, skater: Skater,
		host_timestamp: float, rtt_ms: float) -> void:
	var pid: int = _registry.resolve_peer_id(skater)
	# One-timers skip the normal pickup flow, so the shooter is never recorded
	# in the carrier history. Record them as a deflection (the shooter redirects
	# a moving puck without possessing it) so goal attribution and assist credit
	# work — without this, get_last_toucher() returns the passer at goal time.
	_shot_tracker.on_deflection(pid)
	_shot_tracker.on_shot_started(pid)
	var rtt_half: float = rtt_ms / 2000.0
	var saved_goalie_positions: Array[Vector3] = []
	var saved_goalie_rotations: Array[float] = []
	if _state_buffer_manager != null and _state_buffer_manager.is_ready() and rtt_ms > 0.0:
		var rewind_time: float = host_timestamp - rtt_half
		var snap: WorldSnapshot = _state_buffer_manager.get_state_at(rewind_time)
		for gc: GoalieController in goalie_controllers:
			saved_goalie_positions.append(gc.goalie.global_position)
			saved_goalie_rotations.append(gc.goalie.get_goalie_rotation_y())
			var gs: GoalieNetworkState = snap.goalie_states.get(gc.team_id)
			if gs != null:
				gc.goalie.set_goalie_position(gs.position_x, gs.position_z)
				gc.goalie.set_goalie_rotation_y(gs.rotation_y)
	puck.set_carrier(skater)
	puck.release(direction, power)
	if rtt_ms > 0.0:
		var skater_vel := Vector3(skater.velocity.x, 0.0, skater.velocity.z)
		puck.set_puck_position(puck.get_puck_position() + (direction * power + skater_vel) * rtt_half)
	if not saved_goalie_positions.is_empty():
		for i: int in goalie_controllers.size():
			goalie_controllers[i].goalie.global_position = saved_goalie_positions[i]
			goalie_controllers[i].goalie.set_goalie_rotation_y(saved_goalie_rotations[i])


func on_remote_puck_release(direction: Vector3, power: float, is_slapper: bool, shooter_peer_id: int, host_timestamp: float, rtt_ms: float) -> void:
	# Sender must be the current carrier on the host. Without this check, any
	# peer can send release_puck with arbitrary direction/power and the host
	# obediently triggers puck.release on whoever is actually carrying — the
	# parameters control the trajectory but puck.carrier picks the releaser.
	# A `puck.carrier == null` here means a different code path already
	# released the puck (raced RPCs); ignore the duplicate. The shot sound
	# moves below the validation so a malicious peer can't spam phantom
	# shot sounds on the host either. Only the host runs this function
	# (release_puck.rpc_id(1, ...)), so the early return is benign for the
	# (currently nonexistent) client path.
	if NetworkManager.is_host:
		if puck == null or _registry == null:
			return
		if puck.carrier == null:
			return
		if _registry.resolve_peer_id(puck.carrier) != shooter_peer_id:
			return
	var sound: SoundManager.Sound = SoundManager.Sound.SHOT_SLAPPER if is_slapper else SoundManager.Sound.SHOT_WRISTER
	var shot_pos: Vector3 = puck.get_puck_position() if puck != null else Vector3.ZERO
	SoundManager.play_world(sound, shot_pos, 0.0, 0.04)
	if NetworkManager.is_host:
		_record_replay_audio_event("shot", shot_pos, power, {"is_slapper": is_slapper})
	if NetworkManager.is_host:
		_start_pending_shot_from_carrier()
		var rtt_half: float = rtt_ms / 2000.0
		var skater_vel := Vector3.ZERO
		if rtt_ms > 0.0:
			var shooter_record: PlayerRecord = _registry.get_record(shooter_peer_id)
			if shooter_record != null and shooter_record.skater != null:
				skater_vel = shooter_record.skater.velocity
				skater_vel.y = 0.0
		var saved_goalie_positions: Array[Vector3] = []
		var saved_goalie_rotations: Array[float] = []
		if _state_buffer_manager != null and _state_buffer_manager.is_ready() and NetworkManager.is_real_peer(shooter_peer_id) and rtt_ms > 0.0:
			var rewind_time: float = host_timestamp - rtt_half
			var snap: WorldSnapshot = _state_buffer_manager.get_state_at(rewind_time)
			for gc: GoalieController in goalie_controllers:
				saved_goalie_positions.append(gc.goalie.global_position)
				saved_goalie_rotations.append(gc.goalie.get_goalie_rotation_y())
				var gs: GoalieNetworkState = snap.goalie_states.get(gc.team_id)
				if gs != null:
					gc.goalie.set_goalie_position(gs.position_x, gs.position_z)
					gc.goalie.set_goalie_rotation_y(gs.rotation_y)
		puck.release(direction, power)
		# Apply RTT advance AFTER release. puck.release() snaps global_position to
		# ex_carrier.get_blade_contact_global() (carrier is still set at call time),
		# so any position set before release() is silently overwritten. Applying the
		# advance here ensures the host trajectory starts from the same position as
		# the client's Jolt prediction (blade + velocity * rtt_half).
		if rtt_ms > 0.0:
			puck.set_puck_position(puck.get_puck_position() + (direction * power + skater_vel) * rtt_half)
		for i: int in goalie_controllers.size():
			goalie_controllers[i].goalie.global_position = saved_goalie_positions[i]
			goalie_controllers[i].goalie.set_goalie_rotation_y(saved_goalie_rotations[i])
		return
	puck.release(direction, power)


func _start_pending_shot_from_carrier() -> void:
	if puck == null or puck.carrier == null:
		return
	_shot_tracker.on_shot_started(_registry.resolve_peer_id(puck.carrier))


# ── Puck network events ──────────────────────────────────────────────────────
func _on_remote_carrier_changed(new_carrier_peer_id: int) -> void:
	if puck_controller != null:
		puck_controller.notify_remote_carrier_changed(new_carrier_peer_id)


func on_carrier_puck_dropped() -> void:
	var local_record := _registry.get_local() if _registry != null else null
	if local_record != null:
		local_record.controller.on_puck_released_network()
		puck_controller.notify_local_puck_dropped()


func on_local_player_picked_up_puck() -> void:
	var record := _registry.get_local() if _registry != null else null
	if record != null:
		record.controller.on_puck_picked_up_network()
		puck_controller.notify_local_pickup(record.skater)


func on_local_player_puck_stolen() -> void:
	var local_record := _registry.get_local() if _registry != null else null
	if local_record != null:
		local_record.controller.on_puck_released_network()
		puck_controller.notify_local_puck_dropped()


# ── Goal received (client-side RPC) ──────────────────────────────────────────
func _on_goal_received(scoring_team_id: int, score0: int, score1: int,
		scorer_name: String, assist1_name: String, assist2_name: String) -> void:
	if _phase_coord == null:
		return
	_phase_coord.on_goal_received(scoring_team_id, score0, score1,
			scorer_name, assist1_name, assist2_name)


func _on_faceoff_positions_received(positions: Array) -> void:
	if _phase_coord != null:
		_phase_coord.on_faceoff_positions(positions)


func _on_puck_out_of_play_received() -> void:
	# Client-side mirror of the host's OOB-confirmed moment. The FACEOFF_PREP
	# phase change still arrives via world state; this just lights up the
	# whistle + toast for clients at the same beat the host plays them.
	puck_out_of_play.emit()
	SoundManager.play_sfx(SoundManager.Sound.FACEOFF_WHISTLE)


# ── Input batches from peers (host only) ─────────────────────────────────────
# NetworkManager emits `input_batch_received` from its receive_input_batch RPC;
# we route to the matching RemoteController. Drops batches for unregistered
# peers or freed controllers (peer left mid-flight).
func _on_input_batch_received(peer_id: int, inputs: Array[InputState]) -> void:
	if not NetworkManager.is_host or _registry == null:
		return
	var record: PlayerRecord = _registry.get_record(peer_id)
	if record == null or not is_instance_valid(record.controller):
		return
	var remote: RemoteController = record.controller as RemoteController
	if remote == null:
		return
	remote.receive_input_batch(inputs)


# ── World state & stats RPC forwarding ───────────────────────────────────────
func _on_world_state_received(data: PackedByteArray) -> void:
	if _codec != null:
		_codec.decode_world_state(data)  # updates _state_machine.current_phase
	if data.size() < 6:
		return
	var host_ts: float = data.decode_float(2)
	# Feed the in-memory ring buffer so this peer's GoalReplayDriver has a
	# clip to extract when a goal fires. Skipped during the cinematic itself
	# (NetworkManager.is_replay_mode is mirrored to clients) so we don't
	# overwrite the live pre-goal frames with frozen mid-replay state.
	if _recorder != null and not NetworkManager.is_replay_mode() \
			and not _is_celebration_phase():
		_recorder.record_frame(data, host_ts)
	# Tee the broadcast into the local .mreplay file. Use the host_ts encoded
	# in the packet so timestamps align across host + client recordings —
	# local_time() differs per peer. Same dead-puck + replay-mode gate as
	# the host's get_world_state path.
	if _replay_file_writer != null and _should_record_to_file():
		_replay_file_writer.enqueue_frame(host_ts, data)
		if _state_machine != null:
			_last_recorded_phase = _state_machine.current_phase


func _on_stats_received(data: Array) -> void:
	if _codec != null:
		_codec.decode_stats(data)
	stats_updated.emit()


func _on_phase_for_broadcast_rate(new_phase: GamePhase.Phase) -> void:
	# Drop to 5 Hz during dead-puck phases (goal, prep, end-of-period, game-over)
	# where positions don't change, recovering ~40% of session broadcast bandwidth.
	var hz: float = 5.0 if PhaseRules.is_movement_locked(new_phase) else float(Constants.STATE_RATE)
	NetworkManager.set_broadcast_rate(hz)


func _on_remote_phase_changed(new_phase: GamePhase.Phase) -> void:
	_last_emitted_clock_secs = -1
	phase_changed.emit(new_phase)
	# Client mirror of the host's handle_phase_entered(GOAL_SCORED) trigger.
	# Host advances GOAL_CELEBRATION → GOAL_SCORED via state-machine tick;
	# clients learn about it via WS, and the replay cinematic kicks in here.
	if new_phase == GamePhase.Phase.GOAL_SCORED and _phase_coord != null \
			and not NetworkManager.is_host:
		_phase_coord.start_goal_replay()


func _on_clock_updated_externally(t: float) -> void:
	_last_emitted_clock_secs = -1
	clock_updated.emit(t)


func _observe_telemetry() -> void:
	var skater_buf: int = 0
	var extrapolating: bool = false
	if _registry != null:
		for peer_id: int in _registry.all():
			var r: PlayerRecord = _registry.get_record(peer_id)
			if r == null:
				continue
			if r.is_local:
				var lc := r.controller as LocalController
				if lc != null and lc.last_reconcile_error > 0.0:
					NetworkTelemetry.record_reconcile(lc.last_reconcile_error)
					lc.last_reconcile_error = 0.0
			else:
				var rc := r.controller as RemoteController
				if rc != null:
					skater_buf = rc.get_buffer_depth()
					extrapolating = extrapolating or rc.is_extrapolating
	var puck_buf: int = puck_controller.get_buffer_depth() if puck_controller != null else 0
	var goalie_buf: int = 0
	for gc: GoalieController in goalie_controllers:
		goalie_buf = gc.get_buffer_depth()
		extrapolating = extrapolating or gc.is_extrapolating
	if puck_controller != null:
		extrapolating = extrapolating or puck_controller.is_extrapolating
	_telemetry.observe_actors(skater_buf, puck_buf, goalie_buf, extrapolating)


func _sync_stats_to_clients() -> void:
	stats_updated.emit()
	if not NetworkManager.is_host or _codec == null:
		return
	NetworkManager.send_stats_to_all(_codec.encode_stats())


# ── Slot swap ─────────────────────────────────────────────────────────────────
func _on_slot_swap_requested(peer_id: int, new_team_id: int, new_slot: int) -> void:
	if not NetworkManager.is_host or _swap_coord == null:
		return
	# Player → spectator: any peer requesting a spectator slot.
	if new_team_id == GameRules.SPECTATOR_TEAM_ID:
		_demote_player_to_spectator(peer_id)
		return
	# Spectator → player: peer is in the spectator set, requesting a player slot.
	# `try_swap_slot` won't validate this because the peer isn't in
	# `_state_machine.players` yet, so we run a dedicated promotion path.
	if _spectator_peers.has(peer_id):
		_promote_spectator_to_player(peer_id, new_team_id, new_slot)
		return
	var carrier: Skater = puck.carrier if puck != null else null
	var confirmation: Dictionary = _swap_coord.request_swap(peer_id, new_team_id, new_slot, carrier)
	if confirmation.is_empty():
		return
	NetworkManager.send_confirm_slot_swap(peer_id,
			confirmation.old_team_id, confirmation.old_slot,
			confirmation.new_team_id, confirmation.new_slot,
			confirmation.jersey, confirmation.helmet, confirmation.pants)


func _on_slot_swap_confirmed(peer_id: int, old_team_id: int, old_slot: int,
		new_team_id: int, new_slot: int,
		jersey: Color, helmet: Color, pants: Color) -> void:
	if _swap_coord != null:
		_swap_coord.apply_confirmed_swap(peer_id, old_team_id, old_slot,
				new_team_id, new_slot, jersey, helmet, pants)
	# Update the local controller's team context (camera flip, move vector, shot
	# direction) when the local player is the one who swapped.
	if _registry != null:
		var record: PlayerRecord = _registry.get_record(peer_id)
		if record != null and record.is_local:
			var local_ctrl: LocalController = record.controller as LocalController
			if local_ctrl != null:
				local_ctrl.set_local_team_id(new_team_id)


func _on_hit_landed(hitter_peer_id: int, victim: Skater, impulse_magnitude: float) -> void:
	_hit_claim.notify_local_hit(hitter_peer_id, victim, impulse_magnitude)


func _on_hit_claim_received(hitter_peer_id: int, victim_peer_id: int, host_timestamp: float, rtt_ms: float) -> void:
	if not NetworkManager.is_host:
		return
	_hit_claim.receive_claim(hitter_peer_id, victim_peer_id, host_timestamp, rtt_ms)


# ── Scene exit & reset ───────────────────────────────────────────────────────
func _on_game_over() -> void:
	if _state_machine == null or _registry == null or _career_reporter == null:
		return
	# Offline + tutorial don't count as career games — there's no opponent
	# pool, the tutorial is replayed as practice, and a player shouldn't be
	# able to pad stats by playing themselves. is_offline_mode covers both
	# (start_tutorial calls start_offline).
	if NetworkManager.is_offline_mode:
		return
	var local: PlayerRecord = _registry.get_local()
	if local == null or local.team == null:
		return
	var team_id: int = local.team.team_id
	var gf: int = _state_machine.scores[team_id]
	var ga: int = _state_machine.scores[1 - team_id]
	var outcome: String = "draw"
	if gf > ga:
		outcome = "win"
	elif gf < ga:
		outcome = "loss"
	_career_reporter.report(local, gf, ga, outcome,
			_game_id, team_id, _state_machine.period_scores, _state_machine.num_periods)


# Window-close hook — closes the replay file cleanly when the user clicks
# the OS window's X. Without this, a quit mid-game leaves the .mreplay
# without END_OF_RECORDS or the footer, and the OS may signal mid-write
# leaving the last record torn. NOTIFICATION_WM_CLOSE_REQUEST fires before
# Godot's auto-quit cascade so we have time to drain the worker thread
# synchronously via close_async (which blocks on wait_to_finish). The
# in-game scene-transition path (back to main menu, rematch) already
# closes via on_scene_exit; this only catches the OS-level close case.
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_close_replay_file_writer()


func on_scene_exit() -> void:
	set_input_blocked(false)
	# Drain + flush the replay file before tearing down state — close_async
	# blocks until the worker exits, so we must call this while the registry
	# (used to build the footer) is still intact.
	_close_replay_file_writer()
	_last_recorded_phase = -1
	if _shot_tracker != null:
		_shot_tracker.clear_state()
	if _registry != null:
		_registry.clear_state()
	_state_machine = null
	_spawner = null
	teams.clear()
	puck = null
	goals.clear()
	goalies.clear()
	goalie_controllers.clear()
	puck_controller = null
	_registry = null
	_codec = null
	_state_buffer_manager = null
	current_snapshot = null
	team_brains = []
	# Null PhaseCoordinator's _state_machine before stopping the driver so
	# any replay_stopped signal that fires during teardown returns early from
	# _on_goal_replay_stopped's guard rather than calling handle_phase_entered
	# against partially-torn-down state.
	if _phase_coord != null:
		_phase_coord.cleanup()
	if _goal_replay_driver != null:
		_goal_replay_driver.stop()
		_goal_replay_driver.queue_free()
		_goal_replay_driver = null
	_recorder = null
	_shot_tracker = null
	_pickup_claim = null
	_hit_claim = null
	_phase_coord = null
	_swap_coord = null
	if _debug_overlay:
		_debug_overlay.queue_free()
		_debug_overlay = null
	_telemetry = null
	NetworkTelemetry.instance = null
	_last_emitted_clock_secs = -1
	_puck_oob_timer = 0.0
	_teardown_spectator_camera()
	_spectator_peers.clear()
	_game_id = ""
	NetworkManager.prepare_for_new_game()


func reset_game() -> void:
	_drop_puck_if_carried()
	_apply_reset()
	# Each rematch gets its own .mreplay so the viewer doesn't render two
	# games concatenated as one continuous file with a visible score reset
	# in the middle. Host mints the new game_id and ships it so every peer
	# rolls over to the same filename.
	var new_id: String = ""
	if not _game_id.is_empty():
		new_id = PlayerPrefs.generate_uuid()
	NetworkManager.notify_reset_to_all(new_id)
	_rollover_replay_file_to(new_id)
	_state_machine.begin_faceoff_prep()
	_phase_coord.handle_phase_entered()
	game_reset.emit()


func on_game_reset(new_game_id: String = "") -> void:
	_apply_reset()
	_rollover_replay_file_to(new_game_id)
	# Clear client-side carry state so PuckController stops pinning to blade.
	var local_record := _registry.get_local() if _registry != null else null
	if local_record != null and local_record.controller.has_puck:
		local_record.controller.on_puck_released_network()
		puck_controller.notify_local_puck_dropped()
	game_reset.emit()


func _apply_reset() -> void:
	_state_machine.reset_all()
	_last_emitted_clock_secs = -1
	_last_ghost_state.clear()
	_hit_claim.reset_throttle()
	_puck_oob_timer = 0.0
	score_changed.emit(0, 0)
	period_changed.emit(1)
	clock_updated.emit(_state_machine.period_duration)
	_registry.reset_all_stats()
	_shot_tracker.reset_all()
	stats_updated.emit()


# ── Return to Lobby ──────────────────────────────────────────────────────────
func return_to_lobby() -> void:
	if not NetworkManager.is_host:
		return
	_drop_puck_if_carried()
	# Rebuild pending_bot_slots from registry's bot records so the lobby
	# reloads with the same bot configuration the host took into the game.
	# Bots are stripped from the roster (they're not real peers) and instead
	# round-trip as bot-slot markers; this is what restores the "X" action
	# on the host's slot cards.
	var bot_slots: Dictionary[int, bool] = {}
	if _registry != null:
		for peer_id: int in _registry.all():
			var r: PlayerRecord = _registry.get_record(peer_id)
			if r == null or not r.is_bot or r.team == null:
				continue
			bot_slots[r.team.team_id * 3 + r.team_slot] = true
	NetworkManager.pending_bot_slots = bot_slots
	for peer_id: int in NetworkManager.connected_peer_ids():
		NetworkManager.send_bot_slots_to(peer_id, bot_slots)
	NetworkManager.send_return_to_lobby_to_all(_build_lobby_roster_array())


func _on_return_to_lobby(_roster: Array) -> void:
	on_scene_exit()
	NetworkSimManager.clear_pending()
	get_tree().change_scene_to_file(Constants.SCENE_LOBBY)


# Live-update the local skater + record when the player edits their identity
# via the SideMenu's player card. Only safe in offline contexts (free play);
# online identity changes would also need an RPC for peers to mirror, which
# is out of scope for the current free-play work.
func _on_local_identity_changed(p_name: String, p_number: int, p_is_left: bool) -> void:
	if _registry == null:
		return
	var record: PlayerRecord = _registry.get_local()
	if record == null:
		return
	record.player_name = p_name
	record.jersey_number = p_number
	record.is_left_handed = p_is_left
	if record.skater != null:
		record.skater.set_player_name(p_name)
		record.skater.set_jersey_info(p_name, p_number, record.text_color)
		record.skater.is_left_handed = p_is_left


# Re-tint home (and possibly away) when the local player picks a new
# favorite team palette from the SideMenu's player card. The local skater
# is always on the home team in free play, so we re-skin its uniform and
# the home goalie. If apply_preferred_color also re-rolled the away color
# to avoid a collision, the away goalie gets re-tinted too.
func _on_local_preferred_color_changed(home_color_id: String, away_color_id: String) -> void:
	if teams.size() < 2:
		return
	var home_changed: bool = teams[0].color_id != home_color_id
	var away_changed: bool = teams[1].color_id != away_color_id
	if not home_changed and not away_changed:
		return
	teams[0].color_id = home_color_id
	teams[1].color_id = away_color_id
	if home_changed:
		_apply_team_colors_to_actors(0)
	if away_changed:
		_apply_team_colors_to_actors(1)
	var home_c: Dictionary = TeamColorRegistry.get_colors(teams[0].color_id, 0)
	var away_c: Dictionary = TeamColorRegistry.get_colors(teams[1].color_id, 1)
	team_colors_ready.emit(home_c.primary, home_c.secondary, away_c.primary, away_c.secondary)


func _apply_team_colors_to_actors(team_id: int) -> void:
	var colors: Dictionary = TeamColorRegistry.get_colors(teams[team_id].color_id, team_id)
	# `goalies` is stored positionally ([top, bottom]) while team_id is
	# semantic (0 = home = bottom net, 1 = away = top net) — indexing the
	# array directly by team_id flips the two. Route through the team's
	# goalie_controller, which is the authoritative team-to-goalie binding
	# set up in _spawn_goalies.
	var gc: GoalieController = teams[team_id].goalie_controller
	if gc != null and gc.goalie != null:
		gc.goalie.set_goalie_color(colors.jersey, colors.helmet, colors.goalie_pads)
	if _registry == null:
		return
	for peer_id: int in _registry.all():
		var record: PlayerRecord = _registry.get_record(peer_id)
		if record == null or record.skater == null or record.team == null:
			continue
		if record.team.team_id != team_id:
			continue
		record.jersey_color = colors.jersey
		record.helmet_color = colors.helmet
		record.pants_color = colors.pants
		record.socks_color = colors.socks
		record.jersey_stripe_color = colors.jersey_stripe
		record.pants_stripe_color = colors.pants_stripe
		record.socks_stripe_color = colors.socks_stripe
		record.text_color = colors.text
		record.text_outline_color = colors.text_outline
		record.secondary_color = colors.secondary
		record.skater.set_player_color(colors.jersey, colors.helmet,
				colors.pants, colors.socks, colors.primary)
		record.skater.set_jersey_stripes(colors.jersey_stripe,
				colors.pants_stripe, colors.socks_stripe)
		record.skater.set_jersey_info(record.player_name, record.jersey_number, colors.text)


func _build_lobby_roster_array() -> Array:
	var result: Array = []
	if _registry == null:
		return result
	for peer_id: int in _registry.all():
		var r: PlayerRecord = _registry.get_record(peer_id)
		# Bots are not real peers — they round-trip through pending_bot_slots,
		# not the roster. Including them here would render them as human-filled
		# cards in the lobby with no remove action.
		if r.is_bot:
			continue
		var team_id: int = r.team.team_id if r.team != null else 0
		result.append([peer_id, team_id, r.team_slot, r.player_name,
				r.is_left_handed, r.jersey_number])
	# Spectators aren't in _registry, so without this they'd come back to the
	# lobby as orphan peers — no slot, no name, no jersey number — and the
	# host's identity lookup would default everything to "Player" / 10. Append
	# them explicitly using the names/handedness/numbers tracked by
	# NetworkManager from request_join. Spectator slots are reassigned 0..N
	# since the original index isn't preserved across the game session.
	var spec_idx: int = 0
	for peer_id: int in _spectator_peers:
		result.append([peer_id, GameRules.SPECTATOR_TEAM_ID, spec_idx,
				NetworkManager.get_peer_name(peer_id),
				NetworkManager.get_peer_handedness(peer_id),
				NetworkManager.get_peer_number(peer_id)])
		spec_idx += 1
	return result


func return_to_free_play() -> void:
	# Free play is the new "home" — there is no main menu screen to land on.
	# Tear down whatever activity the player was in (lobby, match, tutorial,
	# replay), re-arm offline mode with the player's favorite home palette
	# and a random away, and drop them back on the ice. The SideMenu
	# (opened with Escape) is where they pick a new activity.
	on_scene_exit()
	NetworkSimManager.clear_pending()
	NetworkManager.reset()
	NetworkManager.start_free_play()
	get_tree().change_scene_to_file(Constants.SCENE_HOCKEY)


# ── Helpers ──────────────────────────────────────────────────────────────────
func _puck_speed_volume(speed: float) -> float:
	return lerpf(-10.0, 0.0, clampf((speed - 1.0) / 20.0, 0.0, 1.0))


# Drops a carried puck and notifies the remote carrier. Returns the carrier
# peer_id (-1 if no carrier). Host-only — safe to call from dead phases.
func _drop_puck_if_carried() -> int:
	if puck == null or puck.carrier == null:
		return -1
	var carrier_peer_id: int = _resolve_skater_peer_id(puck.carrier)
	puck.drop()
	if carrier_peer_id != -1 and NetworkManager.connected_peer_ids().has(carrier_peer_id):
		NetworkManager.notify_puck_dropped_to_carrier(carrier_peer_id)
	return carrier_peer_id


func _push_lobby_assignments_to_clients() -> void:
	var slots: Dictionary = NetworkManager.pending_lobby_slots
	var existing: Array[Array] = _collect_existing_player_data()
	for peer_id: int in slots:
		if peer_id == 1:
			continue
		var entry: Dictionary = slots[peer_id]
		var team_id: int = entry.team_id
		var team_slot: int = entry.team_slot
		if team_id == GameRules.SPECTATOR_TEAM_ID:
			# Spectators get the slot-assignment RPC so they take the SpectatorCamera
			# path on the client, plus existing-players sync for actor render. No
			# state-machine slot is reserved and no skater is spawned.
			_spectator_peers[peer_id] = true
			NetworkManager.send_slot_assignment(peer_id, team_slot, team_id,
					Color(0, 0, 0, 0), Color(0, 0, 0, 0), Color(0, 0, 0, 0))
			NetworkManager.send_sync_existing_players(peer_id, existing)
			continue
		var is_left: bool = entry.get("is_left_handed", true)
		var p_name: String = entry.get("player_name", "Player")
		var p_number: int = entry.get("jersey_number", 10)
		NetworkManager.send_sync_existing_players(peer_id, existing)
		var colors: Dictionary = _spawn_player_and_broadcast(
				peer_id, team_id, team_slot, is_left, p_name, p_number, false)
		existing.append([peer_id, team_slot, team_id,
				colors.jersey, colors.helmet, colors.pants, is_left, p_name, p_number])
	NetworkManager.pending_lobby_slots = {}


func _spawn_bots_from_lobby() -> void:
	# Host-only. Iterates pending_bot_slots (set by lobby toggles), spawns an
	# AIController-driven skater per marked slot, and broadcasts a remote-skater
	# spawn so clients render each bot through their existing RemoteController
	# pipeline. Synthetic peer_ids in [-6, -1] avoid colliding with real ENet
	# peers (always positive); send_slot_assignment is skipped because it
	# targets peer_ids and bots have no peer connection.
	if not NetworkManager.is_host:
		return
	if NetworkManager.pending_bot_slots.is_empty():
		return
	var bot_id: int = 0
	for slot_key: int in NetworkManager.pending_bot_slots:
		if not NetworkManager.pending_bot_slots[slot_key]:
			continue
		# Slot keys for non-spectator slots: team*3+slot. Spectator keys are
		# >= 100 and bots can't occupy them; skip defensively.
		if slot_key < 0 or slot_key >= 6:
			continue
		var team_id: int = 0 if slot_key < 3 else 1
		var team_slot: int = slot_key % 3
		# Refuse to overwrite a slot that a human already claimed.
		if _slot_already_taken(team_id, team_slot):
			continue
		var team: Team = teams[team_id]
		var colors: Dictionary = TeamColorRegistry.get_colors(team.color_id, team_id)
		var record: PlayerRecord = _registry.spawn_bot(bot_id, team_slot, team)
		_state_machine.register_remote_assigned_player(record.peer_id, team_slot, team_id)
		# Bot visible to clients: same RPC humans use. Clients spawn it as a
		# RemoteController-driven skater because peer_id is not their own.
		NetworkManager.send_spawn_remote_skater(record.peer_id, team_slot, team_id,
				colors.jersey, colors.helmet, colors.pants,
				record.is_left_handed, record.player_name, record.jersey_number)
		bot_id += 1
	# Clear after spawning so a return-to-lobby + restart starts fresh; the
	# host will re-toggle bot slots in the next lobby session if desired.
	NetworkManager.pending_bot_slots = {}


func _slot_already_taken(team_id: int, team_slot: int) -> bool:
	for peer_id: int in _registry.all():
		var r: PlayerRecord = _registry.get_record(peer_id)
		if r.team.team_id == team_id and r.team_slot == team_slot:
			return true
	return false


# Public AI-facing snapshot accessor. Hides the clock detail
# (StateBufferManager uses Time.get_ticks_usec()/1e6, NOT local_time()) so
# callers don't accidentally cross timelines after a rehost. Pass 0 for the
# freshest captured state.
func get_state_delayed(delay_seconds: float) -> WorldSnapshot:
	if _state_buffer_manager == null:
		return null
	var ts: float = Time.get_ticks_usec() / 1_000_000.0 - delay_seconds
	return _state_buffer_manager.get_state_at(ts)


func _collect_existing_player_data() -> Array[Array]:
	var existing: Array[Array] = []
	for peer_id: int in _registry.all():
		var r: PlayerRecord = _registry.get_record(peer_id)
		existing.append([peer_id, r.team_slot, r.team.team_id,
				r.jersey_color, r.helmet_color, r.pants_color,
				r.is_left_handed, r.player_name, r.jersey_number])
	return existing


# ── Getters passed as Callables to collaborators ─────────────────────────────
func _get_puck_controller() -> PuckController:
	return puck_controller


func _get_goalie_controllers() -> Array:
	return goalie_controllers


# ── World state (NetworkManager provider callback) ───────────────────────────
func get_world_state() -> PackedByteArray:
	var state: PackedByteArray = _codec.encode_world_state() if _codec != null else PackedByteArray()
	if state.is_empty():
		return state
	var ts: float = NetworkManager.local_time()
	# In-memory recorder feeds GoalReplayDriver. Gated by is_replay_mode (the
	# cinematic is the consumer, not the producer) AND by GOAL_CELEBRATION
	# (the celebration beat is live gameplay; we don't want its frames in the
	# replay clip, which should end at the puck-in-net moment captured via
	# _capture_goal_moment_frame).
	if _recorder != null and not NetworkManager.is_replay_mode() \
			and not _is_celebration_phase():
		_recorder.record_frame(state, ts)
	# File writer skips dead-puck phase ticks past the first one — see
	# _should_record_to_file. The first frame on each phase transition
	# captures the puck-in-net moment / faceoff snap / etc.
	if _replay_file_writer != null and _should_record_to_file():
		_replay_file_writer.enqueue_frame(ts, state)
		if _state_machine != null:
			_last_recorded_phase = _state_machine.current_phase
	return state


func _should_record_to_file() -> bool:
	if NetworkManager.is_replay_mode():
		return false
	if _state_machine == null:
		return true
	var phase: int = _state_machine.current_phase
	if PhaseRules.is_movement_locked(phase):
		# Capture only the first frame of each movement-locked phase. Goal:
		# the puck-in-net moment on GOAL_SCORED entry — without this, the
		# last recorded frame before the gap is the previous PLAYING tick,
		# which usually shows the puck still approaching the net rather
		# than inside it. Subsequent ticks at 5 Hz are duplicate static
		# state and add nothing.
		return phase != _last_recorded_phase
	return true


# ── Public API consumed by controllers, HUD, camera, scoreboard ──────────────
func is_host() -> bool:
	return NetworkManager.is_host


func is_movement_locked() -> bool:
	if _state_machine == null:
		return false
	return _state_machine.is_movement_locked()


func allows_blade_aim_during_lock() -> bool:
	if _state_machine == null:
		return false
	return _state_machine.allows_blade_aim_during_lock()


func is_input_blocked() -> bool:
	return _input_blocked


func set_input_blocked(blocked: bool) -> void:
	_input_blocked = blocked


func get_skater_team(skater: Skater) -> Team:
	return _registry.resolve_team(skater) if _registry != null else null


func get_puck() -> Puck:
	return puck


func spawn_tutorial_dummy(position: Vector3) -> Dictionary:
	return _spawner.spawn_remote_player(
		position, Color(0.8, 0.3, 0.3), Color(0.2, 0.2, 0.2), Color(0.15, 0.15, 0.15),
		Color(0.8, 0.3, 0.3), Color(0.8, 0.3, 0.3), false, puck, self)


# Directly triggers icing ghost mode for team 0 without requiring a hybrid-icing
# race win. Used by TutorialManager to demonstrate the mechanic in single-player
# (no opposing players means the race always waves off in normal detection).
func trigger_tutorial_icing() -> void:
	if _state_machine == null:
		return
	_state_machine.icing_team_id = 0
	_state_machine._icing_timer = GameRules.ICING_GHOST_DURATION


func get_goalie_data() -> Array[Dictionary]:
	return _cached_goalie_data


# Rebuilds `_cached_goalie_data` from the live goalies array. Reuses each
# Dictionary in place so the steady-state per-tick cost is three key
# writes per goalie rather than a full Array+Dictionary allocation.
func _refresh_goalie_data_cache() -> void:
	var n: int = goalies.size()
	while _cached_goalie_data.size() < n:
		_cached_goalie_data.append({})
	while _cached_goalie_data.size() > n:
		_cached_goalie_data.pop_back()
	for i: int in range(n):
		var entry: Dictionary = _cached_goalie_data[i]
		entry["position"] = goalies[i].global_position
		entry["rotation_y"] = goalies[i].get_goalie_rotation_y()
		entry["is_butterfly"] = goalie_controllers[i].is_butterfly()


func get_slot_roster() -> Array[Dictionary]:
	return _registry.get_slot_roster() if _registry != null else []


func get_local_player() -> PlayerRecord:
	return _registry.get_local() if _registry != null else null


func get_players() -> Dictionary[int, PlayerRecord]:
	if _registry == null:
		var empty: Dictionary[int, PlayerRecord] = {}
		return empty
	return _registry.all()


func get_period_duration() -> float:
	return _state_machine.period_duration if _state_machine != null else GameRules.PERIOD_DURATION


func get_num_periods() -> int:
	return _state_machine.num_periods if _state_machine != null else GameRules.NUM_PERIODS


func get_rule_set() -> int:
	return _state_machine.rule_set if _state_machine != null else GameRules.DEFAULT_RULE_SET


func get_period_scores() -> Array:
	if _state_machine == null:
		return GameStateMachine._make_period_scores(GameRules.NUM_PERIODS)
	return _state_machine.period_scores


func apply_stats(data: Array) -> void:
	_on_stats_received(data)

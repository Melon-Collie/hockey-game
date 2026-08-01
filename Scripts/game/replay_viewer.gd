class_name ReplayViewer
extends Node

# Root script for the offline .mreplay viewer. The hosting scene
# (Scenes/ReplayViewer.tscn) just needs a rink + lighting; this script
# instantiates puck / goalies / skaters at runtime from the file's roster
# header and drives them via FileReplayDriver.
#
# File path is provided by the launching screen via
# NetworkManager.pending_replay_path. Empty path = bail back to free play.
#
# Required scene nodes (the user wires these in the editor):
#   - This script on the root Node
#   - The rink visuals + goals (HockeyGoal nodes for the net meshes)
#   - WorldEnvironment + DirectionalLight3D for lighting
#   - No Camera3D (CameraDirector mounts broadcast / chase / POV / free cams at runtime)
#   - No HUD (added in a follow-up commit)

var _spawner: ActorSpawner = null
var _puck: Puck = null
var _puck_controller: PuckController = null
var _goalie_controllers: Array[GoalieController] = []
var _records: Dictionary = {}  # peer_id → PlayerRecord
var _codec: WorldStateCodec = null
var _driver: FileReplayDriver = null
var _camera_director: CameraDirector = null
var _hud: ReplayViewerHUD = null
var _crowd: CrowdAudioController = null
# The arena's center-hung scoreboard (inside the instanced RinkArena scene).
# Fed the recorded game state / goal events directly — its live GameManager
# signals never fire during offline playback.
var _jumbotron: Jumbotron = null
# Recorded game phase of the currently-applied frame (GamePhase.Phase; −1
# before the first frame lands). Backs the is_faceoff_prep() stub.
var _replay_phase: int = -1
# Cached so the player_joined event handler can spawn mid-game arrivals
# without re-deriving them from header.
var _home_color_slot: int = TeamColorRegistry.DEFAULT_HOME_SLOT
var _away_color_slot: int = TeamColorRegistry.DEFAULT_AWAY_SLOT
var _home_colors: Dictionary = {}
var _away_colors: Dictionary = {}
# Regulation period count from the replay header — sizes the Tab scoreboard's
# per-period grid and the OT-label threshold. Set in _mount_hud.
var _num_periods: int = GameRules.NUM_PERIODS
# Header roster cached for backward-seek rebuilds — the driver sends us the
# events stream up through the new clock, but we have to re-spawn the
# initial roster ourselves first.
var _header_roster: Array = []


func _ready() -> void:
	PlayerPrefs.apply_video()
	var path: String = NetworkManager.pending_replay_path
	NetworkManager.pending_replay_path = ""
	if path.is_empty():
		push_error("ReplayViewer: no replay path; returning to main menu")
		GameManager.return_to_free_play()
		return

	var read_result: Dictionary = ReplayFileReader.read(path)
	if not read_result.ok:
		push_error("ReplayViewer: failed to read %s — %s" % [path, read_result.error])
		GameManager.return_to_free_play()
		return

	# Replay mode silences RemoteController._physics_process (no buffer to
	# interpolate from offline) and the codec's own host-state apply paths.
	# The driver writes positions via apply_replay_state directly.
	NetworkManager.start_replay_mode(0.0)

	# The viewer's cameras (broadcast booth, chase, free) sit far from the
	# action; widen the 3D sound falloff so recorded puck/shot/check events
	# stay audible from the cinematic distance instead of attenuating to
	# silence. Restored in _exit_tree.
	SoundManager.set_world_audio_range(SoundManager.AudioRange.REPLAY_FAR)

	_spawner = ActorSpawner.new()
	_spawner.setup(self)
	_spawn_actors_from_header(read_result.header)
	_mount_camera()
	_mount_crowd_audio()
	_start_playback(read_result.frames)
	_mount_hud(read_result.header)


func _exit_tree() -> void:
	# Restore the global flag so a subsequent live game / lobby session works.
	NetworkManager.stop_replay_mode()
	# Restore the live 3D sound falloff (widened on entry for the far cameras).
	SoundManager.set_world_audio_range(SoundManager.AudioRange.LIVE)
	# Restore mouse mode if the user left free-cam with RMB captured — the
	# next scene's UI needs a visible cursor. Director.teardown() handles
	# this via FreeCamera.deactivate() when free is the active mode.
	if _camera_director != null:
		_camera_director.teardown()
		_camera_director = null


# ── Setup ────────────────────────────────────────────────────────────────────

func _spawn_actors_from_header(header: Dictionary) -> void:
	var puck_result: Dictionary = _spawner.spawn_puck_with_controller(false)
	_puck = puck_result.puck
	_puck_controller = puck_result.controller
	# PuckController would otherwise run client-side prediction every tick;
	# with it off, nothing moves the Node3D puck between FileReplayDriver writes.
	_puck_controller.set_physics_process(false)

	var goalie_result: Dictionary = _spawner.spawn_goalie_pair(_puck, false)
	# Order must match GameManager._spawn_goalies (game_manager.gd:592) —
	# WorldStateCodec encodes per-goalie state by goalie_controllers index, so
	# a different order here would apply top-goalie state to the bottom goalie
	# (visible as goalies appearing in each other's net wearing the wrong
	# team's colors).
	_goalie_controllers = [goalie_result.top_controller, goalie_result.bottom_controller]
	_goalie_controllers[0].team_id = 1
	_goalie_controllers[1].team_id = 0
	for gc: GoalieController in _goalie_controllers:
		gc.set_physics_process(false)

	# Replay headers carry int slot indices, but JSON.parse_string decodes
	# every number as float — so accept both. Legacy fruit-name strings in
	# old .mreplay files fall back to defaults rather than crash.
	var raw_home: Variant = header.get("home_color_slot", TeamColorRegistry.DEFAULT_HOME_SLOT)
	var raw_away: Variant = header.get("away_color_slot", TeamColorRegistry.DEFAULT_AWAY_SLOT)
	if raw_home is int or raw_home is float:
		_home_color_slot = int(raw_home)
	else:
		push_warning("ReplayViewer: legacy color id in header, using default home")
		_home_color_slot = TeamColorRegistry.DEFAULT_HOME_SLOT
	if raw_away is int or raw_away is float:
		_away_color_slot = int(raw_away)
	else:
		push_warning("ReplayViewer: legacy color id in header, using default away")
		_away_color_slot = TeamColorRegistry.DEFAULT_AWAY_SLOT
	_home_colors = TeamColorRegistry.get_colors(_home_color_slot, 0)
	_away_colors = TeamColorRegistry.get_colors(_away_color_slot, 1)
	goalie_result.bottom_goalie.apply_uniform(_home_colors)
	goalie_result.top_goalie.apply_uniform(_away_colors)
	# Goalie identity (name + number on the sweater), matching the live spawn in
	# GameManager._spawn_goalies. The AI goalies' identities are compile-time
	# constants (not in the .mreplay header), so read them straight from
	# GameManager. bottom = home = team 0, top = away = team 1 (the same mapping
	# the goalie_controllers indices use above).
	goalie_result.bottom_goalie.apply_jersey_info(GameManager.GOALIE_NAMES[0], GameManager.GOALIE_NUMBERS[0])
	goalie_result.top_goalie.apply_jersey_info(GameManager.GOALIE_NAMES[1], GameManager.GOALIE_NUMBERS[1])
	_apply_crowd_colors()

	_header_roster = header.get("roster", []) as Array
	for entry: Variant in _header_roster:
		_spawn_skater_from_roster(entry as Dictionary)


func _spawn_skater_from_roster(entry: Dictionary) -> void:
	var peer_id: int = int(entry.get("peer_id", 0))
	# Idempotent — header roster + event-replay re-fires on seek-forward
	# could otherwise spawn the same actor twice.
	if _records.has(peer_id):
		return
	var team_id: int = int(entry.get("team_id", 0))
	var team_slot: int = int(entry.get("team_slot", 0))
	var is_left: bool = bool(entry.get("is_left_handed", true))
	var p_name: String = entry.get("player_name", "Player")
	var jersey_number: int = int(entry.get("jersey_number", 10))
	var team_obj := Team.new()
	team_obj.team_id = team_id
	team_obj.color_slot = _home_color_slot if team_id == 0 else _away_color_slot
	var team_colors: Dictionary = _home_colors if team_id == 0 else _away_colors
	# Re-apply the recorded build (height / weight / gear) so the skater's mesh,
	# reach, and re-derived lean match the host's — without it the replay skater
	# sits at the neutral frame and the host's lean-compensated blade positions
	# leave the stick floating off the ice. Missing "build" (legacy .mreplay) →
	# from_dict returns the neutral build, matching the old behavior.
	var attrs: PlayerAttributes = PlayerAttributes.from_dict(entry.get("build", {}) as Dictionary)
	var spawned: Dictionary = _spawner.spawn_remote_player(
			PlayerRules.faceoff_position(team_id, team_slot),
			is_left, _puck, self, attrs)
	var skater: Skater = spawned.skater
	var controller: RemoteController = spawned.controller
	# Skater._physics_process integrates position from whatever velocity
	# apply_replay_state set last. When the viewer is paused, the replay engine
	# isn't running so velocity isn't refreshed — the skater coasts on its stale
	# velocity until unpause snaps it back. Disable physics processing entirely;
	# apply_replay_state covers all visual updates (position, blade, IK) itself.
	skater.set_physics_process(false)
	# Latch off the flat-on-ice slot rings, name labels, stamina rings, and
	# slapper indicators — they're designed for the local player's top-down
	# gameplay camera and look wrong (or misleading, in the top-down POV cam)
	# from the director's camera angles. set_physics_process(false) above also
	# means SkaterHUDCoordinator.update() would never auto-hide them.
	skater.set_world_hud_hidden(true)
	skater.set_player_name(p_name)
	skater.set_uniform(team_colors)
	skater.set_jersey_info(p_name, jersey_number)

	var record := PlayerRecord.new(peer_id, team_slot, false, team_obj)
	record.skater = skater
	record.controller = controller
	record.player_name = p_name
	record.jersey_number = jersey_number
	record.is_left_handed = is_left
	record.jersey_color = team_colors.jersey
	record.text_color = team_colors.text
	record.text_outline_color = team_colors.text_outline
	_records[record.peer_id] = record


# The crowd (ArenaStands) and scoreboard (Jumbotron) live inside the instanced
# RinkArena scene. In the live game they recolor themselves off
# GameManager.team_colors_ready, which never fires for replay colors offline —
# so push the replay palette to them directly here, reusing the same setup /
# set_team_colors the live signal would call. find_child returns Node, so type
# the results for member access.
func _apply_crowd_colors() -> void:
	var stands: ArenaStands = find_child("ArenaStands", true, false) as ArenaStands
	if stands == null:
		push_warning("ReplayViewer: ArenaStands not found; crowd keeps default colors")
		return
	stands.setup(
		_home_colors.primary, _home_colors.secondary,
		_away_colors.primary, _away_colors.secondary)
	_jumbotron = find_child("Jumbotron", true, false) as Jumbotron
	if _jumbotron == null:
		push_warning("ReplayViewer: Jumbotron not found; board stays on attract")
		return
	_jumbotron.set_team_colors(
		_home_colors.primary, _home_colors.secondary,
		_away_colors.primary, _away_colors.secondary)


func _mount_camera() -> void:
	_camera_director = CameraDirector.new()
	add_child(_camera_director)
	_camera_director.setup(
		func() -> Vector3:
			return _puck.global_position if _puck != null else Vector3.ZERO,
		func() -> Array[Skater]:
			var out: Array[Skater] = []
			for record: PlayerRecord in _records.values():
				if record != null and record.skater != null and is_instance_valid(record.skater):
					out.append(record.skater)
			return out)
	_camera_director.activate_initial()


func get_camera_director() -> CameraDirector:
	return _camera_director


# Live play instances CrowdAudio as a node in Hockey.tscn; the offline viewer
# scene has no such node, so mount the same controller in code. Its _ready
# starts the ambient murmur loop on the Arena bus (the same bus + PlayerPrefs
# volume slider live play uses). Goal cheers are driven from _on_replay_event
# instead of the GameManager signals, which don't fire offline.
func _mount_crowd_audio() -> void:
	_crowd = CrowdAudioController.new()
	add_child(_crowd)


func _start_playback(frames: Array) -> void:
	_codec = WorldStateCodec.new()
	# decode_for_replay only walks the packet bytes — it doesn't reach into
	# the codec's other collaborators, so the no-setup() codec is fine here.
	_driver = FileReplayDriver.new()
	add_child(_driver)
	_driver.setup(_codec, _records, _puck, _goalie_controllers, frames)
	_driver.event_emitted.connect(_on_replay_event)
	_driver.roster_rebuild_requested.connect(_on_roster_rebuild)
	# Track the recorded phase for the is_faceoff_prep() stub below — the
	# skater gait's faceoff ready-stance reads it through the game_state
	# interface, so replayed faceoffs crouch at the dot like live ones.
	_driver.game_state_changed.connect(_on_replay_game_state)
	# Cut the tracking cameras on seeks / gap skips / faceoff resets, so the
	# broadcast cam frames the faceoff the moment the reset frame is up
	# instead of panning across the rink from wherever play stopped.
	_driver.playback_discontinuity.connect(
			func() -> void: _camera_director.on_playback_discontinuity())
	_driver.play()


func _on_replay_game_state(gs: Dictionary) -> void:
	_replay_phase = int(gs.get("phase", -1))
	# Drive the arena scoreboard from the recorded game state — score, clock,
	# period, and the phase-selected page (GOAL during celebrations, BREAK
	# between periods, FINAL at game over) all track the playback clock.
	if _jumbotron != null:
		_jumbotron.apply_replay_game_state(gs)


# Dispatch on event kind so the viewer stays in sync with mid-game roster
# changes (player_joined / player_left). Goal events are forwarded to the
# HUD if it cares (currently no-op; future goal banner work consumes them).
func _on_replay_event(event: Dictionary) -> void:
	var kind: String = event.get("kind", "")
	if kind == "player_joined":
		_spawn_skater_from_roster(event)
	elif kind == "player_left":
		_despawn_skater(int(event.get("peer_id", -1)))
	else:
		# Audio + body-check VFX events. Goal events flow through too — the
		# replayer ignores unknown kinds, and goal-horn playback can be
		# wired by a future HUD listener if desired (live games already
		# play it on goal_received; offline replays don't have NetworkManager
		# delivering anything).
		ReplayEventReplayer.dispatch_with_records(event, _records)
		# Crowd cheer + ambient duck on replayed goals — the live
		# GameManager.goal_scored that drives this in a real game doesn't
		# fire offline, so trigger it off the recorded goal event here.
		if kind == "goal":
			if _crowd != null:
				_crowd.cheer()
			# Fill the jumbotron's GOAL page (scorer name + team flash); the
			# page itself is selected by the recorded phase.
			if _jumbotron != null:
				_jumbotron.show_goal(str(event.get("scorer", "")),
						clampi(int(event.get("scoring_team_id", 0)), 0, 1))


func _despawn_skater(peer_id: int) -> void:
	if not _records.has(peer_id):
		return
	var record: PlayerRecord = _records[peer_id]
	if record.skater != null:
		record.skater.queue_free()
	if record.controller != null:
		record.controller.queue_free()
	_records.erase(peer_id)


# Backward seek: tear down every actor, respawn the header roster, replay
# the events stream up to the new clock so any mid-game joins/leaves that
# happened before the seek target are reflected in the visible roster.
func _on_roster_rebuild(events_through_t: Array) -> void:
	# Snapshot keys before iterating — _despawn_skater erases from _records.
	var current_peers: Array = _records.keys()
	for peer_id: Variant in current_peers:
		_despawn_skater(int(peer_id))
	for entry: Variant in _header_roster:
		_spawn_skater_from_roster(entry as Dictionary)
	for event: Variant in events_through_t:
		_on_replay_event(event as Dictionary)


func _mount_hud(header: Dictionary) -> void:
	_hud = ReplayViewerHUD.new()
	add_child(_hud)
	_num_periods = _scoreboard_num_periods(header)
	_hud.setup(_driver, header, _camera_director,
		_home_color_slot, _away_color_slot, _num_periods,
		Callable(self, "_scoreboard_players"),
		Callable(self, "_scoreboard_period_scores"))


# ── Tab-scoreboard data providers ────────────────────────────────────────────
# The replay reuses the live Scoreboard, which reads players + period scores.
# Replay world-state frames carry no per-player stats block (stats ship on a
# separate reliable channel that isn't recorded), so the only stats we can
# reconstruct are GOALS and ASSISTS — recorded goal events carry the scorer /
# assist display names. SOG / hits / blocks are not in the file and show 0.
# Goal events identify players by display name only (no peer id), so we match
# names against records; the synthesized scoreboard names ("P1"/"P2"/"P3" for
# nameless players) are deterministic, so they still match the recorded names.

# Returns peer_id → PlayerRecord, the exact shape GameManager.get_players()
# yields, after refreshing each record's goal / assist counts from the events.
func _scoreboard_players() -> Dictionary:
	_refresh_event_stats()
	return _records


# [team0_periods[], team1_periods[]] — same shape as GameManager.get_period_scores().
# Reconstructed from goal events with host_ts <= the current virtual clock so
# the board tracks live as the user scrubs.
func _scoreboard_period_scores() -> Array:
	var num_periods: int = maxi(1, _num_periods)
	var scores: Array = [[], []]
	for team: int in 2:
		for _p: int in num_periods:
			(scores[team] as Array).append(0)
	if _driver == null:
		return scores
	var clock: float = _driver.get_virtual_clock()
	for event: Dictionary in _driver.get_events():
		if event.host_ts > clock:
			continue
		var data: Dictionary = event.get("data", {}) as Dictionary
		if data.get("kind", "") != "goal":
			continue
		var team_id: int = clampi(int(data.get("scoring_team_id", 0)), 0, 1)
		var period_idx: int = clampi(int(data.get("period", 1)) - 1, 0, num_periods - 1)
		(scores[team_id] as Array)[period_idx] += 1
	return scores


# Recount goals + assists from the event stream up to the current clock and
# write them onto each record's PlayerStats. Idempotent — fully recomputed each
# call so scrubbing backward decrements correctly. Goal events carry only
# display names (no peer id), so credit by matching record.display_name().
func _refresh_event_stats() -> void:
	var by_name: Dictionary = {}  # display_name → PlayerStats
	for record: PlayerRecord in _records.values():
		if record == null or record.stats == null:
			continue
		record.stats.goals = 0
		record.stats.assists = 0
		by_name[record.display_name()] = record.stats
	if _driver == null:
		return
	var clock: float = _driver.get_virtual_clock()
	for event: Dictionary in _driver.get_events():
		if event.host_ts > clock:
			continue
		var data: Dictionary = event.get("data", {}) as Dictionary
		if data.get("kind", "") != "goal":
			continue
		var scorer: String = str(data.get("scorer", ""))
		if by_name.has(scorer):
			(by_name[scorer] as PlayerStats).goals += 1
		for key: String in ["assist1", "assist2"]:
			var assister: String = str(data.get(key, ""))
			if not assister.is_empty() and by_name.has(assister):
				(by_name[assister] as PlayerStats).assists += 1


# Header may carry a num_periods field; default to the rules constant. Accepts
# int OR float (JSON decodes numbers as float).
func _scoreboard_num_periods(header: Dictionary) -> int:
	var raw: Variant = header.get("num_periods", GameRules.NUM_PERIODS)
	if raw is int or raw is float:
		return maxi(1, int(raw))
	return GameRules.NUM_PERIODS


# ── Stub interface for RemoteController.setup(skater, puck, game_state) ─────
# Controllers early-return on NetworkManager.is_replay_mode(), so these are
# only consulted on the rare paths that don't gate (e.g. ghost flag updates).
# Reporting host=false / movement_locked=true keeps them inert.

func is_host() -> bool:
	return false


func is_movement_locked() -> bool:
	return true


# Recorded phase, updated from the driver's game_state_changed as frames
# apply (seeks included — a paused scrub re-applies the frame). The gait's
# faceoff ready-stance polls this through the game_state interface, exactly
# as it polls GameManager in live play.
func is_faceoff_prep() -> bool:
	return _replay_phase == GamePhase.Phase.FACEOFF_PREP


# Replay never wants stick wiggle — the recorded skater poses own the blade.
func allows_blade_aim_during_lock() -> bool:
	return false


func is_input_blocked() -> bool:
	return true


# ── Public accessors for the upcoming HUD ────────────────────────────────────

func get_driver() -> FileReplayDriver:
	return _driver

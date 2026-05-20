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
#   - No Camera3D (SpectatorCamera is mounted at runtime)
#   - No HUD (added in a follow-up commit)

var _spawner: ActorSpawner = null
var _puck: Puck = null
var _puck_controller: PuckController = null
var _goalie_controllers: Array[GoalieController] = []
var _records: Dictionary = {}  # peer_id → PlayerRecord
var _codec: WorldStateCodec = null
var _driver: FileReplayDriver = null
var _camera: SpectatorCamera = null
var _hud: ReplayViewerHUD = null
# Cached so the player_joined event handler can spawn mid-game arrivals
# without re-deriving them from header.
var _home_color_slot: int = TeamColorRegistry.DEFAULT_HOME_SLOT
var _away_color_slot: int = TeamColorRegistry.DEFAULT_AWAY_SLOT
var _home_colors: Dictionary = {}
var _away_colors: Dictionary = {}
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

	_spawner = ActorSpawner.new()
	_spawner.setup(self)
	_spawn_actors_from_header(read_result.header)
	_mount_camera()
	_start_playback(read_result.frames)
	_mount_hud(read_result.header)


func _exit_tree() -> void:
	# Restore the global flag so a subsequent live game / lobby session works.
	NetworkManager.stop_replay_mode()


# ── Setup ────────────────────────────────────────────────────────────────────

func _spawn_actors_from_header(header: Dictionary) -> void:
	var puck_result: Dictionary = _spawner.spawn_puck_with_controller(false)
	_puck = puck_result.puck
	_puck_controller = puck_result.controller
	# RigidBody freeze prevents physics drift between FileReplayDriver writes.
	# PuckController would otherwise run client-side prediction every tick.
	_puck.freeze = true
	_puck_controller.set_physics_process(false)

	var goalie_result: Dictionary = _spawner.spawn_goalie_pair(_puck, false)
	_goalie_controllers = [goalie_result.bottom_controller, goalie_result.top_controller]
	_goalie_controllers[0].team_id = 0
	_goalie_controllers[1].team_id = 1
	for gc: GoalieController in _goalie_controllers:
		gc.set_physics_process(false)

	# Replay headers carry int slot indices. Legacy fruit-name strings in old
	# .mreplay files won't typecheck — fall back to defaults and warn rather
	# than crash. Hard break: no string→slot mapping.
	var raw_home: Variant = header.get("home_color_slot", TeamColorRegistry.DEFAULT_HOME_SLOT)
	var raw_away: Variant = header.get("away_color_slot", TeamColorRegistry.DEFAULT_AWAY_SLOT)
	if raw_home is int:
		_home_color_slot = raw_home
	else:
		push_warning("ReplayViewer: legacy color id in header, using default home")
		_home_color_slot = TeamColorRegistry.DEFAULT_HOME_SLOT
	if raw_away is int:
		_away_color_slot = raw_away
	else:
		push_warning("ReplayViewer: legacy color id in header, using default away")
		_away_color_slot = TeamColorRegistry.DEFAULT_AWAY_SLOT
	_home_colors = TeamColorRegistry.get_colors(_home_color_slot, 0)
	_away_colors = TeamColorRegistry.get_colors(_away_color_slot, 1)
	goalie_result.bottom_goalie.set_goalie_color(_home_colors.jersey, _home_colors.helmet, _home_colors.goalie_pads)
	goalie_result.top_goalie.set_goalie_color(_away_colors.jersey, _away_colors.helmet, _away_colors.goalie_pads)

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
	var spawned: Dictionary = _spawner.spawn_remote_player(
			PlayerRules.faceoff_position(team_id, team_slot),
			team_colors.jersey, team_colors.helmet, team_colors.pants,
			team_colors.socks, team_colors.primary,
			is_left, _puck, self)
	var skater: Skater = spawned.skater
	var controller: RemoteController = spawned.controller
	# Skater._physics_process calls move_and_slide each tick using whatever
	# velocity apply_replay_state set last. When the viewer is paused, the
	# replay engine isn't running so velocity isn't refreshed — the skater
	# coasts on its stale velocity until unpause snaps it back. Disable
	# physics processing entirely; apply_replay_state covers all visual
	# updates (position, blade, IK) on its own.
	skater.set_physics_process(false)
	skater.set_player_name(p_name)
	skater.set_jersey_info(p_name, jersey_number, team_colors.text)
	skater.set_jersey_stripes(team_colors.jersey_stripe, team_colors.pants_stripe, team_colors.socks_stripe)

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


func _mount_camera() -> void:
	_camera = SpectatorCamera.new()
	add_child(_camera)
	_camera.setup(func() -> Vector3:
		return _puck.global_position if _puck != null else Vector3.ZERO)
	_camera.activate()


func _start_playback(frames: Array) -> void:
	_codec = WorldStateCodec.new()
	# decode_for_replay only walks the packet bytes — it doesn't reach into
	# the codec's other collaborators, so the no-setup() codec is fine here.
	_driver = FileReplayDriver.new()
	add_child(_driver)
	_driver.setup(_codec, _records, _puck, _goalie_controllers, frames)
	_driver.event_emitted.connect(_on_replay_event)
	_driver.roster_rebuild_requested.connect(_on_roster_rebuild)
	_driver.play()


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
	_hud.setup(_driver, header)


# ── Stub interface for RemoteController.setup(skater, puck, game_state) ─────
# Controllers early-return on NetworkManager.is_replay_mode(), so these are
# only consulted on the rare paths that don't gate (e.g. ghost flag updates).
# Reporting host=false / movement_locked=true keeps them inert.

func is_host() -> bool:
	return false


func is_movement_locked() -> bool:
	return true


# Replay never wants stick wiggle — the recorded skater poses own the blade.
func allows_blade_aim_during_lock() -> bool:
	return false


func is_input_blocked() -> bool:
	return true


# ── Public accessors for the upcoming HUD ────────────────────────────────────

func get_driver() -> FileReplayDriver:
	return _driver

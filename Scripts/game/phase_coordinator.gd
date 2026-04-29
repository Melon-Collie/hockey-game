class_name PhaseCoordinator
extends RefCounted

# Owns all side effects that fire on phase transitions. Pulled out of
# GameManager because the phase-entry flow (puck lock/unlock/reset, goalie
# reset, faceoff teleport, goal scoring) is one coherent piece of game logic
# that reads better in its own file.
#
# Host vs client:
#   - handle_phase_entered()   : host-side, called after GameStateMachine.tick
#                                transitions (puck reset, faceoff, game-over)
#   - on_goal_scored_into()    : host-side, fired by the goal sensor
#   - on_goal_received()       : clients apply the authoritative goal RPC
#   - on_faceoff_positions()   : clients teleport to their new faceoff slot
#
# Collaborators talk back via signals (`phase_changed`, `goal_scored`, etc.)
# and via three injected Callables for puck drop / goal broadcast / faceoff
# broadcast. Nothing in here reaches into NetworkManager directly.

signal goal_scored(scoring_team: Team, scorer_name: String, assist1_name: String, assist2_name: String)
signal score_changed(score_0: int, score_1: int)
signal phase_changed(new_phase: GamePhase.Phase)
signal period_changed(new_period: int)
signal clock_updated(time_remaining: float)
signal game_over
signal stats_need_sync
signal faceoff_positions_ready(positions: Array)  # host → broadcast to clients
signal goal_broadcast_needed(
		scoring_team_id: int, score0: int, score1: int,
		scorer_name: String, assist1_name: String, assist2_name: String)
signal replay_started
signal replay_stopped

var _state_machine: GameStateMachine = null
var _registry: PlayerRegistry = null
var _teams: Array[Team] = []
var _puck_getter: Callable = Callable()
var _goalie_controllers_getter: Callable = Callable()
var _shot_tracker: ShotOnGoalTracker = null
# Drops a carried puck (host-only). Returns carrier peer_id or -1.
var _puck_drop_requester: Callable = Callable()
# Tells the host that a player has a pending shot (shot → timer arm).
# Used for the shot-on-goal tracker's `on_shot_started` event from inside the
# goal path; we pass it as a Callable rather than a direct tracker call so
# the caller stays in control of the "is this actually a shot" logic.

# Goal-replay cinematic. GameManager owns the Node lifecycle (add_child /
# queue_free); PhaseCoordinator drives start/stop and wires the signals.
# All three are null in offline / tutorial sessions.
var _recorder: ReplayRecorder = null
var _goal_replay_driver: GoalReplayDriver = null
var _codec: WorldStateCodec = null
var _scene_tree: SceneTree = null
# Host-only callable: captures the goal-moment world-state frame into the
# in-memory recorder immediately on goal detection, filling the up-to-25 ms
# gap since the last broadcast. Clients leave this as Callable() (invalid).
var _force_record_goal_frame: Callable = Callable()

# Seconds to keep recording after goal fires so the clip includes puck-in-net
# and the shooter's follow-through. Must stay well under
# GameStateMachine.GOAL_PAUSE_DURATION (2.0 s).
const POST_GOAL_CAPTURE_WINDOW: float = 0.5


func setup(
		state_machine: GameStateMachine,
		registry: PlayerRegistry,
		teams: Array[Team],
		puck_getter: Callable,
		goalie_controllers_getter: Callable,
		shot_tracker: ShotOnGoalTracker,
		puck_drop_requester: Callable,
		recorder: ReplayRecorder,
		goal_replay_driver: GoalReplayDriver,
		codec: WorldStateCodec,
		scene_tree: SceneTree,
		is_host: bool,
		force_record_goal_frame: Callable) -> void:
	_state_machine = state_machine
	_registry = registry
	_teams = teams
	_puck_getter = puck_getter
	_goalie_controllers_getter = goalie_controllers_getter
	_shot_tracker = shot_tracker
	_puck_drop_requester = puck_drop_requester
	_recorder = recorder
	_goal_replay_driver = goal_replay_driver
	_codec = codec
	_scene_tree = scene_tree
	_force_record_goal_frame = force_record_goal_frame
	if _goal_replay_driver != null:
		_goal_replay_driver.replay_started.connect(replay_started.emit)
		_goal_replay_driver.replay_stopped.connect(replay_stopped.emit)
		if is_host:
			_goal_replay_driver.replay_stopped.connect(_on_goal_replay_stopped)


# ── Host: phase transitions ──────────────────────────────────────────────────

func handle_phase_entered() -> void:
	var puck: Puck = _get_puck()
	match _state_machine.current_phase:
		GamePhase.Phase.FACEOFF_PREP:
			if _goal_replay_driver != null:
				_goal_replay_driver.stop()
			period_changed.emit(_state_machine.current_period)
			clock_updated.emit(_state_machine.time_remaining)
			stats_need_sync.emit()
			_enter_faceoff_prep(puck)
		GamePhase.Phase.FACEOFF:
			_enter_faceoff(puck)
		GamePhase.Phase.PLAYING:
			# Transition from FACEOFF timeout — unlock puck.
			if puck != null:
				puck.pickup_locked = false
		GamePhase.Phase.END_OF_PERIOD:
			_puck_drop_requester.call()
			if puck != null:
				puck.pickup_locked = true
			clock_updated.emit(0.0)
		GamePhase.Phase.GAME_OVER:
			_puck_drop_requester.call()
			if puck != null:
				puck.pickup_locked = true
			clock_updated.emit(0.0)
			game_over.emit()
	phase_changed.emit(_state_machine.current_phase)


func _enter_faceoff_prep(puck: Puck) -> void:
	if puck != null:
		puck.reset()
		puck.pickup_locked = true
	for gc: GoalieController in _goalie_controllers_getter.call():
		gc.reset_to_crease()
	var positions: Array = []
	for peer_id: int in _registry.all():
		var record: PlayerRecord = _registry.get_record(peer_id)
		var pos: Vector3 = PlayerRules.faceoff_position(record.team.team_id, record.team_slot)
		record.faceoff_position = pos
		record.controller.teleport_to(pos)
		positions.append_array([peer_id, pos.x, pos.y, pos.z])
	faceoff_positions_ready.emit(positions)


func _enter_faceoff(puck: Puck) -> void:
	if puck == null:
		return
	puck.pickup_locked = false


func on_pickup(_peer_id: int) -> void:
	if _state_machine.on_faceoff_puck_picked_up():
		phase_changed.emit(_state_machine.current_phase)


# ── Host: goal scoring pipeline ──────────────────────────────────────────────

func on_goal_scored_into(defending_team: Team) -> void:
	var carrier_peer_id: int = _puck_drop_requester.call()
	var scoring_team_id: int = _state_machine.on_goal_scored(defending_team.team_id)
	if scoring_team_id == -1:
		return  # wrong phase, ignored

	var scorer_name: String = ""
	var assist1_name: String = ""
	var assist2_name: String = ""
	var raw_scorer_id: int = carrier_peer_id if carrier_peer_id != -1 \
			else _shot_tracker.get_last_toucher()
	var is_own_goal: bool = _is_own_goal(raw_scorer_id, defending_team.team_id)
	var scorer_id: int = raw_scorer_id
	if is_own_goal:
		scorer_id = _shot_tracker.find_scorer_on_team(scoring_team_id)

	if scorer_id != -1:
		var record: PlayerRecord = _registry.get_record(scorer_id)
		if record != null:
			record.stats.goals += 1
			var assist_names: Array[String] = _shot_tracker.credit_assists(scorer_id)
			assist1_name = assist_names[0] if assist_names.size() > 0 else ""
			assist2_name = assist_names[1] if assist_names.size() > 1 else ""
			if not is_own_goal:
				_shot_tracker.on_goal_confirmed(scorer_id)
			scorer_name = record.display_name()
	_shot_tracker.clear_pending()
	stats_need_sync.emit()

	var puck: Puck = _get_puck()
	if puck != null:
		puck.pickup_locked = true
	if defending_team.defended_goal != null and defending_team.defended_goal.vfx != null:
		defending_team.defended_goal.vfx.celebrate()
	goal_scored.emit(_teams[scoring_team_id], scorer_name, assist1_name, assist2_name)
	score_changed.emit(_state_machine.scores[0], _state_machine.scores[1])
	phase_changed.emit(_state_machine.current_phase)
	goal_broadcast_needed.emit(
			scoring_team_id, _state_machine.scores[0], _state_machine.scores[1],
			scorer_name, assist1_name, assist2_name)
	_on_goal_for_replay()


func _is_own_goal(raw_scorer_id: int, defending_team_id: int) -> bool:
	if raw_scorer_id == -1:
		return false
	var record: PlayerRecord = _registry.get_record(raw_scorer_id)
	return record != null and record.team.team_id == defending_team_id


# ── Clients: receive authoritative events ────────────────────────────────────

func on_goal_received(
		scoring_team_id: int,
		score0: int, score1: int,
		scorer_name: String, assist1_name: String, assist2_name: String) -> void:
	_state_machine.apply_remote_goal(scoring_team_id, score0, score1)
	var puck: Puck = _get_puck()
	if puck != null:
		puck.pickup_locked = true
	goal_scored.emit(_teams[scoring_team_id], scorer_name, assist1_name, assist2_name)
	var defended_goal: HockeyGoal = _teams[1 - scoring_team_id].defended_goal
	if defended_goal != null and defended_goal.vfx != null:
		defended_goal.vfx.celebrate()
	score_changed.emit(_state_machine.scores[0], _state_machine.scores[1])
	phase_changed.emit(_state_machine.current_phase)
	_on_goal_for_replay()


func on_faceoff_positions(positions: Array) -> void:
	var local_peer_id: int = _registry.get_local().peer_id if _registry.get_local() != null else -1
	var i: int = 0
	while i < positions.size():
		var peer_id: int = positions[i]
		var pos := Vector3(positions[i + 1], positions[i + 2], positions[i + 3])
		i += 4
		if peer_id == local_peer_id and _registry.has(peer_id):
			_registry.get_record(peer_id).controller.teleport_to(pos)


# ── Internal ──────────────────────────────────────────────────────────────────

func _get_puck() -> Puck:
	if not _puck_getter.is_valid():
		return null
	return _puck_getter.call() as Puck


# ── Goal replay cinematic ─────────────────────────────────────────────────────

# Null _state_machine so _on_goal_replay_stopped's guard catches any late
# replay_stopped signal that fires during scene teardown.
func cleanup() -> void:
	_state_machine = null


func _on_goal_for_replay() -> void:
	if _recorder == null or _goal_replay_driver == null or _codec == null:
		return
	if _force_record_goal_frame.is_valid():
		_force_record_goal_frame.call()
	if _scene_tree != null:
		_scene_tree.create_timer(POST_GOAL_CAPTURE_WINDOW).timeout.connect(_start_goal_replay)


func _start_goal_replay() -> void:
	if _recorder == null or _goal_replay_driver == null or _codec == null:
		return
	_goal_replay_driver.start(_recorder, _codec, _registry,
			_puck_getter.call() as Puck, _goalie_controllers_getter.call())


# Host-only: advance state machine once the cinematic finishes naturally.
func _on_goal_replay_stopped() -> void:
	if _state_machine == null or _state_machine.current_phase != GamePhase.Phase.GOAL_SCORED:
		return
	_state_machine.advance_post_goal()
	handle_phase_entered()

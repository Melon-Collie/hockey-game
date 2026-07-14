extends Node

# Offline passing drill: "how many can you complete out of 10". Spawned by
# game_scene.gd via DrillRegistry when NetworkManager.drill_id selects it. Owns
# the whole loop — stage a pass scenario (a teammate somewhere new, often
# skating a route), hand the player the puck, wait for the pass, credit it when
# the puck lands on the teammate's blade, tally it, and restage — finishing with
# a results card.
#
# Modelled on ShotAccuracyManager's lifecycle (single local player + puck, a
# code-built HUD, flash-then-restage, DrillSession tally) and the tutorial's
# Passing module (a puppet teammate whose blade chases a loose pass so a
# rough-but-honest lead still gets corralled). PassingDrillRules owns the
# scenario catalogue and the no-repeat sequencing; this node owns the staging,
# puppet motion, saucer wall, and completion detection.

# Team 0 attacks -Z, so every lane runs toward -Z (passer up-ice of receiver).
const _ICE_Y: float = 0.05
const _TOTAL_PASSES: int = 10

# How far in front of the player the handed-back puck is staged. Skating onto it
# runs the NORMAL proximity-pickup path (a bare set_carrier bypasses
# PuckController's bookkeeping — see the tutorial's _stage_puck_for_player).
const _STAGE_PUCK_AHEAD: float = 1.2

# Saucer board: a knee-high box across the lane, this far ahead of the passer —
# INSIDE the LOW saucer's airborne span but with runway for it to have climbed
# past board height (~0.12 m by ~1 m out). Wall scenarios use straight lanes so
# this axis-aligned board squarely blocks a flat pass. Deep receiver gives the
# saucer room to land and slide in grounded (see PassingDrillRules).
const _WALL_AHEAD: float = 4.0
const _WALL_SIZE: Vector3 = Vector3(2.4, 0.12, 0.08)

# Receiver patrol: a moving teammate skates his route end to end until the pass
# is thrown, so he stays a live moving target. This is the arrival radius at
# which he turns and skates back (a touch wider than the AI's own 0.5 m arrival
# so the flip reads as a smooth change of direction, not a stop).
const _PATROL_FLIP_RADIUS: float = 1.2

# In-flight pass resolution — the same clocks as the tutorial's passing drills.
const _PASS_START_GRACE: float = 0.35  # s after release before the dead-pass rules arm
const _PASS_REST_SPEED: float  = 0.5   # m/s below which a loose pass is stopped
const _PASS_STALL_GRACE: float = 0.4   # s stopped before the pass is called dead
const _PASS_MISS_MARGIN: float = 1.5   # m past the receiver, receding = missed
const _MAX_PASS_TIME: float    = 4.0   # s safety cap — retire a wedged pass no matter what
# Long per-skater pickup cooldown applied at release so the passer can't chase
# their own pass down and re-collect it. Lifted at restage.
const _PICKUP_LOCK_S: float = 999.0

# How long the COMPLETE! / MISSED flash holds before the next scenario stages.
const _RESULT_HOLD: float = 1.4

enum Stage { LIVE, RESULT, DONE }

var _local_record: PlayerRecord = null
var _local_controller: LocalController = null
var _skater: Skater = null
var _puck: Puck = null
var _hud: PassingDrillHUD = null
var _wall_node: TutorialWall = null

# The teammate puppet (team 0), spawned once and repositioned per attempt.
var _puppet_record: PlayerRecord = null

var _session: DrillSession = null
# Untyped container (a typed array of an inner class isn't used anywhere in the
# codebase); elements are cast to PassScenario at access, so typing stays strong
# where it's read.
var _scenarios: Array = []
var _scenario_index: int = -1
var _scenario: PassingDrillRules.PassScenario = null

var _stage: Stage = Stage.LIVE
var _result_timer: float = 0.0

# Receiver patrol state (moving scenarios only).
var _route_a: Vector2 = Vector2.ZERO
var _route_b: Vector2 = Vector2.ZERO
var _route_to_b: bool = true

# Pass-in-flight accumulators (see the tutorial's passing drills for why a
# release is watched for a dead/past/timeout miss rather than trusted to land).
var _pass_live: bool = false
var _pass_air_time: float = 0.0
var _pass_stall_time: float = 0.0
var _on_pass_callable: Callable = Callable()


func _ready() -> void:
	_local_record = GameManager.get_local_player()
	if _local_record == null:
		push_error("PassingDrillManager: no local player found")
		return
	_local_controller = _local_record.controller as LocalController
	_skater = _local_record.skater
	_puck = GameManager.get_puck()

	_session = DrillSession.new(_TOTAL_PASSES)
	_scenarios = PassingDrillRules.scenarios()

	# A teammate puppet on team 0 — spawned once here, repositioned each attempt.
	# Placed off-rink initially; _begin_attempt moves it to the scenario spot.
	_puppet_record = GameManager.spawn_tutorial_bot(Vector3(0.0, 1.0, 0.0), 0, 0)

	_hud = PassingDrillHUD.new()
	add_child(_hud)
	_hud.retry_pressed.connect(_on_retry)
	_hud.exit_pressed.connect(_on_exit)

	# Any release from carry is the pass — the drill is about the read and the
	# lead, so quick snap, wrister, or saucer all count as the attempt.
	_on_pass_callable = func(_dir: Vector3, _power: float, _is_slapper: bool) -> void:
		_on_pass_released()
	_local_controller.puck_release_requested.connect(_on_pass_callable)

	_begin_attempt()


func _exit_tree() -> void:
	# Mirror the other drills: tear down what this manager owns on the way out
	# (covers the scene change from return_to_free_play, which frees this subtree).
	if _local_controller != null and _on_pass_callable.is_valid() \
			and _local_controller.puck_release_requested.is_connected(_on_pass_callable):
		_local_controller.puck_release_requested.disconnect(_on_pass_callable)
	_clear_wall()
	if _puppet_record != null:
		GameManager.despawn_tutorial_bot(_puppet_record)
		_puppet_record = null


# ── Attempt lifecycle ─────────────────────────────────────────────────────────

func _begin_attempt() -> void:
	_stage = Stage.LIVE
	_pass_live = false
	_pass_air_time = 0.0
	_pass_stall_time = 0.0

	_scenario_index = PassingDrillRules.pick_next(_scenario_index, randi(), _scenarios.size())
	_scenario = _scenarios[_scenario_index] as PassingDrillRules.PassScenario

	# Stand the player at the passer spot facing the teammate, put the puck on
	# their stick, and stage the teammate (skating his route if it's a moving rep).
	var lane_dir: Vector2 = (_scenario.receiver - _scenario.passer)
	var face: Vector2 = lane_dir.normalized() if lane_dir.length() > 0.01 else Vector2(0.0, -1.0)
	_local_controller.teleport_to(_to_world(_scenario.passer), face)
	_stage_puppet()
	_stage_wall()
	_stage_puck_for_player()

	_hud.set_progress(_session.current_attempt_number(), _session.total_attempts, _session.makes)
	_hud.set_scenario(_scenario.title)


func _resolve_attempt(made: bool) -> void:
	_session.record(made)
	_stage = Stage.RESULT
	_pass_live = false
	_result_timer = _RESULT_HOLD
	# Leave the puck where the attempt ended so the player SEES the result during
	# the hold; pickup stays locked (from release) so a settling puck can't be
	# re-collected before the next scenario stages.
	_puck.set_skater_cooldown(_skater, _RESULT_HOLD + 1.0)
	_hud.flash_result(made, _session.makes, _session.attempts_taken)
	if made:
		SoundManager.play_ui(SoundManager.Sound.UI_CLICK)
	else:
		SoundManager.play_crowd(SoundManager.Sound.FACEOFF_WHISTLE)


func _advance() -> void:
	if _session.is_complete():
		_stage = Stage.DONE
		_clear_wall()
		_hud.show_results(_session.makes, _session.total_attempts)
	else:
		_begin_attempt()


# ── Per-tick detection ────────────────────────────────────────────────────────

func _physics_process(delta: float) -> void:
	if _local_record == null or _skater == null or not is_instance_valid(_puck):
		return
	match _stage:
		Stage.RESULT:
			_result_timer -= delta
			if _result_timer <= 0.0:
				_advance()
		Stage.LIVE:
			_tick_live(delta)
		Stage.DONE:
			pass


func _tick_live(delta: float) -> void:
	_drive_puppet()

	if not _pass_live:
		return

	# Teammate came up with it — a completed pass, however he corralled it.
	if _puppet_record != null and is_instance_valid(_puppet_record.skater) \
			and _puck.carrier == _puppet_record.skater:
		_resolve_attempt(true)
		return

	# Watch the loose pass for a dead / past / timed-out miss.
	_pass_air_time += delta
	if _pass_air_time < _PASS_START_GRACE:
		return
	if _pass_air_time >= _MAX_PASS_TIME:
		_resolve_attempt(false)
		return
	if _puck.carrier != null:
		return  # a bobble settling on someone's blade this tick — not resolved yet

	var puck_pos: Vector3 = _puck.get_puck_position()
	var puck_vel: Vector3 = _puck.get_puck_velocity()
	# Dead slow: the pass has stopped making progress. Arm the stall clock.
	if puck_vel.length() <= _PASS_REST_SPEED:
		_pass_stall_time += delta
	else:
		_pass_stall_time = 0.0
	if _pass_stall_time >= _PASS_STALL_GRACE:
		_resolve_attempt(false)
		return
	# Slid past the receiver and receding: an incoming pass always closes on him,
	# so a puck beyond him and moving away is a clean miss. Uses his LIVE position
	# (he may still be skating his route).
	if _puppet_record != null and is_instance_valid(_puppet_record.skater):
		var recv_pos: Vector3 = _puppet_record.skater.global_position
		var to_recv := Vector3(recv_pos.x - puck_pos.x, 0.0, recv_pos.z - puck_pos.z)
		if to_recv.length() > _PASS_MISS_MARGIN and puck_vel.dot(to_recv) < 0.0:
			_resolve_attempt(false)


# Drives the teammate puppet each tick: patrol his route until the pass is
# thrown (so he stays a moving target the player has to lead), and present his
# blade — at the loose puck once a pass is in flight so a rough lead still gets
# corralled, otherwise back at the passer as a target.
func _drive_puppet() -> void:
	if _puppet_record == null or not is_instance_valid(_puppet_record.skater):
		return
	var ai_ctrl: AIController = _puppet_record.controller as AIController
	if ai_ctrl == null:
		return

	# Patrol: flip the route endpoint on arrival, but freeze targeting once the
	# pass is away so the lead the player read stays valid through the flight.
	if _scenario != null and _scenario.receiver_moves() and not _pass_live:
		var here := Vector2(_puppet_record.skater.global_position.x,
				_puppet_record.skater.global_position.z)
		var cur: Vector2 = _route_b if _route_to_b else _route_a
		if here.distance_to(cur) <= _PATROL_FLIP_RADIUS:
			_route_to_b = not _route_to_b
			ai_ctrl.script_move_to(_to_world(_route_b if _route_to_b else _route_a))

	ai_ctrl.script_aim_at(_puck.get_puck_position() if _puck.carrier == null
			else _skater.global_position)


# Arms the in-flight watch on any release and locks the passer from re-pickup
# until the attempt resolves — so mashing the pass button can't re-collect the
# puck and keep possession.
func _on_pass_released() -> void:
	if _stage != Stage.LIVE or _pass_live:
		return
	_pass_live = true
	_pass_air_time = 0.0
	_pass_stall_time = 0.0
	_puck.set_skater_cooldown(_skater, _PICKUP_LOCK_S)


# ── HUD handlers ──────────────────────────────────────────────────────────────

func _on_retry() -> void:
	_session.restart()
	_hud.hide_results()
	_begin_attempt()


func _on_exit() -> void:
	_stage = Stage.DONE
	NetworkManager.drill_id = ""
	GameManager.return_to_free_play()


# ── Staging helpers ───────────────────────────────────────────────────────────

# On-ice (x, z) → world Vector3 at the standard spawn height.
func _to_world(spot: Vector2) -> Vector3:
	return Vector3(spot.x, 1.0, spot.y)


# Repositions the teammate at the scenario's receiver spot, faces him back at
# the passer, and starts his route (skating to the endpoint for a moving rep,
# holding otherwise). Mirrors the tutorial's _ensure_puppet reposition branch.
func _stage_puppet() -> void:
	if _puppet_record == null or not is_instance_valid(_puppet_record.skater):
		return
	_puppet_record.skater.global_position = _to_world(_scenario.receiver)
	var to_passer := (_scenario.passer - _scenario.receiver)
	if to_passer.length() > 0.01:
		# Through the controller so both facing stores update (see the tutorial's
		# _ensure_puppet — setting only the skater desyncs the pose facing).
		_puppet_record.controller.set_spawn_facing(to_passer.normalized())
	var ai_ctrl: AIController = _puppet_record.controller as AIController
	if ai_ctrl == null:
		return
	_route_a = _scenario.receiver
	_route_b = _scenario.receiver_target
	_route_to_b = true
	if _scenario.receiver_moves():
		ai_ctrl.script_move_to(_to_world(_route_b))
	else:
		ai_ctrl.script_hold()
	ai_ctrl.script_aim_at(_skater.global_position)


# Drops (or clears) the saucer board for the current scenario, a few strides
# ahead of the passer along the lane.
func _stage_wall() -> void:
	if _scenario == null or not _scenario.wall:
		_clear_wall()
		return
	var lane_dir: Vector2 = (_scenario.receiver - _scenario.passer).normalized()
	var center: Vector2 = _scenario.passer + lane_dir * _WALL_AHEAD
	if _wall_node == null or not is_instance_valid(_wall_node):
		_wall_node = TutorialWall.new()
		add_child(_wall_node)
	_wall_node.show_wall(Vector3(center.x, 0.0, center.y), _WALL_SIZE)


func _clear_wall() -> void:
	if _wall_node != null and is_instance_valid(_wall_node):
		_wall_node.clear()


# Stages the puck a stride in front of the freshly-teleported player, lifting the
# pickup lock left from the previous attempt so it can be collected normally.
# Every lane faces -Z, so ahead = -Z. Never hand the puck to a stick from here (a
# bare set_carrier bypasses PuckController's bookkeeping — see the tutorial).
func _stage_puck_for_player() -> void:
	_puck.remove_skater_cooldown(_skater)
	if _puck.carrier != null:
		_puck.drop()
	_puck.set_puck_position(Vector3(_skater.global_position.x, _ICE_Y,
			_skater.global_position.z - _STAGE_PUCK_AHEAD))
	_puck.linear_velocity = Vector3.ZERO

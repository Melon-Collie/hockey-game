extends Node

# Offline shot-accuracy drill: "how many targets can you hit out of 10".
# Spawned by game_scene.gd via DrillRegistry when NetworkManager.drill_id
# selects it.
# Each attempt stages the shooter in the slot with the puck a stride ahead and
# lights ONE random bullseye from AccuracyDrillRules' pool — the four corners,
# the five-hole, or the mid-side holes a LOW-loft saucer reaches. The released
# shot is watched with the Shooting tutorial's in-flight rules: credit lands
# when the puck reaches the net plane on the bullseye (rough aim rewarded, no
# clean goal required), anything else — wide, dead, or a rebound — is a miss.
#
# A combination of the Shooting tutorial's target plumbing (TutorialTargets
# bullseyes + TutorialShotRules detection + the same frozen open-stance
# goalie) and the penalty drill's lifecycle shape (DrillSession tally, a
# code-built HUD, flash-then-restage, results card).

const _ATTACK_DIR_Z: float = -1.0
const _GOAL_PLANE_Z: float = -GameRules.GOAL_LINE_Z
const _ICE_Y: float = 0.05
const _TOTAL_SHOTS: int = 10

# Targets float just in front of the net mesh, same as the tutorial drill.
const _TARGET_FRONT_OFFSET: float = 0.10

# Shooter staging: in the slot, SLOT_DIST_M out from the attacked net, facing
# it, with the puck a stride ahead so collecting it runs the NORMAL proximity-
# pickup path (a bare set_carrier bypasses PuckController's bookkeeping — see
# TutorialManager._stage_puck_for_player for the history).
const _FACE_NET: Vector2 = Vector2(0.0, -1.0)
const _STAGE_PUCK_AHEAD: float = 1.2

# In-flight shot resolution — the same clocks as the Shooting tutorial's
# drills. A shot is retired the instant it passes the net plane (hit or miss)
# OR goes dead: stops advancing, rebounds back past _SHOT_BACKWARD_TOL, or
# wedges past the safety cap.
const _SHOT_REST_SPEED: float = 0.5   # m/s of forward progress that counts as stopped
const _SHOT_STALL_GRACE: float = 0.4  # s stopped before the shot is called dead
const _SHOT_START_GRACE: float = 0.35 # s after release before the dead-puck rules arm
const _SHOT_BACKWARD_TOL: float = 0.75 # m of retreat from the furthest point = rebound, dead
const _SHOT_MAX_TIME: float = 3.0     # s safety cap — retire a wedged shot no matter what
# Long per-skater pickup cooldown applied at release so the loose puck can't be
# re-collected mid-flight or during the result hold. Lifted at restage.
const _PICKUP_LOCK_S: float = 999.0

# How long the HIT! / MISS flash holds before the next target is staged.
const _RESULT_HOLD: float = 1.4

enum Stage { AIMING, IN_FLIGHT, RESULT, DONE }

var _local_record: PlayerRecord = null
var _local_controller: LocalController = null
var _skater: Skater = null
var _puck: Puck = null
var _hud: ShotAccuracyHUD = null
var _target_node: TutorialTargets = null

var _session: DrillSession = null
var _stage: Stage = Stage.AIMING
var _result_timer: float = 0.0
var _target_index: int = -1
# Single-element scratch array for TutorialTargets/TutorialShotRules, reused
# across attempts so the per-attempt staging never re-allocates it.
var _lit: Array[Vector2] = [Vector2.ZERO]

# Shot-in-flight accumulators (see TutorialManager's shooting drills for why
# forward speed is derived from progress deltas, not rigidbody velocity).
var _shot_start_z: float = 0.0
var _shot_last_progress: float = 0.0
var _shot_max_progress: float = 0.0
var _shot_stall_time: float = 0.0
var _shot_air_time: float = 0.0
var _on_shot_callable: Callable = Callable()


func _ready() -> void:
	_local_record = GameManager.get_local_player()
	if _local_record == null:
		push_error("ShotAccuracyManager: no local player found")
		return
	_local_controller = _local_record.controller as LocalController
	_skater = _local_record.skater
	_puck = GameManager.get_puck()

	_session = DrillSession.new(_TOTAL_SHOTS)

	# Frozen open-stance goalie in the net, same as the tutorial's target
	# drill — the corners / five-hole / sides read as the holes he leaves.
	GameManager.spawn_tutorial_goalie()

	_target_node = TutorialTargets.new()
	add_child(_target_node)

	_hud = ShotAccuracyHUD.new()
	add_child(_hud)
	_hud.retry_pressed.connect(_on_retry)
	_hud.exit_pressed.connect(_on_exit)

	# Any release (quick shot, wrister, slapper) arms the in-flight watch —
	# picking the right tool for the called spot is the whole drill.
	_on_shot_callable = func(_dir: Vector3, _power: float, _is_slapper: bool) -> void:
		_on_shot_released()
	_local_controller.puck_release_requested.connect(_on_shot_callable)

	_begin_attempt()


func _exit_tree() -> void:
	# Mirror the penalty drill: the manager owns the lone goalie, so tear it
	# down on the way out (covers the scene change from return_to_free_play).
	GameManager.despawn_tutorial_goalie()
	if _local_controller != null and _on_shot_callable.is_valid() \
			and _local_controller.puck_release_requested.is_connected(_on_shot_callable):
		_local_controller.puck_release_requested.disconnect(_on_shot_callable)


# ── Attempt lifecycle ─────────────────────────────────────────────────────────

func _begin_attempt() -> void:
	_stage = Stage.AIMING
	_local_controller.teleport_to(Vector3(0.0, 1.0, _slot_z()), _FACE_NET)
	_stage_puck_for_player()
	_target_index = AccuracyDrillRules.pick_next(_target_index, randi())
	_lit[0] = AccuracyDrillRules.TARGET_POSITIONS[_target_index]
	_target_node.show_targets(_lit, _GOAL_PLANE_Z, _TARGET_FRONT_OFFSET)
	_hud.set_progress(_session.current_attempt_number(), _session.total_attempts,
			_session.makes)
	_hud.set_target(AccuracyDrillRules.TARGET_NAMES[_target_index])


func _resolve_attempt(hit: bool) -> void:
	_session.record(hit)
	_stage = Stage.RESULT
	_result_timer = _RESULT_HOLD
	if hit:
		# Pop the bullseye (positive feedback) — the puck is left in play so
		# the shooter sees it reach the net; pickup stays locked from release.
		_target_node.hide_target(0)
		SoundManager.play_ui(SoundManager.Sound.UI_CLICK)
	else:
		SoundManager.play_crowd(SoundManager.Sound.FACEOFF_WHISTLE)
	_hud.flash_result(hit, _session.makes, _session.attempts_taken)


func _advance() -> void:
	if _session.is_complete():
		_stage = Stage.DONE
		_target_node.clear()
		_hud.show_results(_session.makes, _session.total_attempts)
	else:
		_begin_attempt()


# ── Per-tick detection ────────────────────────────────────────────────────────

func _physics_process(delta: float) -> void:
	if _local_record == null or _skater == null or not is_instance_valid(_puck):
		return
	match _stage:
		Stage.IN_FLIGHT:
			_tick_shot(delta)
		Stage.RESULT:
			_result_timer -= delta
			if _result_timer <= 0.0:
				_advance()
		_:
			pass  # AIMING waits on the release signal; DONE waits on the HUD


# Arms the in-flight watch on any release and locks the puck from re-pickup
# until the attempt resolves and restages — mashing the shoot button can't
# re-collect a rebound and keep possession.
func _on_shot_released() -> void:
	if _stage != Stage.AIMING:
		return
	_stage = Stage.IN_FLIGHT
	_shot_start_z = _skater.global_position.z
	_shot_last_progress = 0.0
	_shot_max_progress = 0.0
	_shot_stall_time = 0.0
	_shot_air_time = 0.0
	_puck.set_skater_cooldown(_skater, _PICKUP_LOCK_S)


func _tick_shot(delta: float) -> void:
	if _puck.carrier != null:
		return  # release still settling on this tick

	var pos: Vector3 = _puck.get_puck_position()
	# Forward progress toward the net and its rate — the progress delta reads
	# negative on a rebound, which the rest test then trips immediately.
	var progress: float = (pos.z - _shot_start_z) * _ATTACK_DIR_Z
	var fwd_speed: float = (progress - _shot_last_progress) / delta if delta > 0.0 else 0.0
	_shot_last_progress = progress
	_shot_max_progress = maxf(_shot_max_progress, progress)
	_shot_air_time += delta
	# Only arm the dead-puck test after the release settles, so a shot still
	# leaving the blade isn't read as stalled on its first frames.
	if _shot_air_time < _SHOT_START_GRACE:
		_shot_stall_time = 0.0
	elif fwd_speed <= _SHOT_REST_SPEED:
		_shot_stall_time += delta
	else:
		_shot_stall_time = 0.0

	# The moment the puck reaches the net plane the attempt resolves: on the
	# lit bullseye (within tolerance) is a hit, anywhere else is a miss.
	if TutorialShotRules.crossed_goal_plane(pos.z, _GOAL_PLANE_Z, _ATTACK_DIR_Z):
		var idx: int = TutorialShotRules.nearest_target(
				pos.x, pos.y, _lit, AccuracyDrillRules.HIT_RADIUS)
		_resolve_attempt(idx >= 0)
		return
	# Rebound off the goalie: the puck retreats past its furthest point back
	# toward the shooter. Retire it promptly rather than waiting out the stall.
	if _shot_air_time >= _SHOT_START_GRACE \
			and progress < _shot_max_progress - _SHOT_BACKWARD_TOL:
		_resolve_attempt(false)
		return
	# Gone dead short of the net (stopped advancing).
	if TutorialShotRules.shot_missed(false, pos.z, _GOAL_PLANE_Z, _ATTACK_DIR_Z,
			fwd_speed, _SHOT_REST_SPEED, _shot_stall_time, _SHOT_STALL_GRACE):
		_resolve_attempt(false)
		return
	# Safety: a wedged puck that never resolves any other way.
	if _shot_air_time >= _SHOT_MAX_TIME:
		_resolve_attempt(false)


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

# Player's shooting spot: in the slot, SLOT_DIST_M out from the attacked net
# (team 0 attacks -Z) — the same spot as the tutorial's target drill.
func _slot_z() -> float:
	return -(GameRules.GOAL_LINE_Z - GameRules.SLOT_DIST_M)


# Stages the puck a stride ahead of the freshly-teleported shooter, lifting the
# pickup lock left from the previous attempt so it can be collected normally.
func _stage_puck_for_player() -> void:
	_puck.remove_skater_cooldown(_skater)
	if _puck.carrier != null:
		_puck.drop()
	_puck.set_puck_position(Vector3(_skater.global_position.x, _ICE_Y,
			_skater.global_position.z - _STAGE_PUCK_AHEAD))
	_puck.linear_velocity = Vector3.ZERO

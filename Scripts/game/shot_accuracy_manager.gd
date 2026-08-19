extends DrillLoop

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

const _GOAL_PLANE_Z: float = -GameRules.GOAL_LINE_Z
const _TOTAL_SHOTS: int = 10

# Targets float just in front of the net mesh, same as the tutorial drill.
const _TARGET_FRONT_OFFSET: float = 0.10

# The two clocks that are this drill's own — the shared release/stall/rest ones
# are DrillLoop's. A shot is retired the instant it passes the net plane (hit or
# miss) OR goes dead: stops advancing, rebounds back past the tolerance, or
# wedges past the safety cap.
const _SHOT_BACKWARD_TOL: float = 0.75 # m of retreat from the furthest point = rebound, dead
const _SHOT_MAX_TIME: float = 3.0     # s safety cap — retire a wedged shot no matter what

var _target_node: TutorialTargets = null
var _target_index: int = -1
# The shot is away. Inside Stage.LIVE, which is aiming until this latches.
var _shot_live: bool = false
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
	if not bind_local_player(_TOTAL_SHOTS):
		return

	# Frozen open-stance goalie in the net, same as the tutorial's target
	# drill — the corners / five-hole / sides read as the holes he leaves.
	GameManager.spawn_tutorial_goalie()

	_target_node = TutorialTargets.new()
	add_child(_target_node)

	mount_hud(ShotAccuracyHUD.new())

	# Any release (quick pass, wrister, slapper) arms the in-flight watch —
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
	_stage = Stage.LIVE
	_shot_live = false
	_local_controller.teleport_to(Vector3(0.0, 1.0, _slot_z()), FACE_NET)
	stage_puck_for_player()
	_target_index = AccuracyDrillRules.pick_next(_target_index, randi())
	_lit[0] = AccuracyDrillRules.TARGET_POSITIONS[_target_index]
	_target_node.show_targets(_lit, _GOAL_PLANE_Z, _TARGET_FRONT_OFFSET)
	show_attempt_progress()
	(_hud as ShotAccuracyHUD).set_target(AccuracyDrillRules.TARGET_NAMES[_target_index])


func _resolve_attempt(hit: bool) -> void:
	_shot_live = false
	if hit:
		# Pop the bullseye (positive feedback) — the puck is left in play so
		# the shooter sees it reach the net; pickup stays locked from release.
		_target_node.hide_target(0)
		SoundManager.play_ui(SoundManager.Sound.UI_CLICK)
	else:
		SoundManager.play_crowd(SoundManager.Sound.FACEOFF_WHISTLE)
	record_result(hit)


func _on_drill_complete() -> void:
	_target_node.clear()


# ── Per-tick detection ────────────────────────────────────────────────────────

# Aiming waits on the release signal, so there is nothing to watch until the
# shot is away.
func _tick_live(delta: float) -> void:
	if _shot_live:
		_tick_shot(delta)


# Arms the in-flight watch on any release and locks the puck from re-pickup
# until the attempt resolves and restages — mashing the shoot button can't
# re-collect a rebound and keep possession.
func _on_shot_released() -> void:
	if _stage != Stage.LIVE or _shot_live:
		return
	_shot_live = true
	_shot_start_z = _skater.global_position.z
	_shot_last_progress = 0.0
	_shot_max_progress = 0.0
	_shot_stall_time = 0.0
	_shot_air_time = 0.0
	_puck.set_skater_cooldown(_skater, PICKUP_LOCK_S)


func _tick_shot(delta: float) -> void:
	if _puck.carrier != null:
		return  # release still settling on this tick

	var pos: Vector3 = _puck.get_puck_position()
	# Forward progress toward the net and its rate — the progress delta reads
	# negative on a rebound, which the rest test then trips immediately.
	var progress: float = (pos.z - _shot_start_z) * ATTACK_DIR_Z
	var fwd_speed: float = (progress - _shot_last_progress) / delta if delta > 0.0 else 0.0
	_shot_last_progress = progress
	_shot_max_progress = maxf(_shot_max_progress, progress)
	_shot_air_time += delta
	# Only arm the dead-puck test after the release settles, so a shot still
	# leaving the blade isn't read as stalled on its first frames.
	if _shot_air_time < RELEASE_GRACE_S:
		_shot_stall_time = 0.0
	elif fwd_speed <= REST_SPEED:
		_shot_stall_time += delta
	else:
		_shot_stall_time = 0.0

	# The moment the puck reaches the net plane the attempt resolves: on the
	# lit bullseye (within tolerance) is a hit, anywhere else is a miss.
	if TutorialShotRules.crossed_goal_plane(pos.z, _GOAL_PLANE_Z, ATTACK_DIR_Z):
		var idx: int = TutorialShotRules.nearest_target(
				pos.x, pos.y, _lit, AccuracyDrillRules.HIT_RADIUS)
		_resolve_attempt(idx >= 0)
		return
	# Rebound off the goalie: the puck retreats past its furthest point back
	# toward the shooter. Retire it promptly rather than waiting out the stall.
	if _shot_air_time >= RELEASE_GRACE_S \
			and progress < _shot_max_progress - _SHOT_BACKWARD_TOL:
		_resolve_attempt(false)
		return
	# Gone dead short of the net (stopped advancing).
	if TutorialShotRules.shot_missed(false, pos.z, _GOAL_PLANE_Z, ATTACK_DIR_Z,
			fwd_speed, REST_SPEED, _shot_stall_time, STALL_GRACE_S):
		_resolve_attempt(false)
		return
	# Safety: a wedged puck that never resolves any other way.
	if _shot_air_time >= _SHOT_MAX_TIME:
		_resolve_attempt(false)


# ── Staging helpers ───────────────────────────────────────────────────────────

# Player's shooting spot: in the slot, SLOT_DIST_M out from the attacked net
# (team 0 attacks -Z) — the same spot as the tutorial's target drill.
func _slot_z() -> float:
	return -(GameRules.GOAL_LINE_Z - GameRules.SLOT_DIST_M)

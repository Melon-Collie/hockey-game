extends Node

# Offline penalty-shot drill: "how many can you score out of 10". Spawned by
# game_scene.gd via DrillRegistry when NetworkManager.drill_id selects it. Owns
# the whole loop — stage the shooter at centre with the puck a stride ahead to
# skate onto, let them pick it up and drive in on a lone reactive goalie, classify
# the attempt with PenaltyShotRules (NHL Rule 24.2: keep the puck moving toward
# the net, one shot, no rebounds), tally it, and restage — finishing with a
# results card. The keep-it-moving rules don't arm until the shooter actually
# picks up the puck, so a loose puck waiting at centre never reads as a stalled
# shot.
#
# Modelled on TutorialManager's lifecycle (single local player + puck, a manager
# that owns staging and a code-built HUD), minus the multi-step machinery.

# Team 0 shoots toward -Z, so it attacks the -Z net (where spawn_penalty_goalie
# places the goalie). The goal line is at -GOAL_LINE_Z.
const _ATTACK_DIR_Z: float = -1.0
const _GOAL_LINE_Z: float = -GameRules.GOAL_LINE_Z
const _NET_HALF_WIDTH: float = GameRules.NET_HALF_WIDTH
const _ICE_Y: float = 0.05
const _TOTAL_SHOTS: int = 10

# Centre-ice staging spot for the shooter. The puck is staged a stride ahead
# (toward the net) so the shooter skates onto it — the normal proximity-pickup
# path — rather than starting glued to the blade.
const _START: Vector3 = Vector3(0.0, 1.0, 0.0)
const _FACE_NET: Vector2 = Vector2(0.0, -1.0)
const _STAGE_PUCK_AHEAD: float = 1.2

# How long the GOAL! / NO GOAL flash holds before the next shot is staged.
const _RESULT_HOLD: float = 1.4
# Safety net: an attempt that's been live this long (puck wedged, etc.) without
# resolving is force-scored as a miss so the drill can't soft-lock.
const _MAX_ATTEMPT_TIME: float = 20.0

enum Stage { LIVE, RESULT, DONE }

var _local_record: PlayerRecord = null
var _local_controller: LocalController = null
var _skater: Skater = null
var _puck: Puck = null
var _hud: PenaltyDrillHUD = null

var _session: DrillSession = null
var _cfg: PenaltyShotRules.Config = null

var _stage: Stage = Stage.LIVE
var _result_timer: float = 0.0

# Per-attempt accumulators that PenaltyShotRules.classify reads.
var _start_z: float = 0.0
var _last_progress: float = 0.0
var _max_progress: float = 0.0
var _started: bool = false
var _stall_time: float = 0.0
var _attempt_time: float = 0.0
# Latches true the first tick the shooter carries the staged puck. The keep-it-
# moving failure rules are suppressed until then (and the rush is measured from
# the pickup point), so a loose puck sitting at centre pre-pickup can't be scored
# as a stalled/backward shot.
var _has_possessed: bool = false


func _ready() -> void:
	_local_record = GameManager.get_local_player()
	if _local_record == null:
		push_error("PenaltyDrillManager: no local player found")
		return
	_local_controller = _local_record.controller as LocalController
	_skater = _local_record.skater
	_puck = GameManager.get_puck()

	_session = DrillSession.new(_TOTAL_SHOTS)
	_cfg = PenaltyShotRules.Config.new()

	GameManager.spawn_penalty_goalie()

	_hud = PenaltyDrillHUD.new()
	add_child(_hud)
	_hud.retry_pressed.connect(_on_retry)
	_hud.exit_pressed.connect(_on_exit)

	_begin_attempt()


func _exit_tree() -> void:
	# Mirror TutorialManager: the manager owns the lone goalie, so tear it down
	# on the way out (covers the scene change from return_to_free_play, which
	# frees this subtree). despawn nulls the GameManager fields so the next
	# session can spawn a fresh one.
	GameManager.despawn_penalty_goalie()


# ── Attempt lifecycle ─────────────────────────────────────────────────────────

func _begin_attempt() -> void:
	_stage = Stage.LIVE
	_last_progress = 0.0
	_max_progress = 0.0
	_started = false
	_stall_time = 0.0
	_attempt_time = 0.0
	_has_possessed = false

	# Stand the shooter at centre facing the net with the puck staged a stride
	# ahead to skate onto, and reset the goalie into its crease.
	_local_controller.teleport_to(_START, _FACE_NET)
	_stage_puck_for_player()
	GameManager.reset_penalty_goalie()

	# Provisional baseline; re-based to the pickup point once the shooter actually
	# collects the puck (see _tick_live), so forward progress measures the rush.
	_start_z = _puck.get_puck_position().z
	_hud.set_progress(_session.current_attempt_number(), _session.total_attempts, _session.makes)


func _resolve_attempt(made: bool) -> void:
	_session.record(made)
	_stage = Stage.RESULT
	_result_timer = _RESULT_HOLD
	# Leave the puck where the attempt ended (in the net on a goal, out wide on a
	# miss) so the shooter actually SEES the result during the hold, instead of it
	# vanishing off-rink the instant it crosses. Detection is off now (_stage is
	# RESULT, so _tick_live won't run) and re-pickup is locked, so a settling
	# rebound can't re-trigger or be re-collected before the next attempt stages.
	_puck.set_skater_cooldown(_skater, _RESULT_HOLD + 1.0)
	_hud.flash_result(made, _session.makes, _session.attempts_taken)
	SoundManager.play_crowd(SoundManager.Sound.GOAL_HORN if made else SoundManager.Sound.FACEOFF_WHISTLE)


func _advance() -> void:
	if _session.is_complete():
		_stage = Stage.DONE
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
	# Hold all failure detection until the shooter picks up the puck. Before that
	# the loose puck is just sitting at centre — measuring "keep it moving" against
	# it would fail the attempt before the shot even begins. On pickup, re-base the
	# rush to the pickup point so forward progress starts from zero there.
	if not _has_possessed:
		if _puck.carrier == _skater:
			_has_possessed = true
			_start_z = _puck.get_puck_position().z
			_last_progress = 0.0
			_max_progress = 0.0
		return

	var pos: Vector3 = _puck.get_puck_position()
	var progress: float = PenaltyShotRules.forward_progress(pos.z, _start_z, _ATTACK_DIR_Z)
	# Forward speed from the change in progress, NOT the rigidbody velocity — a
	# carried puck is frozen to the blade and reports ~0 velocity even while the
	# shooter skates it up the ice.
	var fwd_speed: float = (progress - _last_progress) / delta if delta > 0.0 else 0.0
	_last_progress = progress
	_max_progress = maxf(_max_progress, progress)

	if not _started and progress >= _cfg.start_progress:
		_started = true
	if _started:
		_attempt_time += delta
		# Only accumulate stall time once the running-start grace has elapsed —
		# otherwise a slow accelerate-from-standstill would bank enough stall
		# during the grace to die the instant it lifts, defeating the window.
		if _attempt_time < _cfg.start_grace:
			_stall_time = 0.0
		elif fwd_speed <= _cfg.rest_speed:
			_stall_time += delta
		else:
			_stall_time = 0.0

	var outcome: PenaltyShotRules.Outcome = PenaltyShotRules.classify(
			pos.x, pos.y, pos.z, fwd_speed, progress, _max_progress,
			_started, _stall_time, _attempt_time,
			_ATTACK_DIR_Z, _GOAL_LINE_Z, _NET_HALF_WIDTH, _cfg)

	if outcome == PenaltyShotRules.Outcome.LIVE:
		if _started and _attempt_time >= _MAX_ATTEMPT_TIME:
			_resolve_attempt(false)
		return
	_resolve_attempt(outcome == PenaltyShotRules.Outcome.GOAL)


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

# Stages the puck a stride ahead of the freshly-teleported shooter (toward the
# net) so collecting it runs the NORMAL proximity-pickup path — a bare set_carrier
# bypasses PuckController's bookkeeping (see the passing/accuracy drills). stage_at
# fully parks it (position + linear AND angular velocity), so a rebound left
# spinning from the previous attempt can't carry momentum into this one. The
# per-attempt pickup lock from the result hold is lifted so it can be collected.
func _stage_puck_for_player() -> void:
	_puck.remove_skater_cooldown(_skater)
	_puck.stage_at(Vector3(_skater.global_position.x, _ICE_Y,
			_skater.global_position.z - _STAGE_PUCK_AHEAD))

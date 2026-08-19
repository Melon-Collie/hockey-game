extends DrillLoop

# Offline penalty-shot drill: "how many can you score out of 10". Spawned by
# game_scene.gd via DrillRegistry when NetworkManager.drill_id selects it. Owns
# the whole loop — stage the shooter at centre with the puck a stride ahead to
# skate onto, let them pick it up and drive in on a lone reactive goalie, classify
# the attempt with PenaltyShotRules (NHL Rule 24.2, read as a gameplay rule: the
# SHOOTER must keep driving toward the net — one shot, no rebounds), tally it, and
# restage — finishing with a results card. The keep-driving rules don't arm until
# the shooter actually picks up the puck, so a loose puck waiting at centre never
# reads as a stalled shot. Because those rules track the player's own forward
# drive (not the puck), dangling or shooting the puck can't fail the attempt —
# only the shooter stalling or backing off does.
#
# Modelled on TutorialManager's lifecycle (single local player + puck, a manager
# that owns staging and a code-built HUD), minus the multi-step machinery.

# Team 0 attacks the -Z net, where spawn_penalty_goalie places the goalie.
const _GOAL_LINE_Z: float = -GameRules.GOAL_LINE_Z
const _NET_HALF_WIDTH: float = GameRules.NET_HALF_WIDTH
const _TOTAL_SHOTS: int = 10

# Centre-ice staging spot for the shooter.
const _START: Vector3 = Vector3(0.0, 1.0, 0.0)

# Safety net: an attempt that's been live this long (puck wedged, etc.) without
# resolving is force-scored as a miss so the drill can't soft-lock.
const _MAX_ATTEMPT_TIME: float = 20.0

var _cfg: PenaltyShotRules.Config = null

# Per-attempt accumulators that PenaltyShotRules.classify reads.
var _start_z: float = 0.0
var _last_progress: float = 0.0
var _max_progress: float = 0.0
var _started: bool = false
var _stall_time: float = 0.0
var _attempt_time: float = 0.0
# Wall-clock since the shooter first collected the puck, used only for the safety
# timeout — independent of `_started`/`_released` so a shot fired before the rush
# arms (a quick snap off the pickup) can't hang if it never crosses the line.
var _live_time: float = 0.0
# Latches true the first tick the shooter carries the staged puck. The keep-it-
# moving failure rules are suppressed until then (and the rush is measured from
# the pickup point), so a loose puck sitting at centre pre-pickup can't be scored
# as a stalled/backward shot.
var _has_possessed: bool = false
# Latches true once the puck leaves the shooter's blade (shot away, poked, or
# knocked loose). From then on the keep-moving rules retire — it's a shot in
# flight, resolved only by crossing the goal line or the safety timeout.
var _released: bool = false


func _ready() -> void:
	if not bind_local_player(_TOTAL_SHOTS):
		return
	_cfg = PenaltyShotRules.Config.new()
	GameManager.spawn_penalty_goalie()
	mount_hud(PenaltyDrillHUD.new())
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
	_live_time = 0.0
	_has_possessed = false
	_released = false

	# Stand the shooter at centre facing the net with the puck staged a stride
	# ahead to skate onto, and reset the goalie into its crease.
	_local_controller.teleport_to(_START, FACE_NET)
	stage_puck_for_player()
	GameManager.reset_penalty_goalie()

	# Provisional baseline; re-based to the shooter's position once they actually
	# collect the puck (see _tick_live), so forward progress measures the rush.
	# Progress is the SHOOTER's, not the puck's — the keep-driving rules track the
	# player skating in, so dangling/shooting the puck can't end the attempt.
	_start_z = _skater.global_position.z
	show_attempt_progress()


func _resolve_attempt(made: bool) -> void:
	# Leave the puck where the attempt ended (in the net on a goal, out wide on a
	# miss) so the shooter actually SEES the result during the hold, instead of it
	# vanishing off-rink the instant it crosses. Detection is off now (_stage is
	# RESULT, so _tick_live won't run) and re-pickup is locked, so a settling
	# rebound can't re-trigger or be re-collected before the next attempt stages.
	_puck.set_skater_cooldown(_skater, RESULT_HOLD + 1.0)
	record_result(made)
	SoundManager.play_crowd(SoundManager.Sound.GOAL_HORN if made else SoundManager.Sound.FACEOFF_WHISTLE)


# ── Per-tick detection ────────────────────────────────────────────────────────

func _tick_live(delta: float) -> void:
	# Hold all failure detection until the shooter picks up the puck. Before that
	# the loose puck is just sitting at centre — measuring "keep it moving" against
	# it would fail the attempt before the shot even begins. On pickup, re-base the
	# rush to the pickup point so forward progress starts from zero there.
	if not _has_possessed:
		if _puck.carrier == _skater:
			_has_possessed = true
			_start_z = _skater.global_position.z
			_last_progress = 0.0
			_max_progress = 0.0
		return

	_live_time += delta
	var pos: Vector3 = _puck.get_puck_position()

	# Once the puck leaves the shooter's blade (shot away, poked, or knocked loose)
	# the keep-moving rules retire: it's a shot in flight now, resolved only by
	# crossing the goal line or the safety timeout. The shooter's momentum no
	# longer matters — they're free to stop or peel off.
	if _puck.carrier != _skater:
		_released = true

	# While carrying, failure detection tracks the SHOOTER's drive to the net, not
	# the puck: the attempt only dies when the player stalls or skates backward, so
	# dangling the puck (which moves it laterally or pulls it to the hip) never ends
	# the rush. Skip this bookkeeping once released — the flags are frozen and the
	# keep-moving rules no longer read them. Goal / miss detection still keys on the
	# puck crossing the goal line (below), in every phase.
	var progress: float = 0.0
	var fwd_speed: float = 0.0
	if not _released:
		progress = PenaltyShotRules.forward_progress(
				_skater.global_position.z, _start_z, ATTACK_DIR_Z)
		# Forward speed from the change in the shooter's progress this tick.
		fwd_speed = (progress - _last_progress) / delta if delta > 0.0 else 0.0
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
			_started, _released, _stall_time, _attempt_time,
			ATTACK_DIR_Z, _GOAL_LINE_Z, _NET_HALF_WIDTH, _cfg)

	if outcome == PenaltyShotRules.Outcome.LIVE:
		if _live_time >= _MAX_ATTEMPT_TIME:
			_resolve_attempt(false)
		return
	_resolve_attempt(outcome == PenaltyShotRules.Outcome.GOAL)

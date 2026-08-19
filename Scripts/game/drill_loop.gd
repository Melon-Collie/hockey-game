class_name DrillLoop
extends Node

# Base for the offline practice drills — the "how many out of ten" loop the
# penalty, shot-accuracy and passing managers all run. It is the manager-side
# twin of DrillHUD, which already factors the presentation half the same way.
#
# What lives here is what was repeated verbatim in all three: binding the local
# player, staging the puck a stride ahead so collecting it runs the normal
# proximity-pickup path, the stage machine and its result-hold countdown, and
# the retry/exit handlers.
#
# What deliberately does NOT live here is each drill's in-flight watcher. They
# look alike — a release grace, a stall clock, a safety cap — but they answer
# different questions: the penalty drill watches the SHOOTER's forward drive,
# accuracy watches the puck's progress toward the net plane, passing watches the
# puck closing on a moving receiver. Only the clocks are shared, so only the
# clocks are here. Folding the three watchers into one would put a drill's
# failure condition somewhere it cannot be read.
#
# A subclass overrides _begin_attempt() and _tick_live(); everything else is
# inherited.

# The shared clocks. A drill's own thresholds — what counts as a make, how far
# past the receiver is a miss — stay in the drill.
const ICE_Y: float = 0.05
const STAGE_PUCK_AHEAD: float = 1.2
# How long a result flash holds before the next attempt is staged.
const RESULT_HOLD: float = 1.4
# Per-skater pickup cooldown applied at release, so a loose puck can't be
# re-collected mid-attempt or during the result hold. Lifted at restage.
const PICKUP_LOCK_S: float = 999.0
# Team 0 shoots toward -Z, so every drill's lane and net sit that way.
const ATTACK_DIR_Z: float = -1.0
const FACE_NET: Vector2 = Vector2(0.0, -1.0)
# Dead-puck clocks, shared by the accuracy and passing watchers. Sized in
# TutorialManager's shooting drills and carried forward.
const RELEASE_GRACE_S: float = 0.35  # after release, before the dead rules arm
const REST_SPEED: float = 0.5        # m/s of progress that counts as stopped
const STALL_GRACE_S: float = 0.4     # s stopped before the puck is called dead

# LIVE covers the whole attempt, including a shot or pass in flight — a drill
# that needs to know the puck is away tracks that with its own flag, since what
# it means differs per drill (and what to do about it differs more).
enum Stage { LIVE, RESULT, DONE }

var _local_record: PlayerRecord = null
var _local_controller: LocalController = null
var _skater: Skater = null
var _puck: Puck = null
var _hud: DrillHUD = null
var _session: DrillSession = null
var _stage: Stage = Stage.LIVE
var _result_timer: float = 0.0


# Binds the local player and puck. False (with the error already pushed) means
# there is nobody to run the drill for — the subclass must return from _ready.
func bind_local_player(total_attempts: int) -> bool:
	_local_record = GameManager.get_local_player()
	if _local_record == null:
		push_error("%s: no local player found" % get_script().resource_path.get_file())
		return false
	_local_controller = _local_record.controller as LocalController
	_skater = _local_record.skater
	_puck = GameManager.get_puck()
	_session = DrillSession.new(total_attempts)
	return true


# Mounts the drill's HUD and wires the two buttons every drill has. Skip is
# passing-only and stays wired by that drill.
func mount_hud(hud: DrillHUD) -> void:
	_hud = hud
	add_child(_hud)
	_hud.retry_pressed.connect(_on_retry)
	_hud.exit_pressed.connect(_on_exit)


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


# Tallies the attempt and starts the result flash. A drill does its own
# end-of-attempt work — leaving the puck where it landed, popping a bullseye,
# picking the sound — around this call.
func record_result(made: bool) -> void:
	_session.record(made)
	_stage = Stage.RESULT
	_result_timer = RESULT_HOLD
	_hud.flash_result(made, _session.makes, _session.attempts_taken)


func _advance() -> void:
	if not _session.is_complete():
		_begin_attempt()
		return
	_stage = Stage.DONE
	_on_drill_complete()
	_hud.show_results(_session.makes, _session.total_attempts)


# Stages the puck a stride ahead of the freshly-teleported player (every drill
# faces -Z, so ahead is -Z), lifting the pickup lock left from the previous
# attempt. Skating onto it runs the NORMAL proximity-pickup path — never hand a
# puck to a stick from here, since a bare set_carrier bypasses PuckController's
# bookkeeping. stage_at fully parks it (position, linear AND angular velocity,
# any queued elevation), so a puck left spinning by the last attempt can't carry
# its momentum into this one.
func stage_puck_for_player() -> void:
	_puck.remove_skater_cooldown(_skater)
	_puck.stage_at(Vector3(_skater.global_position.x, ICE_Y,
			_skater.global_position.z - STAGE_PUCK_AHEAD))


func show_attempt_progress() -> void:
	_hud.set_progress(_session.current_attempt_number(), _session.total_attempts, _session.makes)


# ── Overridable by a drill ────────────────────────────────────────────────────

func _begin_attempt() -> void:
	pass


func _tick_live(_delta: float) -> void:
	pass


# Teardown the results card wants done first — the accuracy drill's targets, the
# passing drill's saucer board. Nothing by default.
func _on_drill_complete() -> void:
	pass


# ── HUD handlers ──────────────────────────────────────────────────────────────

func _on_retry() -> void:
	_session.restart()
	_hud.hide_results()
	_begin_attempt()


func _on_exit() -> void:
	_stage = Stage.DONE
	NetworkManager.drill_id = ""
	GameManager.return_to_free_play()

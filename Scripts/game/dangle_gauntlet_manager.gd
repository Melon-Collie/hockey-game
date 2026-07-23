extends Node

# Offline Dangle Gauntlet drill: a single timed run where you carry a loose puck
# through a fixed serpentine of gates, in order, racing the clock. Spawned by
# game_scene.gd via DrillRegistry when NetworkManager.drill_id selects it.
#
# Unlike the other drills (penalty / accuracy / passing), this is one continuous
# run, not "N attempts out of 10": the clock starts the moment you pick up the
# staged puck, each gate must be threaded WITH the puck under control and in
# sequence, and the run ends when the last gate clears (or you bail out). Scoring
# is time + a medal (DangleDrillRules.medal); gates lit green as you clear them.
#
# Modelled on the sibling drills' lifecycle (single local player + puck, a
# code-built HUD, results card, teardown in _exit_tree). DangleDrillRules owns
# the course geometry, the gate-crossing test, and the par/medal math; DrillGates
# renders the markers; this node owns the staging, the clock, and progression.

const _ICE_Y: float = 0.05
const _STAGE_PUCK_AHEAD: float = 1.2  # metres in front of spawn (team 0 attacks -Z)

# The puck counts as "under control" for a gate clear if it's carried, or loose
# but within this radius of the skater — a poked-ahead touch still threads a
# gate, but a shot fired down the ice can't clear gates from range.
const _CONTROL_RADIUS: float = 2.5

# Safety cap: retire a run that never finishes (puck lost and un-recoverable
# even with Skip) so the results card always eventually shows.
const _MAX_RUN_TIME: float = 120.0

enum Stage { WAITING, RUNNING, DONE }

var _local_record: PlayerRecord = null
var _local_controller: LocalController = null
var _skater: Skater = null
var _puck: Puck = null
var _hud: DangleGauntletHUD = null
var _gates_node: DrillGates = null

var _course: Array = []
var _total: int = 0
var _next: int = 0          # index of the active gate (the one to thread next)
var _cleared: int = 0       # gates actually threaded (Skip advances _next, not this)

var _stage: Stage = Stage.WAITING
var _elapsed: float = 0.0
var _prev_puck_xz: Vector2 = Vector2.ZERO


func _ready() -> void:
	_local_record = GameManager.get_local_player()
	if _local_record == null:
		push_error("DangleGauntletManager: no local player found")
		return
	_local_controller = _local_record.controller as LocalController
	_skater = _local_record.skater
	_puck = GameManager.get_puck()

	_course = DangleDrillRules.build_course()
	_total = _course.size()

	_gates_node = DrillGates.new()
	add_child(_gates_node)
	_gates_node.show_course(_course)

	_hud = DangleGauntletHUD.new()
	add_child(_hud)
	_hud.retry_pressed.connect(_on_retry)
	_hud.exit_pressed.connect(_on_exit)
	_hud.skip_pressed.connect(_on_skip)
	_hud.enable_skip()

	_start_fresh()


func _exit_tree() -> void:
	# Nothing external is spawned (no goalie, no puppet), but clear the markers on
	# the way out for symmetry with the sibling drills' teardown.
	if _gates_node != null and is_instance_valid(_gates_node):
		_gates_node.clear()


# ── Run lifecycle ─────────────────────────────────────────────────────────────

# Stages the player and puck at the start line and arms a fresh run. The clock
# stays paused until the player picks up the staged puck.
func _start_fresh() -> void:
	_stage = Stage.WAITING
	_elapsed = 0.0
	_next = 0
	_cleared = 0

	_local_controller.teleport_to(_to_world(DangleDrillRules.SPAWN), Vector2(0.0, -1.0))
	_stage_puck_for_player()
	_prev_puck_xz = _puck_xz()

	for i: int in _total:
		_gates_node.set_state(i, DrillGates.State.PENDING)
	if _total > 0:
		_gates_node.set_state(0, DrillGates.State.ACTIVE)

	_hud.set_par(DangleDrillRules.par_time())
	_hud.set_gate(1, _total)
	_hud.set_clock(0.0, false)
	_hud.hide_flash()


func _finish() -> void:
	_stage = Stage.DONE
	var medal: DangleDrillRules.Medal = DangleDrillRules.medal(_elapsed, _cleared, _total)
	_hud.set_clock(_elapsed, false)
	_hud.show_time_results(_elapsed, _cleared, _total, medal)
	if _cleared >= _total and medal != DangleDrillRules.Medal.NONE:
		SoundManager.play_ui(SoundManager.Sound.UI_CLICK)
	else:
		SoundManager.play_crowd(SoundManager.Sound.FACEOFF_WHISTLE)


# ── Per-tick ──────────────────────────────────────────────────────────────────

func _physics_process(delta: float) -> void:
	if _local_record == null or _skater == null or not is_instance_valid(_puck):
		return
	match _stage:
		Stage.WAITING:
			_tick_waiting()
		Stage.RUNNING:
			_tick_running(delta)
		Stage.DONE:
			pass


# The clock starts the instant the player gains the staged puck.
func _tick_waiting() -> void:
	_prev_puck_xz = _puck_xz()
	if _puck.carrier == _skater:
		_stage = Stage.RUNNING
		_elapsed = 0.0
		_hud.flash_go()
		SoundManager.play_ui(SoundManager.Sound.UI_CLICK)


func _tick_running(delta: float) -> void:
	_elapsed += delta
	_hud.set_clock(_elapsed, true)
	# Clear the GO! flash a beat after the run begins.
	if _elapsed > 0.6:
		_hud.hide_flash()

	var cur_xz: Vector2 = _puck_xz()
	if _next < _total:
		var gate: DangleDrillRules.Gate = _course[_next] as DangleDrillRules.Gate
		if DangleDrillRules.crossed_gate(_prev_puck_xz, cur_xz, gate) and _in_control(cur_xz):
			_clear_current_gate()
	_prev_puck_xz = cur_xz

	if _stage == Stage.RUNNING and _elapsed >= _MAX_RUN_TIME:
		_finish()


func _clear_current_gate() -> void:
	_gates_node.set_state(_next, DrillGates.State.CLEARED)
	_cleared += 1
	_next += 1
	SoundManager.play_ui(SoundManager.Sound.UI_CLICK)
	if _next >= _total:
		_finish()
	else:
		_gates_node.set_state(_next, DrillGates.State.ACTIVE)
		_hud.set_gate(mini(_next + 1, _total), _total)


# The puck is "under control" if carried, or loose but within a stride of the
# skater — so a fired-away puck can't clear gates it happens to pass through.
func _in_control(puck_xz: Vector2) -> bool:
	if _puck.carrier == _skater:
		return true
	var here := Vector2(_skater.global_position.x, _skater.global_position.z)
	return here.distance_to(puck_xz) <= _CONTROL_RADIUS


# ── HUD handlers ──────────────────────────────────────────────────────────────

func _on_retry() -> void:
	_hud.hide_results()
	_start_fresh()


# In-play escape hatch: bail the current gate (the puck got away and can't be
# threaded). Advances past it WITHOUT crediting a clear, so the run can still
# finish — but a bailed gate forfeits the medal (cleared < total → DNF).
func _on_skip() -> void:
	if _stage != Stage.RUNNING or _next >= _total:
		return
	_gates_node.set_state(_next, DrillGates.State.PENDING)
	_next += 1
	if _next >= _total:
		_finish()
	else:
		_gates_node.set_state(_next, DrillGates.State.ACTIVE)
		_hud.set_gate(mini(_next + 1, _total), _total)


func _on_exit() -> void:
	_stage = Stage.DONE
	NetworkManager.drill_id = ""
	GameManager.return_to_free_play()


# ── Staging helpers ───────────────────────────────────────────────────────────

func _to_world(spot: Vector2) -> Vector3:
	return Vector3(spot.x, 1.0, spot.y)


func _puck_xz() -> Vector2:
	var p: Vector3 = _puck.get_puck_position()
	return Vector2(p.x, p.z)


# Stages the puck a stride ahead of the freshly-teleported player (ahead = -Z for
# team 0), lifting any leftover pickup lock so it's collected normally. stage_at
# fully parks the puck so a previous run's momentum can't carry over.
func _stage_puck_for_player() -> void:
	_puck.remove_skater_cooldown(_skater)
	_puck.stage_at(Vector3(_skater.global_position.x, _ICE_Y,
			_skater.global_position.z - _STAGE_PUCK_AHEAD))

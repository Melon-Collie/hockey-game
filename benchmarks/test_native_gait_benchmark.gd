extends GutTest

# ── Gait GDScript-vs-native micro-benchmark (report-only; NOT in the default
# suite) ─ Times SkaterSkatingCoordinator.apply against the C++ port
# (NativeSkaterGait, native/src/) in the same states the gait micro-benchmark
# uses, on one real skater. The native rows include the FULL per-frame
# boundary cost a production integration would pay: reading the skater/
# controller inputs, building the flags word, the apply call, and all 14
# output getters.
#
# Run explicitly:
#   bash .claude/hooks/run-gut.sh -gdir=res://benchmarks
#
# Compare RELATIVELY within one run (debug engine inflates GDScript, debug
# godot-cpp inflates the native side differently). Goes pending when the
# extension isn't built.

const State = SkaterStateMachine.State
const REPS: int = 3000
const DELTA: float = 1.0 / 120.0

const F_BRAKE: int = 1
const F_HIT: int = 2
const F_BLADE_UP: int = 4
const F_LEFTY: int = 8
const F_SPRINT: int = 16
const F_FACEOFF: int = 32


class StubGameState extends Node:
	func is_host() -> bool:
		return true

	func is_movement_locked() -> bool:
		return false


var _results: Array[Dictionary] = []
var _skater: Skater = null
var _controller: SkaterController = null
var _puck: Puck = null
var _state: StubGameState = null
var _native: RefCounted = null


func before_all() -> void:
	if not ClassDB.class_exists(&"NativeSkaterGait"):
		return
	_puck = load("res://Scenes/Puck.tscn").instantiate() as Puck
	add_child(_puck)
	_puck.global_position = Vector3(20.0, 0.0, 20.0)

	_skater = load("res://Scenes/Skater.tscn").instantiate() as Skater
	add_child(_skater)
	_skater.global_position = Vector3(2.0, GameRules.FACEOFF_SPAWN_HEIGHT, 8.0)

	_state = StubGameState.new()
	add_child(_state)

	_controller = SkaterController.new()
	add_child(_controller)
	_controller.setup(_skater, _puck, _state)

	_native = ClassDB.instantiate(&"NativeSkaterGait")
	_native.set_state_ids(
			State.SKATING_WITH_PUCK, State.SKATING_WITHOUT_PUCK,
			State.SHOT_BLOCKING, State.FOLLOW_THROUGH, State.WRISTER_AIM,
			State.SLAPPER_CHARGE_WITH_PUCK, State.SLAPPER_CHARGE_WITHOUT_PUCK,
			State.ONE_TIMER_RETENTION)
	_native.set_leg_scale(_controller._skating.leg_scale)
	_native.configure(_controller)


func after_all() -> void:
	if _controller != null:
		_controller.free()
	if _skater != null:
		_skater.free()
	if _puck != null:
		_puck.free()
	if _state != null:
		_state.free()


func _skate_forward() -> void:
	_skater.velocity = Vector3(3.5, 0.0, -4.0)
	_skater.move_intent = Vector2(0.4, -0.9)
	_skater.brake_intent = false
	_skater.current_shot_state = State.SKATING_WITHOUT_PUCK


func _glide() -> void:
	_skater.velocity = Vector3(3.5, 0.0, -4.0)
	_skater.move_intent = Vector2.ZERO
	_skater.brake_intent = false
	_skater.current_shot_state = State.SKATING_WITHOUT_PUCK


func _rest() -> void:
	_skater.velocity = Vector3.ZERO
	_skater.move_intent = Vector2.ZERO
	_skater.brake_intent = false
	_skater.current_shot_state = State.SKATING_WITHOUT_PUCK


func _hockey_stop() -> void:
	_skater.velocity = Vector3(3.5, 0.0, -4.0)
	_skater.move_intent = Vector2.ZERO
	_skater.brake_intent = true
	_skater.current_shot_state = State.SKATING_WITHOUT_PUCK


func _blocking() -> void:
	_skater.velocity = Vector3(1.0, 0.0, -1.0)
	_skater.move_intent = Vector2.ZERO
	_skater.brake_intent = false
	_skater.current_shot_state = State.SHOT_BLOCKING


# The full per-frame native path: input reads, flags build, apply, all getters.
func _native_step() -> void:
	var flags: int = 0
	if _skater.brake_intent:
		flags |= F_BRAKE
	if _skater.hit_committed:
		flags |= F_HIT
	if _skater.blade_up:
		flags |= F_BLADE_UP
	if _skater.is_left_handed:
		flags |= F_LEFTY
	if _controller.sprint_active:
		flags |= F_SPRINT
	if _controller.is_faceoff_ready():
		flags |= F_FACEOFF
	var code: int = _native.apply(DELTA, _skater.velocity,
			_skater.global_transform.basis, _skater.move_intent,
			_skater.current_shot_state, _skater.shot_charge,
			_controller.stagger_timer, _controller.knockdown_timer,
			_controller.celebration_progress(), flags)
	if code != 0:
		return
	var _lp: float = _native.get_l_pitch()
	var _lr: float = _native.get_l_roll()
	var _lk: float = _native.get_l_knee()
	var _rp: float = _native.get_r_pitch()
	var _rr: float = _native.get_r_roll()
	var _rk: float = _native.get_r_knee()
	var _el: float = _native.get_foot_evert_l()
	var _er: float = _native.get_foot_evert_r()
	var _cd: float = _native.get_crouch_drop()
	var _tp: float = _native.get_trunk_pitch_add()
	var _tr: float = _native.get_trunk_roll_add()
	var _sy: float = _native.get_stop_yaw_offset()
	var _ty: float = _native.get_travel_align_yaw()
	var _hy: float = _native.get_shot_hip_yaw()


func _print_results() -> void:
	var widest: int = 0
	for r: Dictionary in _results:
		widest = maxi(widest, (r["label"] as String).length())
	gut.p("")
	gut.p("── Gait cost by state (µs/call, %d reps) ──" % REPS)
	gut.p("  %s  %10s  %10s  %8s" % ["state".rpad(widest), "GDScript", "native", "speedup"])
	for r: Dictionary in _results:
		gut.p("  %s  %10.2f  %10.2f  %7.1fx" % [
				(r["label"] as String).rpad(widest), r["gd_us"], r["nat_us"],
				(r["gd_us"] as float) / maxf(r["nat_us"] as float, 0.001)])
	gut.p("")


func test_gait_gdscript_vs_native_by_state() -> void:
	if _native == null:
		pending("native extension not built — see native/README.md")
		return
	for spec: Array in [
			["skating (intent + speed)", _skate_forward],
			["gliding (speed, no intent)", _glide],
			["at rest (settled)", _rest],
			["hockey stop (braking)", _hockey_stop],
			["shot-blocking (planted)", _blocking],
		]:
		var setter: Callable = spec[1]
		setter.call()
		# Settle the smoothing on BOTH sides so the timed run measures the
		# steady state (and, for "at rest", the settled early-out).
		for _w: int in 240:
			_controller._skating.apply(DELTA)
			_native_step()

		var t0: int = Time.get_ticks_usec()
		for _i: int in REPS:
			_controller._skating.apply(DELTA)
		var gd_us: float = float(Time.get_ticks_usec() - t0) / float(REPS)

		t0 = Time.get_ticks_usec()
		for _i: int in REPS:
			_native_step()
		var nat_us: float = float(Time.get_ticks_usec() - t0) / float(REPS)

		_results.append({"label": spec[0], "gd_us": gd_us, "nat_us": nat_us})
	_print_results()
	assert_true(_results.size() == 5, "benchmark produced rows")

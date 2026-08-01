extends GutTest

# ── Gait / render-pose micro-benchmark (report-only; NOT in the default suite) ─
# Times Skater.render_pose_update and its parts on one real skater.
#
# Why this exists, precisely: the F7 freeze sweep split the cosmetic rig in half
# and found the WRITE half (bone poses, stick/arm rebuild, both elbow IK solves)
# costs 0.12 ms +/- 0.32 across ten skaters — statistically nothing — while the
# SOLVE half costs 1.82 ms. That is ~80% of all freezable cosmetic cost in the
# frame, and it is this path. Everything else on the cosmetic list is rounding
# error beside it.
#
# Run explicitly:
#   bash .claude/hooks/run-gut.sh -gdir=res://benchmarks
#
# Compare RELATIVELY (part vs part, state vs state, before vs after a change),
# never as an absolute frame cost: a debug build inflates GDScript, and the
# parts overlap.
#
# SkaterSkatingCoordinator.apply() is one ~750-line function, so its sections
# cannot be called individually without extracting them first — which is a
# refactor, and refactoring before measuring is what this file exists to
# prevent. Instead it is timed in several STATES. The gait branches hard on
# intent, planting, braking and shot state, so the spread between states says
# which branches are expensive without touching the code to find out.

const REPS: int = 3000


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


func before_all() -> void:
	# Plain add_child + free in after_all, not add_child_autofree: autofree runs
	# per TEST, and a second test in this file would then hit freed actors.
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
	_skate_forward()


func after_all() -> void:
	_controller.free()
	_skater.free()
	_puck.free()
	_state.free()


# ── State setters. The gait reads REPLICATED intent, not the state machine, so
# posing a state is a matter of writing the same fields the wire would.
func _skate_forward() -> void:
	_skater.velocity = Vector3(3.5, 0.0, -4.0)
	_skater.move_intent = Vector2(0.4, -0.9)
	_skater.brake_intent = false
	_skater.current_shot_state = SkaterStateMachine.State.SKATING_WITHOUT_PUCK


func _glide() -> void:
	# Carrying speed with no keys down — the stride gate is intent, not speed,
	# so this is the branch a coasting skater actually takes.
	_skater.velocity = Vector3(3.5, 0.0, -4.0)
	_skater.move_intent = Vector2.ZERO
	_skater.brake_intent = false
	_skater.current_shot_state = SkaterStateMachine.State.SKATING_WITHOUT_PUCK


func _rest() -> void:
	_skater.velocity = Vector3.ZERO
	_skater.move_intent = Vector2.ZERO
	_skater.brake_intent = false
	_skater.current_shot_state = SkaterStateMachine.State.SKATING_WITHOUT_PUCK


func _hockey_stop() -> void:
	_skater.velocity = Vector3(3.5, 0.0, -4.0)
	_skater.move_intent = Vector2.ZERO
	_skater.brake_intent = true
	_skater.current_shot_state = SkaterStateMachine.State.SKATING_WITHOUT_PUCK


func _blocking() -> void:
	# Planted: the braced wall pose owns the legs and the intent branches are
	# skipped wholesale, so this is the cheap end of the range.
	_skater.velocity = Vector3(1.0, 0.0, -1.0)
	_skater.move_intent = Vector2.ZERO
	_skater.brake_intent = false
	_skater.current_shot_state = SkaterStateMachine.State.SHOT_BLOCKING


func _bench(label: String, fn: Callable) -> void:
	fn.call()  # warm: first-call inits, smoothing seeds, scratch growth
	var t0: int = Time.get_ticks_usec()
	for _i: int in REPS:
		fn.call()
	_results.append({
		"label": label,
		"us": float(Time.get_ticks_usec() - t0) / float(REPS),
	})


func _print_results() -> void:
	var widest: int = 0
	for r: Dictionary in _results:
		widest = maxi(widest, (r["label"] as String).length())
	gut.p("")
	gut.p("── Render-pose cost (µs/call, %d reps) ──" % REPS)
	for r: Dictionary in _results:
		gut.p("  %s  %8.2f" % [(r["label"] as String).rpad(widest), r["us"]])
	gut.p("")


# The headline plus its parts. The parts DO sum here, near enough:
# _render_pose_update is exactly the three calls below it.
func test_render_pose_costs() -> void:
	var delta: float = 1.0 / 120.0
	var aim: Vector3 = _skater.global_position + Vector3(1.2, 0.0, -3.0)
	_skate_forward()

	_bench("_render_pose_update (WHOLE)", func() -> void:
		_controller._render_pose_update(delta))

	_bench("  gait (_skating.apply)", func() -> void:
		_controller._skating.apply(delta))

	_bench("  head tracking", func() -> void:
		_controller._pose.apply_head_tracking_aim(aim, delta))

	_bench("  bottom-hand IK", func() -> void:
		_controller._ik.update_bottom_hand())

	# The write half, for scale. The freeze sweep says this is ~nothing across
	# ten skaters; if that is wrong, it shows up here as a number comparable to
	# the gait's.
	_bench("[write] update_arm_mesh", func() -> void:
		_skater.update_arm_mesh())
	_bench("[write] update_bottom_arm_mesh", func() -> void:
		_skater.update_bottom_arm_mesh())
	_bench("[write] update_stick_mesh", func() -> void:
		_skater.update_stick_mesh())

	_print_results()
	assert_true(_results.size() > 0, "benchmark produced rows")


# Same call, five states. The gait branches hard on intent / planting / braking,
# so the spread names the expensive branches without extracting them.
func test_gait_cost_by_state() -> void:
	var delta: float = 1.0 / 120.0
	_results.clear()

	for spec: Array in [
			["skating (intent + speed)", _skate_forward],
			["gliding (speed, no intent)", _glide],
			["at rest", _rest],
			["hockey stop (braking)", _hockey_stop],
			["shot-blocking (planted)", _blocking],
		]:
		var setter: Callable = spec[1]
		setter.call()
		# Settle the smoothing so the timed run measures the STEADY state rather
		# than the ease toward it — several signals lerp toward their target.
		for _w: int in 240:
			_controller._skating.apply(delta)
		_bench(spec[0] as String, func() -> void:
			_controller._skating.apply(delta))

	_print_results()
	assert_true(_results.size() > 0, "benchmark produced rows")


# The orthonormal-basis question, isolated. The gait's intent block runs
# `_skater.global_transform.basis.inverse()` every call, and the skater root's
# basis is only ever written as `rotation.y = ...` (Skater.set_facing) — a pure
# Y rotation, so transposed() is the same matrix for less arithmetic. These two
# lines produce identical results by different routes; the gap IS the price. If
# it is noise, leave the clearer spelling alone.
func test_basis_inverse_vs_transposed() -> void:
	_results.clear()
	var xform: Transform3D = _skater.global_transform
	var v := Vector3(0.4, 0.0, -0.9)

	_bench("[A] basis.inverse() * v", func() -> void:
		var _r: Vector3 = xform.basis.inverse() * v)
	_bench("[B] basis.transposed() * v", func() -> void:
		var _r: Vector3 = xform.basis.transposed() * v)

	# Same answer, or the swap is not available.
	var a: Vector3 = xform.basis.inverse() * v
	var b: Vector3 = xform.basis.transposed() * v
	assert_almost_eq(a.distance_to(b), 0.0, 0.0001,
			"transposed() must equal inverse() on the skater root's basis")
	_print_results()

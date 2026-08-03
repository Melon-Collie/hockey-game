extends GutTest

# Stateful parity: NativeBladeDangle (C++ GDExtension, native/src/) against the
# GDScript reference block in SkaterIKCoordinator.apply_blade_from_mouse, driven
# side by side on two real Skater scenes + SkaterControllers posed identically.
# The reference controller has every native IK handle nulled so its coordinator
# runs the actual GDScript body; the other stays fully native. The smoother
# carries cross-tick state (smoothed blade, dangle velocity, prev skater pos),
# so parity is checked EVERY step — a divergence compounds and trips within a
# few frames of where it happens.
#
# GUT yields frames between test functions; a live controller would tick during
# those frames on one side only, permanently offsetting the state. All
# processing is disabled and every step here is explicit. Goes pending when the
# extension isn't built.

const State = SkaterStateMachine.State
const DELTA: float = 1.0 / 120.0
const TOLERANCE: float = 0.001
const SEED: int = 0x44414E47  # "DANG"

var _rng := RandomNumberGenerator.new()
var _puck: Puck = null
var _state: Node = null
var _skater_ref: Skater = null
var _skater_nat: Skater = null
var _ref: SkaterController = null
var _nat: SkaterController = null
var _step_count: int = 0


class StubGameState extends Node:
	func is_host() -> bool:
		return true

	func is_movement_locked() -> bool:
		return false


func before_all() -> void:
	if not ClassDB.class_exists(&"NativeBladeDangle"):
		return
	_puck = load("res://Scenes/Puck.tscn").instantiate() as Puck
	add_child(_puck)
	_puck.global_position = Vector3(20.0, 0.0, 20.0)
	_state = StubGameState.new()
	add_child(_state)

	_skater_ref = _spawn_skater()
	_skater_nat = _spawn_skater()
	_ref = _spawn_controller(_skater_ref)
	_nat = _spawn_controller(_skater_nat)
	# Reference side runs the actual GDScript block — never compare the native
	# port against itself.
	_ref._ik._native_dangle = null
	_ref._ik._native_top = null
	_ref._ik._native_bottom = null


func after_all() -> void:
	for n: Node in [_ref, _nat, _skater_ref, _skater_nat, _puck, _state]:
		if n != null:
			n.free()


func _spawn_skater() -> Skater:
	var skater: Skater = load("res://Scenes/Skater.tscn").instantiate() as Skater
	add_child(skater)
	skater.global_position = Vector3(2.0, GameRules.FACEOFF_SPAWN_HEIGHT, 8.0)
	skater.set_process(false)
	skater.set_physics_process(false)
	return skater


func _spawn_controller(skater: Skater) -> SkaterController:
	var controller := SkaterController.new()
	add_child(controller)
	controller.setup(skater, _puck, _state)
	controller.set_process(false)
	controller.set_physics_process(false)
	return controller


func _native_missing() -> bool:
	if _nat != null:
		return false
	pending("native extension not built — see native/README.md")
	return true


# Hard resync at each test's start: identical pose on both skaters, smoothing
# state dropped on both sides (reset forwards to the native instance).
func _resync() -> void:
	_place(Vector3(2.0, GameRules.FACEOFF_SPAWN_HEIGHT, 8.0), 0.0)
	_ref._sm.set_state(State.SKATING_WITHOUT_PUCK)
	_nat._sm.set_state(State.SKATING_WITHOUT_PUCK)
	_ref._ik.reset_blade_smoothing()
	_nat._ik.reset_blade_smoothing()


func _place(pos: Vector3, yaw: float) -> void:
	for skater: Skater in [_skater_ref, _skater_nat]:
		skater.global_position = pos
		skater.rotation.y = yaw


func _set_shot_state(state: int) -> void:
	_ref._sm.set_state(state)
	_nat._sm.set_state(state)


# Runs both coordinators one step from the same input, then compares the
# smoothed blade and the blade the skater ended up with. Returns false (after
# failing the test) on divergence so callers can bail out of long loops.
func _step(mouse: Vector3, delta: float, label: String,
		hold_blade: bool = false, hold_target: Vector3 = Vector3.INF) -> bool:
	var input := InputState.new()
	input.mouse_world_pos = mouse
	_ref._ik.apply_blade_from_mouse(input, delta, hold_blade, hold_target)
	_nat._ik.apply_blade_from_mouse(input, delta, hold_blade, hold_target)
	_step_count += 1

	var where: String = "%s @ step %d" % [label, _step_count]
	var smoothed_err: float = (_ref._ik._smoothed_blade_world
			- _nat._ik._smoothed_blade_world).length()
	if smoothed_err > TOLERANCE:
		fail_test("smoothed blade diverged (%s): gd=%s native=%s err=%.6f" % [
				where, _ref._ik._smoothed_blade_world,
				_nat._ik._smoothed_blade_world, smoothed_err])
		return false
	var blade_err: float = (_skater_ref.get_blade_position()
			- _skater_nat.get_blade_position()).length()
	if blade_err > TOLERANCE:
		fail_test("skater blade diverged (%s): gd=%s native=%s err=%.6f" % [
				where, _skater_ref.get_blade_position(),
				_skater_nat.get_blade_position(), blade_err])
		return false
	return true


# Lissajous cursor around the skater — near, far past ROM, and side-to-side
# whips, all through the second-order arrive law (the default accel > 0).
func _cursor(i: int, center: Vector3, scale: float = 1.0) -> Vector3:
	var t: float = float(i) * DELTA
	return center + Vector3(
			sin(t * 3.1) * 2.2 * scale, 0.0, -1.0 - absf(cos(t * 1.7)) * 2.0 * scale)


func test_cursor_tracking_matches() -> void:
	if _native_missing():
		return
	_resync()
	var center: Vector3 = _skater_ref.global_position
	for i: int in 300:
		if not _step(_cursor(i, center), DELTA, "tracking"):
			return
	# Far cursor: pinned to the ROM boundary, sweeping laterally.
	for i: int in 150:
		var mouse: Vector3 = center + Vector3(sin(float(i) * 0.05) * 8.0, 0.0, -9.0)
		if not _step(mouse, DELTA, "far sweep"):
			return
	pass_test("cursor tracking in lockstep within %f" % TOLERANCE)


func test_skater_translation_matches() -> void:
	if _native_missing():
		return
	_resync()
	# Skate a curve while dangling: the translation carry must not eat the
	# dangle budget on either side.
	var pos := Vector3(2.0, GameRules.FACEOFF_SPAWN_HEIGHT, 8.0)
	for i: int in 300:
		var t: float = float(i) * DELTA
		pos += Vector3(sin(t * 0.9), 0.0, -1.0).normalized() * 6.0 * DELTA
		_place(pos, t * 0.4)
		if not _step(pos + Vector3(cos(t * 2.3) * 1.5, 0.0, -1.8), DELTA, "translate"):
			return
	pass_test("skating translation carry in lockstep within %f" % TOLERANCE)


func test_wrister_aim_paths_match() -> void:
	if _native_missing():
		return
	_resync()
	var center: Vector3 = _skater_ref.global_position
	# Establish a dangle baseline, then enter the aim: the on/off-axis split
	# reads the lagged smoothed blade as its axis.
	for i: int in 60:
		if not _step(center + Vector3(0.5, 0.0, -1.5), DELTA, "pre-aim"):
			return
	_set_shot_state(State.WRISTER_AIM)
	# Fast lateral whips + pull-backs through the split.
	for i: int in 240:
		var t: float = float(i) * DELTA
		var mouse: Vector3 = center + Vector3(sin(t * 6.0) * 2.5, 0.0, -1.0 - cos(t * 2.0) * 1.5)
		if not _step(mouse, DELTA, "aim whip"):
			return
	# Freeze hold (human): target == current blade, near-zero step bookkeeping.
	for i: int in 60:
		if not _step(center + Vector3(1.0, 0.0, -2.0), DELTA, "aim hold", true):
			return
	# Bot hold toward a scored release spot (finite hold_target_world).
	var release: Vector3 = center + Vector3(-0.8, 0.0, -1.3)
	for i: int in 90:
		if not _step(center, DELTA, "bot hold", true, release):
			return
	_set_shot_state(State.SKATING_WITHOUT_PUCK)
	# Exit: the inertia model must resume from a coherent velocity on both sides.
	for i: int in 120:
		if not _step(_cursor(i, center), DELTA, "aim exit"):
			return
	pass_test("wrister aim split/hold in lockstep within %f" % TOLERANCE)


func test_delta_zero_reapply_matches() -> void:
	if _native_missing():
		return
	_resync()
	var pos := Vector3(2.0, GameRules.FACEOFF_SPAWN_HEIGHT, 8.0)
	for i: int in 180:
		pos += Vector3(0.3, 0.0, -1.0).normalized() * 5.0 * DELTA
		_place(pos, 0.0)
		if not _step(pos + Vector3(1.2, 0.0, -1.6), DELTA, "pre-reconcile"):
			return
		# Reconcile final re-apply: delta 0 must NOT snap to the target, while
		# the translation carry and prev-skater update still happen — including
		# across a position snap, exactly like a reconcile.
		if i % 7 == 0:
			pos += Vector3(0.05, 0.0, -0.04)
			_place(pos, 0.0)
			if not _step(pos + Vector3(-2.0, 0.0, -2.5), 0.0, "reconcile re-apply"):
				return
	pass_test("delta==0 re-apply in lockstep within %f" % TOLERANCE)


func test_reset_and_seed_match() -> void:
	if _native_missing():
		return
	_resync()
	var center: Vector3 = _skater_ref.global_position
	for i: int in 90:
		if not _step(_cursor(i, center), DELTA, "pre-reset"):
			return
	# Reconcile-entry reset: next solve re-seeds from the first input's target.
	_ref._ik.reset_blade_smoothing()
	_nat._ik.reset_blade_smoothing()
	for i: int in 90:
		if not _step(_cursor(i + 31, center), DELTA, "post-reset"):
			return
	# Follow-through handoff seed: dangle resumes from rest at the seeded spot.
	var seed_pos: Vector3 = center + Vector3(0.9, 0.0, -1.1)
	_ref._ik.seed_blade_smoothing(seed_pos)
	_nat._ik.seed_blade_smoothing(seed_pos)
	for i: int in 90:
		if not _step(_cursor(i + 67, center), DELTA, "post-seed"):
			return
	pass_test("reset/seed handoffs in lockstep within %f" % TOLERANCE)


func test_first_order_fallback_matches() -> void:
	if _native_missing():
		return
	_resync()
	# max_blade_accel 0 disables inertia — the pre-v4 servo. Syncing through
	# invalidate_configs is the same route apply_attributes uses.
	for c: SkaterController in [_ref, _nat]:
		c.max_blade_accel = 0.0
		c._ik.invalidate_configs()
	var center: Vector3 = _skater_ref.global_position
	for i: int in 240:
		if not _step(_cursor(i, center, 1.4), DELTA, "first-order"):
			return
	for c: SkaterController in [_ref, _nat]:
		c.max_blade_accel = 250.0
		c._ik.invalidate_configs()
	pass_test("first-order fallback in lockstep within %f" % TOLERANCE)


func test_chaos_fuzz_matches() -> void:
	if _native_missing():
		return
	_rng.seed = SEED
	_resync()
	var pos := Vector3(2.0, GameRules.FACEOFF_SPAWN_HEIGHT, 8.0)
	var yaw: float = 0.0
	var steps_done: int = 0
	while steps_done < 1800:
		var dwell: int = _rng.randi_range(4, 30)
		var vel := Vector3(_rng.randf_range(-7.0, 7.0), 0.0, _rng.randf_range(-7.0, 7.0))
		var yaw_rate: float = _rng.randf_range(-2.0, 2.0)
		var mouse_off := Vector3(_rng.randf_range(-6.0, 6.0), 0.0, _rng.randf_range(-6.0, -0.3))
		var aiming: bool = _rng.randf() < 0.25
		_set_shot_state(State.WRISTER_AIM if aiming else State.SKATING_WITHOUT_PUCK)
		var hold: bool = aiming and _rng.randf() < 0.5
		var hold_target: Vector3 = Vector3.INF
		if hold and _rng.randf() < 0.5:
			hold_target = pos + Vector3(_rng.randf_range(-1.0, 1.0), 0.0, _rng.randf_range(-1.5, -0.5))
		if _rng.randf() < 0.06:
			_ref._ik.reset_blade_smoothing()
			_nat._ik.reset_blade_smoothing()
		if _rng.randf() < 0.06:
			var seed_pos: Vector3 = pos + Vector3(
					_rng.randf_range(-1.2, 1.2), 0.0, _rng.randf_range(-1.6, -0.4))
			_ref._ik.seed_blade_smoothing(seed_pos)
			_nat._ik.seed_blade_smoothing(seed_pos)
		# Occasional off-rate frame and reconcile-style delta 0 re-applies.
		var delta: float = DELTA if _rng.randf() < 0.85 else _rng.randf_range(1.0 / 30.0, 1.0 / 20.0)
		if _rng.randf() < 0.1:
			delta = 0.0
		for i: int in dwell:
			pos += vel * maxf(delta, 0.0) if delta > 0.0 else Vector3.ZERO
			yaw += yaw_rate * delta
			_place(pos, yaw)
			if not _step(pos + mouse_off, delta, "chaos", hold, hold_target):
				return
			steps_done += 1
	pass_test("%d chaos steps in lockstep within %f" % [steps_done, TOLERANCE])

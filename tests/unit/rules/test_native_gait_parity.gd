extends GutTest

# Stateful parity: NativeSkaterGait (C++ GDExtension, native/src/) against the
# GDScript reference SkaterSkatingCoordinator, driven side by side through the
# same input sequences on a real Skater scene + SkaterController. Both solvers
# carry ~40 floats of smoothed internal state, so parity is checked EVERY step
# of every scenario — a logic divergence compounds and trips within a few
# frames of where it happens.
#
# The CaptureSkater subclass swaps in for the scene's script before _ready so
# the GDScript coordinator's three pose writes land in inspectable fields
# instead of skeleton bone poses. Goes pending when the extension isn't built.

const State = SkaterStateMachine.State
const DELTA: float = 1.0 / 120.0
const TOLERANCE: float = 0.001
const SEED: int = 0x47414954  # "GAIT"

# NativeSkaterGait.apply flag bits.
const F_BRAKE: int = 1
const F_HIT: int = 2
const F_BLADE_UP: int = 4
const F_LEFTY: int = 8
const F_SPRINT: int = 16
const F_FACEOFF: int = 32


class CaptureSkater extends Skater:
	var cap_leg: PackedFloat64Array = PackedFloat64Array([0, 0, 0, 0, 0, 0, 0, 0])
	var cap_evert: PackedFloat64Array = PackedFloat64Array([0, 0])
	var cap_crouch: float = 0.0

	func set_leg_swing(left_pitch: float, left_roll: float, left_knee: float,
			right_pitch: float, right_roll: float, right_knee: float,
			left_yaw: float = 0.0, right_yaw: float = 0.0) -> void:
		cap_leg[0] = left_pitch
		cap_leg[1] = left_roll
		cap_leg[2] = left_knee
		cap_leg[3] = right_pitch
		cap_leg[4] = right_roll
		cap_leg[5] = right_knee
		cap_leg[6] = left_yaw
		cap_leg[7] = right_yaw

	func set_foot_eversion(left_roll: float, right_roll: float) -> void:
		cap_evert[0] = left_roll
		cap_evert[1] = right_roll

	var cap_edge: PackedFloat64Array = PackedFloat64Array([0, 0])

	func set_edge_loads(left: float, right: float) -> void:
		cap_edge[0] = left
		cap_edge[1] = right

	func set_skating_crouch_drop(drop: float) -> void:
		cap_crouch = drop


class StubGameState extends Node:
	var faceoff_prep: bool = false

	func is_host() -> bool:
		return true

	func is_movement_locked() -> bool:
		return false

	func is_faceoff_prep() -> bool:
		return faceoff_prep


var _rng := RandomNumberGenerator.new()
var _skater: CaptureSkater = null
var _controller: SkaterController = null
var _puck: Puck = null
var _state: StubGameState = null
var _native: RefCounted = null
var _configure_missing: String = ""
var _step_count: int = 0


func before_all() -> void:
	if not ClassDB.class_exists(&"NativeSkaterGait"):
		return
	_puck = load("res://Scenes/Puck.tscn").instantiate() as Puck
	add_child(_puck)
	_puck.global_position = Vector3(20.0, 0.0, 20.0)

	var skater_node: Node = load("res://Scenes/Skater.tscn").instantiate()
	skater_node.set_script(CaptureSkater)
	_skater = skater_node as CaptureSkater
	add_child(_skater)
	_skater.global_position = Vector3(2.0, GameRules.FACEOFF_SPAWN_HEIGHT, 8.0)

	_state = StubGameState.new()
	add_child(_state)

	_controller = SkaterController.new()
	add_child(_controller)
	_controller.setup(_skater, _puck, _state)
	# The coordinator is now WIRED to the native port — null its handle so the
	# reference side of this parity suite runs the actual GDScript body instead
	# of comparing the native port against itself.
	_controller._skating._native = null
	# GUT yields frames between test functions; a live controller would tick
	# the GDScript gait during those frames while the native one stands still,
	# permanently offsetting the stride phase. All stepping here is explicit.
	_controller.set_process(false)
	_controller.set_physics_process(false)
	_skater.set_process(false)
	_skater.set_physics_process(false)

	_native = ClassDB.instantiate(&"NativeSkaterGait")
	_native.set_state_ids(
			State.SKATING_WITH_PUCK, State.SKATING_WITHOUT_PUCK,
			State.SHOT_BLOCKING, State.FOLLOW_THROUGH, State.WRISTER_AIM,
			State.SLAPPER_CHARGE_WITH_PUCK, State.SLAPPER_CHARGE_WITHOUT_PUCK,
			State.ONE_TIMER_RETENTION)
	_native.set_leg_scale(_controller._skating.leg_scale)
	_configure_missing = _native.configure(_controller)


func after_all() -> void:
	if _controller != null:
		_controller.free()
	if _skater != null:
		_skater.free()
	if _puck != null:
		_puck.free()
	if _state != null:
		_state.free()


func _native_missing() -> bool:
	if _native != null:
		return false
	NativeParityGuard.report_missing(self, "NativeSkaterGait")
	return true


func _gd() -> SkaterSkatingCoordinator:
	return _controller._skating


# Runs both implementations one step from the same posed inputs, then compares
# every output channel. Returns false (after failing the test) on divergence
# so callers can bail out of long loops.
func _step(delta: float, label: String) -> bool:
	_gd().apply(delta)
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
	var code: int = _native.apply(delta, _skater.velocity,
			_skater.global_transform.basis, _skater.move_intent,
			_skater.current_shot_state, _skater.shot_charge,
			_controller.stagger_timer, _controller.knockdown_timer,
			_controller.knockdown_elapsed(),
			_controller.celebration_progress(), flags)
	_step_count += 1

	var where: String = "%s @ step %d" % [label, _step_count]
	if _gd()._settled != (code != 0):
		fail_test("settle mismatch (%s): gd=%s native_code=%d" % [
				where, _gd()._settled, code])
		return false
	if code != 0:
		return true

	var pairs: Array = [
		["l_pitch", _skater.cap_leg[0], _native.get_l_pitch()],
		["l_roll", _skater.cap_leg[1], _native.get_l_roll()],
		["l_knee", _skater.cap_leg[2], _native.get_l_knee()],
		["r_pitch", _skater.cap_leg[3], _native.get_r_pitch()],
		["r_roll", _skater.cap_leg[4], _native.get_r_roll()],
		["r_knee", _skater.cap_leg[5], _native.get_r_knee()],
		["l_yaw", _skater.cap_leg[6], _native.get_l_yaw()],
		["r_yaw", _skater.cap_leg[7], _native.get_r_yaw()],
		["evert_l", _skater.cap_evert[0], _native.get_foot_evert_l()],
		["evert_r", _skater.cap_evert[1], _native.get_foot_evert_r()],
		["edge_l", _skater.cap_edge[0], _native.get_edge_load_l()],
		["edge_r", _skater.cap_edge[1], _native.get_edge_load_r()],
		["crouch", _skater.cap_crouch, _native.get_crouch_drop()],
		["trunk_pitch", _gd().trunk_pitch_add, _native.get_trunk_pitch_add()],
		["trunk_roll", _gd().trunk_roll_add, _native.get_trunk_roll_add()],
		["stop_yaw", _gd().stop_yaw_offset, _native.get_stop_yaw_offset()],
		["travel_yaw", _gd().travel_align_yaw, _native.get_travel_align_yaw()],
		["shot_hip_yaw", _gd().shot_hip_yaw, _native.get_shot_hip_yaw()],
	]
	for p: Array in pairs:
		var err: float = absf((p[1] as float) - (p[2] as float))
		if err > TOLERANCE:
			fail_test("%s diverged (%s): gd=%.6f native=%.6f err=%.6f" % [
					p[0], where, p[1], p[2], err])
			return false
	return true


func _pose(vel: Vector3, intent: Vector2, yaw: float) -> void:
	_skater.velocity = vel
	_skater.move_intent = intent
	_skater.rotation.y = yaw


# Hard resync at each test's start: tests must not depend on what state the
# previous test (or any stray engine frame) left behind.
func _resync() -> void:
	_quiet_pose()
	_gd().reset_to_rest()
	_native.reset_to_rest()


func _quiet_pose() -> void:
	_pose(Vector3.ZERO, Vector2.ZERO, 0.0)
	_skater.brake_intent = false
	_skater.current_shot_state = State.SKATING_WITHOUT_PUCK
	_skater.shot_charge = 0.0
	_skater.hit_committed = false
	_skater.blade_up = false
	_controller.sprint_active = false
	_controller.stagger_timer = 0.0
	_controller.knockdown_timer = 0.0
	_controller._knockdown_total = 0.0
	_controller._celebration_timer = 0.0
	_state.faceoff_prep = false


# Every tunable the port reads must exist on the controller by its exact
# @export name — a rename on either side fails here, not as silent drift.
func test_configure_finds_every_tunable() -> void:
	if _native_missing():
		return
	assert_eq(_configure_missing, "", "controller properties missing: %s" % _configure_missing)


func test_scripted_scenarios_match() -> void:
	if _native_missing():
		return
	_rng.seed = SEED
	_resync()

	# Skate forward with acceleration (effort/push paths), then glide out.
	var vel := Vector3.ZERO
	for i: int in 240:
		vel = vel.move_toward(Vector3(3.0, 0.0, -5.5), 6.0 * DELTA)
		_pose(vel, Vector2(0.4, -0.9), 0.1)
		if not _step(DELTA, "accelerate"):
			return
	for i: int in 180:
		vel = vel.move_toward(Vector3(1.5, 0.0, -2.5), 1.2 * DELTA)
		_pose(vel, Vector2.ZERO, 0.1)
		if not _step(DELTA, "glide"):
			return

	# Carve: velocity direction sweeps while intent holds across travel.
	for i: int in 300:
		var ang: float = 0.9 * float(i) * DELTA
		vel = Vector3(sin(ang), 0.0, -cos(ang)) * 5.0
		_pose(vel, Vector2(1.0, 0.0), ang * 0.8)
		if not _step(DELTA, "carve"):
			return

	# Hockey stop: brake hard from speed (effort collapses, stop pose latches).
	_skater.brake_intent = true
	for i: int in 160:
		vel = vel.move_toward(Vector3.ZERO, 9.0 * DELTA)
		_pose(vel, Vector2.ZERO, 0.6)
		if not _step(DELTA, "hockey stop"):
			return
	_skater.brake_intent = false

	# Backpedal and shuffle (aim-locked stances).
	for i: int in 160:
		vel = vel.move_toward(Vector3(0.0, 0.0, 3.0), 4.0 * DELTA)
		_pose(vel, Vector2(0.0, 1.0), 0.0)
		if not _step(DELTA, "backpedal"):
			return
	for i: int in 160:
		vel = vel.move_toward(Vector3(1.2, 0.0, 0.0), 4.0 * DELTA)
		_pose(vel, Vector2(1.0, 0.0), 0.0)
		if not _step(DELTA, "shuffle"):
			return

	# Sprint burst.
	_controller.sprint_active = true
	for i: int in 200:
		vel = vel.move_toward(Vector3(0.0, 0.0, -8.5), 7.0 * DELTA)
		_pose(vel, Vector2(0.0, -1.0), 0.0)
		if not _step(DELTA, "sprint"):
			return
	_controller.sprint_active = false
	pass_test("all scripted skating scenarios in lockstep within %f" % TOLERANCE)


func test_shot_and_contact_paths_match() -> void:
	if _native_missing():
		return
	_rng.seed = SEED + 1
	_resync()
	var vel := Vector3(1.0, 0.0, -2.0)

	# Wrister: aim + charge -> follow-through -> back to skating.
	_skater.current_shot_state = State.WRISTER_AIM
	for i: int in 90:
		_skater.shot_charge = minf(float(i) / 60.0, 1.0)
		_pose(vel, Vector2(0.2, -0.5), 0.2)
		if not _step(DELTA, "wrister aim"):
			return
	_skater.current_shot_state = State.FOLLOW_THROUGH
	for i: int in 60:
		_pose(vel, Vector2.ZERO, 0.2)
		if not _step(DELTA, "wrister follow-through"):
			return
	_skater.current_shot_state = State.SKATING_WITH_PUCK
	_skater.shot_charge = 0.0

	# Slapper: wind-up -> retention -> follow-through.
	_skater.current_shot_state = State.SLAPPER_CHARGE_WITH_PUCK
	for i: int in 80:
		_skater.shot_charge = minf(float(i) / 70.0, 1.0)
		_pose(vel, Vector2.ZERO, 0.2)
		if not _step(DELTA, "slap charge"):
			return
	_skater.current_shot_state = State.ONE_TIMER_RETENTION
	for i: int in 30:
		if not _step(DELTA, "retention"):
			return
	_skater.current_shot_state = State.FOLLOW_THROUGH
	for i: int in 70:
		if not _step(DELTA, "slap follow-through"):
			return
	_skater.current_shot_state = State.SKATING_WITHOUT_PUCK
	_skater.shot_charge = 0.0

	# Shot block: one-knee drop in and out (foot eversion path).
	_skater.current_shot_state = State.SHOT_BLOCKING
	for i: int in 120:
		_pose(Vector3.ZERO, Vector2.ZERO, 0.2)
		if not _step(DELTA, "block"):
			return
	_skater.current_shot_state = State.SKATING_WITHOUT_PUCK
	for i: int in 80:
		if not _step(DELTA, "block release"):
			return

	# Check drive (same event injected into both), commit, stick lift.
	var dir := Vector3(0.7, 0.0, -0.7)
	_gd().start_check_drive(dir, 0.9)
	_native.start_check_drive(dir, 0.9)
	for i: int in 100:
		_pose(vel, Vector2(0.3, -0.8), 0.2)
		if not _step(DELTA, "check drive"):
			return
	_skater.hit_committed = true
	_skater.blade_up = true
	for i: int in 100:
		if not _step(DELTA, "commit + lift"):
			return
	_skater.hit_committed = false
	_skater.blade_up = false

	# Stagger, then knockdown layered over it.
	_controller.stagger_timer = 1.4
	for i: int in 80:
		_controller.stagger_timer = maxf(_controller.stagger_timer - DELTA, 0.0)
		if not _step(DELTA, "stagger"):
			return
	# The window total feeds knockdown_elapsed(), which drives the entry ramp —
	# maintained here the way apply_knockdown/_sync_knockdown_meta would.
	_controller.knockdown_timer = 1.2
	_controller._knockdown_total = 1.2
	for i: int in 120:
		_controller.stagger_timer = maxf(_controller.stagger_timer - DELTA, 0.0)
		_controller.knockdown_timer = maxf(_controller.knockdown_timer - DELTA, 0.0)
		if not _step(DELTA, "knockdown"):
			return

	# Faceoff ready stance, then celebration bounce.
	_state.faceoff_prep = true
	_pose(Vector3.ZERO, Vector2.ZERO, 0.0)
	for i: int in 150:
		if not _step(DELTA, "faceoff"):
			return
	_state.faceoff_prep = false
	_controller.start_celebration(1.5)
	for i: int in 150:
		_controller._celebration_timer = maxf(_controller._celebration_timer - DELTA, 0.0)
		if not _step(DELTA, "celebration"):
			return
	_controller._celebration_timer = 0.0
	pass_test("all shot/contact/timer paths in lockstep within %f" % TOLERANCE)


func test_settle_and_reset_match() -> void:
	if _native_missing():
		return
	_resync()
	# Some motion first so there's state to settle from.
	for i: int in 120:
		_pose(Vector3(2.0, 0.0, -2.0), Vector2(0.5, -0.5), 0.0)
		if not _step(DELTA, "pre-settle motion"):
			return
	# Quiet for well past the settle window: both must settle in lockstep.
	_quiet_pose()
	for i: int in 200:
		if not _step(DELTA, "settling"):
			return
	assert_true(_gd()._settled, "GDScript gait settled")
	assert_true(_native.is_settled(), "native gait settled")
	# Any input wakes both the same frame.
	_pose(Vector3.ZERO, Vector2(0.0, -1.0), 0.0)
	for i: int in 60:
		if not _step(DELTA, "wake"):
			return
	assert_false(_gd()._settled, "GDScript gait woke")
	# Explicit teleport reset, injected into both.
	_gd().reset_to_rest()
	_native.reset_to_rest()
	for i: int in 60:
		_pose(Vector3(1.0, 0.0, -1.0), Vector2(0.4, -0.4), 0.3)
		if not _step(DELTA, "post-reset"):
			return


func test_chaos_fuzz_matches() -> void:
	if _native_missing():
		return
	_rng.seed = SEED + 2
	_resync()
	var states: Array[int] = [
		State.SKATING_WITH_PUCK, State.SKATING_WITHOUT_PUCK,
		State.SHOT_BLOCKING, State.FOLLOW_THROUGH, State.WRISTER_AIM,
		State.SLAPPER_CHARGE_WITH_PUCK, State.SLAPPER_CHARGE_WITHOUT_PUCK,
		State.ONE_TIMER_RETENTION,
	]
	var vel := Vector3.ZERO
	var yaw: float = 0.0
	var steps_done: int = 0
	while steps_done < 2400:
		# Dwell on a random scenario for a stretch, like real play does.
		var dwell: int = _rng.randi_range(5, 45)
		var target_vel := Vector3(_rng.randf_range(-8.0, 8.0), 0.0, _rng.randf_range(-8.0, 8.0))
		var intent := Vector2.ZERO
		if _rng.randf() < 0.75:
			var oct: int = _rng.randi_range(0, 7)
			intent = Vector2(sin(oct * PI / 4.0), -cos(oct * PI / 4.0))
		var yaw_rate: float = _rng.randf_range(-2.0, 2.0)
		_skater.brake_intent = _rng.randf() < 0.15
		_controller.sprint_active = _rng.randf() < 0.2
		_skater.hit_committed = _rng.randf() < 0.1
		_skater.blade_up = _rng.randf() < 0.1
		_state.faceoff_prep = _rng.randf() < 0.05
		if _rng.randf() < 0.3:
			_skater.current_shot_state = states[_rng.randi_range(0, states.size() - 1)]
		_skater.shot_charge = _rng.randf() if _rng.randf() < 0.5 else 0.0
		if _rng.randf() < 0.08:
			_controller.stagger_timer = _rng.randf_range(0.2, 1.5)
		if _rng.randf() < 0.05:
			_controller.knockdown_timer = _rng.randf_range(0.2, 1.2)
			_controller._knockdown_total = _controller.knockdown_timer
		if _rng.randf() < 0.08:
			var dir := Vector3(_rng.randf_range(-1, 1), 0.0, _rng.randf_range(-1, 1))
			var hit: float = _rng.randf_range(0.2, 1.0)
			_gd().start_check_drive(dir, hit)
			_native.start_check_drive(dir, hit)
		# Occasional off-rate frame (render hitch) — delta parity isn't 120 Hz-only.
		var delta: float = DELTA if _rng.randf() < 0.9 else _rng.randf_range(1.0 / 30.0, 1.0 / 20.0)
		for i: int in dwell:
			vel = vel.move_toward(target_vel, 8.0 * delta)
			yaw += yaw_rate * delta
			_pose(vel, intent, yaw)
			_controller.stagger_timer = maxf(_controller.stagger_timer - delta, 0.0)
			_controller.knockdown_timer = maxf(_controller.knockdown_timer - delta, 0.0)
			if not _step(delta, "chaos"):
				return
			steps_done += 1
	pass_test("%d chaos steps in lockstep within %f" % [steps_done, TOLERANCE])

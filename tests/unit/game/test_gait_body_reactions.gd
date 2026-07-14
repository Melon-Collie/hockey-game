extends GutTest

# Reactive body language in the gait (SkaterSkatingCoordinator): the
# check-delivery drive (hitter finishing through a landed hit, armed by the
# host-authoritative broadcast via start_check_drive), the stick-lift working
# posture (keyed off the replicated blade_up), and the goal-celebration knee
# bounce (reading the controller's celebration timer, which the controllers age
# at physics rate via tick_celebration — the gait itself only reads the progress
# now that it runs at render rate).

const SKATER_SCENE: PackedScene = preload("res://Scenes/Skater.tscn")
const DT: float = 1.0 / 120.0

var _skater: Skater = null
var _controller: SkaterController = null
var _coord: SkaterSkatingCoordinator = null
var _shin_l: Node3D = null


func before_each() -> void:
	_skater = SKATER_SCENE.instantiate() as Skater
	add_child_autofree(_skater)
	_skater.set_physics_process(false)
	_skater.set_process(false)
	_controller = SkaterController.new()
	autofree(_controller)
	var sm := SkaterStateMachine.new()
	_coord = SkaterSkatingCoordinator.new()
	_coord.setup(_skater, sm, _controller)
	_skater.set_facing(Vector2(0.0, -1.0))
	_skater.velocity = Vector3.ZERO
	_skater.move_intent = Vector2.ZERO
	_shin_l = _skater.get_node("MeshRoot/LowerBody/LegL/ShinL") as Node3D


func _tick(count: int) -> void:
	for _i: int in count:
		# The controllers age the celebration timer at physics rate now; the gait
		# (render rate) only reads its progress. Mirror both here so the coordinator
		# sees the countdown advance.
		_controller.tick_celebration(DT)
		_coord.apply(DT)


func test_check_drive_leans_into_hit_and_settles() -> void:
	# A full-hardness hit straight ahead (world −Z is this body's forward).
	_coord.start_check_drive(Vector3(0.0, 0.0, -1.0), 1.0)
	var min_pitch: float = INF
	var min_shin: float = INF
	for _i: int in 54:  # 0.45 s = check_drive_time
		_coord.apply(DT)
		min_pitch = minf(min_pitch, _coord.trunk_pitch_add)
		min_shin = minf(min_shin, _shin_l.rotation.x)
	assert_lt(min_pitch, -0.1,
			"the trunk should drive INTO the hit (peak pitch add %.3f rad)" % min_pitch)
	assert_lt(min_shin, -0.1, "the legs should drive under the finishing shoulder")
	_tick(30)
	assert_almost_eq(_coord.trunk_pitch_add, 0.0, 0.01,
			"the drive should settle out after check_drive_time")


func test_check_drive_refire_hardens_without_restarting() -> void:
	_coord.start_check_drive(Vector3(0.0, 0.0, -1.0), 0.4)
	_tick(20)  # mid-envelope
	_coord.start_check_drive(Vector3(1.0, 0.0, 0.0), 1.0)  # grind re-fire
	# The clock must not restart: the drive finishes on the original timer.
	_tick(40)  # 20 + 40 = 60 ticks = 0.5 s > check_drive_time
	assert_almost_eq(_coord.trunk_pitch_add, 0.0, 0.01,
			"a sustained-contact re-fire must not extend the drive forever")


func test_stick_lift_pops_chest_and_releases() -> void:
	_skater.blade_up = true
	_tick(90)
	assert_gt(_coord.trunk_pitch_add, 0.03,
			"the lift should tip the chest up (pitch add %.3f)" % _coord.trunk_pitch_add)
	assert_lt(_shin_l.rotation.x, -0.05, "the lift should carry a light working coil")
	_skater.blade_up = false
	_tick(120)
	assert_almost_eq(_coord.trunk_pitch_add, 0.0, 0.01, "the lift read should release")


func test_celebration_bounces_knees_and_timer_ages() -> void:
	_controller.start_celebration(1.5)
	var min_shin: float = INF
	var max_shin_late: float = -INF
	for i: int in 180:  # the full 1.5 s window
		_controller.tick_celebration(DT)  # physics-rate aging (was owned by the gait)
		_coord.apply(DT)
		min_shin = minf(min_shin, _shin_l.rotation.x)
		if i > 36:  # past the ramp — the pump should return near straight between hops
			max_shin_late = maxf(max_shin_late, _shin_l.rotation.x)
	assert_lt(min_shin, -0.25,
			"the celebration should pump the knees (deepest %.3f rad)" % min_shin)
	assert_gt(max_shin_late, -0.1,
			"the pump should release between hops, not hold a squat")
	# The controllers age the timer at physics rate now (tick_celebration), on
	# every path including wire-fed remotes. A few grace ticks absorb the
	# 180 × (1/120) float-summation residue.
	_tick(6)
	assert_false(_controller.is_celebrating(), "the timer should have aged out")

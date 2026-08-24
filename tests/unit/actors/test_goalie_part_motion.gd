extends GutTest

# Goalie.get_collision_part_velocities — the per-tick finite difference the
# analytic save resolves its rebound against (GoalieSaveRules.rebound_velocity).
#
# It is measured from WORLD origins, and this is the test that says so: moving
# the goalie's ROOT has to show up on every part, because a shuffling goalie
# carries his pads with him and a puck resting against one is met by a moving
# wall either way. A sampler differencing the pose config instead would report
# zero for all of it and pass every display-less assertion about the pose.

const _GOALIE_SCENE: String = "res://Scenes/Goalie.tscn"


func _live_goalie() -> Goalie:
	var packed: PackedScene = load(_GOALIE_SCENE)
	var goalie: Goalie = packed.instantiate() as Goalie
	add_child_autofree(goalie)
	return goalie


func test_a_still_goalie_reports_no_part_motion() -> void:
	var goalie: Goalie = _live_goalie()
	await get_tree().physics_frame
	goalie.get_collision_part_velocities()
	await get_tree().physics_frame
	for v: Vector3 in goalie.get_collision_part_velocities():
		assert_almost_eq(v.length(), 0.0, 0.0001, "a parked goalie's parts are still")


func test_sliding_the_goalie_moves_every_part_with_him() -> void:
	var goalie: Goalie = _live_goalie()
	await get_tree().physics_frame
	goalie.get_collision_part_velocities()   # baseline
	var step: float = 1.0 / float(Engine.physics_ticks_per_second)
	var speed: float = 2.0
	goalie.position += Vector3(speed * step, 0.0, 0.0)
	await get_tree().physics_frame
	var vels: PackedVector3Array = goalie.get_collision_part_velocities()
	assert_gt(vels.size(), 0, "the goalie has collision parts to measure")
	for v: Vector3 in vels:
		assert_almost_eq(v.x, speed, 0.01, "every part carries the body's own pace")


func test_a_gap_in_sampling_reports_no_velocity_rather_than_a_stale_average() -> void:
	# The puck only asks near the net, so the first ask after a spell up ice is
	# many ticks after the last one. Averaging the goalie's travel over that gap
	# would push the puck with motion that is long finished.
	var goalie: Goalie = _live_goalie()
	await get_tree().physics_frame
	goalie.get_collision_part_velocities()
	goalie.position += Vector3(1.0, 0.0, 0.0)
	await get_tree().physics_frame
	await get_tree().physics_frame
	for v: Vector3 in goalie.get_collision_part_velocities():
		assert_almost_eq(v.length(), 0.0, 0.0001, "no honest estimate across the gap")


func test_repeated_reads_inside_one_tick_agree() -> void:
	# The client's re-predict calls the gather several times per frame.
	# Differencing per call would charge one tick of travel to each of them.
	var goalie: Goalie = _live_goalie()
	await get_tree().physics_frame
	goalie.get_collision_part_velocities()
	goalie.position += Vector3(0.02, 0.0, 0.0)
	await get_tree().physics_frame
	var first: PackedVector3Array = goalie.get_collision_part_velocities().duplicate()
	assert_eq(goalie.get_collision_part_velocities(), first, "second read is the same tick")
	assert_eq(goalie.get_collision_part_velocities(), first, "and so is the third")

extends GutTest

# The gait's rotations and the sizing seam's positions live on the leg rig's
# bones now, not on Node3Ds — see Skater.leg_bone_euler / leg_bone_position.
const _LEG_L: int = SkaterMeshBuilder.LegBone.LEG_L
const _LEG_R: int = SkaterMeshBuilder.LegBone.LEG_R
const _SHIN_L: int = SkaterMeshBuilder.LegBone.SHIN_L
const _SHIN_R: int = SkaterMeshBuilder.LegBone.SHIN_R

# Gait world-direction symmetry — the stride must be IDENTICAL whether the
# skater travels up-ice (−Z) or down-ice (+Z) with facing aligned to travel.
# The gait is meant to be purely body-frame (velocity decomposed through the
# skater's basis), so any tick-by-tick divergence between the two runs is a
# world-frame leak — user-visible as "a distinctively different gait skating
# up vs down". Drives the real Skater scene + SkaterSkatingCoordinator for
# several stride cycles in each direction and diffs every leg channel.

const SKATER_SCENE: PackedScene = preload("res://Scenes/Skater.tscn")
const DT: float = 1.0 / 120.0
const TICKS: int = 240  # 2 s at 120 Hz — several full stride cycles


# Runs the gait for TICKS with the given world travel direction (facing
# aligned to it) and returns one Array of packed leg/pose samples per tick.
func _run_direction(travel: Vector2) -> Array:
	var skater: Skater = SKATER_SCENE.instantiate() as Skater
	add_child_autofree(skater)
	skater.set_physics_process(false)
	skater.set_process(false)
	var controller: SkaterController = SkaterController.new()
	autofree(controller)
	var sm := SkaterStateMachine.new()
	var coord := SkaterSkatingCoordinator.new()
	coord.setup(skater, sm, controller)

	skater.set_facing(travel)
	skater.velocity = Vector3(travel.x, 0.0, travel.y) * 6.0
	# The stride is input-gated (v15 intent byte) — stamp held movement
	# intent so this guards the real stride, not the no-keys glide pose.
	skater.move_intent = travel


	var samples: Array = []
	for _i: int in TICKS:
		coord.apply(DT)
		samples.append([
			skater.leg_bone_euler(_LEG_L), skater.leg_bone_euler(_LEG_R),
			skater.leg_bone_euler(_SHIN_L).x, skater.leg_bone_euler(_SHIN_R).x,
			coord.travel_align_yaw, coord.stop_yaw_offset,
			coord.trunk_pitch_add, coord.trunk_roll_add,
		])
	return samples


func test_up_ice_and_down_ice_strides_match() -> void:
	var up: Array = _run_direction(Vector2(0.0, -1.0))
	var down: Array = _run_direction(Vector2(0.0, 1.0))
	assert_eq(up.size(), down.size())
	var worst: float = 0.0
	var worst_tick: int = -1
	var worst_channel: int = -1
	for i: int in up.size():
		var a: Array = up[i]
		var b: Array = down[i]
		for c: int in a.size():
			var diff: float
			if a[c] is Vector3:
				diff = (a[c] as Vector3 - b[c] as Vector3).length()
			else:
				diff = absf(float(a[c]) - float(b[c]))
			if diff > worst:
				worst = diff
				worst_tick = i
				worst_channel = c
	assert_lt(worst, 0.0001,
			"up-ice vs down-ice gait diverged: worst diff %.6f at tick %d channel %d (0/1=leg rot, 2/3=knee, 4=align_yaw, 5=stop_yaw, 6/7=trunk)"
			% [worst, worst_tick, worst_channel])


# ── Full-pipeline symmetry ────────────────────────────────────────────────────
# Same guard through the whole _process_input path (facing tracking, pose
# lean, IK, gait, movement) with mirrored synthetic inputs: move held along
# travel, cursor 4 m dead ahead. Any divergence here that the coordinator-only
# test above misses lives in the pose/IK/facing layers.

class GameStateStub:
	extends Node

	func is_host() -> bool:
		return false

	func is_movement_locked() -> bool:
		return false


func _run_full_pipeline(travel: Vector2) -> Array:
	var skater: Skater = SKATER_SCENE.instantiate() as Skater
	add_child_autofree(skater)
	skater.set_physics_process(false)
	skater.set_process(false)
	var puck: Puck = (preload("res://Scenes/Puck.tscn").instantiate()) as Puck
	add_child_autofree(puck)
	puck.set_physics_process(false)
	puck.global_position = Vector3(20.0, 0.0, 20.0)  # far away — no interactions
	var gs := GameStateStub.new()
	add_child_autofree(gs)
	var controller := SkaterController.new()
	add_child_autofree(controller)
	controller.setup(skater, puck, gs)
	# The spawn path — syncs the skater's facing AND the pose coordinator's
	# internal facing var (desyncing them was the old spawn-twist bug).
	controller.set_spawn_facing(travel)

	var upper: Node3D = skater.get_node("MeshRoot/UpperBody") as Node3D
	var lower: Node3D = skater.get_node("MeshRoot/LowerBody") as Node3D
	var facing_target: float = atan2(-travel.x, -travel.y)

	var samples: Array = []
	for _i: int in TICKS:
		var input := InputState.new()
		input.delta = DT
		input.move_vector = travel
		input.mouse_world_pos = skater.global_position \
				+ Vector3(travel.x, 0.0, travel.y) * 4.0
		controller._process_input(input, DT)
		samples.append([
			skater.leg_bone_euler(_LEG_L), skater.leg_bone_euler(_LEG_R),
			upper.rotation, lower.rotation,
			angle_difference(facing_target, skater.rotation.y),
			Vector2(skater.velocity.x, skater.velocity.z).length(),
		])
	return samples


func test_full_pipeline_up_vs_down_matches() -> void:
	var up: Array = _run_full_pipeline(Vector2(0.0, -1.0))
	var down: Array = _run_full_pipeline(Vector2(0.0, 1.0))
	var worst: float = 0.0
	var worst_tick: int = -1
	var worst_channel: int = -1
	for i: int in up.size():
		var a: Array = up[i]
		var b: Array = down[i]
		for c: int in a.size():
			var diff: float
			if a[c] is Vector3:
				diff = (a[c] as Vector3 - b[c] as Vector3).length()
			else:
				diff = absf(float(a[c]) - float(b[c]))
			if diff > worst:
				worst = diff
				worst_tick = i
				worst_channel = c
	assert_lt(worst, 0.0001,
			"full-pipeline up vs down diverged: worst diff %.6f at tick %d channel %d (0/1=leg rot, 2=upper rot, 3=lower rot, 4=facing err, 5=speed)"
			% [worst, worst_tick, worst_channel])


func test_east_and_west_strides_match() -> void:
	# Same guard across the rink's X axis — catches leaks keyed on the other
	# world direction.
	var east: Array = _run_direction(Vector2(1.0, 0.0))
	var west: Array = _run_direction(Vector2(-1.0, 0.0))
	var worst: float = 0.0
	for i: int in east.size():
		var a: Array = east[i]
		var b: Array = west[i]
		for c: int in a.size():
			var diff: float
			if a[c] is Vector3:
				diff = (a[c] as Vector3 - b[c] as Vector3).length()
			else:
				diff = absf(float(a[c]) - float(b[c]))
			worst = maxf(worst, diff)
	assert_lt(worst, 0.0001, "east vs west gait diverged (worst diff %.6f)" % worst)

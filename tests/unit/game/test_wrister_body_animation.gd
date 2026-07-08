extends GutTest

# Shot body animation (SkaterSkatingCoordinator) — the load settles the weight
# over the stick-side back leg while the charge builds (wrister drag-charge,
# slapper wind-up), and the release transfers it over the front foot with the
# back leg kicking into extension behind. Driven purely from the replicated
# current_shot_state + shot_charge (the stick-flex contract), so these tests
# drive those fields directly the way a wire-fed remote would.
#
# Default handedness is LEFT (Skater.is_left_handed = true), so the stick side
# — the back leg — is the LEFT leg throughout.

const SKATER_SCENE: PackedScene = preload("res://Scenes/Skater.tscn")
const State = SkaterStateMachine.State
const DT: float = 1.0 / 120.0

var _skater: Skater = null
var _coord: SkaterSkatingCoordinator = null
var _leg_l: Node3D = null
var _leg_r: Node3D = null
var _shin_l: Node3D = null
var _shin_r: Node3D = null


func before_each() -> void:
	_skater = SKATER_SCENE.instantiate() as Skater
	add_child_autofree(_skater)
	_skater.set_physics_process(false)
	_skater.set_process(false)
	var controller: SkaterController = SkaterController.new()
	autofree(controller)
	var sm := SkaterStateMachine.new()
	_coord = SkaterSkatingCoordinator.new()
	_coord.setup(_skater, sm, controller)
	# Standstill, no intent — every stride channel is quiet, so the leg pose is
	# purely the shot stance under test.
	_skater.set_facing(Vector2(0.0, -1.0))
	_skater.velocity = Vector3.ZERO
	_skater.move_intent = Vector2.ZERO
	_leg_l = _skater.get_node("MeshRoot/LowerBody/LegL") as Node3D
	_leg_r = _skater.get_node("MeshRoot/LowerBody/LegR") as Node3D
	_shin_l = _skater.get_node("MeshRoot/LowerBody/LegL/ShinL") as Node3D
	_shin_r = _skater.get_node("MeshRoot/LowerBody/LegR/ShinR") as Node3D


func _tick(count: int) -> void:
	for _i: int in count:
		_coord.apply(DT)


func test_wrister_load_settles_over_back_leg() -> void:
	var rest_body_y: float = _skater.upper_body.position.y
	_skater.current_shot_state = State.WRISTER_AIM
	_skater.shot_charge = 1.0
	_tick(180)  # 1.5 s — load blend fully settled
	# Foot stagger: the stick-side (left) foot drops back behind the front foot.
	assert_lt(_leg_l.rotation.x, _leg_r.rotation.x - 0.05,
			"stick-side foot should stagger back through the load (l %.3f, r %.3f)"
			% [_leg_l.rotation.x, _leg_r.rotation.x])
	# Weight over the stick side: shared roll toward −X (the lefty's stick side).
	assert_lt(_leg_l.rotation.z, -0.01, "legs should roll toward the stick side")
	assert_lt(_leg_r.rotation.z, -0.01, "legs should roll toward the stick side")
	# Hips coil with the load — stick-side (−X) hip back reads as positive yaw.
	assert_gt(_coord.shot_hip_yaw, 0.01, "hips should coil into the load")
	# The load sits into the shot — the stance crouch drops the body.
	assert_lt(_skater.upper_body.position.y, rest_body_y - 0.005,
			"the load stance should sink the body")


func test_release_kicks_back_leg_and_transfers_weight() -> void:
	# Charge fully, then release: the real release zeroes the charge as the
	# state flips, so the kick power must come from the latched smoothed load.
	_skater.current_shot_state = State.WRISTER_AIM
	_skater.shot_charge = 1.0
	_tick(180)
	_skater.current_shot_state = State.FOLLOW_THROUGH
	_skater.shot_charge = 0.0
	# Sample the whole kick window for its extreme pose.
	var max_split: float = 0.0
	var split_l_knee: float = 0.0
	var split_r_knee: float = 0.0
	var split_r_roll: float = 0.0
	var min_hip_yaw: float = INF
	for _i: int in 60:  # 0.5 s = wrister_kick_time
		_coord.apply(DT)
		var split: float = _leg_r.rotation.x - _leg_l.rotation.x
		min_hip_yaw = minf(min_hip_yaw, _coord.shot_hip_yaw)
		if split > max_split:
			max_split = split
			split_l_knee = _shin_l.rotation.x
			split_r_knee = _shin_r.rotation.x
			split_r_roll = _leg_r.rotation.z
	assert_gt(max_split, 0.25,
			"back (stick-side) leg should drive into extension behind (split %.3f rad)" % max_split)
	assert_gt(split_l_knee, split_r_knee + 0.03,
			"kicking knee should straighten past the seated front knee (l %.3f, r %.3f)"
			% [split_l_knee, split_r_knee])
	assert_gt(split_r_roll, 0.005,
			"weight should transfer over the front (+X) foot at the kick peak")
	assert_lt(min_hip_yaw, -0.01, "hips should uncoil through the release")
	# Everything settles after the kick window + load decay.
	_skater.current_shot_state = State.SKATING_WITHOUT_PUCK
	_tick(180)
	assert_almost_eq(_coord.shot_hip_yaw, 0.0, 0.005, "hip yaw should settle to rest")
	assert_almost_eq(_leg_l.rotation.x - _leg_r.rotation.x, 0.0, 0.02,
			"leg split should settle to rest")


func test_quick_shot_release_still_flicks() -> void:
	# A pass fires from carry with no aim state and no charge — the kick must
	# still read at the min-power floor.
	_skater.current_shot_state = State.SKATING_WITH_PUCK
	_tick(10)
	_skater.current_shot_state = State.FOLLOW_THROUGH
	var max_split: float = 0.0
	for _i: int in 60:
		_coord.apply(DT)
		max_split = maxf(max_split, _leg_r.rotation.x - _leg_l.rotation.x)
	assert_gt(max_split, 0.05,
			"an uncharged snap should still flick the back leg (split %.3f rad)" % max_split)


func test_slapper_wind_up_loads_back_leg() -> void:
	var rest_body_y: float = _skater.upper_body.position.y
	# A full wind-up: shot_charge fills over max_slapper_charge_time (0.7 s)
	# while the wind-up completes in slapper_wind_up_time (0.3 s), so charge
	# 1.0 is well past a complete wind-up.
	_skater.current_shot_state = State.SLAPPER_CHARGE_WITH_PUCK
	_skater.shot_charge = 1.0
	_tick(180)
	assert_lt(_leg_l.rotation.x, _leg_r.rotation.x - 0.08,
			"stick-side foot should stagger back through the wind-up (l %.3f, r %.3f)"
			% [_leg_l.rotation.x, _leg_r.rotation.x])
	assert_lt(_leg_l.rotation.z, -0.02, "legs should roll the weight to the stick side")
	assert_gt(_coord.shot_hip_yaw, 0.05, "hips should coil under the wound-up torso")
	assert_lt(_skater.upper_body.position.y, rest_body_y - 0.01,
			"the wind-up should sit deep — the power position")


func test_slapper_release_kicks_through_contact() -> void:
	_skater.current_shot_state = State.SLAPPER_CHARGE_WITH_PUCK
	_skater.shot_charge = 1.0
	_tick(180)
	_skater.current_shot_state = State.FOLLOW_THROUGH
	_skater.shot_charge = 0.0
	var max_split: float = 0.0
	var split_l_knee: float = 0.0
	var split_r_knee: float = 0.0
	var min_hip_yaw: float = INF
	for _i: int in 80:  # 0.67 s — spans slapper_kick_time
		_coord.apply(DT)
		var split: float = _leg_r.rotation.x - _leg_l.rotation.x
		min_hip_yaw = minf(min_hip_yaw, _coord.shot_hip_yaw)
		if split > max_split:
			max_split = split
			split_l_knee = _shin_l.rotation.x
			split_r_knee = _shin_r.rotation.x
	assert_gt(max_split, 0.4,
			"the slap swing should drive the back leg into full extension (split %.3f rad)"
			% max_split)
	assert_gt(split_l_knee, split_r_knee + 0.03,
			"kicking knee should straighten past the seated front knee (l %.3f, r %.3f)"
			% [split_l_knee, split_r_knee])
	assert_lt(min_hip_yaw, -0.05, "hips should uncoil hard through the slap release")


func test_short_wind_up_slap_still_commits() -> void:
	# A one-timer released off a barely-started wind-up: the swing is still a
	# full-body motion, so the kick must fire at the slapper's min-power floor.
	_skater.current_shot_state = State.SLAPPER_CHARGE_WITHOUT_PUCK
	_skater.shot_charge = 0.02
	_tick(12)
	_skater.current_shot_state = State.FOLLOW_THROUGH
	_skater.shot_charge = 0.0
	var max_split: float = 0.0
	for _i: int in 80:
		_coord.apply(DT)
		max_split = maxf(max_split, _leg_r.rotation.x - _leg_l.rotation.x)
	assert_gt(max_split, 0.2,
			"a short-wind slap should still commit the body (split %.3f rad)" % max_split)

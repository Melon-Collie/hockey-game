extends GutTest

# The gait's rotations and the sizing seam's positions live on the leg rig's
# bones now, not on Node3Ds — see Skater.leg_bone_euler / leg_bone_position.
const _LEG_L: int = SkaterMeshBuilder.LegBone.LEG_L
const _LEG_R: int = SkaterMeshBuilder.LegBone.LEG_R
const _SHIN_L: int = SkaterMeshBuilder.LegBone.SHIN_L
const _SHIN_R: int = SkaterMeshBuilder.LegBone.SHIN_R

# Shot body animation (SkaterSkatingCoordinator + the pose coordinator's
# block branch) — the load settles the weight over the stick-side back leg
# while the charge builds (wrister drag-charge, slapper wind-up), the release
# transfers it over the front foot with the back leg kicking into extension
# behind, and the shot block drops to one knee with the far leg extended along
# the ice. Driven purely from the replicated current_shot_state + shot_charge
# (the stick-flex contract), so these tests drive those fields directly the way
# a wire-fed remote would.
#
# Default handedness is LEFT (Skater.is_left_handed = true), so the stick side
# — the back leg on a shot, the kneeling leg on a block — is the LEFT leg
# throughout.

const SKATER_SCENE: PackedScene = preload("res://Scenes/Skater.tscn")
const State = SkaterStateMachine.State
const DT: float = 1.0 / 120.0

var _skater: Skater = null
var _coord: SkaterSkatingCoordinator = null


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


func _tick(count: int) -> void:
	for _i: int in count:
		_coord.apply(DT)


func test_wrister_load_settles_over_back_leg() -> void:
	var rest_body_y: float = _skater.upper_body.position.y
	_skater.current_shot_state = State.WRISTER_AIM
	_skater.shot_charge = 1.0
	_tick(180)  # 1.5 s — load blend fully settled
	# Foot stagger: the stick-side (left) foot drops back behind the front foot.
	assert_lt(_skater.leg_bone_euler(_LEG_L).x, _skater.leg_bone_euler(_LEG_R).x - 0.05,
			"stick-side foot should stagger back through the load (l %.3f, r %.3f)"
			% [_skater.leg_bone_euler(_LEG_L).x, _skater.leg_bone_euler(_LEG_R).x])
	# Weight over the stick side: shared roll toward −X (the lefty's stick side).
	assert_lt(_skater.leg_bone_euler(_LEG_L).z, -0.01, "legs should roll toward the stick side")
	assert_lt(_skater.leg_bone_euler(_LEG_R).z, -0.01, "legs should roll toward the stick side")
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
		var split: float = _skater.leg_bone_euler(_LEG_R).x - _skater.leg_bone_euler(_LEG_L).x
		min_hip_yaw = minf(min_hip_yaw, _coord.shot_hip_yaw)
		if split > max_split:
			max_split = split
			split_l_knee = _skater.leg_bone_euler(_SHIN_L).x
			split_r_knee = _skater.leg_bone_euler(_SHIN_R).x
			split_r_roll = _skater.leg_bone_euler(_LEG_R).z
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
	assert_almost_eq(_skater.leg_bone_euler(_LEG_L).x - _skater.leg_bone_euler(_LEG_R).x, 0.0, 0.02,
			"leg split should settle to rest")


func test_quick_pass_release_still_flicks() -> void:
	# A pass fires from carry with no aim state and no charge — the kick must
	# still read at the min-power floor.
	_skater.current_shot_state = State.SKATING_WITH_PUCK
	_tick(10)
	_skater.current_shot_state = State.FOLLOW_THROUGH
	var max_split: float = 0.0
	for _i: int in 60:
		_coord.apply(DT)
		max_split = maxf(max_split, _skater.leg_bone_euler(_LEG_R).x - _skater.leg_bone_euler(_LEG_L).x)
	assert_gt(max_split, 0.05,
			"an uncharged snap should still flick the back leg (split %.3f rad)" % max_split)


func test_slapper_wind_up_loads_back_leg() -> void:
	var rest_body_y: float = _skater.upper_body.position.y
	# A full wind-up: the pose fills over the same max_slapper_charge_time as
	# shot_charge (the wind-up IS the charge gauge), so charge 1.0 is a
	# complete wind-up.
	_skater.current_shot_state = State.SLAPPER_CHARGE_WITH_PUCK
	_skater.shot_charge = 1.0
	_tick(180)
	assert_lt(_skater.leg_bone_euler(_LEG_L).x, _skater.leg_bone_euler(_LEG_R).x - 0.08,
			"stick-side foot should stagger back through the wind-up (l %.3f, r %.3f)"
			% [_skater.leg_bone_euler(_LEG_L).x, _skater.leg_bone_euler(_LEG_R).x])
	assert_lt(_skater.leg_bone_euler(_LEG_L).z, -0.02, "legs should roll the weight to the stick side")
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
		var split: float = _skater.leg_bone_euler(_LEG_R).x - _skater.leg_bone_euler(_LEG_L).x
		min_hip_yaw = minf(min_hip_yaw, _coord.shot_hip_yaw)
		if split > max_split:
			max_split = split
			split_l_knee = _skater.leg_bone_euler(_SHIN_L).x
			split_r_knee = _skater.leg_bone_euler(_SHIN_R).x
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
		max_split = maxf(max_split, _skater.leg_bone_euler(_LEG_R).x - _skater.leg_bone_euler(_LEG_L).x)
	assert_gt(max_split, 0.2,
			"a short-wind slap should still commit the body (split %.3f rad)" % max_split)


func test_block_drops_to_one_knee() -> void:
	var rest_hips_y: float = _skater.lower_body.position.y
	_skater.current_shot_state = State.SHOT_BLOCKING
	_tick(120)
	# Default handedness is LEFT, so the LEFT knee is the one that drops: thigh
	# pitched forward, shin folded back along the ice, no splay on that side.
	assert_gt(_skater.leg_bone_euler(_LEG_L).x, 0.3,
			"the down thigh should pitch forward (l pitch %.3f)" % _skater.leg_bone_euler(_LEG_L).x)
	assert_lt(_skater.leg_bone_euler(_SHIN_L).x, -1.5,
			"the down shin should fold back along the ice (l knee %.3f)" % _skater.leg_bone_euler(_SHIN_L).x)
	assert_almost_eq(_skater.leg_bone_euler(_LEG_L).z, 0.0, 0.05,
			"the kneeling leg stays under the body, not splayed")
	# The far leg extends out the other side (right toward +X = positive roll),
	# near-straight, so its skate seals the ice beside the kneeling body.
	assert_gt(_skater.leg_bone_euler(_LEG_R).z, 0.8,
			"the far leg should extend out to the side (r roll %.3f)" % _skater.leg_bone_euler(_LEG_R).z)
	assert_gt(_skater.leg_bone_euler(_SHIN_R).x, -0.3,
			"the extended leg should stay near-straight (r knee %.3f)" % _skater.leg_bone_euler(_SHIN_R).x)
	# Kneeling drops the hips most of the way to the ice — far deeper than any
	# skating crouch, which is what makes the block read as committed.
	assert_lt(_skater.lower_body.position.y, rest_hips_y - 0.3,
			"the kneel should sink the hips (hips %.3f, rest %.3f)"
			% [_skater.lower_body.position.y, rest_hips_y])
	# Releasing the block eases the knee drop back out to a neutral stance.
	_skater.current_shot_state = State.SKATING_WITHOUT_PUCK
	_tick(240)
	assert_almost_eq(_skater.leg_bone_euler(_LEG_R).z, 0.0, 0.02, "leg extension should release to rest")
	assert_almost_eq(_skater.lower_body.position.y, rest_hips_y, 0.01,
			"body drop should release to rest")


func test_block_extended_skate_stays_on_the_ice() -> void:
	# The extended leg's abduction is SOLVED from the kneel height, so both feet
	# land at the same height — the seal lies along the ice instead of the far
	# skate floating above it or scissoring through it.
	_skater.current_shot_state = State.SHOT_BLOCKING
	_tick(120)
	var down_foot: float = _foot_y(_LEG_L, _SHIN_L)
	var ext_foot: float = _foot_y(_LEG_R, _SHIN_R)
	assert_almost_eq(ext_foot, down_foot, 0.02,
			"both skates should sit at ice level (down %.3f, extended %.3f)" % [down_foot, ext_foot])


# Skate height in MeshRoot space, from the posed hip/knee/roll angles over the
# dropped hips — what the rig actually renders. Compared between the two legs,
# so the ice plane's own offset cancels.
func _foot_y(leg: int, shin: int) -> float:
	var hip: float = _skater.leg_bone_euler(leg).x
	var roll: float = _skater.leg_bone_euler(leg).z
	var knee: float = _skater.leg_bone_euler(shin).x
	var span: float = 0.31 * cos(hip) + 0.45 * cos(hip + knee)
	return _skater.lower_body.position.y - 0.13 - span * cos(roll)


func test_block_seal_height_matches_the_kneeling_body() -> void:
	# Calibration: the block's collision seal is authored (collision can't read a
	# render-rate pose), so it has to be re-derived whenever the kneel angles
	# move. This pins the two together — the seal covers the kneeling head and
	# stops there, rather than walling off a standing body that isn't there.
	var controller: SkaterController = SkaterController.new()
	autofree(controller)
	var sm := SkaterStateMachine.new()
	var pose := SkaterPoseCoordinator.new()
	pose.setup(_skater, sm, SkaterAimingBehavior.new(), controller, _coord)
	_skater.current_shot_state = State.SHOT_BLOCKING
	sm.set_state(State.SHOT_BLOCKING)
	_skater.set_block_stance(true)  # the collision half, normally flipped on entry
	for _i: int in 120:
		_coord.apply(DT)
		pose.apply_upper_body(DT)
	# Helmet centre in world Y, over the dropped and pitched torso. The skater
	# body rides at FACEOFF_SPAWN_HEIGHT with the ice at 0.
	var helmet_y: float = _skater.upper_bone_base_position(SkaterMeshBuilder.UpperBone.HELMET).y
	var head_center: float = GameRules.FACEOFF_SPAWN_HEIGHT + _skater.upper_body.position.y \
			+ helmet_y * cos(_skater.upper_body.rotation.x)
	var seal: float = _skater.get_body_block_y_range().y
	assert_gt(seal, head_center,
			"the seal should cover the kneeling head (seal %.3f, head centre %.3f)"
			% [seal, head_center])
	assert_lt(seal, head_center + 0.25,
			"the seal shouldn't wall off a body that isn't there (seal %.3f, head centre %.3f)"
			% [seal, head_center])


func test_block_tips_the_chest_onto_the_down_knee() -> void:
	# The torso branch runs on the simulating machine via the pose coordinator;
	# wire it the way SkaterController.setup does and hold SHOT_BLOCKING.
	var controller: SkaterController = SkaterController.new()
	autofree(controller)
	var sm := SkaterStateMachine.new()
	var pose := SkaterPoseCoordinator.new()
	pose.setup(_skater, sm, SkaterAimingBehavior.new(), controller, _coord)
	sm.set_state(State.SHOT_BLOCKING)
	for _i: int in 120:
		pose.apply_upper_body(DT)
	assert_lt(_skater.upper_body.rotation.x, -0.15,
			"the chest should tip forward over the down knee (pitch %.3f rad)"
			% _skater.upper_body.rotation.x)
	# Default handedness is LEFT: the knee drops on the −X side, so the torso
	# rolls onto it — positive rotation.z tips the torso top toward local −X.
	assert_gt(_skater.upper_body.rotation.z, 0.1,
			"the torso should roll onto the down knee (roll %.3f rad)"
			% _skater.upper_body.rotation.z)

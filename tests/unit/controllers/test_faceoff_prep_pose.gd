extends GutTest

# FACEOFF_PREP poses the body through two entry points `_process_input` never
# reaches — `tick_faceoff_approach` while the skate-in glides, then
# `apply_blade_aim_only` for the rest of the countdown — and the state machine
# is not dispatched on either. That combination is what let three things ride
# from the whistle to the drop, and none of them is visible in a still: whether
# the block cleared, whether the hips came square, and whether the two roles
# actually hold different stances rather than looking like they do from one
# camera angle. tools/pose_capture.gd renders how the poses READ; this pins the
# numbers underneath them.

const SKATER_SCENE: PackedScene = preload("res://Scenes/Skater.tscn")
const PUCK_SCENE: PackedScene = preload("res://Scenes/Puck.tscn")
const State = SkaterStateMachine.State
const DT: float = 1.0 / 120.0
# Comfortably past every ease in the prep pose (the slowest is the crouch's
# stride_intensity_speed at 6/s) so the assertions are about the settled value.
const SETTLE_TICKS: int = 120


class StubGameState extends Node:
	var faceoff_prep: bool = true

	func is_host() -> bool:
		return true

	func is_movement_locked() -> bool:
		return faceoff_prep

	func is_faceoff_prep() -> bool:
		return faceoff_prep


var _state: StubGameState = null
var _puck: Puck = null


func before_each() -> void:
	_state = StubGameState.new()
	add_child_autofree(_state)
	_puck = PUCK_SCENE.instantiate() as Puck
	add_child_autofree(_puck)
	_puck.set_physics_process(false)
	_puck.set_process(false)


func _controller(center: bool = false) -> SkaterController:
	var skater: Skater = SKATER_SCENE.instantiate() as Skater
	add_child_autofree(skater)
	skater.global_position = Vector3(0.0, GameRules.FACEOFF_SPAWN_HEIGHT, 0.0)
	skater.set_physics_process(false)
	skater.set_process(false)
	skater.is_faceoff_center = center
	var c := SkaterController.new()
	add_child_autofree(c)
	c.set_physics_process(false)
	c.set_process(false)
	c.setup(skater, _puck, _state)
	# What ActorSpawner does next, and where the grip chokes are sized off this
	# build's own stick — without it the address holds a full-length lever.
	c.apply_attributes(PlayerAttributes.new())
	return c


# One prep, start to finish: the skate-in from `from`, then the countdown hold.
# Mirrors what LocalController/AIController do on a locked tick.
func _run_prep(c: SkaterController, from: Vector3, hold: int = SETTLE_TICKS,
		dot_distance: float = 1.0) -> void:
	var target := Vector3(0.0, GameRules.FACEOFF_SPAWN_HEIGHT, 0.0)
	c.begin_approach(from, target, Vector2(0.0, -1.0), 1.0)
	var input := InputState.new()
	input.delta = DT
	input.mouse_world_pos = Vector3(0.0, 0.0, -dot_distance)
	for _i: int in 120 + hold:
		if not c.tick_faceoff_approach(DT):
			c.skater.velocity = Vector3.ZERO
			c.apply_blade_aim_only(input, DT)
		c.skater._process(DT)


# ── The block must not ride the walk-in ──────────────────────────────────────

# A player holding the block when the whistle goes never gets another state
# machine dispatch, so nothing inside SHOT_BLOCKING can end it. The teleport at
# the head of the approach is the only thing that can.
func test_a_blocker_caught_by_the_whistle_stands_up_for_the_draw() -> void:
	var c: SkaterController = _controller()
	c._enter_shot_block()
	c.skater.current_shot_state = State.SHOT_BLOCKING
	var blocking_radius: float = c.skater.get_body_block_radius()

	c.begin_approach(Vector3(0.0, GameRules.FACEOFF_SPAWN_HEIGHT, 6.0),
			Vector3(0.0, GameRules.FACEOFF_SPAWN_HEIGHT, 0.0), Vector2(0.0, -1.0), 1.0)

	assert_ne(c._sm.get_state(), State.SHOT_BLOCKING,
			"the skate-in must leave the block stance")
	assert_ne(c.skater.current_shot_state, State.SHOT_BLOCKING,
			"the replicated mirror the gait plants the legs off must clear too")
	assert_lt(c.skater.get_body_block_radius(), blocking_radius,
			"the widened body-block cylinder must come off with the stance")


func test_a_charge_caught_by_the_whistle_is_still_cancelled() -> void:
	var c: SkaterController = _controller()
	c._sm.set_state(State.WRISTER_AIM)
	c.begin_approach(Vector3(0.0, GameRules.FACEOFF_SPAWN_HEIGHT, 6.0),
			Vector3(0.0, GameRules.FACEOFF_SPAWN_HEIGHT, 0.0), Vector2(0.0, -1.0), 1.0)
	assert_eq(c._sm.get_state(), State.SKATING_WITHOUT_PUCK,
			"a wind-up must not survive the faceoff teleport")


# ── The walk-in is skating, the dot is a stance ──────────────────────────────

func test_the_ready_stance_is_off_while_the_skate_in_is_still_running() -> void:
	var c: SkaterController = _controller()
	c.begin_approach(Vector3(0.0, GameRules.FACEOFF_SPAWN_HEIGHT, 8.0),
			Vector3(0.0, GameRules.FACEOFF_SPAWN_HEIGHT, 0.0), Vector2(0.0, -1.0), 1.0)
	assert_false(c.is_faceoff_ready(),
			"a skater still covering ground is skating, not set")
	# Run the glide out; arrival clears the approach and the stance arms.
	for _i: int in 130:
		c.tick_faceoff_approach(DT)
	assert_true(c.is_faceoff_ready(), "set at the dot, the stance arms")


# The skate-in yaws the hips onto the line it travels (hip_align_max_deg is 50°),
# and the countdown path is the only publisher of that channel once the glide
# hands back. A path that skips it leaves the legs pointed down the walk-in for
# the rest of the prep.
func test_the_hips_come_square_after_walking_in_from_the_side() -> void:
	var c: SkaterController = _controller()
	_run_prep(c, Vector3(9.0, GameRules.FACEOFF_SPAWN_HEIGHT, 6.0))
	assert_almost_eq(rad_to_deg(c.skater.lower_body.rotation.y), 0.0, 2.0,
			"the hips must unwind onto the dot facing, not freeze on the walk-in line")


func test_the_skater_lands_on_the_dot() -> void:
	var c: SkaterController = _controller()
	_run_prep(c, Vector3(9.0, GameRules.FACEOFF_SPAWN_HEIGHT, 6.0))
	assert_almost_eq(c.skater.global_position.x, 0.0, 0.001, "on the dot in x")
	assert_almost_eq(c.skater.global_position.z, 0.0, 0.001, "on the dot in z")


# ── Centre vs winger ─────────────────────────────────────────────────────────

# Both halves of the centre's address, against the same skater standing in the
# same place as a winger: the gait's crouch (a body drop that keeps the skates
# on the ice) and its trunk fold. Absolute values are feel; the ORDERING is the
# thing that must not quietly invert.
func test_the_centre_sits_deeper_than_the_players_behind_him() -> void:
	var winger: SkaterController = _controller(false)
	var centre: SkaterController = _controller(true)
	_run_prep(winger, Vector3(0.0, GameRules.FACEOFF_SPAWN_HEIGHT, 4.0))
	_run_prep(centre, Vector3(0.0, GameRules.FACEOFF_SPAWN_HEIGHT, 4.0))
	assert_gt(centre.skater._skating_crouch_drop, winger.skater._skating_crouch_drop * 2.0,
			"the centre's crouch must read as a different pose, not a nudge")
	assert_lt(centre._skating.trunk_pitch_add, winger._skating.trunk_pitch_add - 0.15,
			"the centre's chest folds forward over the dot (negative pitch)")


# The fold goes on the trunk TEXTURE, which is bones only. Putting it on the
# torso lean instead rotates the UpperBody node the blade markers hang from, and
# the blade-first IK answers by standing the shaft on end — so this pins that
# the centre's stick still addresses the ice.
func test_the_centre_still_gets_his_blade_down_on_the_dot() -> void:
	var centre: SkaterController = _controller(true)
	var winger: SkaterController = _controller(false)
	_run_prep(centre, Vector3(0.0, GameRules.FACEOFF_SPAWN_HEIGHT, 4.0),
			SETTLE_TICKS, centre.faceoff_center_distance())
	_run_prep(winger, Vector3(0.0, GameRules.FACEOFF_SPAWN_HEIGHT, 4.0))
	var centre_blade: Vector3 = centre.skater.upper_body_to_global(
			centre.skater.get_blade_position())
	var winger_blade: Vector3 = winger.skater.upper_body_to_global(
			winger.skater.get_blade_position())
	assert_almost_eq(centre_blade.y, winger_blade.y, 0.02,
			"the crouch must not lift the blade off the ice")


# ── The centre's arms ────────────────────────────────────────────────────────

# The address folds the chest 48° over the dot, and the ARMS hang from the
# shoulders that fold with it (SkaterArmRig._textured_shoulder). Solve the hands
# off the un-folded marker instead and they land a third of a metre behind the
# shoulder they grow from — the two-bone IK then has nowhere to put the elbow
# but forward of the wrist, and the arm reads as bending backwards.
func test_neither_arm_bends_backwards_in_the_address() -> void:
	var centre: SkaterController = _controller(true)
	_run_prep(centre, Vector3(0.0, GameRules.FACEOFF_SPAWN_HEIGHT, 4.0),
			SETTLE_TICKS, centre.faceoff_center_distance())
	for top: bool in [true, false]:
		var elbow: Vector3 = _elbow(centre, top)
		var hand: Vector3 = _hand(centre, top)
		assert_lt(hand.z, elbow.z + 0.01,
				"the hand must be no further back than its own elbow")
		assert_gt(elbow.y, hand.y,
				"and the elbow above it — an arm reaching down to a stick on the ice")


# The other way an arm goes wrong at this depth: not reversed but shut. The
# close-range hand solve answers a puck inside the stick's reach by raising the
# hand (TopHandIK's CLOSE regime), and over a body folded this far that walks
# the hand up to the shoulder it hangs from, leaving the elbow cocked out
# sideways with no arm to speak of.
func test_the_address_arms_are_open() -> void:
	var centre: SkaterController = _controller(true)
	_run_prep(centre, Vector3(0.0, GameRules.FACEOFF_SPAWN_HEIGHT, 4.0),
			SETTLE_TICKS, centre.faceoff_center_distance())
	var span: float = centre.skater.upper_arm_length + centre.skater.forearm_length
	for top: bool in [true, false]:
		assert_gt(_shoulder(centre, top).distance_to(_hand(centre, top)), span * 0.4,
				"the arm must be extended, not folded shut under the shoulder")


# What the placement is FOR: the blade has to end up on the dot the puck is
# dropped at. The address's own geometry decides where that is — the crouched
# hand height, the choked stick, the fold's carry — and every one of them is
# derived at the whistle, before the pose exists, so this is where a wrong
# derivation shows up.
func test_the_address_puts_the_blade_on_the_dot() -> void:
	var centre: SkaterController = _controller(true)
	var dot: float = centre.faceoff_center_distance()
	_run_prep(centre, Vector3(0.0, GameRules.FACEOFF_SPAWN_HEIGHT, 4.0), SETTLE_TICKS, dot)
	var blade: Vector3 = centre.skater.upper_body_to_global(
			centre.skater.get_blade_position())
	assert_almost_eq(blade.z - centre.skater.global_position.z, -dot, 0.10,
			"the centre's blade must address the dot he was placed for")


# All three in the skater's own frame, world-space: −Z is in front of him.
func _shoulder(c: SkaterController, top: bool) -> Vector3:
	return c.skater.upper_body_to_global(c._ik.address_shoulder(
			c.skater.shoulder.position if top else c.skater.bottom_shoulder.position))


func _hand(c: SkaterController, top: bool) -> Vector3:
	return c.skater.upper_body_to_global(
			c.skater.get_top_hand_position() if top else c.skater.bottom_hand.position)


func _elbow(c: SkaterController, top: bool) -> Vector3:
	var rig: Skeleton3D = c.skater.upper_body.get_node("UpperRig") as Skeleton3D
	var bone: int = SkaterMeshBuilder.UpperBone.TOP_ELBOW if top \
			else SkaterMeshBuilder.UpperBone.BOTTOM_ELBOW
	return c.skater.upper_body_to_global(rig.get_bone_global_pose(bone).origin)


# ── The centre's hands ───────────────────────────────────────────────────────

# The draw grip: the bottom hand walks down the shaft over the countdown, and
# walks back once the puck is live. Measured as the share of the shaft between
# the hands, which is what the grip actually is.
func test_the_centre_takes_a_draw_grip_and_gives_it_back() -> void:
	var winger: SkaterController = _controller(false)
	var centre: SkaterController = _controller(true)
	_run_prep(winger, Vector3(0.0, GameRules.FACEOFF_SPAWN_HEIGHT, 4.0))
	_run_prep(centre, Vector3(0.0, GameRules.FACEOFF_SPAWN_HEIGHT, 4.0))
	assert_gt(_hand_spread(centre), _hand_spread(winger) + 0.1,
			"the centre's hands must come apart on the shaft for the draw")

	# The drop releases the address, and the hands ease back with it.
	_state.faceoff_prep = false
	var input := InputState.new()
	input.delta = DT
	input.mouse_world_pos = Vector3(0.0, 0.0, -1.0)
	for _i: int in SETTLE_TICKS:
		centre.skater.velocity = Vector3.ZERO
		centre.apply_blade_aim_only(input, DT)
		centre.skater._process(DT)
	assert_almost_eq(_hand_spread(centre), _hand_spread(winger), 0.02,
			"and go back to a carry grip once the puck is live")


# Distance between the two hands as a share of the stick.
func _hand_spread(c: SkaterController) -> float:
	var top: Vector3 = c.skater.get_top_hand_position()
	var bottom: Vector3 = c.skater.bottom_hand.position
	return top.distance_to(bottom) / c._ik.solve_stick_length()


# ── The centre's base ────────────────────────────────────────────────────────

# The wide base under the fold, and the half of it a still can't show: the splay
# shortens each leg's vertical span, so the body owes the deficit as extra drop
# or the skates ride up off the ice on their outside edges.
func test_the_centre_sets_a_wider_base_than_the_players_behind_him() -> void:
	var winger: SkaterController = _controller(false)
	var centre: SkaterController = _controller(true)
	_run_prep(winger, Vector3(0.0, GameRules.FACEOFF_SPAWN_HEIGHT, 4.0))
	_run_prep(centre, Vector3(0.0, GameRules.FACEOFF_SPAWN_HEIGHT, 4.0))
	assert_gt(_stance_width(centre), _stance_width(winger) + 0.1,
			"the centre's feet must set wide, not stack under a deep squat")


# Against a skater standing on the same spot, because both hold LEVEL boots and
# a level boot's blade hangs a fixed depth below the pivot measured here — so
# equal pivot heights are equal blade heights. (A skate left to tilt with its
# shin, which is every other pose in the game, is not comparable this way.)
func test_the_wide_base_keeps_both_skates_on_the_ice() -> void:
	var standing: SkaterController = _controller(true)
	var centre: SkaterController = _controller(true)
	_run_prep(centre, Vector3(0.0, GameRules.FACEOFF_SPAWN_HEIGHT, 4.0))
	# The tolerance is the fore/aft stagger's own residual: it swings the boot
	# pivot down on the trailing leg and up on the leading one by about a
	# centimetre each, and a single body drop cannot answer two legs moving
	# opposite ways. The splay and the fold, which move both together, must be
	# paid exactly — so anything past this is one of those two, not the stagger.
	for left: bool in [true, false]:
		assert_almost_eq(centre.skater.blade_mark_position(left).y,
				standing.skater.blade_mark_position(left).y, 0.02,
				"the address must not sink its skates through the ice, or float them")


# The other half of standing a body up over splayed, deeply folded legs: the
# boot inherits every rotation in the chain, so without the ankle's give-back
# the address stands both blades up on their heels and outside edges.
func test_the_address_holds_both_blades_flat() -> void:
	var standing: SkaterController = _controller(true)
	var centre: SkaterController = _controller(true)
	_run_prep(centre, Vector3(0.0, GameRules.FACEOFF_SPAWN_HEIGHT, 4.0))
	for left: bool in [true, false]:
		assert_lt(_skate_tilt_deg(centre, standing, left), 8.0,
				"the centre addresses the dot on flat blades, not on their heels")


# The placement runs at the whistle, before the pose exists, so the drop it
# lays the dot out from is DERIVED. This is the pair that must agree.
func test_the_address_drop_is_the_crouch_the_gait_settles_at() -> void:
	var centre: SkaterController = _controller(true)
	_run_prep(centre, Vector3(0.0, GameRules.FACEOFF_SPAWN_HEIGHT, 4.0))
	assert_almost_eq(centre._skating.faceoff_address_drop(),
			centre.skater._skating_crouch_drop, 0.005,
			"the derived address drop must be the crouch he actually takes")


# The shaft's angle over the dot, which the address decides three ways at once:
# the hand's ceiling sets how high it is held, the draw choke how long a lever
# it is, and the placement how far the blade is from it. Get any of them wrong
# and the centre addresses the puck with a shovel.
func test_the_address_lays_the_shaft_out_over_the_dot() -> void:
	var centre: SkaterController = _controller(true)
	_run_prep(centre, Vector3(0.0, GameRules.FACEOFF_SPAWN_HEIGHT, 4.0), SETTLE_TICKS,
			centre.faceoff_center_distance())
	assert_gt(_shaft_flatness(centre), cos(deg_to_rad(50.0)),
			"the shaft must lie out ahead of him, not stand on end")


# How far a posed skate has tipped away from where the same skate sits on an
# untouched rig — the skater in `rest` — in degrees. Read off the live rig
# rather than the pose inputs, because the tilt is the composition of the hip,
# the knee and the ankle, which is exactly what no single channel can tell you.
# Against the rest rig rather than world up: the boot bone's authored basis is
# the mesh's, and it is nobody's business here what axis it points down.
func _skate_tilt_deg(c: SkaterController, rest: SkaterController,
		left: bool) -> float:
	var bone: int = SkaterMeshBuilder.LegBone.FOOT_L if left \
			else SkaterMeshBuilder.LegBone.FOOT_R
	return rad_to_deg(_sole_axis(c, bone).angle_to(_sole_axis(rest, bone)))


func _sole_axis(c: SkaterController, bone: int) -> Vector3:
	var rig: Skeleton3D = c.skater.lower_body.get_node("LegRig") as Skeleton3D
	return rig.get_bone_global_pose(bone).basis.y.normalized()


# Lateral span between the two skates, in the skater's own frame.
func _stance_width(c: SkaterController) -> float:
	var span: Vector3 = c.skater.blade_mark_position(true) \
			- c.skater.blade_mark_position(false)
	return absf(c.skater.global_transform.basis.inverse().x.dot(span))


# How much of the stick's length is spent reaching ACROSS the ice rather than
# down to it: 1.0 is a shaft laid flat, 0.0 one stood on its end.
func _shaft_flatness(c: SkaterController) -> float:
	var hand: Vector3 = c.skater.upper_body_to_global(c.skater.get_top_hand_position())
	var blade: Vector3 = c.skater.upper_body_to_global(c.skater.get_blade_position())
	return Vector2(blade.x - hand.x, blade.z - hand.z).length() \
			/ c._ik.solve_stick_length()


func test_nobody_holds_a_draw_stance_once_the_puck_is_live() -> void:
	var centre: SkaterController = _controller(true)
	_run_prep(centre, Vector3(0.0, GameRules.FACEOFF_SPAWN_HEIGHT, 4.0))
	assert_true(centre.is_faceoff_ready())
	_state.faceoff_prep = false
	assert_false(centre.is_faceoff_ready(),
			"the stance is gated on the phase, so the drop releases it")

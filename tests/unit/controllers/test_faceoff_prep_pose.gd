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
	return c


# One prep, start to finish: the skate-in from `from`, then the countdown hold.
# Mirrors what LocalController/AIController do on a locked tick.
func _run_prep(c: SkaterController, from: Vector3, hold: int = SETTLE_TICKS) -> void:
	var target := Vector3(0.0, GameRules.FACEOFF_SPAWN_HEIGHT, 0.0)
	c.begin_approach(from, target, Vector2(0.0, -1.0), 1.0)
	var input := InputState.new()
	input.delta = DT
	input.mouse_world_pos = Vector3(0.0, 0.0, -1.0)
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
	_run_prep(centre, Vector3(0.0, GameRules.FACEOFF_SPAWN_HEIGHT, 4.0))
	_run_prep(winger, Vector3(0.0, GameRules.FACEOFF_SPAWN_HEIGHT, 4.0))
	var centre_blade: Vector3 = centre.skater.upper_body_to_global(
			centre.skater.get_blade_position())
	var winger_blade: Vector3 = winger.skater.upper_body_to_global(
			winger.skater.get_blade_position())
	assert_almost_eq(centre_blade.y, winger_blade.y, 0.02,
			"the crouch must not lift the blade off the ice")
	assert_almost_eq(centre_blade.z, winger_blade.z, 0.10,
			"nor pull it back in from the aim point")


func test_nobody_holds_a_draw_stance_once_the_puck_is_live() -> void:
	var centre: SkaterController = _controller(true)
	_run_prep(centre, Vector3(0.0, GameRules.FACEOFF_SPAWN_HEIGHT, 4.0))
	assert_true(centre.is_faceoff_ready())
	_state.faceoff_prep = false
	assert_false(centre.is_faceoff_ready(),
			"the stance is gated on the phase, so the drop releases it")

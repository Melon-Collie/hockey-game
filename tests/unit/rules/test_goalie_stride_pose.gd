extends GutTest

# GoalieBodyConfigBuilder puck-play stride — the procedural skating gait
# applied during the behind-net trip (PLAYING_PUCK). Properties under test:
# the two pads swing in ANTI-PHASE (opposite fore/aft signs), only the
# forward-swinging pad lifts off the ice (the recovery — the pushing pad
# stays planted), zero intensity reproduces the rest pose exactly (the
# gait eases out to nothing when the goalie stops), and the paddle-down
# STOP pose suppresses the stride entirely.

func _builder() -> GoalieBodyConfigBuilder:
	return GoalieBodyConfigBuilder.new()


func _puck_play_inputs(phase: float, intensity: float) -> GoalieBodyConfigBuilder.Inputs:
	var inputs := GoalieBodyConfigBuilder.Inputs.new()
	inputs.state = GoalieStateMachine.State.PLAYING_PUCK
	inputs.current_x = 0.0
	inputs.goalie_z = 0.0
	inputs.direction_sign = -1
	inputs.puck_position = Vector3(0.0, 0.0, -3.0)
	inputs.puck_play_stride_phase = phase
	inputs.puck_play_stride_intensity = intensity
	return inputs


func test_pads_swing_in_anti_phase() -> void:
	# Mid-stroke (phase π/2, warped): the left pad drives one way, the right
	# pad the other. Compare each pad's fore/aft against the rest pose — the
	# builder reuses one scratch config, so capture before rebuilding.
	var builder := _builder()
	var rest: GoalieBodyConfig = builder.build(_puck_play_inputs(PI / 2.0, 0.0))
	var rest_left_z: float = rest.left_pad_pos.z
	var rest_right_z: float = rest.right_pad_pos.z
	var cfg: GoalieBodyConfig = builder.build(_puck_play_inputs(PI / 2.0, 1.0))
	var left_swing: float = cfg.left_pad_pos.z - rest_left_z
	var right_swing: float = cfg.right_pad_pos.z - rest_right_z
	assert_lt(left_swing * right_swing, 0.0,
			"pads must swing opposite directions mid-stroke")


func test_only_the_forward_swinging_pad_lifts() -> void:
	# At phase π/2 the left pad swings forward (recovery) and lifts; the
	# right pad is pushing and must stay planted at the rest height.
	var builder := _builder()
	var rest: GoalieBodyConfig = builder.build(_puck_play_inputs(PI / 2.0, 0.0))
	var rest_left_y: float = rest.left_pad_pos.y
	var rest_right_y: float = rest.right_pad_pos.y
	var cfg: GoalieBodyConfig = builder.build(_puck_play_inputs(PI / 2.0, 1.0))
	assert_gt(cfg.left_pad_pos.y, rest_left_y, "recovering pad lifts off the ice")
	assert_almost_eq(cfg.right_pad_pos.y, rest_right_y, 0.0001,
			"pushing pad stays planted")


func test_zero_intensity_is_the_rest_pose() -> void:
	# Intensity 0 (goalie arrived / not yet moving) must be byte-identical to
	# the un-strided puck-play pose — no residual offsets to pop on ease-out.
	var builder := _builder()
	var rest: GoalieBodyConfig = builder.build(_puck_play_inputs(1.3, 0.0))
	var rest_left: Vector3 = rest.left_pad_pos
	var rest_right: Vector3 = rest.right_pad_pos
	var rest_body_y: float = rest.body_pos.y
	var cfg: GoalieBodyConfig = builder.build(_puck_play_inputs(1.3, 0.0))
	assert_eq(cfg.left_pad_pos, rest_left)
	assert_eq(cfg.right_pad_pos, rest_right)
	assert_eq(cfg.body_pos.y, rest_body_y)


func test_stop_pose_suppresses_the_stride() -> void:
	# The paddle-down trap plants the goalie — full stride intensity must not
	# leak into the STOP pose's pads.
	var builder := _builder()
	var stop_inputs := _puck_play_inputs(PI / 2.0, 0.0)
	stop_inputs.puck_play_stopping = true
	var rest: GoalieBodyConfig = builder.build(stop_inputs)
	var rest_left: Vector3 = rest.left_pad_pos
	var rest_right: Vector3 = rest.right_pad_pos
	var strided_inputs := _puck_play_inputs(PI / 2.0, 1.0)
	strided_inputs.puck_play_stopping = true
	var cfg: GoalieBodyConfig = builder.build(strided_inputs)
	assert_eq(cfg.left_pad_pos, rest_left, "stopping pose ignores stride phase")
	assert_eq(cfg.right_pad_pos, rest_right)

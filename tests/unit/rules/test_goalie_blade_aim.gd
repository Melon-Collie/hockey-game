extends GutTest

# GoalieBodyConfigBuilder blade aim — the closed-loop solve that lands the
# stick BLADE on the wrist→puck line (replacing the old fixed-lookahead yaw
# heuristic that ignored the puck's depth and the stick geometry). Property
# under test: rotating the blade's tilt-projected offset by the solved yaw
# yields a vector COLLINEAR with wrist→puck (and pointing at it), whenever the
# solve isn't clamped. Rotation convention mirrors Godot's +Y yaw
# (x' = x·cosθ + z·sinθ, z' = z·cosθ − x·sinθ).

func _builder() -> GoalieBodyConfigBuilder:
	return GoalieBodyConfigBuilder.new()


# Standing-state inputs with an identity local frame (direction_sign -1,
# goalie at origin) so puck world coords == goalie-local coords.
func _standing_inputs(puck_local: Vector3) -> GoalieBodyConfigBuilder.Inputs:
	var inputs := GoalieBodyConfigBuilder.Inputs.new()
	inputs.state = GoalieStateMachine.State.STANDING
	inputs.current_x = 0.0
	inputs.goalie_z = 0.0
	inputs.direction_sign = -1
	inputs.puck_position = puck_local
	return inputs


# Blade horizontal offset from the wrist after the config's tilt + yaw.
func _blade_offset(cfg: GoalieBodyConfig) -> Vector2:
	var yaw: float = deg_to_rad(cfg.blocker_rot.y)
	var bx: float = GoalieBodyConfigBuilder.BLADE_ASSEMBLY_X
	var bz: float = -GoalieBodyConfigBuilder.BLADE_ASSEMBLY_DROP \
			* sin(deg_to_rad(cfg.blocker_rot.x))
	return Vector2(
			bx * cos(yaw) + bz * sin(yaw),
			bz * cos(yaw) - bx * sin(yaw))


func test_active_blade_lands_on_the_puck_line() -> void:
	# Puck placed so the required yaw sits inside the ±25° intent cap: the
	# solved yaw must rotate the blade offset exactly onto wrist→puck.
	var puck := Vector3(0.263, 0.0, -0.666)
	var inputs := _standing_inputs(puck)
	inputs.blade_intent_active = true
	var cfg: GoalieBodyConfig = _builder().build(inputs)
	var blade: Vector2 = _blade_offset(cfg)
	var to_puck := Vector2(puck.x - cfg.blocker_pos.x, puck.z - cfg.blocker_pos.z)
	var cross: float = blade.x * to_puck.y - blade.y * to_puck.x
	assert_almost_eq(cross, 0.0, 0.01, "blade offset collinear with wrist→puck")
	assert_gt(blade.x * to_puck.x + blade.y * to_puck.y, 0.0,
			"…and pointing AT the puck, not away from it")


func test_far_side_puck_clamps_at_the_intent_cap() -> void:
	# A puck far across the body needs more yaw than the assembly allows —
	# the solve saturates at the cap instead of swinging the pad off the body.
	var inputs := _standing_inputs(Vector3(-1.5, 0.0, -0.5))
	inputs.blade_intent_active = true
	var cfg: GoalieBodyConfig = _builder().build(inputs)
	assert_almost_eq(absf(cfg.blocker_rot.y), _builder().active_blade_max_yaw_deg, 0.01,
			"out-of-reach angles saturate the yaw cap")


func test_standing_sweep_solves_from_the_extended_wrist() -> void:
	# The sweep extends the wrist toward the puck side BEFORE the solve; the
	# blade must still land on the line measured from the extended wrist.
	# Puck placed so the post-extension solve sits inside the ±45° sweep cap.
	var puck := Vector3(0.2, 0.0, -0.8)
	var inputs := _standing_inputs(puck)
	inputs.standing_sweep_active = true
	var cfg: GoalieBodyConfig = _builder().build(inputs)
	var blade: Vector2 = _blade_offset(cfg)
	var to_puck := Vector2(puck.x - cfg.blocker_pos.x, puck.z - cfg.blocker_pos.z)
	var cross: float = blade.x * to_puck.y - blade.y * to_puck.x
	assert_almost_eq(cross, 0.0, 0.01,
			"sweep blade lands on the puck line from the extended wrist")


func test_windup_cocks_away_from_the_send_corner() -> void:
	# During the pre-strike backswing the blade moves AWAY from the send side
	# and back toward the body — the visible wind that makes the strike read
	# as the stick clearing the puck.
	var inputs := _standing_inputs(Vector3(0.3, 0.0, -0.6))
	inputs.sweep_anim_dir = 1.0
	inputs.sweep_windup_progress = 1.0
	var b := _builder()
	# The builder reuses one scratch config — capture the windup numbers before
	# building the rest pose for comparison.
	var cfg: GoalieBodyConfig = b.build(inputs)
	var windup_x: float = cfg.blocker_pos.x
	var windup_z: float = cfg.blocker_pos.z
	var rest := GoalieBodyConfigBuilder.Inputs.new()
	rest.state = GoalieStateMachine.State.STANDING
	rest.direction_sign = -1
	var rest_cfg: GoalieBodyConfig = b.build(rest)
	assert_lt(windup_x, rest_cfg.blocker_pos.x,
			"blade cocks opposite the +local-X send")
	assert_gt(windup_z, rest_cfg.blocker_pos.z,
			"…and pulls back toward the body")

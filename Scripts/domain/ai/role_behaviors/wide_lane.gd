class_name AIRoleWideLane

# WIDE_L / WIDE_R role behavior — TRANS_OFFENSE, 5v5 only. The rush's wide
# drivers: fill the outside lanes at pace so the entry has width (defenders
# must respect three lanes, which is what opens the middle for the carrier
# and the trailer). Paced to the play like OUTLET — lead the carrier up-ice,
# but never onside-break: hold up at the attacking blue line until the puck
# crosses (the body-level offside brake is the hard backstop; this keeps the
# route honest so the brake never has to slam).

const LANE_INSET_M: float = 4.0     # off the boards
const LEAD_AHEAD_M: float = 5.0     # up-ice of the play reference
const LINE_HOLD_BACK_M: float = 0.8 # NZ-side stand-off at the blue line


static func decide(ctx: RoleContext, side: float) -> RoleDecision:
	var d := RoleDecision.new()
	var own_dir: float = ctx.own_goal_dir
	var play_ref: Vector3 = AIRoleHelpers.resolve_offensive_play_ref(ctx)
	if not play_ref.is_finite():
		d.target_position = ctx.self_pos
		return d

	var x: float = side * (GameRules.RINK_HALF_WIDTH - LANE_INSET_M)
	# Lead the play up-ice (toward the attacking net).
	var z: float = play_ref.z - own_dir * LEAD_AHEAD_M
	# Offside honesty: until the PUCK is across the attacking blue line,
	# hold the NZ side of it.
	var attacking_blue_z: float = -own_dir * GameRules.BLUE_LINE_Z
	var puck_in_zone: bool = own_dir * play_ref.z < own_dir * attacking_blue_z
	if not puck_in_zone:
		var hold_z: float = attacking_blue_z + own_dir * LINE_HOLD_BACK_M
		if own_dir * z < own_dir * hold_z:
			z = hold_z
	d.target_position = Vector3(x, 0.0, z)
	# The lane advances with the rush — hit it in stride.
	d.arrive_at_speed = true
	return d

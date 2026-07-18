class_name AIRoleBreakoutCenter

# BREAKOUT_C role behavior — BREAKOUT, 5v5 only. The center's low swing: the
# SECOND outlet underneath the breakout (the half-wall winger is the first).
# The researched rules (plan appendix): swing low mirroring the puck side,
# chest open to the middle, stay BELOW/level with the puck until the first
# pass is made, be available as you cross the hash marks. Timing beats
# position — the swing paces the carrier rather than parking.
#
# Model: the swing point sits in the mid lane (half the carrier's lateral —
# mirroring his side while keeping the middle), a few metres goal-side of
# him, clamped in front of our goal line. lane_clear from the carrier picks
# between the mid-lane point and a slide toward the strong-side circle when
# the middle is clogged.

const SWING_BELOW_M: float = 3.0       # goal-side of the carrier
const GOAL_LINE_PAD_M: float = 2.0
const MID_LANE_FRACTION: float = 0.5   # mirror the puck side, keep the middle
const CIRCLE_LANE_X_M: float = 6.0     # alternate: strong-side circle lane


static func decide(ctx: RoleContext) -> RoleDecision:
	var d := RoleDecision.new()
	var own_dir: float = ctx.own_goal_dir
	var carrier_pos: Vector3 = AIRoleHelpers.resolve_offensive_play_ref(ctx)
	if not carrier_pos.is_finite():
		d.target_position = ctx.self_pos
		return d

	var opp_positions: Array[Vector3] = ctx.scratch_opp_positions
	var opp_states: Array[SkaterNetworkState] = ctx.scratch_opp_states
	AIRoleHelpers.collect_opponents(ctx, opp_positions, opp_states)

	# Below the puck until the first pass: depth = carrier + a few metres
	# toward our net, never behind the goal line.
	var cap: float = GameRules.GOAL_LINE_Z - GOAL_LINE_PAD_M
	var z: float = clampf(carrier_pos.z + own_dir * SWING_BELOW_M, -cap, cap)

	# Two swing lanes: the mid-lane mirror and the strong-circle slide —
	# take whichever gives the carrier the cleaner outlet feed.
	var mid := Vector3(carrier_pos.x * MID_LANE_FRACTION, 0.0, z)
	var circle := Vector3(signf(carrier_pos.x) * CIRCLE_LANE_X_M, 0.0, z)
	var pass_speed_mid: float = AIActionScoring.expected_pass_speed(carrier_pos, mid)
	var pass_speed_circle: float = AIActionScoring.expected_pass_speed(carrier_pos, circle)
	var lane_mid: float = AIActionScoring.lane_clear(
			carrier_pos, mid, opp_positions, pass_speed_mid)
	var lane_circle: float = AIActionScoring.lane_clear(
			carrier_pos, circle, opp_positions, pass_speed_circle)
	var target: Vector3 = mid if lane_mid >= lane_circle else circle
	if not AIRoleHelpers.is_legal_position(target):
		target = mid if target == circle else circle
	d.target_position = target
	# The swing paces the retrieval — arrive in stride, not parked.
	d.arrive_at_speed = true
	return d

class_name AIRoleFlank

# FLANK_L / FLANK_R role behavior — NEUTRAL only. The two non-CHASE
# peers during loose-puck play. Job: stand off to either side of
# the puck, slightly defensive, ready to support whoever gets it.
#
# Trivial. Target = puck position offset by FLANK_LATERAL_M to the
# assigned side and FLANK_DEPTH_M back toward our own net. The
# left/right split is handled by the brain (X-axis assignment with
# hysteresis); each role behavior just receives the lateral sign
# and computes the target.
#
# Not quite "no utility AI": the shape above is pure PUCKWATCHING — the
# target is a rigid offset off the puck, so both flanks follow the puck
# wherever it goes, including up-ice past everyone. That is what produced the
# last man back stepping to his own blue line while an opponent lurked behind
# him: a stand nobody can recover from is not a stand, and NEUTRAL was the one
# game state whose off-puck shape never asked the question. So the flank stand
# is bounded by the same race-home read every other defensive station uses
# (RUSH_D1, the D pair's line hold, the points, the valve): hold the puck-side
# shape while the counter-attack channels are containable, sag down the retreat
# line exactly as far as they demand when they aren't. Contained counters leave
# the shape untouched, so ordinary loose-puck play is unchanged — the bound only
# bites on the guaranteed-breakaway geometry it exists to refuse.

# Lateral offset from puck X axis. Sampling parameter — the
# defensive "shape" the team holds during loose-puck play.
const FLANK_LATERAL_M: float = 3.0

# Depth back from puck toward our own net. Keeps the flanks
# slightly defensive so they're already in position if F1 (CHASE)
# loses the draw.
const FLANK_DEPTH_M: float = 2.0


# `lateral_sign` is -1 for FLANK_L, +1 for FLANK_R — passed by the
# dispatcher based on which slot was assigned.
static func decide(ctx: RoleContext, lateral_sign: float) -> RoleDecision:
	var d := RoleDecision.new()
	if ctx.snapshot == null or ctx.snapshot.puck_state == null:
		d.target_position = ctx.self_pos
		return d
	var puck_pos: Vector3 = ctx.snapshot.puck_state.position
	var stand := Vector3(
			puck_pos.x + lateral_sign * FLANK_LATERAL_M,
			0.0,
			puck_pos.z + ctx.own_goal_dir * FLANK_DEPTH_M)
	# Race-home bound (see the header doc). Channels are built off the full
	# opponent list, memoized per snapshot — the second flank's fill is a
	# cache hit.
	AIRoleHelpers.collect_counter_threats(
			ctx, ctx.scratch_counter_states, ctx.scratch_counter_caps)
	AIRoleHelpers.fill_counter_channels(ctx, ctx.scratch_counter_states,
			ctx.scratch_counter_caps, ctx.defending_goal_pos,
			AIRoleHelpers.ThreatSet.COUNTER_ATTACKERS)
	d.target_position = AIRoleHelpers.most_forward_feasible(
			stand, AIRoleHelpers.self_race_vmax(ctx), ctx.self_max_accel,
			AIRoleHelpers.station_retreat_floor(ctx, stand))
	return d

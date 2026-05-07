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
# No utility AI — there's nothing to score against in NEUTRAL play
# beyond "stand near the puck on this side."

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
	d.target_position = Vector3(
			puck_pos.x + lateral_sign * FLANK_LATERAL_M,
			0.0,
			puck_pos.z + ctx.own_goal_dir * FLANK_DEPTH_M)
	return d

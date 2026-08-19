class_name AIRoleFlank

# FLANK_L / FLANK_R role behavior — NEUTRAL only. The two non-CHASE
# peers during loose-puck play. Job: stand off to either side of
# the puck, slightly defensive, ready to support whoever gets it.
#
# Target = puck position offset by FLANK_LATERAL_M to the assigned side and
# FLANK_DEPTH_M back toward our own net. The left/right split is the brain's
# (X-axis assignment with hysteresis); this receives the lateral sign.
#
# That shape alone is pure PUCKWATCHING — a rigid offset off the puck, so both
# flanks follow it wherever it goes, including up-ice past everyone, and the last
# man steps to his own blue line while an opponent lurks behind him. So the stand
# is bounded by the shared numbers read, which asks BOTH halves: has a man got
# behind me with nobody covering, AND is anybody home behind me. The second is
# what a puck race needs — nobody is behind anybody yet, so the reactive half
# alone reads clear for every station and the whole shape steps up together.
# The read is antisymmetric, so exactly one flank draws the layer: one on the
# puck, one in support, one home. Nobody behind AND a body home leaves the stand
# untouched, so ordinary loose-puck play is unchanged.

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
	# The LAYER's stand — where this body goes when it is the one that has to stay
	# back — is the defensive post at our own blue line, the same stand 5v5's back
	# pair holds in this state, so both team sizes hold one neutral-zone structure.
	# It must be a spot that is still a layer once the puck is won: a puck-relative
	# floor is not, because every candidate it can name sits a couple of metres off
	# a loose puck at centre ice and is skated through the moment anybody picks it
	# up.
	d.target_position = AIRoleHelpers.neutral_station_target(
			ctx, stand, ctx.prev_held_forward_stand,
			AIZoneCoverage.defensive_anchor(
					true, ctx.self_home_side, ctx.defending_goal_pos.z))
	d.held_forward_stand = d.target_position.distance_to(stand) < 0.5
	return d

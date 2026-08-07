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
# is bounded by the shared numbers read (AIRoleHelpers.neutral_station_target).
#
# That bound has TWO halves, and for a long time only the first existed.
#
#   A MAN HAS GOT BEHIND ME with nobody covering — give up exactly the ice that
#     restores the layer. Reactive by nature, and correctly so: it refuses a
#     guaranteed-breakaway geometry that is already on the ice.
#   IS ANYBODY HOME BEHIND ME — the numbers half, asked BEFORE the turnover.
#     This is the one the shape needed. In a neutral-zone puck race nobody is
#     behind anybody yet, so the reactive half reads clear for every station,
#     both flanks hold a stand two metres off the puck, and the man gets behind
#     them because they all stepped up. Measured: 66% of the following threat
#     window with nobody between the opposing carrier and our net, and the
#     elected RUSH_D1 already up-ice of the puck when the state flipped. The read
#     is antisymmetric (AIRoleHelpers.home_layer_behind_me), so exactly one flank
#     draws the layer — one on the puck, one in support, one home, which is the
#     shape three players actually hold.
#
# Nobody behind AND a body home leaves the stand untouched, so ordinary
# loose-puck play with a layer already back is unchanged.

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
	# Last-man bound (see the header doc). The LAYER's stand — where this body goes
	# when it is the one that has to stay back — is the defensive post at our own
	# blue line, which is exactly the stand 5v5's back pair holds in this same
	# state (AIRoleDefenseman's DBACK). The two team sizes therefore hold the same
	# neutral-zone structure, and the layer is somewhere that is still a layer once
	# the puck is won: a puck-relative floor is not, because every candidate it can
	# name sits a couple of metres off a loose puck at centre ice and is skated
	# through the moment anybody picks it up.
	d.target_position = AIRoleHelpers.neutral_station_target(
			ctx, stand, ctx.prev_held_forward_stand,
			AIZoneCoverage.defensive_anchor(
					true, ctx.self_home_side, ctx.defending_goal_pos.z))
	d.held_forward_stand = d.target_position.distance_to(stand) < 0.5
	return d

class_name AIRoleZoneDefense

# DZONE zone-coverage behavior (5v5 only) — one module for all five area
# roles (ZONE_D_STRONG / ZONE_D_WEAK / ZONE_C / ZONE_W_STRONG / ZONE_W_WEAK).
# The geometry lives in AIZoneCoverage; this consumes it. Design: plan §3.
#
# Per dispatch, in priority order:
#   1. PRESSURE — if my area owns the puck (AIZoneCoverage.pressure_owner),
#      I'm the one defender on the carrier: full AIRolePressure behavior
#      (goal-side cutoff, body-check commit, loose-puck safety).
#   2. COVER — else cover the man the brain gave me, with the shared cover
#      stand (AIRoleHelpers.cover_threat). WHICH man is not this module's
#      decision: TeamBrain matches every zone defender to a DISTINCT
#      opponent, with my area entering as eligibility. The lock still
#      releases when the man leaves my ice (+ release margin, applied to the
#      eligibility) — never chase him out of the structure; the neighbour
#      whose ice he enters picks him up.
#   3. BREATHE — else hold the area's rest anchor, which slides with the
#      puck (collapse toward the house when it goes low, extend toward the
#      points when it goes high).
#
# Choosing per role was the defect this replaced. Five independent argmaxes
# over deliberately OVERLAPPING areas — ZONE_D_STRONG's is everything below
# 8 m with no lateral bound, so it contains the whole net-front box and 3.5 m
# of the slot — coordinated nothing: measured on the real stack, 61% of D-zone
# ticks had a man covered twice and 52% of all locks issued were stacked on a
# body somebody else already had, three deep at times. Every redundant lock is
# a man left open somewhere else. One matching makes distinct men structural,
# exactly as the 3v3 backline has always had.
#
# RoleDecision.locked_man_pid is still published, because the state machine
# reads it to pick the reactive dispatch cadence for a defender covering a
# mover.

static func decide(ctx: RoleContext, role_slot: int) -> RoleDecision:
	var own_goal_z: float = ctx.defending_goal_pos.z
	var strong_x: float = ctx.strong_x

	# No puck info → hold the rest shape.
	if ctx.snapshot == null or ctx.snapshot.puck_state == null:
		var d0 := RoleDecision.new()
		d0.target_position = AIZoneCoverage.anchor_of(
				role_slot, strong_x, own_goal_z, ctx.self_pos)
		return d0

	var puck_pos: Vector3 = ctx.snapshot.puck_state.position

	# 1. Pressure: my area owns the puck.
	if AIZoneCoverage.pressure_owner(strong_x, own_goal_z, puck_pos) == role_slot:
		return AIRolePressure.decide(ctx)

	# 2. Cover the man the brain matched me to.
	var man_pid: int = ctx.assigned_threat_peer
	var d := RoleDecision.new()
	if AIRoleHelpers.cover_threat(ctx, d, man_pid,
			AIRoleHelpers.resolve_defensive_play_ref(ctx)):
		d.locked_man_pid = man_pid
		return d

	# 3. Breathe on the rest anchor.
	d.target_position = AIZoneCoverage.anchor_of(
			role_slot, strong_x, own_goal_z, puck_pos)
	return d

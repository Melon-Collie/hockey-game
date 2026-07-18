class_name AIRoleZoneDefense

# DZONE zone-coverage behavior (5v5 only) — one module for all five area
# roles (ZONE_D_STRONG / ZONE_D_WEAK / ZONE_C / ZONE_W_STRONG / ZONE_W_WEAK).
# The geometry lives in AIZoneCoverage; this consumes it. Design: plan §3.
#
# Per dispatch, in priority order:
#   1. PRESSURE — if my area owns the puck (AIZoneCoverage.pressure_owner),
#      I'm the one defender on the carrier: full AIRolePressure behavior
#      (goal-side cutoff, body-check commit, loose-puck safety).
#   2. SOFT-LOCK — else cover the most dangerous man inside my area
#      (finish-danger read), goal-side in the carrier→man feed lane
#      (cover_man_target), velocity-led. The lock releases when the man
#      leaves the area (+ release margin) — never chase him out of the
#      structure; the neighbor whose ice he enters picks him up.
#   3. BREATHE — else hold the area's rest anchor, which slides with the
#      puck (collapse toward the house when it goes low, extend toward the
#      points when it goes high).
#
# The incumbent-man memory rides RoleDecision.locked_man_pid → RoleContext.
# prev_locked_man (the state machine round-trips it like prev_role_target),
# which is what makes the lock sticky inside the area without any state in
# this module.

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

	# 2. Soft-lock: the most dangerous man in my area, if any.
	var carrier_pid: int = ctx.snapshot.puck_state.carrier_peer_id
	var our_goalie_pos: Vector3 = AIRoleHelpers.resolve_our_goalie_pos(ctx)
	var man_pid: int = AIZoneCoverage.most_dangerous_man_in_area(
			role_slot, strong_x, own_goal_z, ctx.snapshot, ctx.team_id,
			ctx.team_id_by_peer, our_goalie_pos, carrier_pid,
			ctx.prev_locked_man)
	if man_pid != -1 and ctx.snapshot.skater_states.has(man_pid):
		var play_ref: Vector3 = AIRoleHelpers.resolve_defensive_play_ref(ctx)
		if play_ref.is_finite():
			var man: SkaterNetworkState = ctx.snapshot.skater_states[man_pid]
			var man_pos: Vector3 = AIRoleHelpers.lead_threat(
					man.position, man.velocity, ctx.defensive_anticipation_scale)
			var d := RoleDecision.new()
			d.target_position = AIRoleHelpers.cover_man_target(ctx, man_pos, play_ref)
			d.locked_man_pid = man_pid
			return d

	# 3. Breathe on the rest anchor.
	var d2 := RoleDecision.new()
	d2.target_position = AIZoneCoverage.anchor_of(
			role_slot, strong_x, own_goal_z, puck_pos)
	return d2

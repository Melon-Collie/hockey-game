class_name AIRoleBackcheck

# BACKCHECK role behavior — TRANS_OD only. The Sprinting-Through defender: one
# of the two forward peers racing home as a rush develops. Job: get goal-side
# of the receiver it's assigned and deny the carrier's feed to him — pick up a
# MAN, not an empty patch of ice.
#
# Primary path (assigned a man via TeamBrain's threat partition): cover that
# specific opponent — set up goal-side of him in the carrier→man feed lane
# (AIRoleHelpers.cover_man_target, shared with DZONE ANCHOR/COVER). The deepest
# peer (CONTAIN) gap-controls the carrier; the two BACKCHECKs split the two
# receivers, so the rush is met by a man on every threat instead of everyone
# collapsing on the puck. Sprint-home to the assigned man is emergent from the
# state machine's _resolve_sprint on this (typically distant) target.
#
# Fallback (unassigned — no brain, loose puck, or fewer men than backcheckers):
# the legacy "sprint to slot and shade toward the dominant shot threat" —
# argmax over polar candidates centered on our slot of
#
#     -max over opps of threat_surface_shoot(
#         opp, our_net, our_goalie, our_team_with_us_at_c)
#
# so an extra backchecker with no man still races home and helps at the net.

static func decide(ctx: RoleContext) -> RoleDecision:
	var d := RoleDecision.new()

	# Man-on-threat: cover the receiver the brain assigned us. Needs a live
	# carrier (the feed source) — resolve_defensive_play_ref returns INF when
	# there's no puck, which drops us to the slot fallback below.
	var man_pid: int = ctx.assigned_threat_peer
	if man_pid != -1 and ctx.snapshot != null \
			and ctx.snapshot.skater_states.has(man_pid):
		var carrier_pos: Vector3 = AIRoleHelpers.resolve_defensive_play_ref(ctx)
		if carrier_pos.is_finite():
			var man_pos: Vector3 = ctx.snapshot.skater_states[man_pid].position
			d.target_position = AIRoleHelpers.cover_man_target(ctx, man_pos, carrier_pos)
			return d

	var opp_positions: Array[Vector3] = ctx.scratch_opp_positions
	var opp_states: Array[SkaterNetworkState] = ctx.scratch_opp_states
	AIRoleHelpers.collect_opponents(ctx, opp_positions, opp_states)
	if opp_positions.is_empty():
		# No opps to defend against. Hold at slot.
		d.target_position = Vector3(0.0, 0.0,
				ctx.defending_goal_pos.z - ctx.own_goal_dir * GameRules.SLOT_DIST_M)
		return d

	var our_net: Vector3 = ctx.defending_goal_pos
	var our_goalie_pos: Vector3 = AIRoleHelpers.resolve_our_goalie_pos(ctx)
	var our_team_excluding_self: Array[Vector3] = ctx.scratch_teammates
	AIRoleHelpers.collect_teammates_excluding_self(ctx, our_team_excluding_self)

	# Search center: our slot. Fixed reference — backchecker is
	# explicitly racing to slot defense, not interpolating depth
	# from puck position. Slot derives from real rink geometry:
	# SLOT_DIST_M back along the defending-goal normal.
	var search_center := Vector3(0.0, 0.0,
			our_net.z - ctx.own_goal_dir * GameRules.SLOT_DIST_M)
	var candidates: Array[Vector3] = AIRoleHelpers.generate_candidates_around(
			ctx.self_pos, search_center)

	var best_pos: Vector3 = ctx.self_pos
	var best_score: float = -INF
	for c: Vector3 in candidates:
		if not AIRoleHelpers.is_legal_position(c):
			continue
		if AIRoleHelpers.too_close_to_teammate(c, our_team_excluding_self):
			continue

		var backcheck_score: float = -_max_shot_threat(
				c, opp_positions, our_net, our_goalie_pos,
				our_team_excluding_self)
		if backcheck_score > best_score:
			best_score = backcheck_score
			best_pos = c

	d.target_position = best_pos
	return d


# Returns the highest threat surface any opp could extract from their
# current position with our hypothetical defender at `candidate` in
# the threat's "opponents" list. Identical to ANCHOR's helper —
# duplicated here so each role file is self-contained and can evolve
# independently.
static func _max_shot_threat(
		candidate: Vector3,
		opp_positions: Array[Vector3],
		our_net: Vector3,
		our_goalie_pos: Vector3,
		our_team_excluding_self: Array[Vector3]) -> float:
	var opp_view_defenders: Array[Vector3] = our_team_excluding_self.duplicate()
	opp_view_defenders.append(candidate)
	var max_threat: float = 0.0
	for opp_pos: Vector3 in opp_positions:
		var threat: float = AIActionScoring.threat_surface_shoot(
				opp_pos, our_net, our_goalie_pos,
				GameRules.NET_HALF_WIDTH, opp_view_defenders)
		if threat > max_threat:
			max_threat = threat
	return max_threat

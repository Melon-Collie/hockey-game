class_name AIRoleBackcheck

# BACKCHECK role behavior — TRANS_OD only. The Sprinting-Through
# defender: the up-ice peer with the longest sprint home. Job:
# get to the slot fast and deny the highest-threat shot as the
# play closes on our net.
#
# Same scoring shape as DZONE ANCHOR (inverse-threat-minimax over
# polar samples), but the search center is fixed at our slot
# instead of midpoint(puck, our_net). In TRANS_OD the puck is on
# the opp's side, so midpoint would land at center ice or further
# up — the wrong target for a backchecker whose explicit job is
# to defend the slot first and worry about engagement second.
#
# Algorithm: argmax over polar candidates centered on our slot of
#
#     -max over opps of threat_surface_shoot(
#         opp, our_net, our_goalie, our_team_with_us_at_c)
#
# threat_surface_shoot = max(score_shoot, position_potential). The
# position_potential floor keeps the gradient non-zero when no opp
# is in immediate shooting range, so BACKCHECK still pulls into the
# most threatening opp's pressure cone instead of sitting flat at
# slot during the long sprint home.

static func decide(ctx: RoleContext) -> RoleDecision:
	var d := RoleDecision.new()

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

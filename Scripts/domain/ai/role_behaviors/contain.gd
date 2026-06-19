class_name AIRoleContain

# CONTAIN role behavior — TRANS_OD only. The second defender in
# defensive transition: the deeper-of-the-two off-puck peers (the
# up-ice peer is BACKCHECK sprinting home). Job: engage the play
# forward — contest the carrier's options from one layer back of
# PRESSURE — instead of camping the slot while BACKCHECK handles
# deep coverage.
#
# Scoring shape is PRESSURE's inverse-threat-minimax (minimize the
# carrier's best shoot/pass option with me at c) operating from a
# DEEPER search center: the midpoint of the carrier→our-slot line.
# That puts CONTAIN one layer back from PRESSURE, on the same
# spine. With both bots active, the carrier faces a layered
# defense rather than two bots converging on the same point.
#
# Foot-race-home exposure (mirror of SUPPORT's offensive exposure):
#
#     exposure = clamp(my_time_to_slot / min_opp_time_to_slot - 1, 0, 1)
#     score    = -carrier_best_option(c) * (1 - exposure)
#
# When my recovery margin is healthy (exposure ~0), -carrier_best
# decides. When a candidate is too far up-ice (opps would beat me
# back to the slot), exposure ramps to 1 and the candidate's score
# collapses toward 0 — the argmax avoids over-committed positions
# without a magic radius. SKATER_REF_SPEED_M_S + time_to_arrive are
# the same primitives SUPPORT uses; the units are derived from
# real skating speed, not a tuned constant.
#
# No goal-side filter — search center is by construction between
# carrier and our slot, so polar samples stay in legal defensive
# territory.

static func decide(ctx: RoleContext) -> RoleDecision:
	var d := RoleDecision.new()

	# No live carrier (loose puck / pass in flight) — contain the puck
	# itself instead of freezing, so CONTAIN keeps recovering toward the
	# play. Only stand still if there's no puck at all.
	var carrier_pos: Vector3 = AIRoleHelpers.resolve_defensive_play_ref(ctx)
	if not carrier_pos.is_finite():
		d.target_position = ctx.self_pos
		return d

	var our_net: Vector3 = ctx.defending_goal_pos
	var our_slot := Vector3(0.0, 0.0,
			our_net.z - ctx.own_goal_dir * GameRules.SLOT_DIST_M)
	var our_goalie_pos: Vector3 = AIRoleHelpers.resolve_our_goalie_pos(ctx)
	var our_team_excluding_self: Array[Vector3] = ctx.scratch_teammates
	AIRoleHelpers.collect_teammates_excluding_self(ctx, our_team_excluding_self)

	# Opp peers other than the carrier — pass receivers for the
	# carrier_best_option scoring.
	var opp_teammates: Array[Vector3] = ctx.scratch_opp_receivers
	AIRoleHelpers.collect_opp_team_excluding_carrier(ctx, opp_teammates)

	# Foot-race-home baseline: fastest opp time back to our slot.
	# CONTAIN's exposure measures whether my time to slot beats
	# this; over-committed candidates get penalized.
	var opp_positions: Array[Vector3] = ctx.scratch_opp_positions
	var opp_states: Array[SkaterNetworkState] = ctx.scratch_opp_states
	AIRoleHelpers.collect_opponents(ctx, opp_positions, opp_states)
	var min_opp_time_to_slot: float = INF
	for s: SkaterNetworkState in opp_states:
		var t: float = AIActionScoring.time_to_arrive(s.position, our_slot, s.velocity)
		if t < min_opp_time_to_slot:
			min_opp_time_to_slot = t

	# Search center: midpoint of carrier→our-slot. One layer back
	# from PRESSURE's stick-length-from-carrier center, on the same
	# defensive spine. Naturally tracks the play — moves up-ice
	# with the puck, collapses to the slot as the carrier closes.
	var search_center: Vector3 = (carrier_pos + our_slot) * 0.5
	var candidates: Array[Vector3] = AIRoleHelpers.generate_candidates_around(
			ctx.self_pos, search_center)

	var best_pos: Vector3 = ctx.self_pos
	var best_score: float = -INF
	for c: Vector3 in candidates:
		if not AIRoleHelpers.is_legal_position(c):
			continue
		if AIRoleHelpers.too_close_to_teammate(c, our_team_excluding_self):
			continue

		var my_time_to_slot: float = (c.distance_to(our_slot)
				/ AIActionScoring.SKATER_REF_SPEED_M_S)
		var exposure: float = clampf(
				my_time_to_slot / maxf(min_opp_time_to_slot, 0.001) - 1.0,
				0.0, 1.0)

		var carrier_best: float = _carrier_best_option(
				c, carrier_pos, our_net, our_goalie_pos,
				our_team_excluding_self, opp_teammates)
		var score: float = -carrier_best * (1.0 - exposure)
		if score > best_score:
			best_score = score
			best_pos = c

	d.target_position = best_pos
	return d


# Carrier's best option (shoot or pass to any teammate) with our
# hypothetical defender at `candidate` in their "opponents" list.
# Same primitive PRESSURE uses; CONTAIN minimizes the same quantity
# from a deeper search center. Falls back to the threat-surface
# helpers so the gradient survives when score_shoot / score_pass
# collapse to 0 — keeps CONTAIN engaged with the carrier even when
# there's no immediate scoring threat.
static func _carrier_best_option(
		candidate: Vector3,
		carrier_pos: Vector3,
		our_net: Vector3,
		our_goalie_pos: Vector3,
		our_team_excluding_self: Array[Vector3],
		opp_teammates: Array[Vector3]) -> float:
	var carrier_view_defenders: Array[Vector3] = our_team_excluding_self.duplicate()
	carrier_view_defenders.append(candidate)

	var shoot_value: float = AIActionScoring.threat_surface_shoot(
			carrier_pos, our_net, our_goalie_pos,
			GameRules.NET_HALF_WIDTH, carrier_view_defenders)

	var pass_value: float = 0.0
	for opp_pos: Vector3 in opp_teammates:
		var pass_score: float = AIActionScoring.threat_surface_pass(
				carrier_pos, opp_pos, our_net, our_goalie_pos,
				GameRules.NET_HALF_WIDTH, carrier_view_defenders)
		if pass_score > pass_value:
			pass_value = pass_score

	return maxf(shoot_value, pass_value)

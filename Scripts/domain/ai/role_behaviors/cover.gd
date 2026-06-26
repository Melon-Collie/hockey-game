class_name AIRoleCover

# COVER role behavior — DZONE only. Weak-side support /
# pass-interception read. The third defender. Job: position to
# break the highest-threat pass the carrier could make to a
# teammate.
#
# TRANS_OD uses CONTAIN instead — the deeper TRANS_OD peer
# engages the puck forward rather than camping the slot weak-side.
#
# Inverse scoring on pass threats. PRESSURE evaluates the carrier's
# shot AND pass options at close range; ANCHOR evaluates every
# opp's shot threat at our net; COVER specifically targets pass
# threats from the carrier to their teammates. Each role's
# distinct search region keeps them from clustering.
#
# Algorithm: argmax over a back-of-play candidate set of
#
#     -max over opp_teammates of threat_surface_pass(
#         carrier, opp_teammate, our_net, our_goalie,
#         our_team_with_us_at_c)
#
# threat_surface_pass = max(score_pass, lane_clear × position_potential).
# score_pass folds in lane_clear × score_shoot(receiver); when the
# receiver is too far for an immediate shot threat that collapses to
# 0. The position_potential fallback keeps the gradient alive over
# any legal receiver position, so COVER still pulls into pass lanes
# and onto receivers when no direct scoring pass exists.
#
# Search center: midpoint between puck and our net, shifted
# weak-side (opposite the puck's X). In DZONE the puck is on our
# side so this midpoint sits in front of the slot, and the weak-
# side shift puts COVER on the back-side of the play — exactly
# where the third defender belongs.
#
# No goal-side filter — the search center is by construction
# between puck and our net, so polar samples are mostly in legal
# defensive territory. The is_legal_position filter handles
# rink-bound + crease edge cases.

# Lateral shift toward weak-side relative to the midpoint between
# puck and our net. Sampling parameter — sets the COVER region
# off-center; the actual position falls out of the argmax.
const WEAK_SIDE_OFFSET_M: float = 3.0


static func decide(ctx: RoleContext) -> RoleDecision:
	var d := RoleDecision.new()

	# Play reference: the opp carrier when one holds it, else the loose
	# puck itself. COVER used to freeze at self_pos on a loose puck —
	# the defensive analog of the "stuck on the heels" bug. In DZONE a
	# loose puck in our own zone (the possession_state loose-in-our-DZ
	# override) is a live threat: an opp can grab it and feed a teammate.
	# Reading off the puck spot keeps COVER in the most dangerous
	# secondary lane instead of standing still while ANCHOR/PRESSURE
	# handle the direct recovery/shot. Only truly stand still if there's
	# no puck at all. (NEUTRAL has no carrier and uses FLANK roles.)
	var carrier_pos: Vector3 = AIRoleHelpers.resolve_defensive_play_ref(ctx)
	if not carrier_pos.is_finite():
		d.target_position = ctx.self_pos
		return d

	# Man-on-threat: when the brain assigns us a specific opponent, cover HIM
	# (the carrier→man feed lane) instead of minimizing the max pass threat
	# over all receivers — so COVER and ANCHOR partition the two men rather
	# than both shading the single most dangerous one. Falls through to the
	# legacy all-receivers minimax when unassigned.
	var man_pid: int = ctx.assigned_threat_peer
	if man_pid != -1 and ctx.snapshot.skater_states.has(man_pid):
		var man_pos: Vector3 = ctx.snapshot.skater_states[man_pid].position
		d.target_position = AIRoleHelpers.cover_man_target(ctx, man_pos, carrier_pos)
		return d

	var opp_teammates: Array[Vector3] = ctx.scratch_opp_receivers
	AIRoleHelpers.collect_opp_team_excluding_carrier(ctx, opp_teammates)
	if opp_teammates.is_empty():
		# No pass receivers — no pass threat. PRESSURE/ANCHOR cover
		# the carrier's direct options.
		d.target_position = ctx.self_pos
		return d

	var our_net: Vector3 = ctx.defending_goal_pos
	var our_goalie_pos: Vector3 = AIRoleHelpers.resolve_our_goalie_pos(ctx)
	var our_team_excluding_self: Array[Vector3] = ctx.scratch_teammates
	AIRoleHelpers.collect_teammates_excluding_self(ctx, our_team_excluding_self)

	# Search center: midpoint between puck and our net, shifted
	# weak-side. Lives in the slot vicinity in DZONE.
	var midpoint: Vector3 = (carrier_pos + our_net) * 0.5
	var weak_x_sign: float = (-signf(carrier_pos.x)
			if absf(carrier_pos.x) > 0.001 else 1.0)
	var search_center := Vector3(
			midpoint.x + weak_x_sign * WEAK_SIDE_OFFSET_M,
			0.0,
			midpoint.z)
	var candidates: Array[Vector3] = AIRoleHelpers.generate_candidates_around(
			ctx.self_pos, search_center)

	var best_pos: Vector3 = ctx.self_pos
	var best_score: float = -INF
	for c: Vector3 in candidates:
		if not AIRoleHelpers.is_legal_position(c):
			continue
		if AIRoleHelpers.too_close_to_teammate(c, our_team_excluding_self):
			continue

		var cover_score: float = -_max_pass_threat(
				c, carrier_pos, opp_teammates, our_net, our_goalie_pos,
				our_team_excluding_self)
		if cover_score > best_score:
			best_score = cover_score
			best_pos = c

	d.target_position = best_pos
	return d


# Returns the highest pass-threat surface the carrier could exploit
# to any teammate, with our hypothetical defender at `candidate` in
# the carrier's "opponents" list. Uses threat_surface_pass which
# falls back to lane_clear × position_potential(receiver) when
# score_pass collapses to 0 — gives COVER a non-zero gradient over
# defender position even when no immediate scoring pass exists. So
# COVER pulls into the lane between carrier and the dominant
# positional receiver instead of sitting flat at the bail-out.
static func _max_pass_threat(
		candidate: Vector3,
		carrier_pos: Vector3,
		opp_teammates: Array[Vector3],
		our_net: Vector3,
		our_goalie_pos: Vector3,
		our_team_excluding_self: Array[Vector3]) -> float:
	# Build the carrier's view of defenders: our team + me at c.
	var carrier_view_defenders: Array[Vector3] = our_team_excluding_self.duplicate()
	carrier_view_defenders.append(candidate)

	var max_threat: float = 0.0
	for opp_pos: Vector3 in opp_teammates:
		var threat: float = AIActionScoring.threat_surface_pass(
				carrier_pos, opp_pos, our_net, our_goalie_pos,
				GameRules.NET_HALF_WIDTH, carrier_view_defenders)
		if threat > max_threat:
			max_threat = threat
	return max_threat

class_name AIRoleCover

# COVER role behavior — DZONE + TRANS_OD weak-side support /
# pass-interception read. The third defender. Job: position to
# break the highest-threat pass the carrier could make to a
# teammate.
#
# Inverse scoring on pass threats. PRESSURE evaluates the carrier's
# shot AND pass options at close range; ANCHOR evaluates every
# opp's shot threat at our net; COVER specifically targets pass
# threats from the carrier to their teammates. Each role's
# distinct search region keeps them from clustering.
#
# Algorithm: argmax over a back-of-play candidate set of
#
#     -max over opp_teammates of score_pass(
#         carrier, opp_teammate, our_net, our_goalie,
#         our_team_with_us_at_c)
#
# Same score_pass primitive used everywhere. score_pass's
# receiver-value term internally scores the receiver's potential
# shot at our net, so the post-pass shot threat is implicitly
# captured — COVER doesn't need to score it separately.
#
# Search center: midpoint between puck and our net, shifted
# weak-side (opposite the puck's X). Pure in-game refs —
# midpoint naturally interpolates between DZONE (close to our
# net) and TRANS_OD (NZ-ish) without a state branch. The weak-
# side shift puts COVER on the back-side of the play.
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

	# Threat origin: carrier's position if one exists, else the puck
	# itself. Lets COVER keep working in NEUTRAL (no carrier) or
	# in-flight loose-puck windows.
	var carrier_pos: Vector3 = AIRoleHelpers.resolve_threat_pos(ctx)
	if carrier_pos == Vector3.ZERO:
		# Snapshot null — nothing to score against.
		d.target_position = ctx.self_pos
		return d

	var opp_teammates: Array[Vector3] = AIRoleHelpers.collect_opp_team_excluding_carrier(ctx)
	if opp_teammates.is_empty():
		# No pass receivers — no pass threat to read.
		d.target_position = ctx.self_pos
		return d

	var our_net: Vector3 = ctx.defending_goal_pos
	var our_goalie_pos: Vector3 = AIRoleHelpers.resolve_our_goalie_pos(ctx)
	var our_team_excluding_self: Array[Vector3] = AIRoleHelpers.collect_teammates_excluding_self(ctx)

	# Search center: midpoint between puck and our net, shifted
	# weak-side. Pure in-game refs — no state branching needed,
	# the midpoint position naturally varies across DZONE / TRANS_OD.
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


# Returns the highest score_pass the carrier could make to any
# teammate, with our hypothetical defender position included in
# the carrier's "opponents" list. COVER wants to minimize this.
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
		var threat: float = AIActionScoring.score_pass(
				carrier_pos, opp_pos, our_net, our_goalie_pos,
				GameRules.NET_HALF_WIDTH, carrier_view_defenders)
		if threat > max_threat:
			max_threat = threat
	return max_threat

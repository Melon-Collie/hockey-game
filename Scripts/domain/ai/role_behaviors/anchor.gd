class_name AIRoleAnchor

# ANCHOR role behavior — DZONE + TRANS_OD. Net-front / deep
# defender. Job: defend the slot area and minimize the highest-
# threat shot any opp could take at our net.
#
# Inverse scoring on shot threats. PRESSURE evaluates only the
# carrier; ANCHOR evaluates every opp (carrier + their teammates)
# as a potential shooter, since after a pass any opp could one-time
# the puck. The candidate that minimizes the maximum shot threat
# wins.
#
# Algorithm: argmax over a slot-area candidate set of
#
#     -max over opps of threat_surface_shoot(
#         opp, our_net, our_goalie, our_team_with_us_at_c)
#
# threat_surface_shoot = max(score_shoot, position_potential). The
# position_potential floor keeps the gradient non-zero when an opp
# is too far for a real shot threat — ANCHOR still pulls into that
# opp's pressure cone instead of sitting flat at slot. The minimax
# over the threat set gives ANCHOR's best block position.
#
# Search center: midpoint between the puck and our net. Mirrors
# COVER's pattern. Pure in-game refs — the search region naturally
# moves up the ice with the puck so ANCHOR pushes forward in
# TRANS_OD (puck in NZ → midpoint at our blue line) and tightens to
# slot in DZONE (puck deep → midpoint near net). This delivers the
# "defenders should not just sit in front of net" intent without
# any heuristic blend or behavioral knob.
#
# Polar samples around this center cover the slot/lane region near
# the dominant threat. The argmax shifts laterally toward whichever
# opp is the dominant threat (e.g., the carrier's shot lane vs a
# back-door receiver's cross-crease angle).
#
# No reactive override in v1 — positioning runs every tick, so the
# argmax naturally pulls ANCHOR into a fast-shot lane when one
# becomes the dominant threat. Add a reactive mode (square-up +
# hold) if playtest shows ANCHOR is too slow to block in-flight
# shots.


static func decide(ctx: RoleContext) -> RoleDecision:
	var d := RoleDecision.new()

	var opp_positions: Array[Vector3] = []
	var opp_states: Array[SkaterNetworkState] = []
	AIRoleHelpers.collect_opponents(ctx, opp_positions, opp_states)
	if opp_positions.is_empty():
		# No opps to defend against.
		d.target_position = ctx.self_pos
		return d

	var our_net: Vector3 = ctx.defending_goal_pos
	var our_goalie_pos: Vector3 = AIRoleHelpers.resolve_our_goalie_pos(ctx)
	var our_team_excluding_self: Array[Vector3] = AIRoleHelpers.collect_teammates_excluding_self(ctx)

	# Search center: midpoint between puck and our net. Pure in-game
	# refs — the search region naturally interpolates between TRANS_OD
	# (puck NZ-side → midpoint at our blue line) and DZONE (puck deep
	# → midpoint near net). Falls back to slot when puck_state is
	# unavailable so a missing snapshot doesn't strand ANCHOR at
	# (0, 0, 0).
	var search_center: Vector3
	if ctx.snapshot != null and ctx.snapshot.puck_state != null:
		search_center = (ctx.snapshot.puck_state.position + our_net) * 0.5
	else:
		search_center = Vector3(
				0.0,
				0.0,
				our_net.z - ctx.own_goal_dir * AIActionScoring.IDEAL_SHOT_DIST_M)
	var candidates: Array[Vector3] = AIRoleHelpers.generate_candidates_around(
			ctx.self_pos, search_center)

	var best_pos: Vector3 = ctx.self_pos
	var best_score: float = -INF
	for c: Vector3 in candidates:
		if not AIRoleHelpers.is_legal_position(c):
			continue
		if AIRoleHelpers.too_close_to_teammate(c, our_team_excluding_self):
			continue

		var anchor_score: float = -_max_shot_threat(
				c, opp_positions, our_net, our_goalie_pos,
				our_team_excluding_self)
		if anchor_score > best_score:
			best_score = anchor_score
			best_pos = c

	d.target_position = best_pos
	return d


# Returns the highest threat surface any opp could extract from their
# current position with our hypothetical defender at `candidate` in
# the threat's "opponents" list. Uses threat_surface_shoot which
# falls back to position_potential when score_shoot returns 0 — gives
# ANCHOR a non-zero gradient across opp positions even when no opp is
# in immediate shooting range, so it pulls into the dominant opp's
# pressure cone instead of sitting flat at slot.
static func _max_shot_threat(
		candidate: Vector3,
		opp_positions: Array[Vector3],
		our_net: Vector3,
		our_goalie_pos: Vector3,
		our_team_excluding_self: Array[Vector3]) -> float:
	# Build the opp's view of defenders: our team + me at c.
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

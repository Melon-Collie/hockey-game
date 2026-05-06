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
#     -max over opps of score_shoot(
#         opp, our_net, our_goalie, our_team_with_us_at_c)
#
# Same score_shoot primitive we use for offensive scoring, but
# applied from each opp's perspective with our hypothetical
# defender position included in their "opponents" list. The minimax
# over the threat set gives ANCHOR's best block position.
#
# Search center: the slot — SLOT_DEPTH_M (5 m) in front of our goal
# at center ice. Polar samples cover the strong-side post, weak-side
# post, and high-slot regions. The argmax shifts laterally toward
# whichever opp is the dominant threat (e.g., the carrier's shot
# lane vs a back-door receiver's cross-crease angle).
#
# No reactive override in v1 — positioning runs every tick, so the
# argmax naturally pulls ANCHOR into a fast-shot lane when one
# becomes the dominant threat. Add a reactive mode (square-up +
# hold) if playtest shows ANCHOR is too slow to block in-flight
# shots.

# Search center depth in front of own goal. Mirrors FINISHER's
# SLOT_DEPTH_FROM_GOAL_M — keeps every polar sample (radius
# SEARCH_STEP_M = 3) on the legal side of the goal line
# (GOAL_LINE_BUFFER_M = 1). Pure geometric.
const SLOT_DEPTH_M: float = 5.0


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

	# Search center: the slot, SLOT_DEPTH_M in front of our goal at
	# center ice. Pure in-game ref (our net + slot depth toward
	# neutral). own_goal_dir is +1 for Team 0 (our net at +Z, slot
	# is in -Z direction); -1 for Team 1 (our net at -Z, slot is
	# in +Z direction). Hence subtract own_goal_dir * SLOT_DEPTH_M.
	var search_center := Vector3(
			0.0,
			0.0,
			our_net.z - ctx.own_goal_dir * SLOT_DEPTH_M)
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


# Returns the highest score_shoot any opp could take at our net,
# with our hypothetical defender position included in the threat's
# "opponents" list. ANCHOR wants to minimize this.
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
		var threat: float = AIActionScoring.score_shoot(
				opp_pos, our_net, our_goalie_pos,
				GameRules.NET_HALF_WIDTH, opp_view_defenders)
		if threat > max_threat:
			max_threat = threat
	return max_threat

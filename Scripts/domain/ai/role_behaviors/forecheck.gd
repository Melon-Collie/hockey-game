class_name AIRoleForecheck

# FORECHECK role behavior — FORECHECK state only (opp possesses the puck
# in THEIR defensive zone). The two off-puck forecheckers in the
# conservative 1-1-1 press (F1 reuses AIRolePressure, dispatched
# directly — not here):
#
#   F2 (is_high = false) — mid-lane read, AGGRESSIVE. Sits in the zone
#     and takes away the most dangerous breakout PASS the carrier could
#     make to a teammate. Inverse pass-threat scoring, over a
#     search region biased toward the opp blue line (the breakout
#     lanes). Stays IN the zone — that's the forecheck; sagging out
#     would concede it.
#   F3 (is_high = true)  — high safety, strong side. The one conservative role:
#     the designated first-man-back if the forecheck fails. Holds the opp blue
#     line only while the shared pinch read allows it. A fixed blue-line anchor
#     is a permanent pinch — one chip past it is a breakaway with only the
#     goalie home.
#
# Nobody is offside during a forecheck: we turned the puck over after a legal
# zone entry, so the whole team is onside as long as the puck stays in the zone,
# and keeping it in IS the goal. F1 and F2 therefore press freely with no offside
# concern. If the forecheck fails the state flips to TRANS_DEFENSE, whose rush
# layers pull everyone home and self-clear any delayed-offside ghost on the way.

# How far off the strong-side boards F3 holds at the blue line. Keeps it
# off the wall so it can step to either breakout lane.
const F3_WALL_INSET_M: float = 4.0

# F2 search-center depth toward the opp net from the blue line — how far
# into the zone the mid read sets up. Small: F2 is the high-zone
# interceptor, not a second deep pressurer.
const F2_ZONE_DEPTH_M: float = 4.0


# `is_high` selects F3 (the high blue-line safety) vs F2 (the mid read).
static func decide(ctx: RoleContext, is_high: bool) -> RoleDecision:
	if is_high:
		return _decide_high(ctx)
	return _decide_mid(ctx)


# 5v5's 1-2-2 second layer (plan §2): the same inverse-pass-threat argmax
# as the 3v3 F2, run around a LANE-specific search center — the strong-side
# man works the wall at half-wall height (kill the first outlet: the
# half-wall winger), the weak-side man locks the middle lane at
# circle-tops-to-line height (kill the center outlet + cross-ice reverse).
# The pair re-sorts automatically when the puck crosses (strong_x flip
# re-elects the slots).
const F2_STRONG_WALL_INSET_M: float = 4.0
const F2_STRONG_DEPTH_OFF_GOAL_M: float = 12.0


static func decide_f2(ctx: RoleContext, is_strong: bool) -> RoleDecision:
	var carrier_pos: Vector3 = AIRoleHelpers.resolve_defensive_play_ref(ctx)
	if not carrier_pos.is_finite():
		var d := RoleDecision.new()
		d.target_position = ctx.self_pos
		return d
	var center: Vector3
	if is_strong:
		center = Vector3(
				ctx.strong_x * (GameRules.RINK_HALF_WIDTH - F2_STRONG_WALL_INSET_M),
				0.0,
				-ctx.own_goal_dir * (GameRules.GOAL_LINE_Z - F2_STRONG_DEPTH_OFF_GOAL_M))
	else:
		center = _mid_search_center(ctx, carrier_pos)
	return _decide_mid_at(ctx, carrier_pos, center)


# ── F3: high safety — hold the line only while the race home is winnable ─────
static func _decide_high(ctx: RoleContext) -> RoleDecision:
	var d := RoleDecision.new()
	# Opp blue line on the Z axis (attacking-zone boundary), strong side
	# on X. own_goal_dir is +1 when our net is +Z (we attack -Z), so the
	# opp blue line is at -own_goal_dir * BLUE_LINE_Z.
	var blue_z: float = -ctx.own_goal_dir * GameRules.BLUE_LINE_Z
	var wall_x: float = ctx.strong_x * (GameRules.RINK_HALF_WIDTH - F3_WALL_INSET_M)

	# The pinch read (AIRoleHelpers.may_hold_forward_stand): opponents bottled
	# deep keep the line; their breakout genuinely under way, or a man behind
	# the stand with nobody covering, sends F3 back to his home post.
	var line_stand := Vector3(wall_x, 0.0, blue_z)
	# F3_HIGH exists only in the 3v3 slot table (5v5's forecheck uses the DP pair
	# plus F2_STRONG/_WEAK), and with three skaters and no D pair he IS the team's
	# entire back layer — the designated first man back. So he retreats to the
	# DEFENSEMAN's home post, not the shallower forward one his (absent) lobby
	# identity would otherwise pick.
	d.target_position = AIRoleHelpers.offensive_station_target(
			ctx, line_stand, ctx.prev_held_forward_stand, true)
	d.held_forward_stand = d.target_position.distance_to(line_stand) < 0.5
	return d


# ── F2: mid-lane breakout-pass read ──────────────────────────────────────────
static func _decide_mid(ctx: RoleContext) -> RoleDecision:
	# A loose puck deep in their zone is a prime forecheck moment, so the read
	# falls back to it. Stand still only when there is no puck at all.
	var carrier_pos: Vector3 = AIRoleHelpers.resolve_defensive_play_ref(ctx)
	if not carrier_pos.is_finite():
		var d := RoleDecision.new()
		d.target_position = ctx.self_pos
		return d
	return _decide_mid_at(ctx, carrier_pos, _mid_search_center(ctx, carrier_pos))


# The F2 argmax body, parameterized on the search center so the 3v3 mid read
# and the 5v5 lane pair share one implementation.
static func _decide_mid_at(ctx: RoleContext, carrier_pos: Vector3,
		search_center: Vector3) -> RoleDecision:
	var d := RoleDecision.new()

	var opp_teammates: Array[Vector3] = ctx.scratch_opp_receivers
	# Anticipate: lead the breakout-pass receivers to where they're cutting.
	AIRoleHelpers.collect_opp_team_excluding_carrier(ctx, opp_teammates, true)
	if opp_teammates.is_empty():
		# No outlet receivers to deny — sit at the high-zone read spot so
		# F2 still pressures the breakout lane rather than freezing.
		d.target_position = search_center
		return d

	# F2 denies the opp's BREAKOUT pass — one heading toward OUR net, out of their
	# zone — so the threat minimized is the carrier feeding a teammate up-ice, on
	# the same inverse-pass-threat surface PRESSURE uses.
	var our_net: Vector3 = ctx.defending_goal_pos
	var our_goalie_pos: Vector3 = AIRoleHelpers.resolve_our_goalie_pos(ctx)
	var our_team_excluding_self: Array[Vector3] = ctx.scratch_teammates
	AIRoleHelpers.collect_teammates_excluding_self(ctx, our_team_excluding_self)

	var candidates: Array[Vector3] = AIRoleHelpers.generate_candidates_around(
			ctx.self_pos, search_center)
	# Switch-hysteresis: hold the forecheck spot unless a fresh one deflates the
	# feed clearly more, so the cursor (which snaps to this target) stays steady.
	AIRoleHelpers.append_incumbent(ctx, candidates)

	# Per-receiver pass-threat upper bounds (no candidate appended) for the
	# per-candidate max() early-out — same monotone-in-defenders argument as
	# AIRoleHelpers.carrier_option_bases, same exact result.
	var bases: Array[float] = ctx.scratch_option_bases
	bases.clear()
	for opp_pos: Vector3 in opp_teammates:
		bases.append(AIActionScoring.threat_surface_pass(
				carrier_pos, opp_pos, our_net, our_goalie_pos,
				GameRules.NET_HALF_WIDTH, our_team_excluding_self,
				ctx.scratch_teammate_caps))

	var best_pos: Vector3 = search_center
	var best_score: float = -INF
	for c: Vector3 in candidates:
		if not AIRoleHelpers.is_legal_position(c):
			continue
		# Keep F2 IN the attacking zone — sagging back across the blue line
		# concedes the forecheck. own_goal_dir * z grows toward our net and the
		# opp blue line sits at -own_goal_dir * BLUE_LINE_Z, so "in the zone" is
		# own_goal_dir * c.z <= -BLUE_LINE_Z.
		if ctx.own_goal_dir * c.z > -GameRules.BLUE_LINE_Z:
			continue
		if AIRoleHelpers.too_close_to_teammate(c, our_team_excluding_self):
			continue
		var threat: float = _max_pass_threat(
				c, carrier_pos, opp_teammates, our_net, our_goalie_pos,
				our_team_excluding_self, bases, ctx.scratch_teammate_caps,
				ctx.caps_by_peer.get(ctx.peer_id))
		var score: float = -threat + AIRoleHelpers.incumbent_bonus(ctx, c)
		if score > best_score:
			best_score = score
			best_pos = c

	d.target_position = best_pos
	return d


# F2's search center: F2_ZONE_DEPTH_M inside the opp blue line, shaded halfway to
# the carrier's side so it sits between the strong breakout lane and the
# dangerous middle outlet.
static func _mid_search_center(ctx: RoleContext, carrier_pos: Vector3) -> Vector3:
	var blue_z: float = -ctx.own_goal_dir * GameRules.BLUE_LINE_Z
	var z: float = blue_z - ctx.own_goal_dir * F2_ZONE_DEPTH_M
	var x: float = carrier_pos.x * 0.5
	return Vector3(x, 0.0, z)


# Highest pass-threat surface the carrier could exploit to any teammate, with our
# hypothetical defender at `candidate` added to his view of the opponents.
# `bases` (per-receiver threats WITHOUT the candidate, in opp_teammates order)
# bound each term from above — adding a defender only lowers a surface — so terms
# evaluate in descending-bound order and stop when the running max meets the next
# bound: identical result, fewer surfaces.
static func _max_pass_threat(
		candidate: Vector3,
		carrier_pos: Vector3,
		opp_teammates: Array[Vector3],
		our_net: Vector3,
		our_goalie_pos: Vector3,
		our_team_excluding_self: Array[Vector3],
		bases: Array[float],
		our_team_caps: Array = [],
		self_caps: AISkaterCaps = null) -> float:
	# Defenders = our team + me at the candidate, push/popped into the caller's
	# array in place (10 calls/decide). Caps ride alongside only when the caller
	# supplied a matched array.
	var caps_matched: bool = our_team_caps.size() == our_team_excluding_self.size()
	our_team_excluding_self.push_back(candidate)
	if caps_matched:
		our_team_caps.push_back(self_caps)

	var max_threat: float = 0.0
	var used: int = 0
	while true:
		var bi: int = -1
		var bound: float = -1.0
		for i: int in bases.size():
			if used & (1 << i) == 0 and bases[i] > bound:
				bound = bases[i]
				bi = i
		if bi == -1 or bound <= max_threat:
			break
		used |= 1 << bi
		var threat: float = AIActionScoring.threat_surface_pass(
				carrier_pos, opp_teammates[bi], our_net, our_goalie_pos,
				GameRules.NET_HALF_WIDTH, our_team_excluding_self, our_team_caps)
		if threat > max_threat:
			max_threat = threat
	our_team_excluding_self.pop_back()
	if caps_matched:
		our_team_caps.pop_back()
	return max_threat

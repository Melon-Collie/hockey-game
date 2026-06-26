class_name AIRoleForecheck

# FORECHECK role behavior — FORECHECK state only (opp possesses the puck
# in THEIR defensive zone). The two off-puck forecheckers in the
# conservative 1-1-1 press (F1 reuses AIRolePressure, dispatched
# directly — not here):
#
#   F2 (is_high = false) — mid-lane read, AGGRESSIVE. Sits in the zone
#     and takes away the most dangerous breakout PASS the carrier could
#     make to a teammate. Inverse pass-threat scoring (mirror of COVER),
#     search region biased toward the opp blue line (the breakout
#     lanes). Stays IN the zone — that's the forecheck; sagging out
#     would concede it.
#   F3 (is_high = true)  — high safety at the opp blue line, strong
#     side. The one conservative role: the designated first-man-back if
#     the forecheck fails, so it holds the line rather than pressuring
#     deep. Pure positional anchor.
#
# Nobody is offside during a forecheck. We turned the puck over after a
# legal zone entry, so the whole team is onside as long as the puck
# stays in the zone — and keeping it in the zone IS the goal. So F1 and
# F2 press freely with no offside concern; there's no penalty for being
# deep here. If the forecheck fails and the puck leaves the zone, the
# possession state flips to TRANS_OD, whose BACKCHECK/CONTAIN pull
# everyone home — any brief delayed-offside ghost self-clears on that
# retreat (tag up at the line, re-engage). The risk is accepted, not
# avoided: keeping possession in their end is worth a few bots being
# caught deep on the occasional failed pin.

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


# ── F3: high safety at the opp blue line ─────────────────────────────────────
static func _decide_high(ctx: RoleContext) -> RoleDecision:
	var d := RoleDecision.new()
	# Opp blue line on the Z axis (attacking-zone boundary), strong side
	# on X. own_goal_dir is +1 when our net is +Z (we attack -Z), so the
	# opp blue line is at -own_goal_dir * BLUE_LINE_Z.
	var blue_z: float = -ctx.own_goal_dir * GameRules.BLUE_LINE_Z
	var wall_x: float = ctx.strong_x * (GameRules.RINK_HALF_WIDTH - F3_WALL_INSET_M)
	d.target_position = Vector3(wall_x, 0.0, blue_z)
	return d


# ── F2: mid-lane breakout-pass read ──────────────────────────────────────────
static func _decide_mid(ctx: RoleContext) -> RoleDecision:
	var d := RoleDecision.new()

	# Read off the carrier; fall back to the puck when it's loose (a
	# loose puck deep in their zone is a prime forecheck moment). Stand
	# still only if there's no puck at all.
	var carrier_pos: Vector3 = AIRoleHelpers.resolve_defensive_play_ref(ctx)
	if not carrier_pos.is_finite():
		d.target_position = ctx.self_pos
		return d

	var opp_teammates: Array[Vector3] = ctx.scratch_opp_receivers
	# Anticipate: lead the breakout-pass receivers to where they're cutting.
	AIRoleHelpers.collect_opp_team_excluding_carrier(ctx, opp_teammates, true)
	if opp_teammates.is_empty():
		# No outlet receivers to deny — sit at the high-zone read spot so
		# F2 still pressures the breakout lane rather than freezing.
		d.target_position = _mid_search_center(ctx, carrier_pos)
		return d

	# We're defending OUR net, but F2's job is to deny the opp's BREAKOUT
	# pass — a pass that heads toward OUR net / out of their zone. The
	# threat we minimize is the carrier feeding a teammate up-ice. Score
	# the same inverse-pass-threat surface COVER uses, with our team (+
	# our candidate) as the defenders, evaluated toward our net.
	var our_net: Vector3 = ctx.defending_goal_pos
	var our_goalie_pos: Vector3 = AIRoleHelpers.resolve_our_goalie_pos(ctx)
	var our_team_excluding_self: Array[Vector3] = ctx.scratch_teammates
	AIRoleHelpers.collect_teammates_excluding_self(ctx, our_team_excluding_self)

	var search_center: Vector3 = _mid_search_center(ctx, carrier_pos)
	var candidates: Array[Vector3] = AIRoleHelpers.generate_candidates_around(
			ctx.self_pos, search_center)

	var best_pos: Vector3 = search_center
	var best_score: float = -INF
	for c: Vector3 in candidates:
		if not AIRoleHelpers.is_legal_position(c):
			continue
		# Keep F2 IN the attacking zone — sagging back across the blue
		# line concedes the forecheck. Reject candidates on the NZ side of
		# the opp blue line. own_goal_dir * z grows toward our net; the
		# opp blue line is at -own_goal_dir * BLUE_LINE_Z, so "in the zone"
		# is own_goal_dir * c.z <= -BLUE_LINE_Z (z past the line toward
		# the opp net). No offside concern — the team is onside until the
		# puck leaves, and keeping it in is the whole point.
		if ctx.own_goal_dir * c.z > -GameRules.BLUE_LINE_Z:
			continue
		if AIRoleHelpers.too_close_to_teammate(c, our_team_excluding_self):
			continue
		var threat: float = _max_pass_threat(
				c, carrier_pos, opp_teammates, our_net, our_goalie_pos,
				our_team_excluding_self)
		var score: float = -threat
		if score > best_score:
			best_score = score
			best_pos = c

	d.target_position = best_pos
	return d


# F2 search center: high in the opp zone, between the carrier and the
# opp blue line, biased toward the breakout lanes. Sits F2_ZONE_DEPTH_M
# inside the blue line on the carrier's side so it shades to the strong
# breakout lane.
static func _mid_search_center(ctx: RoleContext, carrier_pos: Vector3) -> Vector3:
	var blue_z: float = -ctx.own_goal_dir * GameRules.BLUE_LINE_Z
	# Inside the blue line toward the opp net (deeper into their zone) by
	# F2_ZONE_DEPTH_M, i.e. away from our net.
	var z: float = blue_z - ctx.own_goal_dir * F2_ZONE_DEPTH_M
	# Bias X toward the carrier's side (the strong breakout lane), but
	# pulled toward center so F2 covers the dangerous middle outlet.
	var x: float = carrier_pos.x * 0.5
	return Vector3(x, 0.0, z)


# Highest pass-threat surface the carrier could exploit to any teammate,
# with our hypothetical defender at `candidate` added to the carrier's
# "opponents" list. Same primitive COVER uses.
static func _max_pass_threat(
		candidate: Vector3,
		carrier_pos: Vector3,
		opp_teammates: Array[Vector3],
		our_net: Vector3,
		our_goalie_pos: Vector3,
		our_team_excluding_self: Array[Vector3]) -> float:
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

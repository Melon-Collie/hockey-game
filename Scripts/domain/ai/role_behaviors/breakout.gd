class_name AIRoleBreakout

# BREAKOUT role behavior — BREAKOUT state only (we possess the puck in
# our OWN defensive zone). Two outlet options for the carrier breaking
# the puck out, asymmetric by job but scored with the same primitive:
#
#   strong (BREAKOUT_STRONG) — the strong-side-wall outlet. Free to
#     advance up-ice toward the blue line on the puck's side. This is
#     the primary "give me the puck and I'll carry it out" option.
#   weak   (BREAKOUT_WEAK)   — the weak-side reverse valve. Stays
#     goal-side of (no further up-ice than) the carrier so a D-to-D
#     reverse is always available and the carrier is never the last
#     man back. Mirrors SUPPORT's safety-valve role, on the weak side.
#
# Scoring (both): argmax over a side-gated candidate set of
#
#     lane_clear(carrier → c, pass_speed) × position_potential(c)
#
# - lane_clear is the reaction-window PASS model (same one the carrier
#   uses to decide the pass), so the outlet positions itself where the
#   carrier actually has a clean lane — the two agree on "threadable."
# - position_potential is the open-ice / forward-progress value of the
#   spot. Crucially it does NOT collapse to 0 deep in our own zone
#   (its closeness ramp spans the whole rink), unlike score_pass /
#   score_shoot which return 0 outside shooting range — so it gives a
#   usable gradient for breakout positioning where score_pass can't.
#
# The asymmetry lives entirely in candidate generation + filtering, not
# the score: STRONG searches up the strong-side wall and is free to
# advance; WEAK searches the weak side and is hard-constrained
# goal-side of the carrier. Search side comes from ctx.strong_x (the
# brain's hysteretic strong side) so it matches the slot assignment.

# Search radius for the polar candidate ring around each role's search
# center. Same scale as the other off-puck roles' SEARCH_STEP_M.
const SEARCH_RADIUS_M: float = 4.0

# How far up-ice (toward our blue line) the STRONG search center sits
# from the carrier, along the breakout direction. One ring-radius of
# lead so the strong outlet presents ahead of the puck on the wall.
const STRONG_LEAD_M: float = 4.0

# Lateral inset from the boards for the strong-side wall center, so the
# polar ring doesn't all clamp against the wall.
const WALL_INSET_M: float = 2.0

# Weak-side safety-valve tolerance: WEAK may sit up to this far up-ice
# of the carrier (roughly even) but no further — keeps it the reverse
# option, never ahead of the play. Mirrors AIRoleSupport.
const GOAL_SIDE_TOLERANCE_M: float = 1.5


# `is_strong` selects the strong-side-wall outlet (true) vs the
# weak-side reverse valve (false).
static func decide(ctx: RoleContext, is_strong: bool) -> RoleDecision:
	var d := RoleDecision.new()

	# Orient off a live teammate carrier; fall back to the puck when
	# it's loose (mid-pass in our own zone). Stand still only if there's
	# no puck at all.
	var carrier_pos: Vector3 = AIRoleHelpers.resolve_offensive_play_ref(ctx)
	if not carrier_pos.is_finite():
		d.target_position = ctx.self_pos
		return d

	var opp_positions: Array[Vector3] = []
	var opp_states: Array[SkaterNetworkState] = []
	AIRoleHelpers.collect_opponents(ctx, opp_positions, opp_states)
	var teammate_positions: Array[Vector3] = AIRoleHelpers.collect_teammates_excluding_self(ctx)

	# Side this outlet works: strong outlet on the strong side, weak
	# outlet on the opposite side.
	var side_x: float = ctx.strong_x if is_strong else -ctx.strong_x
	# Breakout direction: toward our blue line / up-ice (away from our
	# net). own_goal_dir is +1 when our net is +Z, so up-ice is
	# -own_goal_dir on Z.
	var up_ice_z: float = -ctx.own_goal_dir

	var search_center: Vector3 = _search_center(
			ctx, carrier_pos, is_strong, side_x, up_ice_z)
	var candidates: Array[Vector3] = AIRoleHelpers.generate_candidates_around(
			ctx.self_pos, search_center)

	var best_pos: Vector3 = ctx.self_pos
	var best_score: float = -INF
	for c: Vector3 in candidates:
		if not AIRoleHelpers.is_legal_position(c):
			continue
		if AIRoleHelpers.too_close_to_teammate(c, teammate_positions):
			continue
		# Offside isn't a concern here: the breakout zone is our own end,
		# and the hard line is the OPP blue line a full rink away — no
		# candidate from these search centers reaches it, and
		# is_legal_position already bounds the rink. WEAK, the safety
		# valve, is the only one constrained: reject candidates up-ice of
		# the carrier beyond the tolerance so it stays the reverse option.
		if not is_strong and not _is_goal_side_of_carrier(
				c, carrier_pos, ctx.own_goal_dir):
			continue
		var pass_speed: float = AIActionScoring.expected_pass_speed(carrier_pos, c)
		var lane: float = AIActionScoring.lane_clear(
				carrier_pos, c, opp_positions, pass_speed)
		if lane <= 0.0:
			continue
		var potential: float = AIActionScoring.position_potential(
				c, ctx.attacking_goal_pos, opp_positions)
		var score: float = lane * potential
		if score > best_score:
			best_score = score
			best_pos = c

	d.target_position = best_pos
	return d


# Search center for each outlet.
#   STRONG: strong-side wall, led up-ice from the carrier toward our
#     blue line — presents ahead of the puck on the boards.
#   WEAK:   weak-side, level with the carrier on the depth axis — the
#     reverse-valve release point.
static func _search_center(ctx: RoleContext, carrier_pos: Vector3,
		is_strong: bool, side_x: float, up_ice_z: float) -> Vector3:
	var wall_x: float = side_x * (GameRules.RINK_HALF_WIDTH - WALL_INSET_M)
	if is_strong:
		# Lead up-ice from the carrier's depth toward our blue line.
		var z: float = carrier_pos.z + up_ice_z * STRONG_LEAD_M
		return Vector3(wall_x, 0.0, z)
	# Weak: level with the carrier (reverse option on the weak wall).
	return Vector3(wall_x, 0.0, carrier_pos.z)


# True if candidate `c` is goal-side of (or roughly even with) the
# carrier on the depth axis — no further up-ice than the carrier within
# GOAL_SIDE_TOLERANCE_M. own_goal_dir * z grows toward our net, so a
# larger value is "deeper / more goal-side." Mirrors AIRoleSupport.
static func _is_goal_side_of_carrier(c: Vector3, carrier_pos: Vector3,
		own_goal_dir: float) -> bool:
	return own_goal_dir * c.z >= own_goal_dir * carrier_pos.z - GOAL_SIDE_TOLERANCE_M

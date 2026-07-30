class_name AIRoleBreakout

# BREAKOUT role behavior — BREAKOUT state only (we possess the puck in
# our OWN defensive zone). Two outlet options for the carrier breaking
# the puck out, asymmetric by job but scored with the same primitive:
#
#   strong (BREAKOUT_STRONG) — the strong-side-wall outlet. Presents UP
#     THE WALL: candidates are sampled along the strong-side boards from
#     just ahead of the carrier all the way to our blue line (plus a
#     mid-seam column — see MID_SEAM_FRACTION), and the score picks the
#     highest spot whose lane is still clean. So STRONG stretches to the
#     blue line when the wall is open, drops to a lower open spot when
#     the high wall is covered, and swings inside when the wall lane is
#     the carrier's own wheel route — a real up-the-wall breakout
#     outlet, not a 4 m dump-off.
#   weak   (BREAKOUT_WEAK)   — the weak-side reverse valve. Stays
#     goal-side of (no further up-ice than) the carrier so a D-to-D
#     reverse is always available and the carrier is never the last
#     man back. Mirrors SUPPORT's safety-valve role, on the weak side.
#
# Scoring (both): argmax over each role's candidate set of
#
#     lane_clear(carrier → c, pass_speed) × position_potential(c)
#
# - lane_clear is the reaction-window PASS model (same one the carrier
#   uses to decide the pass), so the outlet positions itself where the
#   carrier actually has a clean lane — the two agree on "threadable."
#   It also gates STRONG's stretch: a covered high-wall candidate scores
#   near the BLOCKED_LANE_FLOOR, so STRONG only advances as far as the
#   lane stays open (the floor keeps dead-lane candidates ranked by
#   potential instead of erased — see BLOCKED_LANE_FLOOR).
# - position_potential is the open-ice / forward-progress value of the
#   spot. Its `closeness` term ALREADY rewards up-ice progress (closer to
#   the attacking net), so among equally-open wall candidates the more
#   advanced one wins — no separate up-ice factor needed. It also doesn't
#   collapse to 0 deep in our zone (its ramp spans the whole rink),
#   unlike score_pass / score_shoot, so it gives a usable breakout
#   gradient where those return 0.
#
# The asymmetry lives in candidate generation: STRONG samples up the
# strong-side wall (free to advance); WEAK searches the weak side and is
# hard-constrained goal-side of the carrier. Search side comes from
# ctx.strong_x (the brain's hysteretic strong side) so it matches the
# slot assignment.

# Lateral inset from the boards for the strong-side wall, so candidates
# don't sit hard against the glass — but INSIDE the blade's receive reach
# of the rim line at the wall: the STRONG outlet is the designated rim
# receiver, and the old 2.0 m stance left the rim physically untouchable
# (body ~1.85 m off the inner wall vs a ~1.4 m comfortable blade span —
# every rim-around sailed past the post man). 1.2 m keeps a shoulder of
# air off the glass while the extended blade covers the boards line.
# WEAK's ring uses AIRoleHelpers' shared SEARCH_STEP_M via
# generate_candidates_around.
const WALL_INSET_M: float = 1.2

# STRONG wall sampling: how many points along the wall (carrier→blue line)
# and how far ahead of the carrier the NEAREST one sits. The samples span
# from STRONG_MIN_LEAD_M up-ice of the carrier to our blue line (the zone
# exit); position_potential + lane_clear pick the best of them.
const STRONG_WALL_SAMPLES: int = 5
const STRONG_MIN_LEAD_M: float = 3.0

# STRONG's second column: a mid-seam lane at this fraction of the wall
# offset (≈ the dot lane), same depth samples. One column pinned to the
# wall left the outlet with no move when the wall lane died — most
# visibly when the CARRIER wheels up the strong boards himself and the
# wall is his route, or when a forechecker camps the half-wall. With
# both columns the same lane × potential argmax picks the wall when the
# middle is contested (the classic breakout) and swings inside when the
# wall lane is occupied or covered.
#
# 5v5 (breakout plan §C.1): STRONG is a WALL POST — the researched winger
# holds the boards (the outlet that exists BECAUSE the wall is the one
# protected lane, and the rim's receiver), adjusting only along the wall,
# so the mid-seam column is generated ONLY when the carrier's own route
# occupies the wall lane (his wheel — the one case the post must yield).
# 3v3 keeps both columns (its rover outlet legitimately swings inside).
const MID_SEAM_FRACTION: float = 0.5
# "The carrier owns the wall lane": within the wall inset plus a body of
# the boards on the outlet's side.
const WALL_LANE_BAND_M: float = 3.0

# Floor on the lane term so dead pass lanes rank candidates instead of
# erasing them. lane_clear reads ~0 for EVERY candidate while a
# forechecker is draped on the carrier (a defender within a stick of the
# release blocks all lanes at the origin) or parked on the outlet's own
# route (closing reach over a long flight blankets the whole 3 m-spaced
# column) — with the old hard `lane <= 0 → skip`, all candidates
# vanished, best_pos fell back to self_pos, and the outlet froze in
# place ("the outlet is just stuck there"). The floor keeps
# position_potential's gradient alive so the route keeps developing;
# the moment any real lane opens (floor × potential « lane × potential)
# it dominates the argmax again.
const BLOCKED_LANE_FLOOR: float = 0.15

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

	var opp_positions: Array[Vector3] = ctx.scratch_opp_positions
	var opp_states: Array[SkaterNetworkState] = ctx.scratch_opp_states
	AIRoleHelpers.collect_opponents(ctx, opp_positions, opp_states)
	var teammate_positions: Array[Vector3] = ctx.scratch_teammates
	AIRoleHelpers.collect_teammates_excluding_self(ctx, teammate_positions)

	# Side this outlet works: strong outlet on the strong side, weak
	# outlet on the opposite side.
	var side_x: float = ctx.strong_x if is_strong else -ctx.strong_x

	var candidates: Array[Vector3]
	if is_strong:
		# Up the strong-side wall: carrier → our blue line.
		candidates = _strong_wall_candidates(ctx, carrier_pos, side_x)
	else:
		# Weak-side reverse valve: a ring around a point level with the
		# carrier on the weak wall.
		var search_center: Vector3 = _weak_search_center(carrier_pos, side_x)
		candidates = AIRoleHelpers.generate_candidates_around(ctx.self_pos, search_center)
	# Switch-hysteresis: hold the outlet spot unless a fresh one is clearly
	# better, so the cursor (which snaps to this target) stays steady.
	AIRoleHelpers.append_incumbent(ctx, candidates)

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
				carrier_pos, c, opp_positions, pass_speed,
				AIActionScoring.EMPTY_VEC3, ctx.scratch_opp_caps)
		var potential: float = AIActionScoring.position_potential(
				c, ctx.attacking_goal_pos, opp_positions, ctx.scratch_opp_caps)
		# Floored lane (see BLOCKED_LANE_FLOOR): dead lanes still rank by
		# potential so the outlet keeps skating its route instead of
		# freezing when the carrier is draped / the column is covered.
		var score: float = maxf(lane, BLOCKED_LANE_FLOOR) * potential \
				+ AIRoleHelpers.incumbent_bonus(ctx, c)
		if score > best_score:
			best_score = score
			best_pos = c

	d.target_position = best_pos
	return d


# STRONG candidate set: two columns of depth samples from just ahead of
# the carrier (STRONG_MIN_LEAD_M up-ice) to our blue line (the zone
# exit) — one on the strong-side wall (the role's classic station) and
# one at the mid-seam (MID_SEAM_FRACTION of the wall offset) — plus
# self_pos as a stand-still fallback. The lane × potential argmax picks
# the wall when the middle is contested and swings inside when the wall
# lane is the carrier's own route or covered by the forecheck, so the
# outlet is never pinned to a lane that's already dead.
static func _strong_wall_candidates(ctx: RoleContext, carrier_pos: Vector3,
		side_x: float) -> Array[Vector3]:
	var result: Array[Vector3] = []
	var wall_x: float = side_x * (GameRules.RINK_HALF_WIDTH - WALL_INSET_M)
	var mid_x: float = wall_x * MID_SEAM_FRACTION
	var own_dir: float = ctx.own_goal_dir
	# Depth = own_dir * z grows toward our net; up-ice is SMALLER depth.
	var carrier_depth: float = own_dir * carrier_pos.z
	var blue_depth: float = GameRules.BLUE_LINE_Z
	# Nearest sample sits a bit ahead of the carrier; farthest at the blue
	# line. maxf keeps the range non-inverted when the carrier is already
	# close to the line (then all samples collapse onto the blue line).
	var bottom_depth: float = maxf(carrier_depth - STRONG_MIN_LEAD_M, blue_depth)
	var top_depth: float = blue_depth
	# 5v5 wall post (see the MID_SEAM doc): the mid-seam column exists only
	# when the carrier's own route occupies the wall lane — otherwise the
	# winger holds the boards and adjusts along them.
	var carrier_on_wall: bool = signf(carrier_pos.x) == signf(side_x) \
			and GameRules.RINK_HALF_WIDTH - absf(carrier_pos.x) < WALL_LANE_BAND_M
	var wall_only: bool = ctx.team_size >= 5 and not carrier_on_wall
	for i: int in STRONG_WALL_SAMPLES:
		var t: float = 0.0
		if STRONG_WALL_SAMPLES > 1:
			t = float(i) / float(STRONG_WALL_SAMPLES - 1)
		var depth: float = lerpf(bottom_depth, top_depth, t)
		result.append(Vector3(wall_x, 0.0, own_dir * depth))
		if not wall_only:
			result.append(Vector3(mid_x, 0.0, own_dir * depth))
	result.append(ctx.self_pos)
	return result


# WEAK search center: weak-side wall, level with the carrier on the depth
# axis — the reverse-valve release point.
static func _weak_search_center(carrier_pos: Vector3, side_x: float) -> Vector3:
	var wall_x: float = side_x * (GameRules.RINK_HALF_WIDTH - WALL_INSET_M)
	return Vector3(wall_x, 0.0, carrier_pos.z)


# True if candidate `c` is goal-side of (or roughly even with) the
# carrier on the depth axis — no further up-ice than the carrier within
# GOAL_SIDE_TOLERANCE_M. own_goal_dir * z grows toward our net, so a
# larger value is "deeper / more goal-side." Mirrors AIRoleSupport.
static func _is_goal_side_of_carrier(c: Vector3, carrier_pos: Vector3,
		own_goal_dir: float) -> bool:
	return own_goal_dir * c.z >= own_goal_dir * carrier_pos.z - GOAL_SIDE_TOLERANCE_M

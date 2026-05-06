class_name AIActionScoring

# Pure-function utility scoring for on-puck actions. Each score is a
# multiplicative composition of factors in [0, 1].
#
# Two leaf scorers (score_shoot, score_pass) plus a recursive depth-2
# score_at(pos) defined in the SM. Top-level options compete uniformly:
#
#   shoot:  score_shoot(self_pos)
#   pass:   score_at(receiver_lead) × path_clearance × time_factor
#   carry:  score_at(candidate)     × path_clearance × time_factor
#
# score_at(pos) = max(score_shoot(pos), carry_to_slot_from_pos)
#
# No leaf-pass term inside score_at — at depth 2 we only consider the
# receiver's shot and their carry-to-slot. Stops the bot from
# evaluating chains of passes (which can run away into mutual
# back-and-forth pass loops) and bounds the recursion cleanly.
#
# No dump scoring — 3v3 doesn't reward dumps. No open-man / advance /
# receiver_pressure heuristics — the recursive score_at captures
# "what could the receiver do" with their actual options.

# An opponent within this distance counts toward "pressure" on a target.
# Tuning: raise toward 5 if bots feel oblivious to nearby defenders;
# lower toward 3 if pressure trips on too-distant marks.
const PRESSURE_RADIUS_M: float = 4.0
# How many opponents within radius == fully pressured (score multiplier 0).
# At 3 (default), three forward-cone opponents at full weight saturate
# pressure. Raise toward 4 to make pressure harder to saturate (less
# trigger-happy); lower toward 2 to pressure on a single defender.
const PRESSURE_MAX_COUNT: int = 3

# Beyond this range, shots score 0 from distance alone — keeps bots
# from launching pucks at the goalie from the blue line. Linear falloff:
# `1 - dist / SHOT_RANGE_FALLOFF_M`. Bumped from 18 → 22 to lift
# mid-range scores: the response at 10 m is 0.55 instead of 0.44, so
# clean mid-range shots score meaningfully and pass-to-receiver scores
# (which transitively include `score_shoot(receiver)`) are pulled up
# in the same band — passes to a teammate with a clear path to the
# net are now competitive with self-carry-to-slot. Raise toward 26
# if bots still refuse meaningful shots; lower toward 18 if blue-line
# shots are too common.
const SHOT_RANGE_FALLOFF_M: float = 22.0

# Shot-quality coverage knobs. The two-angle model:
#   coverage   = BASE_COVERAGE × squareness
#   squareness = max(0, 1 - arc_offset / SQUARENESS_OFFSET_RAD)
# where arc_offset is |puck_arc_angle - goalie_arc_angle| at shot
# release. A squared goalie blocks BASE_COVERAGE of the visible net;
# arc_offset >= SQUARENESS_OFFSET_RAD = goalie fully exposed (open
# net). Replaces the legacy shadow-projection openness + linear
# angle-ramp pair.
#
# Tuning: BASE_COVERAGE down (e.g., 0.30) → bots take more shots vs
# squared goalies; up (0.45) → bots pass/cycle more. SQUARENESS_OFFSET
# down (e.g., 25°) → cross-seam plays score higher (goalie reads as
# "exposed" sooner); up (40°) → only severe slides expose the goalie.
const BASE_COVERAGE: float = 0.35
const SQUARENESS_OFFSET_RAD: float = 0.5235988  # deg_to_rad(30)

# Goalie position prediction. Replaces velocity-extrapolation with a
# react-then-slide model: react delay first, then move toward the
# puck-at-release X at max lateral speed. Calibrate to match the
# goalie controller's actual movement (currently
# `goalie_controller.gd` STANDING/READY tracking).
const GOALIE_REACTION_DELAY_S: float = 0.15
const GOALIE_MAX_LATERAL_SPEED_MPS: float = 5.0

# Shadow half-width used by AIShotAim.compute_open_net_aim for the
# lane-check aim point. Independent of the new coverage model — it
# just picks an aim point past the goalie for the segment check.
const GOALIE_SHADOW_HALF_M: float = 0.3

# Lane-clear: an opponent within this perpendicular distance from the
# bot→receiver line segment fully blocks the pass. Score scales linearly
# with distance up to LANE_CLEAR_RADIUS_M (clear). Roughly the
# stick-blade reach of a lane defender. Raise toward 2.0 if passes
# still get picked off mid-lane; lower toward 1.0 if bots over-reject
# legitimate threading passes.
const LANE_CLEAR_RADIUS_M: float = 1.5

# Utility-AI knobs. _pick_action re-runs every physics tick and treats
# CARRY as a fourth competing option scored as
#
#   carry_score = score_at(destination) × discount(time_to_destination)
#
# CARRY_DELAY_DISCOUNT_PER_SEC — per-second decay applied to a future
# action's value. 0.7 / sec gives a ~2-second half-life. Reflects
# compounding uncertainty over time. Raise toward 0.85 to make bots
# more patient on long carries; lower toward 0.55 to commit to
# immediate actions over long-distance carries more aggressively.
#
# ACTION_HYSTERESIS_MARGIN — once a fire intent is set, that intent
# gets this bonus when re-scored. Prevents flicker between two
# close-scoring fire options during pre-aim. Only applies to fire
# intents (SHOOT, SLAPPER, PASS) — CARRY doesn't get a bonus, so the
# bot is free to switch to fire as soon as fire scores higher.
# Raise toward 0.10 if intent flickers visibly; lower toward 0.02 if
# intent feels too sticky.
const CARRY_DELAY_DISCOUNT_PER_SEC: float = 0.55
const ACTION_HYSTERESIS_MARGIN: float = 0.05


# Returns SHOOT score in [0, 1] using the two-angle coverage model:
#
#   shot_quality = dist_response × shot_angle_factor × (1 - coverage)
#   coverage     = BASE_COVERAGE × squareness
#   squareness   = max(0, 1 - arc_offset / SQUARENESS_OFFSET_RAD)
#
#   dist_response     = 1 - (dist / SHOT_RANGE_FALLOFF_M)²            (quadratic)
#   shot_angle_factor = 1 - shot_angle / (PI / 2)                      (linear)
#   puck_arc_angle    = atan2(shooter.x - goal.x, abs(shooter.z - goal.z))
#   goalie_arc_angle  = atan2(goalie_at_release.x - goal.x, ...)
#   arc_offset        = |puck_arc_angle - goalie_arc_angle|
#
# `predicted_goalie_pos` is the goalie's predicted position at shot
# release (use `predict_goalie_pos` to compute). The squareness term
# makes shots that catch the goalie sliding (cross-seam, late
# rotation) score above the BASE_COVERAGE penalty — automatic
# discount for "open net" plays without a separate heuristic.
#
# Final score also multiplies by lane clearance and inverse pressure
# (unchanged from prior implementation).
static func score_shoot(
		shooter: Vector3,
		attacking_goal: Vector3,
		predicted_goalie_pos: Vector3,
		net_half_width: float,
		opponents: Array[Vector3]) -> float:
	# Hard gate: shooter past (or on) the attacking goal line can't
	# shoot in — wraparound territory, returns 0 immediately.
	var net_normal_z: float = -signf(attacking_goal.z)
	var forward: float = (shooter.z - attacking_goal.z) * net_normal_z
	if forward < 0.001:
		return 0.0

	# Distance response — quadratic. Saturates near the net, so going
	# from 4 m → 2 m gains less than 12 m → 10 m. Combined with the
	# carry time-decay this naturally prevents the bot from driving
	# into the goalie at close range; fire wins the comparison once
	# the bot is in shooting range.
	var dist: float = shooter.distance_to(attacking_goal)
	var dist_norm: float = clampf(dist / SHOT_RANGE_FALLOFF_M, 0.0, 1.0)
	var dist_response: float = 1.0 - dist_norm * dist_norm

	# Puck arc angle: atan2 of lateral offset over forward distance.
	# Range [-PI/2, +PI/2] given the forward gate above.
	var puck_arc_angle: float = atan2(shooter.x - attacking_goal.x, forward)
	var shot_angle: float = absf(puck_arc_angle)
	var shot_angle_factor: float = clampf(1.0 - shot_angle / (PI * 0.5), 0.0, 1.0)

	# Goalie arc angle at release. If the goalie ended up behind their
	# own goal line (degenerate edge — shouldn't happen in normal play),
	# treat as squared at center.
	var goalie_forward: float = (predicted_goalie_pos.z - attacking_goal.z) * net_normal_z
	var goalie_arc_angle: float
	if goalie_forward < 0.001:
		goalie_arc_angle = 0.0
	else:
		goalie_arc_angle = atan2(predicted_goalie_pos.x - attacking_goal.x, goalie_forward)

	var arc_offset: float = absf(puck_arc_angle - goalie_arc_angle)
	var squareness: float = maxf(0.0, 1.0 - arc_offset / SQUARENESS_OFFSET_RAD)
	var coverage: float = BASE_COVERAGE * squareness
	var shot_quality: float = dist_response * shot_angle_factor * (1.0 - coverage)

	# Lane clear vs the actual aim point ShotAim would pick (past the
	# goalie's shadow). Identical to old code — the new coverage model
	# changes shot-quality, not aim direction.
	var aim: Vector3 = AIShotAim.compute_open_net_aim(
			shooter, predicted_goalie_pos, attacking_goal.z,
			net_half_width, GOALIE_SHADOW_HALF_M)
	var lane: float = _lane_clear(shooter, aim, opponents)

	# Directional pressure: only opponents in the forward cone toward
	# the attacking goal disrupt the shot. Behind/beside ones don't
	# really stop the release — the threat is bodies between us and
	# the net.
	var pressure_factor: float = 1.0 - _pressure(shooter, opponents, attacking_goal - shooter)

	return shot_quality * lane * pressure_factor


# Predicts the goalie's position at a future moment (shot release).
# React-then-slide model: a fixed reaction delay, then movement toward
# the ARC-MATCHING x at max lateral speed.
#
# Arc-matching: a properly squared goalie sits at the position whose
# arc angle from the goal matches the shooter's. Since the goalie sits
# much closer to the goal than the shooter, that's
#   arc_x = goalie_depth × (puck.x - goal.x) / puck_forward_from_goal
# An earlier version used puck.x directly as the slide target —
# geometrically wrong for off-axis shooters, and a source of bot-
# carry exploits because diagonal carry candidates appeared as "open
# net" plays even when a perfectly-tracking goalie would cover them.
#
# `goalie_now` is the goalie's current world position.
# `attacking_goal` is the goal the puck is aimed at; provides goal
# center and the sign for "forward."
# `release_time_s` is seconds from now until the shot fires.
# `puck_pos_at_release` is where the puck will be when fired (= the
# shooter's position for direct shots; receiver lead for passes;
# carry candidate for carry-then-shoot).
static func predict_goalie_pos(
		goalie_now: Vector3,
		attacking_goal: Vector3,
		release_time_s: float,
		puck_pos_at_release: Vector3) -> Vector3:
	var net_normal_z: float = -signf(attacking_goal.z)
	var puck_forward: float = (puck_pos_at_release.z - attacking_goal.z) * net_normal_z
	var goalie_depth: float = (goalie_now.z - attacking_goal.z) * net_normal_z
	var target_x: float
	if puck_forward < 0.001 or goalie_depth < 0.001:
		# Degenerate: puck on/behind goal line, or goalie there. Slide
		# toward puck.x as a best-effort fallback.
		target_x = puck_pos_at_release.x
	else:
		target_x = attacking_goal.x + goalie_depth * (puck_pos_at_release.x - attacking_goal.x) / puck_forward
	var move_time: float = maxf(0.0, release_time_s - GOALIE_REACTION_DELAY_S)
	var max_move: float = move_time * GOALIE_MAX_LATERAL_SPEED_MPS
	var dx: float = target_x - goalie_now.x
	var dist_to_target: float = absf(dx)
	if dist_to_target < 0.001 or max_move <= 0.0:
		return goalie_now
	if dist_to_target <= max_move:
		return Vector3(target_x, goalie_now.y, goalie_now.z)
	return Vector3(goalie_now.x + signf(dx) * max_move, goalie_now.y, goalie_now.z)


# Returns PASS score in [0, 1] for a specific receiver. Multiplicative:
#   - pass_lane:             1.0 if no opponent in the shooter→receiver line
#   - score_shoot(receiver): receiver's value as a shooter from where
#                            they are (geometry × shot lane × pressure).
#
# Receiver-quality terms (open-man, advancement) are gone — at top
# level the carrier evaluates each teammate via a recursive
# score_at(receiver) that captures "they could shoot or drive to
# slot." This leaf score_pass is what score_at falls back to for the
# shoot branch from a receiver position; it doesn't recurse further
# (no leaf-pass at depth 2) so the bot can't get into infinite
# pass-back-and-forth evaluation loops.
static func score_pass(
		shooter: Vector3,
		receiver: Vector3,
		attacking_goal: Vector3,
		predicted_goalie_pos: Vector3,
		net_half_width: float,
		opponents: Array[Vector3]) -> float:
	if _is_past_goal_line(receiver, attacking_goal):
		return 0.0
	if pass_lane_blocked_by_net(shooter, receiver):
		return 0.0
	var lane: float = _lane_clear(shooter, receiver, opponents)
	if lane <= 0.0:
		return 0.0
	# Receiver's value as a shooter from where they are. Caller is
	# responsible for predicting the goalie at the receiver's release
	# time (flight + receiver wrister charge) — see predict_goalie_pos.
	var receiver_shot: float = score_shoot(
			receiver, attacking_goal, predicted_goalie_pos, net_half_width, opponents)
	return lane * receiver_shot


# ── Helpers ──────────────────────────────────────────────────────────────────


# True if `pos` is past the attacking goal line in the direction the
# attacking team is going (i.e. "behind the net" relative to the
# shooter). For Team 0 attacking -Z (attacking_goal.z = -26.65),
# "past" means z < -26.65; for Team 1 attacking +Z, z > +26.65.
static func _is_past_goal_line(pos: Vector3, attacking_goal: Vector3) -> bool:
	return (pos.z - attacking_goal.z) * signf(attacking_goal.z) > 0.0


# Pressure score in [0, 1] for "do nearby opponents threaten this
# target." Wraps _opponent_density with the standard PRESSURE_* radii.
# All current callers (score_shoot, score_pass receiver) pass a
# forward direction so the cube falloff applies; the Vector3.ZERO
# default is kept as a safety fallback (omnidirectional, every
# opponent in radius weighted 1.0) but isn't currently used.
static func _pressure(target: Vector3, opponents: Array[Vector3],
		forward: Vector3 = Vector3.ZERO) -> float:
	return _opponent_density(target, opponents, forward, PRESSURE_RADIUS_M, PRESSURE_MAX_COUNT)


# Generic weighted opponent density. Counts opponents within `radius`
# of `target`, normalizing the count by `max_count` so the result
# lives in [0, 1]. Direction-weighted when `forward` is non-zero with
# a steep cube falloff: weight = max(0, dot)^3 where dot is the cosine
# of the angle from forward. Behind = 0, perpendicular = 0, 45° forward
# ≈ 0.35, 30° forward ≈ 0.65, dead front = 1.0. The cube falloff
# matches the hockey intuition that defenders behind or beside the play
# don't pressure the carrier — only opponents in the forward path do.
static func _opponent_density(target: Vector3, opponents: Array[Vector3],
		forward: Vector3, radius: float, max_count: int) -> float:
	var directional: bool = forward.length_squared() > 0.0001
	var fwd_x: float = 0.0
	var fwd_z: float = 0.0
	if directional:
		var fl: float = sqrt(forward.x * forward.x + forward.z * forward.z)
		if fl > 0.0001:
			fwd_x = forward.x / fl
			fwd_z = forward.z / fl
		else:
			directional = false
	var weighted: float = 0.0
	var r2: float = radius * radius
	for p: Vector3 in opponents:
		var dx: float = p.x - target.x
		var dz: float = p.z - target.z
		var d2: float = dx * dx + dz * dz
		if d2 >= r2:
			continue
		if directional:
			var d: float = sqrt(d2)
			var dot: float = 0.0 if d < 0.0001 else (dx * fwd_x + dz * fwd_z) / d
			var clamped: float = maxf(0.0, dot)
			weighted += clamped * clamped * clamped
		else:
			weighted += 1.0
	return clampf(weighted / float(max_count), 0.0, 1.0)


# Lane-clear factor in [0, 1]. 1.0 = no opponent within
# LANE_CLEAR_RADIUS_M of the bot→receiver segment; 0.0 = opponent right
# on the line. Concave (sqrt) ramp between — defenders within reach
# of the line still hurt the score, but moderate-distance defenders
# don't crush it. Linear was too harsh: a defender 0.5 m off the
# 1.5 m radius dropped lane to 0.33 (× shot/pass score), killing
# otherwise-good shots through partial traffic. Sqrt: same defender
# yields lane = 0.58. Real shots through traffic find the net more
# often than a third of the time.
#
# Only counts opponents whose projection onto the segment falls between
# the endpoints (t ∈ [0, 1]) — opponents behind the shooter or past the
# receiver don't block the lane.
static func _lane_clear(from: Vector3, to: Vector3, opponents: Array[Vector3]) -> float:
	var dx: float = to.x - from.x
	var dz: float = to.z - from.z
	var line_len_sq: float = dx * dx + dz * dz
	if line_len_sq < 0.01:
		return 1.0  # degenerate (overlapping endpoints)
	var min_perp_sq: float = INF
	for p: Vector3 in opponents:
		var pdx: float = p.x - from.x
		var pdz: float = p.z - from.z
		var t: float = (pdx * dx + pdz * dz) / line_len_sq
		if t <= 0.0 or t >= 1.0:
			continue
		var closest_x: float = from.x + t * dx
		var closest_z: float = from.z + t * dz
		var perp_x: float = p.x - closest_x
		var perp_z: float = p.z - closest_z
		var perp_sq: float = perp_x * perp_x + perp_z * perp_z
		if perp_sq < min_perp_sq:
			min_perp_sq = perp_sq
	if min_perp_sq == INF:
		return 1.0
	var perp: float = sqrt(min_perp_sq)
	return clampf(sqrt(perp / LANE_CLEAR_RADIUS_M), 0.0, 1.0)


# Public lane-clearance check — returns 1.0 if the path from `from`
# to `to` is clear, 0.0 if an opponent is sitting on the line, and a
# linear ramp between based on perpendicular distance up to
# LANE_CLEAR_RADIUS_M. Used by carry-candidate scoring to penalize
# destinations the bot can't reach without going around a defender.
# Caller should project opponents forward by the candidate's expected
# arrival time so the check reflects where defenders WILL BE when
# the bot gets there, not where they are now (same approach as
# pass-lane scoring with flight-time projection).
static func path_clearance(from: Vector3, to: Vector3,
		projected_opponents: Array[Vector3]) -> float:
	return _lane_clear(from, to, projected_opponents)


# True iff the segment from `from` to `to` (in world XZ) intersects
# either net's footprint. Each net is the rectangle x ∈ ±NET_HALF_WIDTH,
# z ∈ [GOAL_LINE_Z, GOAL_LINE_Z + NET_DEPTH] — the goal mouth out to
# the back frame, mirrored for the other team. Used by score_pass to
# treat the net as a hard pass-lane obstruction so corner-to-corner
# OZ passes don't sail through the back of the cage and DZ passes
# don't cross the goal mouth.
static func pass_lane_blocked_by_net(from: Vector3, to: Vector3) -> bool:
	var goal_line_z: float = GameRules.GOAL_LINE_Z
	var net_half_w: float = GameRules.NET_HALF_WIDTH
	var net_depth: float = GameRules.NET_DEPTH
	# Team 0's net (positive z) spans z ∈ [goal_line_z, goal_line_z + net_depth].
	if _segment_crosses_aabb_xz(
			from.x, from.z, to.x, to.z,
			-net_half_w, net_half_w,
			goal_line_z, goal_line_z + net_depth):
		return true
	# Team 1's net (negative z) spans z ∈ [-(goal_line_z + net_depth), -goal_line_z].
	if _segment_crosses_aabb_xz(
			from.x, from.z, to.x, to.z,
			-net_half_w, net_half_w,
			-(goal_line_z + net_depth), -goal_line_z):
		return true
	return false


# Own-DZ slot danger zone. True iff the pass segment crosses the
# rectangle in front of OUR net — the high-danger area where a
# deflected/intercepted pass becomes a goal against. Asymmetric to
# `pass_lane_blocked_by_net` because passes through OPP slot are
# legitimate (backdoor / cross-crease feeds); only OWN slot is risky.
#
# Slot rect: x ∈ ±OWN_DZ_SLOT_HALF_WIDTH_M, z ∈ [own_goal_line - depth,
# own_goal_line] for own_goal_z > 0; mirrored for own_goal_z < 0.
const OWN_DZ_SLOT_HALF_WIDTH_M: float = 2.0
const OWN_DZ_SLOT_DEPTH_M: float = 5.0
static func pass_crosses_own_slot(from: Vector3, to: Vector3, own_goal_z: float) -> bool:
	var depth: float = OWN_DZ_SLOT_DEPTH_M
	var half_w: float = OWN_DZ_SLOT_HALF_WIDTH_M
	if own_goal_z > 0.0:
		# Team 0: own net at +z. Slot is in front of goal line,
		# z ∈ [own_goal_z - depth, own_goal_z].
		return _segment_crosses_aabb_xz(
				from.x, from.z, to.x, to.z,
				-half_w, half_w,
				own_goal_z - depth, own_goal_z)
	else:
		# Team 1: own net at -z. Slot z ∈ [own_goal_z, own_goal_z + depth].
		return _segment_crosses_aabb_xz(
				from.x, from.z, to.x, to.z,
				-half_w, half_w,
				own_goal_z, own_goal_z + depth)


# Liang-Barsky parametric clipping: returns true iff the segment from
# (fx, fz) to (tx, tz) intersects the axis-aligned rectangle bounded
# by [x_min, x_max] × [z_min, z_max]. Endpoint inside the rect counts
# as intersection.
static func _segment_crosses_aabb_xz(
		fx: float, fz: float, tx: float, tz: float,
		x_min: float, x_max: float, z_min: float, z_max: float) -> bool:
	var dx: float = tx - fx
	var dz: float = tz - fz
	var t_min: float = 0.0
	var t_max: float = 1.0
	# X slab.
	if absf(dx) < 0.0001:
		if fx < x_min or fx > x_max:
			return false
	else:
		var t1: float = (x_min - fx) / dx
		var t2: float = (x_max - fx) / dx
		if t1 > t2:
			var tmp: float = t1
			t1 = t2
			t2 = tmp
		t_min = maxf(t_min, t1)
		t_max = minf(t_max, t2)
		if t_min > t_max:
			return false
	# Z slab.
	if absf(dz) < 0.0001:
		if fz < z_min or fz > z_max:
			return false
	else:
		var t1: float = (z_min - fz) / dz
		var t2: float = (z_max - fz) / dz
		if t1 > t2:
			var tmp: float = t1
			t1 = t2
			t2 = tmp
		t_min = maxf(t_min, t1)
		t_max = minf(t_max, t2)
		if t_min > t_max:
			return false
	return true

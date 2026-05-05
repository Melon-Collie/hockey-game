class_name AIActionScoring

# Pure-function utility scoring for on-puck actions. Each score is a
# multiplicative composition of factors in [0, 1]; the SM picks the
# highest-scoring action and falls back to CARRY when none clears the
# action threshold.
#
# Phase 5d shipped baseline SHOOT and PASS scoring. Phase 5e refactors
# PASS to value the receiver's potential shot quality (so a teammate
# at the same depth but with a wider-open net is a valid pass target —
# fixes the "bots never pass side-to-side" problem) and gates passes
# on a clear lane between shooter and receiver.

# An opponent within this distance counts toward "pressure" on a target.
# Tuning: raise toward 5 if bots feel oblivious to nearby defenders;
# lower toward 3 if pressure trips on too-distant marks.
const PRESSURE_RADIUS_M: float = 4.0
# How many opponents within radius == fully pressured (score multiplier 0).
# At 3 (default), three forward-cone opponents at full weight saturate
# pressure. Raise toward 4 to make pressure harder to saturate (less
# trigger-happy); lower toward 2 to pressure on a single defender.
const PRESSURE_MAX_COUNT: int = 3

# Beyond this range, shots score 0 from distance alone — keeps bots from
# launching pucks at the goalie from the blue line. Raise toward 22 if
# bots refuse to take long shots even when wide open; lower toward 14
# if blue-line shots are too common.
const SHOT_RANGE_FALLOFF_M: float = 18.0

# Shooting-angle cone, measured from the net's outward normal (the
# direction the net opens toward center ice). Inside SHOT_ANGLE_FULL_DEG
# the score is unaffected; at SHOT_ANGLE_ZERO_DEG and beyond it's
# completely zeroed. Two purposes:
#   1. Block shots from BEHIND the goal line — past 90° the math
#      automatically zeroes, so we don't need a separate hard gate.
#   2. Penalize extreme-angle shots where the visible net is a sliver.
#      _net_openness measures goalie shadow coverage in 2D and treats
#      a shadow projecting off the net plane as fully open net — but
#      from a 75° angle the actual visible net is narrow regardless
#      of where the shadow lands.
# Tuning: widen FULL→60° / ZERO→90° if bots over-pass on legitimate
# off-angle shots; tighten FULL→40° / ZERO→70° if bad-angle shots are
# too common.
const SHOT_ANGLE_FULL_DEG: float = 50.0
const SHOT_ANGLE_ZERO_DEG: float = 80.0

# Lane-clear: an opponent within this perpendicular distance from the
# bot→receiver line segment fully blocks the pass. Score scales linearly
# with distance up to LANE_CLEAR_RADIUS_M (clear). Roughly the
# stick-blade reach of a lane defender. Raise toward 2.0 if passes
# still get picked off mid-lane; lower toward 1.0 if bots over-reject
# legitimate threading passes.
const LANE_CLEAR_RADIUS_M: float = 1.5

# Outlet pass scoring — when a receiver is "more advanced" toward the
# attacking goal but too far to shoot themselves. Receiver must be at
# least PASS_MIN_ADVANCE_M closer to goal to score above 0; saturates
# at PASS_MAX_ADVANCE_M. Tuning: raise MIN if bots over-pass for tiny
# advancement gains; raise MAX if long stretch passes feel under-valued.
const PASS_MIN_ADVANCE_M: float = 3.0
const PASS_MAX_ADVANCE_M: float = 12.0

# Open-man pass: a teammate with no defender close in front of them is
# a valid pass target even if they don't have a shot or aren't more
# advanced. Possession-keeping pass.
#
# OPEN_MAN_RADIUS_M is the threat radius — opponents past this don't
# count regardless of direction. OPEN_MAN_MAX_SCORE caps the receiver-
# quality contribution so a wide-open teammate doesn't drown out a
# shot or genuine outlet pass when those are available; it does clear
# ACTION_THRESHOLD (0.25) on its own when the lane and pressure terms
# cooperate. Tuning: raise OPEN_MAN_MAX_SCORE toward 0.5 to make bots
# pass-happy on possession; lower toward 0.3 if they pass too often
# instead of carrying.
const OPEN_MAN_RADIUS_M: float = 3.0
const OPEN_MAN_MAX_SCORE: float = 0.4

# Score threshold below which the SM stays in CARRY rather than
# committing to a SHOOT or PASS. Tunes how aggressive bots are.
# Bumped from 0.25 → 0.35 once carrier drift was scoring candidates
# by future action quality (commit 9036a00) — the carrier is now
# strong enough at finding open ice that low-confidence shots and
# pass-to-support outlets shouldn't preempt it. Raise toward 0.45
# if bots still commit to bad reads; lower toward 0.25 if they
# refuse legitimate close-range shots.
const ACTION_THRESHOLD: float = 0.35

# DUMP zone factors. Lower in own zone than you might expect — 3v3
# arcade hockey rewards breakouts more than safe clears, so bots try
# pass/carry out first and only dump under heavy directional pressure.
# Neutral-zone dump (e.g. carrying into a wall of defenders past the
# red line) is the most natural use case. Never from OZ.
# Tuning: raise DUMP_OWN_ZONE_FACTOR toward 0.6 if bots refuse to
# clear under heavy DZ pressure; raise DUMP_NEUTRAL_ZONE_FACTOR toward
# 0.85 if they should be more willing to dump in (less common in 3v3).
const DUMP_OWN_ZONE_FACTOR: float = 0.4
const DUMP_NEUTRAL_ZONE_FACTOR: float = 0.7
const DUMP_OFFENSIVE_ZONE_FACTOR: float = 0.0

# NZ-specific clear-path suppression. In 3v3 the carrier should drive
# into the OZ rather than dump whenever there's open ice ahead —
# controlled entries beat dumps in this format. When has_clear_forward_path
# returns true, the NZ dump score is multiplied by this factor, dropping
# 0.7 × 1.0 (full pressure) to 0.21 — below ACTION_THRESHOLD (0.25), so
# DUMP loses to CARRY. Only triggers in NZ — DZ and OZ already handle
# correctly without this branch. Tuning: raise RADIUS toward 5 for a
# stricter "must have a real wall" rule; lower SUPPRESSION toward 0.1
# to harder-suppress NZ dumps with any open ice.
const NZ_DUMP_CLEAR_PATH_RADIUS_M: float = 3.0
const NZ_DUMP_CLEAR_PATH_SUPPRESSION: float = 0.3

# Backward-pass suppression. When the carrier has a clear forward
# path toward the attacking goal (no opponents within
# BACKWARD_PASS_FORWARD_PATH_RADIUS_M in the forward half-plane), a
# pass whose receiver lies BEHIND the carrier (relative to the
# attacking goal) is multiplied by BACKWARD_PASS_SUPPRESSION. Stops
# bots from immediately passing back to a defender when there's
# open ice to skate into. Forward path occluded → backward passes
# remain a legitimate outlet (cycle / regroup).
const BACKWARD_PASS_FORWARD_PATH_RADIUS_M: float = 6.0
const BACKWARD_PASS_SUPPRESSION: float = 0.3


# Returns SHOOT score in [0, 1]. Multiplicative product of:
#   - shot_geometry: net openness × distance response (see _shot_geometry)
#   - lane_clear:    no opponent in the shooter→aim line segment
#   - 1 - pressure:  inverse of opponent proximity around the shooter
#
# The lane check uses the same aim point ShotAim picks for the actual
# shot, so the score reflects the shot the bot would actually fire —
# not just the goalie's shadow.
static func score_shoot(
		shooter: Vector3,
		attacking_goal: Vector3,
		goalie_pos: Vector3,
		net_half_width: float,
		shadow_half: float,
		opponents: Array[Vector3]) -> float:
	# Hard gate: shooter past the attacking goal line can't shoot in —
	# wraparound territory, doesn't make sense as a SHOOT score.
	if _is_past_goal_line(shooter, attacking_goal):
		return 0.0
	var geom: float = _shot_geometry(shooter, attacking_goal, goalie_pos, net_half_width, shadow_half)
	var aim: Vector3 = AIShotAim.compute_open_net_aim(
			shooter, goalie_pos, attacking_goal.z, net_half_width, shadow_half)
	var lane: float = _lane_clear(shooter, aim, opponents)
	# Directional pressure: only opponents in the forward cone toward
	# the attacking goal disrupt the shot. A defender behind the
	# shooter or directly beside them can't really stop the release —
	# the threat is bodies between us and the net.
	var pressure_factor: float = 1.0 - _pressure(shooter, opponents, attacking_goal - shooter)
	return geom * lane * pressure_factor


# Returns PASS score in [0, 1] for a specific receiver. Multiplicative:
#   - lane_clear:           1.0 if no opponent in the bot→receiver line
#   - receiver_quality:     max of (a) receiver's potential shot score
#                           and (b) advancement bonus — covers both
#                           "tape-to-tape into the slot" and "outlet
#                           pass to a teammate up-ice"
#   - 1 - receiver_pressure: how open the receiver is to catch
#
# `receiver_quality_bonus` (default 1.0) multiplies receiver_quality
# BEFORE the [0, 1] clamp. Used by the carrier to value a slapper-
# charging teammate's shot opportunity higher without short-circuiting
# the lane / pressure terms — a slapper-charging receiver behind a
# blocked lane is still a 0-score pass.
static func score_pass(
		shooter: Vector3,
		receiver: Vector3,
		receiver_facing: Vector2,
		attacking_goal: Vector3,
		goalie_pos: Vector3,
		net_half_width: float,
		shadow_half: float,
		opponents: Array[Vector3],
		receiver_quality_bonus: float = 1.0) -> float:
	# A receiver past the attacking goal line is degenerate (can't shoot,
	# wraparound passes are weird). Skip.
	if _is_past_goal_line(receiver, attacking_goal):
		return 0.0
	# Either net counts as a pass-lane obstruction. Catches the OZ
	# corner-to-corner pass that sails through the back of the net
	# (puck deflects off the netting and the bots loop), and any
	# DZ pass that crosses the goal mouth.
	if pass_lane_blocked_by_net(shooter, receiver):
		return 0.0
	var lane: float = _lane_clear(shooter, receiver, opponents)
	if lane <= 0.0:
		return 0.0
	# Receiver quality: take the max of three terms.
	# - shot quality: receiver has a real shot from where they are.
	# - advancement: outlet to a teammate further up-ice.
	# - open-man: receiver isn't being pressured from in front, so
	#   this is a possession-keeping pass even with no shot or outlet
	#   advantage. Capped low so it loses to genuine shot/outlet
	#   targets when they exist.
	var receiver_geom: float = _shot_geometry(receiver, attacking_goal, goalie_pos, net_half_width, shadow_half)
	var advance: float = _advancement_score(shooter, receiver, attacking_goal)
	var open: float = _receiver_open_score(receiver, receiver_facing, opponents)
	var receiver_quality: float = clampf(
			maxf(maxf(receiver_geom, advance), open) * receiver_quality_bonus,
			0.0, 1.0)
	# Directional pressure on the receiver — opponents in the receiver's
	# forward cone toward the attacking goal are the ones who'll
	# pressure them on reception. Defenders behind the receiver (between
	# them and our own net) aren't realistic interception threats; the
	# shooter→receiver lane block is already handled separately by
	# `_lane_clear`.
	var pressure_factor: float = 1.0 - _pressure(receiver, opponents, attacking_goal - receiver)
	return lane * receiver_quality * pressure_factor


# Returns DUMP score in [0, 1]. Bots dump when pressured and far from
# the attacking goal — clear the zone, force the opponent to chase.
# Multiplicative:
#   - zone_factor: 1.0 in own zone, 0.7 in neutral zone, 0.0 in OZ
#                  (no dumping from offensive zone — try to keep possession)
#   - pressure:    fraction of PRESSURE_MAX_COUNT opponents around us
#
# Note that score_dump deliberately does NOT subtract score_shoot or
# score_pass; the SM picks the max and CARRY is the fallback. If the
# bot has both a high shot and high dump score in the slot under
# pressure, the shot wins because SHOOT score multiplies in the
# distance response (high in slot) while DUMP zone_factor is 0 there.
static func score_dump(
		shooter: Vector3,
		attacking_goal: Vector3,
		own_goal_dir: float,
		blue_line_z: float,
		opponents: Array[Vector3]) -> float:
	var zone_factor: float = _dump_zone_factor(shooter.z, own_goal_dir, blue_line_z)
	if zone_factor <= 0.0:
		return 0.0
	# Directional pressure — a chaser 3m behind the carrier doesn't
	# justify a dump if the ice ahead is open. We're trying to score
	# "can I get forward" not "is anyone close." Forward = toward the
	# attacking goal.
	var forward: Vector3 = attacking_goal - shooter
	var pressure_factor: float = _pressure(shooter, opponents, forward)
	# NZ clear-path override: in the neutral zone with open ice ahead,
	# the carrier should drive in rather than dump. The pressure term
	# alone isn't enough — its 4 m omnidirectional radius can still tag
	# off-axis defenders and lift NZ dump score above threshold even
	# when the forward lane is wide open.
	if zone_factor == DUMP_NEUTRAL_ZONE_FACTOR \
			and has_clear_forward_path(shooter, attacking_goal, opponents,
					NZ_DUMP_CLEAR_PATH_RADIUS_M):
		return zone_factor * NZ_DUMP_CLEAR_PATH_SUPPRESSION * pressure_factor
	return zone_factor * pressure_factor


# Returns the best of (SHOOT score from `pos`, max PASS score from `pos`
# to any teammate). Used by the carrier's anchor search — the carrier
# tries candidate positions around themselves and picks the one where
# they'd have the best option (a shot or a feed). Drives "patient"
# behavior: bot doesn't park at a fixed high slot, it moves toward
# wherever the open option is.
#
# Note this differs from each individual score function only in that
# we delegate to score_shoot / score_pass — the inputs are the same.
# The wrapper exists so the SM doesn't have to duplicate the for-loop
# over teammates inside its own search code.
static func carry_position_score(
		pos: Vector3,
		attacking_goal: Vector3,
		goalie_pos: Vector3,
		net_half_width: float,
		shadow_half: float,
		teammate_positions: Array[Vector3],
		teammate_facings: Array[Vector2],
		opponents: Array[Vector3]) -> float:
	var best: float = score_shoot(pos, attacking_goal, goalie_pos, net_half_width, shadow_half, opponents)
	for i: int in teammate_positions.size():
		var facing: Vector2 = teammate_facings[i] if i < teammate_facings.size() else Vector2.ZERO
		var s: float = score_pass(pos, teammate_positions[i], facing,
				attacking_goal, goalie_pos, net_half_width, shadow_half, opponents)
		if s > best:
			best = s
	return best


# ── Helpers ──────────────────────────────────────────────────────────────────


# Maps the shooter's z to a zone-specific dump factor.
#   own zone:      own_goal_dir * z >  +blue_line_z
#   offensive zone:own_goal_dir * z <  -blue_line_z
#   neutral zone:  in between
static func _dump_zone_factor(self_z: float, own_goal_dir: float, blue_line_z: float) -> float:
	var oriented_z: float = own_goal_dir * self_z
	if oriented_z > blue_line_z:
		return DUMP_OWN_ZONE_FACTOR
	if oriented_z < -blue_line_z:
		return DUMP_OFFENSIVE_ZONE_FACTOR
	return DUMP_NEUTRAL_ZONE_FACTOR

# Geometric shot quality from a position: openness × distance response.
# Used by both SHOOT (shooter geometry) and PASS (receiver geometry).
static func _shot_geometry(
		from: Vector3,
		attacking_goal: Vector3,
		goalie_pos: Vector3,
		net_half_width: float,
		shadow_half: float) -> float:
	var openness: float = _net_openness(from, attacking_goal.z, goalie_pos, net_half_width, shadow_half)
	var dist: float = from.distance_to(attacking_goal)
	var dist_response: float = clampf(1.0 - dist / SHOT_RANGE_FALLOFF_M, 0.0, 1.0)
	var angle: float = _shooting_angle_factor(from, attacking_goal)
	return openness * dist_response * angle


# Returns [0, 1] based on the angle from the net's outward normal to
# the shooter. 0 = directly in front, 90+ = beside or behind the net.
# Linearly ramps from 1.0 at SHOT_ANGLE_FULL_DEG to 0 at
# SHOT_ANGLE_ZERO_DEG; zero past that. Behind-the-goal-line shots
# automatically zero (forward distance is negative → angle > 90°).
static func _shooting_angle_factor(shooter: Vector3, attacking_goal: Vector3) -> float:
	# Net normal points from the goal toward center ice. attacking_goal.z
	# is signed (Team 0 attacks -Z so attacking_goal.z = -GOAL_LINE_Z;
	# net opens toward +Z). The net normal Z-component is the negation
	# of the attacking_goal.z sign.
	var net_normal_z: float = -signf(attacking_goal.z)
	var forward: float = (shooter.z - attacking_goal.z) * net_normal_z
	var lateral: float = absf(shooter.x - attacking_goal.x)
	var angle_deg: float = rad_to_deg(atan2(lateral, forward))
	if angle_deg <= SHOT_ANGLE_FULL_DEG:
		return 1.0
	if angle_deg >= SHOT_ANGLE_ZERO_DEG:
		return 0.0
	return (SHOT_ANGLE_ZERO_DEG - angle_deg) / (SHOT_ANGLE_ZERO_DEG - SHOT_ANGLE_FULL_DEG)


# Fraction of the net not covered by the goalie's projected shadow. 1.0
# = fully open net. Mirrors the geometry in AIShotAim but returns area
# coverage instead of an aim point.
static func _net_openness(
		shooter: Vector3,
		net_z: float,
		goalie: Vector3,
		net_half_width: float,
		shadow_half: float) -> float:
	var dz: float = goalie.z - shooter.z
	var to_net_z: float = net_z - shooter.z
	if absf(dz) < 0.001 or signf(dz) != signf(to_net_z):
		return 1.0
	var t: float = to_net_z / dz
	var shadow_x: float = shooter.x + t * (goalie.x - shooter.x)
	var sl: float = clampf(shadow_x - shadow_half, -net_half_width, net_half_width)
	var sr: float = clampf(shadow_x + shadow_half, -net_half_width, net_half_width)
	var covered: float = maxf(0.0, sr - sl)
	var net_width: float = net_half_width * 2.0
	return clampf((net_width - covered) / net_width, 0.0, 1.0)


# Advancement bonus in [0, 1] for outlet-style passes. Receiver must be
# at least PASS_MIN_ADVANCE_M closer to the attacking goal than the
# shooter; saturates at PASS_MAX_ADVANCE_M.
static func _advancement_score(shooter: Vector3, receiver: Vector3, attacking_goal: Vector3) -> float:
	var my_dist: float = shooter.distance_to(attacking_goal)
	var their_dist: float = receiver.distance_to(attacking_goal)
	var advance: float = my_dist - their_dist
	if advance < PASS_MIN_ADVANCE_M:
		return 0.0
	var span: float = PASS_MAX_ADVANCE_M - PASS_MIN_ADVANCE_M
	return clampf((advance - PASS_MIN_ADVANCE_M) / span, 0.0, 1.0)


# True if `pos` is past the attacking goal line in the direction the
# attacking team is going (i.e. "behind the net" relative to the
# shooter). For Team 0 attacking -Z (attacking_goal.z = -26.65),
# "past" means z < -26.65; for Team 1 attacking +Z, z > +26.65.
static func _is_past_goal_line(pos: Vector3, attacking_goal: Vector3) -> bool:
	return (pos.z - attacking_goal.z) * signf(attacking_goal.z) > 0.0


# Open-man receiver score. Wraps the same opponent-density helper as
# _pressure but with a tighter radius (3 m, "in your kitchen") and a
# directional weighting against the receiver's facing — a forechecker
# in front is a real threat; a backchecker behind can't disrupt the
# reception. Capped at OPEN_MAN_MAX_SCORE so a wide-open teammate
# competes with shot/outlet quality but doesn't drown them out.
#
# receiver_facing is Vector2 packing world XZ (matches
# SkaterNetworkState.facing). Zero-magnitude facing falls through to
# max score (no orientation data → assume open).
static func _receiver_open_score(
		receiver: Vector3,
		receiver_facing: Vector2,
		opponents: Array[Vector3]) -> float:
	var forward: Vector3 = Vector3(receiver_facing.x, 0.0, receiver_facing.y)
	if forward.length_squared() < 0.0001:
		return OPEN_MAN_MAX_SCORE
	var density: float = _opponent_density(receiver, opponents, forward, OPEN_MAN_RADIUS_M, 1)
	return OPEN_MAN_MAX_SCORE * (1.0 - density)


# Pressure score in [0, 1] for "do nearby opponents threaten this
# target." Wraps _opponent_density with the standard PRESSURE_* radii.
# All current callers (score_shoot, score_pass receiver, score_dump)
# pass a forward direction so the cube falloff applies; the
# Vector3.ZERO default is kept as a safety fallback (omnidirectional,
# every opponent in radius weighted 1.0) but isn't currently used.
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


# True iff there is no opponent within `radius` of `from` whose
# position projects forward of `from` along the from→toward axis.
# Used by score_dump's NZ override to detect "open ice ahead." Tighter
# than the omnidirectional pressure check — we only care about
# defenders we'd have to skate through, not ones to the sides or
# behind.
static func has_clear_forward_path(from: Vector3, toward: Vector3,
		opponents: Array[Vector3], radius: float) -> bool:
	var fwd_x: float = toward.x - from.x
	var fwd_z: float = toward.z - from.z
	var fl: float = sqrt(fwd_x * fwd_x + fwd_z * fwd_z)
	if fl < 0.001:
		return true
	var inv_fl: float = 1.0 / fl
	fwd_x *= inv_fl
	fwd_z *= inv_fl
	var r2: float = radius * radius
	for op: Vector3 in opponents:
		var dx: float = op.x - from.x
		var dz: float = op.z - from.z
		var d2: float = dx * dx + dz * dz
		if d2 >= r2:
			continue
		# Anything strictly forward of the carrier counts as in the way.
		if dx * fwd_x + dz * fwd_z > 0.0:
			return false
	return true


# Lane-clear factor in [0, 1]. 1.0 = no opponent within
# LANE_CLEAR_RADIUS_M of the bot→receiver segment; 0.0 = opponent right
# on the line. Smooth linear ramp between.
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
	return clampf(perp / LANE_CLEAR_RADIUS_M, 0.0, 1.0)


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

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
const PRESSURE_RADIUS_M: float = 4.0
# How many opponents within radius == fully pressured (score multiplier 0).
const PRESSURE_MAX_COUNT: int = 3

# Beyond this range, shots score 0 from distance alone — keeps bots from
# launching pucks at the goalie from the blue line.
const SHOT_RANGE_FALLOFF_M: float = 18.0

# Lane-clear: an opponent within this perpendicular distance from the
# bot→receiver line segment fully blocks the pass. Score scales linearly
# with distance up to LANE_CLEAR_RADIUS_M (clear).
const LANE_CLEAR_RADIUS_M: float = 1.5

# Outlet pass scoring — when a receiver is "more advanced" toward the
# attacking goal but too far to shoot themselves. Receiver must be at
# least PASS_MIN_ADVANCE_M closer to goal to score above 0; saturates
# at PASS_MAX_ADVANCE_M.
const PASS_MIN_ADVANCE_M: float = 3.0
const PASS_MAX_ADVANCE_M: float = 12.0

# Score threshold below which the SM stays in CARRY rather than committing
# to a SHOOT or PASS. Tunes how aggressive bots are.
const ACTION_THRESHOLD: float = 0.25


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
	var pressure_factor: float = 1.0 - _pressure(shooter, opponents)
	return geom * lane * pressure_factor


# Returns PASS score in [0, 1] for a specific receiver. Multiplicative:
#   - lane_clear:           1.0 if no opponent in the bot→receiver line
#   - receiver_quality:     max of (a) receiver's potential shot score
#                           and (b) advancement bonus — covers both
#                           "tape-to-tape into the slot" and "outlet
#                           pass to a teammate up-ice"
#   - 1 - receiver_pressure: how open the receiver is to catch
static func score_pass(
		shooter: Vector3,
		receiver: Vector3,
		attacking_goal: Vector3,
		goalie_pos: Vector3,
		net_half_width: float,
		shadow_half: float,
		opponents: Array[Vector3]) -> float:
	# A receiver past the attacking goal line is degenerate (can't shoot,
	# wraparound passes are weird). Skip.
	if _is_past_goal_line(receiver, attacking_goal):
		return 0.0
	var lane: float = _lane_clear(shooter, receiver, opponents)
	if lane <= 0.0:
		return 0.0
	# Receiver quality: take the max of "they have a shot from there" and
	# "this pass moves the puck meaningfully closer to the attacking
	# goal." The shot-quality term handles cross-slot / lateral passes
	# (a teammate at the same depth with a wider-open net beats a
	# covered shooter); the advancement term handles outlet passes
	# (DZ → NZ teammate that's too far to shoot but is nicely positioned
	# to skate up-ice).
	var receiver_geom: float = _shot_geometry(receiver, attacking_goal, goalie_pos, net_half_width, shadow_half)
	var advance: float = _advancement_score(shooter, receiver, attacking_goal)
	var receiver_quality: float = maxf(receiver_geom, advance)
	var pressure_factor: float = 1.0 - _pressure(receiver, opponents)
	return lane * receiver_quality * pressure_factor


# ── Helpers ──────────────────────────────────────────────────────────────────

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
	return openness * dist_response


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


# Pressure score in [0, 1] — fraction of PRESSURE_MAX_COUNT opponents
# within PRESSURE_RADIUS_M of `target`.
static func _pressure(target: Vector3, opponents: Array[Vector3]) -> float:
	var n: int = 0
	var r2: float = PRESSURE_RADIUS_M * PRESSURE_RADIUS_M
	for p: Vector3 in opponents:
		var dx: float = p.x - target.x
		var dz: float = p.z - target.z
		if dx * dx + dz * dz < r2:
			n += 1
	return clampf(float(n) / float(PRESSURE_MAX_COUNT), 0.0, 1.0)


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

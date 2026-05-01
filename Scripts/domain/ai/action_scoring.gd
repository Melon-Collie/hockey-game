class_name AIActionScoring

# Pure-function utility scoring for on-puck actions. Each score is a
# multiplicative composition of factors in [0, 1]; the SM picks the
# highest-scoring action and falls back to CARRY when none clears the
# action threshold.
#
# Phase 5d ships SHOOT and PASS scoring. CARRY is the implicit default
# (no score). DUMP and PROTECT will land later as new score functions.
#
# Factors are deliberately simple — no raycasts (lane-clear), no human
# pass-bias, no curve resources. Tunable via the constants below.

# An opponent within this distance counts toward "pressure" on a target.
const PRESSURE_RADIUS_M: float = 4.0
# How many opponents within radius == fully pressured (score multiplier 0).
const PRESSURE_MAX_COUNT: int = 3

# Beyond this range, shots score 0 from distance alone — keeps bots from
# launching pucks at the goalie from the blue line.
const SHOT_RANGE_FALLOFF_M: float = 18.0

# Pass scoring needs a meaningful advancement; under PASS_MIN_ADVANTAGE_M
# the score is 0 (we don't pass for marginal gains). Saturates above
# PASS_MAX_ADVANTAGE_M.
const PASS_MIN_ADVANTAGE_M: float = 3.0
const PASS_MAX_ADVANTAGE_M: float = 12.0

# Score threshold below which the SM stays in CARRY rather than committing
# to a SHOOT or PASS. Tunes how aggressive bots are.
const ACTION_THRESHOLD: float = 0.25


# Returns SHOOT score in [0, 1]. Multiplicative product of:
#   - openness:      fraction of net not blocked by goalie's shadow
#   - dist_response: 1.0 close, → 0 at SHOT_RANGE_FALLOFF_M
#   - 1 - pressure:  inverse of opponent proximity around the shooter
static func score_shoot(
		shooter: Vector3,
		attacking_goal: Vector3,
		goalie_pos: Vector3,
		net_half_width: float,
		shadow_half: float,
		opponents: Array[Vector3]) -> float:
	var openness: float = _net_openness(shooter, attacking_goal.z, goalie_pos, net_half_width, shadow_half)
	var dist: float = shooter.distance_to(attacking_goal)
	var dist_response: float = clampf(1.0 - dist / SHOT_RANGE_FALLOFF_M, 0.0, 1.0)
	var pressure_factor: float = 1.0 - _pressure(shooter, opponents)
	return openness * dist_response * pressure_factor


# Returns PASS score in [0, 1] for a specific receiver. Multiplicative:
#   - advancement: how much closer to goal the receiver is than us (above
#                  PASS_MIN_ADVANTAGE_M, saturating at PASS_MAX_ADVANTAGE_M)
#   - 1 - pressure: how open the receiver is
static func score_pass(
		shooter: Vector3,
		receiver: Vector3,
		attacking_goal: Vector3,
		opponents: Array[Vector3]) -> float:
	var my_dist: float = shooter.distance_to(attacking_goal)
	var their_dist: float = receiver.distance_to(attacking_goal)
	var advantage: float = my_dist - their_dist
	if advantage < PASS_MIN_ADVANTAGE_M:
		return 0.0
	var span: float = PASS_MAX_ADVANTAGE_M - PASS_MIN_ADVANTAGE_M
	var advance_score: float = clampf((advantage - PASS_MIN_ADVANTAGE_M) / span, 0.0, 1.0)
	var pressure_factor: float = 1.0 - _pressure(receiver, opponents)
	return advance_score * pressure_factor


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

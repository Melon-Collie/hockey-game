extends GutTest

# Calibrates AIActionScoring.time_to_arrive — the universal ETA every race,
# election, lane, and chase read runs on — against ACTUAL arrival times under
# the real skating physics (SkaterMovementRules.apply_movement at 120 Hz)
# driven by the REAL bot steering (AISteering.compute_move_vector's
# velocity-matched seek + the should_brake pivot).
#
# The contract is two-sided: the estimator IS the arrival time, within
# tolerance, cell by cell — not an optimistic lower bound (the pre-phase-model
# heuristic's contract; it under-priced standing starts by ~2× and credited a
# full-speed closer with up to double top speed, which distorted every race at
# the extremes). If the movement tuning drifts (thrust, friction, drag, brake,
# top speed), cells here fail and the phase-model constants in action_scoring
# (VM_FREE_SHED_M_S, VM_SHED_DECEL_M_S2, REVERSAL_BRAKE_DECEL_M_S2,
# RAMP_EFFICIENCY) get re-measured — never silently absorbed.
#
# Known soft spot, deliberately excluded from the tight band: SHORT DIAGONAL
# cuts at speed (≈45° off-velocity within ~8 m). There the controller
# overflies the catch window laterally and loops once before converging —
# reality runs up to ~3× the estimate. Those cells get a loose sanity band
# instead; tightening them is steering work (a better cornering policy), not
# estimator work.

const DT: float = 1.0 / 120.0
# Pass-through tolerance: within one blade's contact of the target counts as
# arrived (ETAs feed contests and races, not parking precision).
const ARRIVE_RADIUS_M: float = 0.5
const TOL_FRAC: float = 0.25
const TOL_FLOOR_S: float = 0.18

var _cfg: SkaterMovementRules.MovementConfig


func before_each() -> void:
	_cfg = SkaterMovementRules.MovementConfig.new()
	_cfg.thrust = GameRules.DEFAULT_SKATER_THRUST_M_S2
	_cfg.friction = 0.8
	_cfg.friction_drag = 0.27
	_cfg.max_speed = GameRules.DEFAULT_SKATER_MAX_SPEED_M_S
	_cfg.move_deadzone = 0.1
	_cfg.brake_multiplier = 4.0
	_cfg.backward_thrust_multiplier = 0.80
	_cfg.crossover_thrust_multiplier = 0.90
	_cfg.puck_carry_speed_multiplier = 1.0


# Measured arrival under the real controller: velocity-matched seek (the
# carrier/station steering) + the pivot brake, facing aligned to the thrust
# (a bot's facing tracks its travel in open ice). Fields are inert (no
# bodies, boards far) for a clean one-body read.
func _sim_arrival_s(v0: Vector3, target: Vector3) -> float:
	var pos := Vector3.ZERO
	var vel: Vector3 = v0
	var t: float = 0.0
	var braking: bool = false
	var no_v: Array[Vector3] = []
	var big: float = 1000.0
	for _i: int in 1800:  # 15 s cap
		var to_t: Vector3 = target - pos
		to_t.y = 0.0
		if to_t.length() <= ARRIVE_RADIUS_M:
			return t
		var mi: Vector2 = AISteering.compute_move_vector(
				pos, target, no_v, no_v, Vector3.ZERO, Vector3.ZERO, big, big,
				AISteering.OPPONENT_REPEL_WEIGHT, no_v, no_v, vel,
				GameRules.DEFAULT_SKATER_MAX_SPEED_M_S)
		braking = AISteering.should_brake(mi, Vector2(vel.x, vel.z), braking)
		var facing_y: float = atan2(-mi.x, -mi.y) if mi.length() > 0.001 else 0.0
		vel = SkaterMovementRules.apply_movement(
				vel, mi, facing_y, false, braking, DT, _cfg)
		pos += vel * DT
		t += DT
	return INF


func _model_s(v0: Vector3, target: Vector3) -> float:
	return AIActionScoring.time_to_arrive(
			Vector3.ZERO, target, v0,
			GameRules.DEFAULT_SKATER_MAX_SPEED_M_S,
			GameRules.DEFAULT_SKATER_THRUST_M_S2)


func _cell(speed: float, angle_deg: float, dist: float) -> Array:
	var ang: float = deg_to_rad(angle_deg)
	var v0 := Vector3(sin(ang), 0.0, -cos(ang)) * speed
	var target := Vector3(0.0, 0.0, -dist)
	var real: float = _sim_arrival_s(v0, target)
	var model: float = _model_s(v0, target)
	gut.p("  v=%.1f  %3.0f°  d=%4.1f:  model %.2fs  real %.2fs" % [
			speed, angle_deg, dist, model, real])
	return [model, real]


func _check_cell(speed: float, angle_deg: float, dist: float) -> void:
	var pair: Array = _cell(speed, angle_deg, dist)
	var tol: float = maxf(pair[1] * TOL_FRAC, TOL_FLOOR_S)
	assert_almost_eq(pair[0], pair[1], tol,
			"v0=%.1f m/s at %.0f° over %.1f m: model %.2fs vs real %.2fs"
			% [speed, angle_deg, dist, pair[0], pair[1]])


func test_standing_starts() -> void:
	# The ramp: a standing start genuinely pays ~0.5 s over dist/top_speed.
	for dist: float in [2.0, 4.0, 8.0, 16.0, 25.0]:
		_check_cell(0.0, 0.0, dist)


func test_full_speed_head_on() -> void:
	# No double-credit: a full-speed closer arrives at dist/top_speed.
	for dist: float in [2.0, 4.0, 8.0, 16.0, 25.0]:
		_check_cell(9.0, 0.0, dist)


func test_half_speed_head_on() -> void:
	for dist: float in [4.0, 8.0, 16.0]:
		_check_cell(4.5, 0.0, dist)


func test_perpendicular_cuts() -> void:
	# The 90° family — the wing-curl read. The velocity-matched seek sheds
	# moderate cross speed for free; only the excess pays.
	for speed: float in [4.5, 9.0]:
		for dist: float in [4.0, 8.0, 16.0, 25.0]:
			_check_cell(speed, 90.0, dist)


func test_curl_back() -> void:
	# 135° — part reversal, part cut.
	for dist: float in [4.0, 8.0, 16.0]:
		_check_cell(9.0, 135.0, dist)
	_check_cell(4.5, 135.0, 4.0)


func test_full_reversal() -> void:
	# 180° — the pivot brake: brake out the retreat (giving back the ground
	# lost while braking), then a standing-start pursuit.
	for speed: float in [4.5, 9.0]:
		for dist: float in [4.0, 8.0, 16.0]:
			_check_cell(speed, 180.0, dist)


func test_long_diagonals() -> void:
	# 45° at range — past the miss-loop zone the model tracks.
	_check_cell(4.5, 45.0, 8.0)
	_check_cell(4.5, 45.0, 16.0)
	_check_cell(9.0, 45.0, 16.0)
	_check_cell(9.0, 45.0, 25.0)


func test_short_diagonal_miss_loop_sanity() -> void:
	# The known soft spot: short diagonal cuts at speed overfly the catch
	# window and loop (see header). The estimator stays an optimistic bound
	# there; the loose ceiling catches a catastrophic steering regression
	# without pinning the loop's exact cost.
	for cell: Array in [[9.0, 45.0, 4.0], [9.0, 45.0, 8.0], [4.5, 45.0, 4.0]]:
		var pair: Array = _cell(cell[0], cell[1], cell[2])
		assert_lte(pair[0], pair[1] + 0.02,
				"model stays a lower bound in the miss-loop zone")
		assert_lt(pair[1], pair[0] * 3.5 + 0.6,
				"miss-loop cost stays bounded (real %.2f vs model %.2f)"
				% [pair[1], pair[0]])


func test_momentum_direction_ordering() -> void:
	# Direction is priced correctly whatever the calibration details.
	var dest := Vector3(0.0, 0.0, -8.0)
	var aligned: float = _model_s(Vector3(0, 0, -6), dest)
	var rest: float = _model_s(Vector3.ZERO, dest)
	var perp: float = _model_s(Vector3(6, 0, 0), dest)
	var away: float = _model_s(Vector3(0, 0, 6), dest)
	assert_lt(aligned, rest, "momentum toward the target beats rest")
	assert_lt(rest, away, "rest beats momentum pointed away")
	assert_lt(perp, away, "a cut beats a full reversal")

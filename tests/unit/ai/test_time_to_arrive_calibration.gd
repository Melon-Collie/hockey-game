extends GutTest

# Validates AIActionScoring.time_to_arrive (the momentum-aware ETA the carry/chase
# scoring leans on) against the ACTUAL arrival time under the real skating physics
# (SkaterMovementRules.apply_movement) driven by the REAL bot steering
# (AISteering.compute_move_vector — the velocity-matched seek that cancels
# cross-drift, plus should_brake for reversals). Each row also prints a NAIVE
# strawman (thrust straight at the target, no velocity-match, no brake) to show
# what the ETA would face WITHOUT the real steering — it orbits on cross-momentum.
#
# The point of measuring against the REAL steering: the ETA's job is to predict how
# long THE BOT takes, and the bot doesn't naively thrust at the target — its
# velocity-matched seek is what makes cross-momentum cheap (the same insight the
# ETA's shed term encodes). Result: the ETA tracks the real steering to within ~1.5x
# in every direction (a consistent optimistic lower bound), while the naive
# controller runs 3-4x slower and orbits — confirming the shed term is calibrated to
# reality, not that either the ETA or the steering is broken.
#
# The prints are the deliverable; the asserts pin the invariants (predicted <=
# actual everywhere — an optimistic lower bound; momentum direction priced right;
# and every direction within ~2x of the real steering).

const DT: float = 1.0 / 120.0
const ARRIVE_RADIUS: float = 1.0   # "close enough to act" — a shot/carry spot, not 0.3 m precision
const MAX_TICKS: int = 1200          # 10 s safety cap


func _cfg() -> SkaterMovementRules.MovementConfig:
	# Faithful to SkaterController's league defaults (the same numbers the ETA's
	# league accel/speed references mirror).
	var c := SkaterMovementRules.MovementConfig.new()
	c.thrust = GameRules.DEFAULT_SKATER_THRUST_M_S2   # 10.5
	c.friction = 0.8
	c.friction_drag = 0.27
	c.max_speed = GameRules.DEFAULT_SKATER_MAX_SPEED_M_S   # 9.0
	c.move_deadzone = 0.1
	c.brake_multiplier = 4.0                          # friction ×4 while braking (the pivot/stop)
	c.puck_carry_speed_multiplier = 0.86
	c.backward_thrust_multiplier = 0.80
	c.crossover_thrust_multiplier = 0.90
	c.sprint_thrust_multiplier = 1.20
	c.sprint_max_speed_multiplier = 1.18
	return c


# Simulate a drive at `dest` from (start, vel); return actual seconds to first
# arrive within ARRIVE_RADIUS. `use_steering` picks the controller:
#   false — NAIVE: thrust straight at the target (a strawman; the bots don't do
#           this — it orbits on cross-momentum).
#   true  — REAL: AISteering.compute_move_vector in carrier mode (velocity-matched
#           seek that cancels cross-drift) + should_brake pivot, the actual logic
#           the bots use. This is what the ETA should be calibrated against.
func _actual_time(start: Vector3, vel: Vector3, dest: Vector3, use_steering: bool) -> float:
	var cfg := _cfg()
	var pos: Vector3 = start
	var v: Vector3 = vel
	var was_braking: bool = false
	var no_v: Array[Vector3] = []
	var big: float = 1000.0   # keep boards/crease fields inert for a clean 1-body read
	for tick: int in MAX_TICKS:
		if pos.distance_to(dest) <= ARRIVE_RADIUS:
			return tick * DT
		var mi: Vector2
		if use_steering:
			mi = AISteering.compute_move_vector(
					pos, dest, no_v, no_v, Vector3.ZERO, Vector3.ZERO, big, big,
					AISteering.OPPONENT_REPEL_WEIGHT, no_v, no_v, v,
					GameRules.DEFAULT_SKATER_MAX_SPEED_M_S)
		else:
			var to_dest := Vector3(dest.x - pos.x, 0.0, dest.z - pos.z)
			mi = Vector2(to_dest.x, to_dest.z)
			if mi.length() > 0.001:
				mi = mi.normalized()
		var brake: bool = use_steering \
				and AISteering.should_brake(mi, Vector2(v.x, v.z), was_braking)
		was_braking = brake
		var facing_y: float = atan2(-mi.x, -mi.y) if mi.length() > 0.001 else 0.0
		v = SkaterMovementRules.apply_movement(v, mi, facing_y, false, brake, DT, cfg)
		pos += v * DT
	return MAX_TICKS * DT


func _row(label: String, start: Vector3, vel: Vector3, dest: Vector3) -> Array:
	var predicted: float = AIActionScoring.time_to_arrive(
			start, dest, vel, GameRules.DEFAULT_SKATER_MAX_SPEED_M_S,
			GameRules.DEFAULT_SKATER_THRUST_M_S2)
	var naive: float = _actual_time(start, vel, dest, false)
	var real: float = _actual_time(start, vel, dest, true)
	gut.p("  %-24s pred=%.2f  REAL=%.2f (r=%.2f)  naive=%.2f (r=%.2f)" % [
			label, predicted, real, predicted / maxf(real, 0.001),
			naive, predicted / maxf(naive, 0.001)])
	# Return [predicted, REAL] — the real steering is the one the ETA must track.
	return [predicted, real]


func test_eta_tracks_actual_arrival() -> void:
	# Target 5 m dead ahead (−Z). Vary the START velocity's direction at 5 m/s.
	var start := Vector3.ZERO
	var dest := Vector3(0.0, 0.0, -5.0)
	var s: float = 5.0
	gut.p("── 5 m target, start speed %.0f m/s, by momentum direction ──" % s)
	var rest: Array = _row("at rest", start, Vector3.ZERO, dest)
	var aligned: Array = _row("aligned (toward dest)", start, Vector3(0, 0, -s), dest)
	var perp: Array = _row("perpendicular (across)", start, Vector3(s, 0, 0), dest)
	var diag: Array = _row("diagonal 45°", start, Vector3(s * 0.707, 0, -s * 0.707), dest)
	var away: Array = _row("away (reverse)", start, Vector3(0, 0, s), dest)

	# INVARIANT 1 — the ETA is an optimistic LOWER BOUND everywhere (constant-cruise
	# approximation ignores acceleration-from-rest and the drag-limited redirect), so
	# it must never over-promise: predicted <= actual in every direction.
	for pair: Array in [rest, aligned, perp, diag, away]:
		assert_lte(pair[0], pair[1] + 0.02,
				"ETA is an optimistic lower bound (pred %.2f <= actual %.2f)" % [pair[0], pair[1]])

	# INVARIANT 2 — momentum DIRECTION is priced correctly: velocity pointed at the
	# target arrives sooner than velocity pointed away, in both prediction and reality.
	assert_lt(aligned[0], away[0], "predicted: momentum toward the target beats away")
	assert_lt(aligned[1], away[1], "actual: momentum toward the target beats away")

	# CALIBRATION — against the REAL steering the ETA tracks within ~2x in EVERY
	# direction, cross-momentum included (the velocity-matched seek is what makes the
	# lateral cut cheap, exactly as the shed term prices it). The naive strawman
	# (printed) runs 3-4x slower — that gap is the steering the bots don't use, not a
	# miscalibrated ETA.
	for pair: Array in [rest, aligned, perp, diag, away]:
		var ratio: float = pair[0] / maxf(pair[1], 0.001)
		assert_gt(ratio, 0.5,
				"ETA tracks the real steering within ~2x (got %.2f)" % ratio)


func test_eta_by_distance_and_speed() -> void:
	# The perpendicular case (where the shed term does its work) across distances
	# and momentum magnitudes — the calibration surface for the new term.
	gut.p("── perpendicular momentum: ETA vs actual across distance × speed ──")
	for dist: float in [3.0, 6.0, 10.0]:
		var dest := Vector3(0.0, 0.0, -dist)
		for s: float in [3.0, 6.0, 9.0]:
			var pair: Array = _row("d=%.0fm  |v_perp|=%.0f" % [dist, s],
					Vector3.ZERO, Vector3(s, 0, 0), dest)
			assert_lte(pair[0], pair[1] + 0.02,
					"ETA stays an optimistic lower bound under cross-momentum")

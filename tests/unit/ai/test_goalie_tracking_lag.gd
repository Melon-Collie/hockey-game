extends GutTest

# ── THE TRACKER IS A LAG FILTER, AND A LAG FILTER NEVER CATCHES UP ───────────
# Instrument for the three things live play produces against a MOVING shooter:
# he cannot keep the man in front, he cannot square to him, and he is beaten
# while doing both. Logged play (2228 shots) prices it — 72.3% save percentage
# when set against 46.7% in motion, with 45% of all shots arriving in motion.
#
# Both tracking channels are first-order lags:
#
#   GoalieController._update_tracking   _tracked_threat_position.lerp(target, k*dt)
#   GoalieController (rotation)         lerp_angle(facing, target, rotation_speed*dt)
#
# A first-order lag has a PERMANENT steady-state error against a constant-
# velocity target: it settles at trailing by `rate / k` and no amount of run-up
# closes it. That property is the whole finding, and it is what separates this
# from "he is a bit slow". A rate LIMIT — his real push speed, his real rotation
# rate — has zero steady-state error until the target genuinely outruns him,
# which is the realistic, counter-playable failure the doctrine says it wants
# ("being unset is DIRECTIONAL"). A lag trails everything, including motion he
# could physically match.
#
# ── WHAT IS ASSERTED, AND WHY NOT A PINNED NUMBER ───────────────────────────
# Pinning "18 degrees" would survive replacing the model with a different broken
# one. The MECHANISM is the claim, so each test asserts a structural property or
# a closed form derived from the tunables:
#
#   1. lag / v is CONSTANT across speed          -> it is first-order, not a rate cap
#   2. that constant is LARGER at range          -> the jitter filter costs real tracking
#   3. facing error = rotation lag + threat lag  -> the two channels COMPOUND
#   4. a longer run-in does not close it         -> steady state, not transient
#
# (3) is the one that matters most and was not obvious: he squares to the
# TRACKED threat, so the threat lag re-enters the facing error as an angle on top
# of the rotation channel's own lag. Validated against measurement to within 2
# degrees across the whole sweep.
#
# If a future change replaces either lag with a rate limit these tests FAIL, and
# that failure is the win. Re-derive for the new model; do not loosen tolerances.
#
# ── MEASURED AT THE PERPENDICULAR CROSSING ──────────────────────────────────
# Sampled as the carrier crosses x = 0, where the geometry is exact: bearing is
# zero and his velocity is perpendicular to the sightline, so omega = v / dist
# with no cosine term to argue about. Run-in is scaled with speed so the lag has
# reached steady state (>= 4 time constants) before the window opens.

const DT: float = 1.0 / 120.0
const GOAL_Z: float = -GameRules.GOAL_LINE_Z
# Sample window either side of the crossing: wide enough to average out tick
# quantisation, narrow enough that the small-angle geometry still holds.
const SAMPLE_HALF_WIDTH_M: float = 0.5
# Distances that bracket the chest-tracking ramp (near 2.5 m, far 7.0 m), so one
# row sits inside the compensated regime and one outside it.
const DISTANCES: Array[float] = [5.0, 8.0]
const SPEEDS: Array[float] = [2.0, 4.0, 6.0, 8.0]

var _goalie: Node = null
var _puck: Node = null
var _ctrl: GoalieController = null
var _shooter: Skater = null


func before_each() -> void:
	_goalie = load("res://Scenes/Goalie.tscn").instantiate()
	_puck = load("res://Scenes/Puck.tscn").instantiate()
	_shooter = load("res://Scenes/Skater.tscn").instantiate() as Skater
	add_child_autofree(_goalie)
	add_child_autofree(_puck)
	add_child_autofree(_shooter)
	_shooter.set_physics_process(false)
	_shooter.set_process(false)
	_ctrl = GoalieController.new()
	add_child_autofree(_ctrl)
	_ctrl.set_skater_getter(func() -> Array: return [_shooter])
	_puck.global_position = Vector3(0.0, 0.0, GOAL_Z + 6.0)
	_ctrl.setup(_goalie, _puck, GOAL_Z, true)


# Run-in distance for a crossing at `v`. Four time constants of the slowest
# channel (tracking_speed_far = 3.0 -> 0.33 s) is 1.33 s of travel; capped so the
# carrier does not start so wide that the arc solve is doing something else.
func _run_in_m(v: float) -> float:
	return clampf(2.0 + 2.0 * v, 6.0, 12.0)


# Drive a carrier straight across the face at `dist` metres out at constant
# lateral speed, and sample both tracking errors at the x = 0 crossing.
#
# He CARRIES but does not wind up: a published wind-up makes him read a shot
# threat and drop, and a dropped goalie is measuring something else. `upright_frac`
# is returned so a run that went down is discounted rather than silently averaged.
func _cross(dist: float, v: float, run_in_m: float = -1.0) -> Dictionary:
	var from_x: float = -(run_in_m if run_in_m > 0.0 else _run_in_m(v))
	var z: float = GOAL_Z + dist
	var pos := Vector3(from_x, 0.0, z)
	var vel := Vector3(absf(v), 0.0, 0.0)
	_shooter.current_shot_state = SkaterStateMachine.State.SKATING_WITH_PUCK
	_shooter.predicted_shot_velocity = Vector3.ZERO
	_shooter.global_position = pos
	_shooter.velocity = Vector3.ZERO
	_puck.set_carrier(_shooter)
	_ctrl.reset_to_crease()
	# Settle square on the start spot, so the crossing measures tracking rather
	# than a keeper still walking out to his depth.
	for _i: int in 400:
		_puck.global_position = pos
		_puck.linear_velocity = Vector3.ZERO
		_ctrl._physics_process(DT)
	var threat_lag: float = 0.0
	var facing_err: float = 0.0
	var samples: int = 0
	var upright: int = 0
	var total: int = 0
	while pos.x < SAMPLE_HALF_WIDTH_M + 0.05:
		pos.x += vel.x * DT
		_shooter.global_position = pos
		_shooter.velocity = vel
		_puck.global_position = pos
		_puck.linear_velocity = Vector3.ZERO
		_ctrl._physics_process(DT)
		total += 1
		if _ctrl._sm.is_upright():
			upright += 1
		if absf(pos.x) <= SAMPLE_HALF_WIDTH_M:
			threat_lag += pos.x - _ctrl._tracked_threat_position.x
			var g: Vector3 = _goalie.global_position
			var true_bearing: float = atan2(-(pos.x - g.x), -(pos.z - g.z))
			facing_err += angle_difference(
					_goalie.get_goalie_rotation_y(), true_bearing)
			samples += 1
	var n: float = float(maxi(samples, 1))
	return {
		"threat_lag_m": threat_lag / n,
		"facing_err_deg": rad_to_deg(facing_err / n),
		"upright_frac": float(upright) / float(maxi(total, 1)),
		"samples": samples,
	}


# ── 1. IT IS A FIRST-ORDER LAG: the trail is proportional to speed ──────────

func test_the_threat_trail_is_proportional_to_carrier_speed() -> void:
	# lag / v is the effective time constant. Constant across a 4x speed sweep is
	# the signature of a lag filter; a rate CAP would instead show lag/v rising
	# sharply once the demand passed the cap and staying near zero below it.
	var rows: Array[String] = []
	var taus_far: Array[float] = []
	for dist: float in DISTANCES:
		var taus: Array[float] = []
		for v: float in SPEEDS:
			var r: Dictionary = _cross(dist, v)
			assert_gt(r["upright_frac"], 0.95,
					"stayed on his feet at %.0f m / %.0f m/s" % [dist, v])
			var tau: float = r["threat_lag_m"] / v
			taus.append(tau)
			rows.append("  %4.1f m  %.0f m/s | trail %+.3f m   lag/v %.4f s   (upright %.0f%%)"
					% [dist, v, r["threat_lag_m"], tau, r["upright_frac"] * 100.0])
		if is_equal_approx(dist, 8.0):
			taus_far = taus
	gut.p("THREAT TRAIL (metres the tracked threat sits behind the real carrier)")
	for s: String in rows:
		gut.p(s)
	# At range the lead term is fully faded out, so the filter runs naked and the
	# implied time constant must be flat.
	var lo: float = taus_far.min()
	var hi: float = taus_far.max()
	gut.p("  implied time constant at 8 m: %.4f .. %.4f s" % [lo, hi])
	assert_lt(hi - lo, 0.02,
			"lag/v is constant across a 4x speed sweep — a first-order lag, not a rate cap")
	assert_between(lo, 0.15, 0.28,
			"and it equals roughly 1/tracking_speed_far minus the carrier lead")


func test_tracking_is_looser_at_range_than_in_tight() -> void:
	# The far-range smoothing exists to reject stickhandle jitter, but it
	# low-passes the carrier's REAL translation along with it — so he tracks WORSE
	# exactly where the bots shoot from. This is the inversion, and it is the
	# medium-range half of the live complaint.
	var near: Dictionary = _cross(5.0, 6.0)
	var far: Dictionary = _cross(8.0, 6.0)
	var near_tau: float = near["threat_lag_m"] / 6.0
	var far_tau: float = far["threat_lag_m"] / 6.0
	gut.p("effective tracking time constant: %.4f s at 5 m | %.4f s at 8 m" % [
			near_tau, far_tau])
	assert_gt(far_tau, near_tau * 2.0,
			"tracking at range is more than twice as laggy as in tight")


# ── 2. THE TWO LAGS COMPOUND — "he cannot square to a shooter" ──────────────

func test_facing_error_is_the_rotation_lag_plus_the_threat_lag() -> void:
	# He squares to the TRACKED threat, not to the puck. So the threat trail
	# re-enters as an angle on top of the rotation channel's own steady-state lag:
	#
	#     facing_err = omega / rotation_speed  +  atan(threat_trail / dist)
	#
	# Both terms are the same defect. Neither alone explains the measurement.
	var rows: Array[String] = []
	var worst: float = 0.0
	for dist: float in DISTANCES:
		for v: float in SPEEDS:
			var r: Dictionary = _cross(dist, v)
			var rot_lag: float = rad_to_deg((v / dist) / _ctrl.rotation_speed)
			var trail_ang: float = rad_to_deg(atan(absf(r["threat_lag_m"]) / dist))
			var predicted: float = rot_lag + trail_ang
			var measured: float = absf(r["facing_err_deg"])
			rows.append("  %4.1f m  %.0f m/s | rot %5.2f + trail %5.2f = %5.2f deg | measured %5.2f"
					% [dist, v, rot_lag, trail_ang, predicted, measured])
			if r["upright_frac"] > 0.95:
				# The prediction adds two angles that are each derived linearly, so
				# its residual grows with the total — at 1.6 rad/s the sum is 25 deg
				# and the small-angle addition is no longer exact. Tolerance is
				# therefore relative, with a floor so the near-zero rows stay honest.
				var tol: float = maxf(0.8, 0.12 * predicted)
				assert_almost_eq(measured, predicted, tol,
						"facing error at %.0f m / %.0f m/s is the two lags compounded"
						% [dist, v])
				worst = maxf(worst, measured)
	gut.p("SQUARING ERROR (degrees his body faces off the true bearing to the puck)")
	for s: String in rows:
		gut.p(s)
	gut.p("  worst: %.1f deg" % worst)
	# The headline: against a shooter moving at a routine pace he is two dozen
	# degrees off square. Half a net width at the goal line.
	assert_gt(worst, 15.0,
			"CHARACTERISATION: a moving shooter leaves him badly off square (fix this and the test fails — re-derive it)")


func test_a_sustained_crossing_never_converges_square() -> void:
	# The property that separates a lag from a slow rate limit: double the run-in
	# and the error does not shrink, because it is a steady state rather than a
	# transient still being worked off. A rate limit would close the gap the
	# moment the demand dropped under the cap.
	var short_run: Dictionary = _cross(5.0, 6.0, 8.0)
	var long_run: Dictionary = _cross(5.0, 6.0, 20.0)
	gut.p("facing error after 8 m of run-in: %.1f deg | after 20 m: %.1f deg" % [
			absf(short_run["facing_err_deg"]), absf(long_run["facing_err_deg"])])
	assert_almost_eq(absf(long_run["facing_err_deg"]),
			absf(short_run["facing_err_deg"]), 1.5,
			"a longer run-in does NOT square him up — steady state, not transient")

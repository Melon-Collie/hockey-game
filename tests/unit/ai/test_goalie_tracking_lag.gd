extends GutTest

# ── WHAT THE GOALIE'S TRACKING OWES A MOVING SHOOTER ─────────────────────────
# Instrument for the three things live play produces against a MOVING shooter:
# he cannot keep the man in front, he cannot square to him, and he is beaten
# while doing both. Logged play (2228 shots) prices it — 72.3% save percentage
# when set against 46.7% in motion, with 45% of all shots arriving in motion.
#
# ── THE MODEL IT HOLDS ──────────────────────────────────────────────────────
# The threat the goalie squares to is the carrier's BODY tracked raw, plus his
# puck OFFSET and the lead built from it, both low-passed for dangle jitter
# (Scripts/controllers/CLAUDE.md → "Filter the puck, not the man"). So against a
# carrier moving at a constant lateral speed the tracked threat sits AHEAD of him
# by exactly `carrier_velocity_lead_time`, with no speed-proportional trail.
#
# The trap this exists to catch: low-passing the BODY too. A first-order filter
# has a permanent steady-state error against a constant-velocity target — it
# settles at trailing by `speed / k` and no run-up closes it — so filtering the
# man charges his real translation a trail proportional to his speed. That trail
# then enters the SQUARING error a second time, because the body rotates toward
# the tracked threat rather than toward the puck, and the two compound. Measured
# before the split: 0.20 s of trail at range (1.6 m behind an 8 m/s skate) and
# 25.8 degrees off square. Never put a filter back on the carrier's position.
#
# ── WHAT IS ASSERTED, AND WHY NOT A PINNED NUMBER ───────────────────────────
# Pinning "1.9 degrees" would survive being replaced by a differently-broken
# model. The MECHANISM is the claim, so each test asserts a structural property
# or a closed form derived from the tunables:
#
#   1. the trail is a LEAD, equal to the lead time exactly  -> body is unfiltered
#   2. that holds across a 4x speed sweep                   -> no filter residue
#   3. squaring error stays small at every speed            -> the two do not compound
#   4. a longer run-in changes nothing                      -> steady state
#
# (1) is the sharp one. A filter on the body cannot produce a constant NEGATIVE
# lag/v, so any reintroduced smoothing shows up as the measured constant moving
# off `-carrier_velocity_lead_time` toward zero and then positive.
#
# ── MEASURED AT THE PERPENDICULAR CROSSING ──────────────────────────────────
# Sampled as the carrier crosses x = 0, where the geometry is exact: bearing is
# zero and his velocity is perpendicular to the sightline, so omega = v / dist
# with no cosine term to argue about. Run-in is scaled with speed so any
# transient has settled before the window opens.

const DT: float = 1.0 / 120.0
const GOAL_Z: float = -GameRules.GOAL_LINE_Z
# Sample window either side of the crossing: wide enough to average out tick
# quantisation, narrow enough that the small-angle geometry still holds.
const SAMPLE_HALF_WIDTH_M: float = 0.5
# Distances that bracket the chest-tracking ramp (near 2.5 m, far 7.0 m). Beyond
# the far anchor the puck lead is fully faded, so the carrier lead is the only
# term left and the closed form is exact.
const DIST_INSIDE_RAMP: float = 5.0
const DIST_PAST_RAMP: float = 8.0
const DISTANCES: Array[float] = [DIST_INSIDE_RAMP, DIST_PAST_RAMP]
const SPEEDS: Array[float] = [2.0, 4.0, 6.0, 8.0]
# The whole point of the split: a moving shooter must not cost him his angle.
# Generous next to the 25.8 degrees the filtered-body model produced, tight
# enough that reintroducing any of it fails here.
const SQUARE_TOLERANCE_DEG: float = 3.0

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


# Run-in for a crossing at `v`: several time constants of the slowest channel,
# capped so the carrier does not start so wide that the arc solve is doing
# something else entirely.
func _run_in_m(v: float) -> float:
	return clampf(2.0 + 2.0 * v, 6.0, 12.0)


# Drive a carrier straight across the face at `dist` metres out at constant
# lateral speed, and sample both tracking errors at the x = 0 crossing.
#
# He CARRIES but does not wind up: a published wind-up makes him read a shot
# threat and drop, and a dropped goalie is measuring something else.
# `upright_frac` is returned so a run that went down is discounted rather than
# silently averaged.
#
# `threat_offset_m` is POSITIVE when the tracked threat trails the man and
# NEGATIVE when it leads him.
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
	var threat_offset: float = 0.0
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
			threat_offset += pos.x - _ctrl._tracked_threat_position.x
			var g: Vector3 = _goalie.global_position
			var true_bearing: float = atan2(-(pos.x - g.x), -(pos.z - g.z))
			facing_err += angle_difference(
					_goalie.get_goalie_rotation_y(), true_bearing)
			samples += 1
	var n: float = float(maxi(samples, 1))
	return {
		"threat_offset_m": threat_offset / n,
		"facing_err_deg": rad_to_deg(facing_err / n),
		"upright_frac": float(upright) / float(maxi(total, 1)),
		"samples": samples,
	}


# ── 1. THE BODY IS NOT FILTERED: the threat LEADS by the lead time ──────────

func test_the_threat_leads_the_carrier_by_exactly_the_lead_time() -> void:
	# Past the chest ramp the puck lead is fully faded, so the carrier lead is
	# the only term and `offset / v` must equal -carrier_velocity_lead_time
	# exactly. Any filter on the body adds a positive (trailing) component, so
	# this is the assertion that catches one coming back.
	var rows: Array[String] = []
	var constants: Array[float] = []
	for v: float in SPEEDS:
		var r: Dictionary = _cross(DIST_PAST_RAMP, v)
		assert_gt(r["upright_frac"], 0.95,
				"stayed on his feet at %.0f m / %.0f m/s" % [DIST_PAST_RAMP, v])
		var k: float = r["threat_offset_m"] / v
		constants.append(k)
		rows.append("  %4.1f m  %.0f m/s | offset %+.3f m   offset/v %+.4f s"
				% [DIST_PAST_RAMP, v, r["threat_offset_m"], k])
	gut.p("THREAT OFFSET past the chest ramp (negative = leads the carrier)")
	for s: String in rows:
		gut.p(s)
	var lo: float = constants.min()
	var hi: float = constants.max()
	gut.p("  implied constant: %+.4f .. %+.4f s  (carrier_velocity_lead_time %.3f)"
			% [lo, hi, _ctrl.carrier_velocity_lead_time])
	assert_lt(hi - lo, 0.01,
			"the implied constant is flat across a 4x speed sweep")
	assert_almost_eq(lo, -_ctrl.carrier_velocity_lead_time, 0.01,
			"and equals the carrier lead exactly — nothing is filtering the body")


func test_tracking_inside_the_ramp_leads_by_at_least_as_much() -> void:
	# Inside the ramp the puck lead has not faded out, so the threat leads by the
	# two leads together. It must never trail: a positive offset anywhere means a
	# filter has been put back on the carrier's translation.
	var rows: Array[String] = []
	for v: float in SPEEDS:
		var r: Dictionary = _cross(DIST_INSIDE_RAMP, v)
		rows.append("  %4.1f m  %.0f m/s | offset %+.3f m   offset/v %+.4f s"
				% [DIST_INSIDE_RAMP, v, r["threat_offset_m"], r["threat_offset_m"] / v])
		assert_lt(r["threat_offset_m"], 0.0,
				"the threat leads rather than trails at %.0f m / %.0f m/s"
				% [DIST_INSIDE_RAMP, v])
	gut.p("THREAT OFFSET inside the chest ramp (negative = leads the carrier)")
	for s: String in rows:
		gut.p(s)


# ── 2. THE CHANNELS DO NOT COMPOUND — "he can square to a moving shooter" ───

func test_squaring_error_stays_small_against_a_moving_shooter() -> void:
	# The headline. The rotation channel still lags (it lerps toward the tracked
	# threat), but the threat now LEADS, so the two largely offset instead of
	# stacking. What matters is the residual the shooter actually faces.
	var rows: Array[String] = []
	var worst: float = 0.0
	for dist: float in DISTANCES:
		for v: float in SPEEDS:
			var r: Dictionary = _cross(dist, v)
			var measured: float = absf(r["facing_err_deg"])
			# What the rotation channel alone would cost if nothing offset it —
			# reported so the margin is visible rather than asserted blind.
			var rot_lag: float = rad_to_deg((v / dist) / _ctrl.rotation_speed)
			rows.append("  %4.1f m  %.0f m/s | off square %5.2f deg  (rotation lag alone would be %5.2f)"
					% [dist, v, measured, rot_lag])
			if r["upright_frac"] > 0.95:
				worst = maxf(worst, measured)
	gut.p("SQUARING ERROR (degrees his body faces off the true bearing to the puck)")
	for s: String in rows:
		gut.p(s)
	gut.p("  worst: %.1f deg" % worst)
	assert_lt(worst, SQUARE_TOLERANCE_DEG,
			"a moving shooter does not cost him his angle")


func test_a_sustained_crossing_holds_its_steady_state() -> void:
	# Whatever the residual is, it must be a steady state rather than a transient
	# still being worked off — otherwise the numbers above depend on how long the
	# run-in happened to be and none of them are comparable.
	var short_run: Dictionary = _cross(DIST_INSIDE_RAMP, 6.0, 8.0)
	var long_run: Dictionary = _cross(DIST_INSIDE_RAMP, 6.0, 20.0)
	gut.p("off square after 8 m of run-in: %.2f deg | after 20 m: %.2f deg" % [
			absf(short_run["facing_err_deg"]), absf(long_run["facing_err_deg"])])
	assert_almost_eq(absf(long_run["facing_err_deg"]),
			absf(short_run["facing_err_deg"]), 1.0,
			"the residual is a steady state, not a transient")

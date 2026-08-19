extends GutTest

# ── Controlled space: the "how much room do I have to operate" read ──────────
# Calibration for AICarrySpace.controlled_space / control_at (see the block
# doc there). These pin the properties the model exists to have — the ones the
# single-ray corridor test it replaced did NOT have — rather than exact values,
# which are free to move with the underlying carry_safety calibration.

const GOAL := Vector3(0.0, 0.0, -26.65)
const HORIZON: float = 9.0

var _opps: Array[Vector3] = []
var _vels: Array[Vector3] = []


func before_each() -> void:
	_opps = []
	_vels = []


func _space(from: Vector3, vel: Vector3 = Vector3.ZERO) -> float:
	return AICarrySpace.controlled_space(
			from, vel, null, GOAL, HORIZON, _opps, _vels)


# A defender `ahead` m up the netward ray from `from`, `off` m to the side.
func _place(from: Vector3, ahead: float, off: float,
		vel: Vector3 = Vector3.ZERO) -> void:
	var dir: Vector3 = (GOAL - from).normalized()
	var perp := Vector3(-dir.z, 0.0, dir.x)
	_opps.append(from + dir * ahead + perp * off)
	_vels.append(vel)


func test_open_ice_is_fully_controlled_at_any_speed() -> void:
	var from := Vector3(-5.0, 0.0, 2.0)
	for speed: float in [0.0, 4.0, 9.0]:
		assert_almost_eq(_space(from, Vector3(0.0, 0.0, -speed)), 1.0, 0.001,
				"empty ice is entirely the carrier's at %.0f m/s" % speed)


func test_no_cliff_at_the_stick_reach_boundary() -> void:
	# THE BUG THIS MODEL EXISTS TO FIX. The old corridor test read 0.556 for a
	# defender 1.00 m off the netward ray and 1.000 at 2.00 m — a 45 cm shift in
	# one body flipping the carry/pass decision. Space must vary SMOOTHLY with
	# how much ice a defender actually takes away.
	var from := Vector3(-5.0, 0.0, 2.0)
	var prev: float = -1.0
	var worst_jump: float = 0.0
	var samples: Array[float] = []
	for off: float in [0.0, 0.5, 1.0, 1.5, 2.0, 3.0, 5.0, 8.0, 12.0, 20.0]:
		_opps = []
		_vels = []
		_place(from, 8.0, off)
		var s: float = _space(from)
		samples.append(s)
		if prev >= 0.0:
			worst_jump = maxf(worst_jump, absf(s - prev))
		prev = s
	gut.p("off-ray 0.0/0.5/1.0/1.5/2.0/3.0/5.0 m -> %s"
			% str(samples.map(func(v: float) -> String: return "%.3f" % v)))
	assert_lt(worst_jump, 0.30,
			"no single 0.5 m step may move space more than 0.30 (worst %.3f)"
					% worst_jump)
	assert_gt(samples[samples.size() - 1], samples[0],
			"a defender well off the lane leaves more space than one on it")


func test_distance_ahead_matters_the_old_read_had_no_clock() -> void:
	# The corridor test returned an IDENTICAL 0.556 for a defender 3 m ahead and
	# one 8 m ahead — it had no time in it at all. A man bearing down on you is
	# not the same as one gap-controlling at the line.
	var from := Vector3(-5.0, 0.0, 2.0)
	var near: float
	var far: float
	_place(from, 3.0, 1.0)
	near = _space(from)
	_opps = []
	_vels = []
	_place(from, 8.0, 1.0)
	far = _space(from)
	gut.p("D 1 m off the ray: 3 m ahead -> %.3f   8 m ahead -> %.3f" % [near, far])
	assert_gt(far, near,
			"a defender further up the ice takes less space away right now")


func test_a_defender_being_out_skated_costs_less_space() -> void:
	# The escape read: a man the carrier is beating along the drive can't
	# sustain a strip, so he shouldn't wall off the ice ahead the way a set
	# gap-controller does. Same body, same spot — only his velocity differs.
	var from := Vector3(-5.0, 0.0, 2.0)
	var drive := Vector3(0.0, 0.0, -8.0)
	_place(from, 3.0, 1.0)                       # standing, gap-controlling
	var vs_set: float = _space(from, drive)
	_opps = []
	_vels = []
	_place(from, 3.0, 1.0, Vector3(0.0, 0.0, -6.0))   # skating with the carrier
	var vs_chaser: float = _space(from, drive)
	gut.p("D 3 m ahead: set %.3f   fleeing-with-the-carrier %.3f"
			% [vs_set, vs_chaser])
	assert_gt(vs_chaser, vs_set,
			"a defender the carrier is running down takes less space than a set one")


func test_lateral_space_is_lost_at_speed_forward_space_is_not() -> void:
	# Momentum is not free: a carrier flying up ice genuinely cannot cut hard
	# across, so his LATERAL options shrink even as his forward ones improve
	# (the same cross-momentum shed the movement rules apply to the real body).
	# This documents that the aggregate can fall with speed — it is the model
	# reporting maneuverability honestly, not a defect. What must hold is that
	# the straight-ahead ice gets BETTER, never worse.
	var from := Vector3(-5.0, 0.0, 2.0)
	var dir: Vector3 = (GOAL - from).normalized()
	var perp := Vector3(-dir.z, 0.0, dir.x)
	_place(from, 6.0, 2.5)
	var ahead: Vector3 = from + dir * HORIZON
	var across: Vector3 = from + (dir * cos(1.2217) - perp * sin(1.2217)) * HORIZON
	for speed: float in [0.0, 9.0]:
		var v := Vector3(dir.x * speed, 0.0, dir.z * speed)
		gut.p("at %.0f m/s: straight-ahead %.3f  70-deg-across %.3f" % [speed,
				AICarrySpace.control_at(ahead, from, v, null, _opps, _vels),
				AICarrySpace.control_at(across, from, v, null, _opps, _vels)])
	var still: float = AICarrySpace.control_at(
			ahead, from, Vector3.ZERO, null, _opps, _vels)
	var flying: float = AICarrySpace.control_at(
			ahead, from, dir * 9.0, null, _opps, _vels)
	assert_gte(flying, still,
			"driving at the objective never reads LESS control of the ice ahead")


func test_samples_off_the_playing_surface_are_dropped_not_zeroed() -> void:
	# A wall doesn't strip the puck — it removes options. Pricing the boards as
	# pressure would discount a clean wall carry as if it were covered, so
	# off-ice samples leave both sums. An unpressured carrier hugging the wall
	# still reads as fully in control.
	var wall := Vector3(GameRules.INNER_HALF_WIDTH - 0.4, 0.0, 2.0)
	assert_almost_eq(_space(wall), 1.0, 0.001,
			"an unpressured carrier on the boards still controls the ice ahead")


func test_degenerate_inputs_are_safe() -> void:
	assert_eq(_space(GOAL), 1.0, "standing on the objective returns full space")
	assert_eq(AICarrySpace.controlled_space(
			Vector3(0.0, 0.0, 2.0), Vector3.ZERO, null, GOAL, 0.0, _opps, _vels),
			1.0, "a zero horizon returns full space")

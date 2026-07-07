extends GutTest

# LegIKRules — the sagittal leg IK must invert the forward model the gait uses,
# and the stride conveyor must read as a skate stride (fast planted push, slow
# lifted recovery).

const THIGH: float = 0.31
const SHIN: float = 0.45


# Forward model — identical to test_gait_stroke_profile / the gait FK.
func _fore(hip: float, knee: float) -> float:
	return THIGH * sin(hip) + SHIN * sin(hip + knee)


func _down(hip: float, knee: float) -> float:
	return THIGH * cos(hip) + SHIN * cos(hip + knee)


func test_solve_round_trips_the_forward_model() -> void:
	# A grid of reachable foot targets must solve to angles that place the foot
	# back at the same point (within reach; the knee takes the backward branch).
	for fore: float in [-0.2, -0.1, 0.0, 0.1, 0.2]:
		for down: float in [0.55, 0.65, 0.72]:
			var sol: Vector2 = LegIKRules.solve_sagittal(fore, down, THIGH, SHIN)
			var got_fore: float = _fore(sol.x, sol.y)
			var got_down: float = _down(sol.x, sol.y)
			assert_almost_eq(got_fore, fore, 0.001,
					"fore mismatch at target (%.2f, %.2f)" % [fore, down])
			assert_almost_eq(got_down, down, 0.001,
					"down mismatch at target (%.2f, %.2f)" % [fore, down])


func test_solve_recovers_the_neutral_stance() -> void:
	# The seated neutral (hip 22°, knee = the geometry-derived flex) round-trips
	# to itself — the IK and the FK agree on the rest pose.
	var hip: float = deg_to_rad(22.0)
	var knee: float = -(hip + asin(clampf(THIGH / SHIN * sin(hip), -1.0, 1.0)))
	var sol: Vector2 = LegIKRules.solve_sagittal(_fore(hip, knee), _down(hip, knee), THIGH, SHIN)
	assert_almost_eq(sol.x, hip, 0.001, "hip pitch not recovered")
	assert_almost_eq(sol.y, knee, 0.001, "knee not recovered")


func test_out_of_reach_clamps_to_full_extension() -> void:
	# A target past the leg's reach solves to a nearly straight leg (knee ~0),
	# not a NaN or a snap.
	var sol: Vector2 = LegIKRules.solve_sagittal(0.0, THIGH + SHIN + 0.5, THIGH, SHIN)
	assert_almost_eq(sol.y, 0.0, 0.001, "knee should straighten at full extension")
	assert_false(is_nan(sol.x), "hip pitch must be finite past reach")


func test_conveyor_push_is_faster_than_recovery() -> void:
	# Sample fore/aft speed across the cycle; the push (fast phase) must peak
	# faster than the recovery, and the recovery must be the lifted one.
	var push_frac: float = 0.35
	var steps: int = 720
	var peak_back: float = 0.0
	var peak_fwd: float = 0.0
	var prev: float = LegIKRules.foot_conveyor(0.0, push_frac).x
	for i: int in range(1, steps + 1):
		var theta: float = TAU * float(i) / float(steps)
		var sample: Vector2 = LegIKRules.foot_conveyor(theta, push_frac)
		var v: float = (sample.x - prev)
		peak_back = maxf(peak_back, -v)
		peak_fwd = maxf(peak_fwd, v)
		prev = sample.x
		# Lift is zero through the whole planted push window.
		if theta / TAU < push_frac:
			assert_almost_eq(sample.y, 0.0, 0.0001, "push must stay on the ice")
	assert_gt(peak_back, peak_fwd, "the push must be the fast phase of the stride")


func test_conveyor_lifts_the_recovery_foot() -> void:
	# Mid-recovery the skate is clear of the ice (the airborne return that hides
	# its forward swing).
	var mid_recovery: float = TAU * (0.35 + (1.0 - 0.35) * 0.5)
	assert_gt(LegIKRules.foot_conveyor(mid_recovery, 0.35).y, 0.5,
			"the recovery foot should lift off the ice")

extends GutTest

# Pins the COMPOSITION rule (plan doc §3). The individual depth models each had
# tests; what never did — and what actually decided the goalie's depth — was how
# they combine. These assert the contract the solver states:
#   * every constraint is a maximum radius; the tightest wins,
#   * caps are floored so no anticipatory read buries him in the net,
#   * the rush backflow owns the approach RATE while it is retreating him,
#   * everything else uses the settle, rate-capped.

const DT: float = 1.0 / 120.0


func _cfg() -> GoalieDepthSolver.Constraints:
	var c := GoalieDepthSolver.Constraints.new()
	c.ceiling_radius = 1.75
	c.floor_radius = 0.10
	c.settle_speed = 4.0
	c.max_speed = 2.2
	return c


func test_unconstrained_settles_toward_the_chart() -> void:
	var c := _cfg()
	var next: float = GoalieDepthSolver.solve(0.10, DT, c)
	assert_gt(next, 0.10, "with nothing binding, he challenges out toward the ceiling")
	assert_lt(next, c.ceiling_radius, "and it settles rather than snapping")


func test_tightest_cap_wins_regardless_of_which_one() -> void:
	# Backdoor tighter than lateral.
	var c := _cfg()
	c.lateral_cap = 1.00
	c.backdoor_cap = 0.60
	var a: float = GoalieDepthSolver.solve(2.0, DT, c)
	# Lateral tighter than backdoor — same answer shape, opposite order.
	var c2 := _cfg()
	c2.lateral_cap = 0.60
	c2.backdoor_cap = 1.00
	var b: float = GoalieDepthSolver.solve(2.0, DT, c2)
	assert_almost_eq(a, b, 0.0001,
			"the tightest cap decides; which constraint supplies it must not matter")


func test_caps_are_floored() -> void:
	# An absurd cap (an unwinnable re-square race returns ~0) must not bury him.
	var c := _cfg()
	c.backdoor_cap = -5.0
	# Start AT the floor so the settle has nowhere to go if the floor holds.
	var next: float = GoalieDepthSolver.solve(c.floor_radius, DT, c)
	assert_almost_eq(next, c.floor_radius, 0.0001,
			"a cap below the floor must clamp to the floor, not drag him behind the line")


func test_rush_backflow_owns_the_rate_while_retreating() -> void:
	var c := _cfg()
	c.rush_radius = 0.20
	c.rush_rate = 3.0            # deliberately faster than max_speed (2.2)
	var next: float = GoalieDepthSolver.solve(1.30, DT, c)
	assert_almost_eq(next, 1.30 - c.rush_rate * DT, 0.0001,
			"a rate-matched backflow retreat bypasses the settle AND the rate cap")


func test_rush_rate_does_not_apply_when_not_retreating() -> void:
	# Already deeper than the backflow wants: the curve is not pulling him in, so
	# the ordinary settle governs the way back out.
	var c := _cfg()
	c.rush_radius = 1.00
	c.rush_rate = 3.0
	var next: float = GoalieDepthSolver.solve(0.20, DT, c)
	assert_gt(next, 0.20, "he moves back out toward the backflow radius")
	assert_true(next - 0.20 <= c.max_speed * DT + 0.0001,
			"and that direction obeys the physical rate cap")


func test_standoff_keeps_him_off_the_puck() -> void:
	# The in-close case. A threat 1.5 m out with a 0.6 m standoff caps him at 0.9,
	# well inside the 1.75 ceiling — he stops short of the puck instead of standing
	# on it. This replaces the old hand-authored `zone_post_z` ramp with a
	# consequence of the goalie having a body.
	var c := _cfg()
	c.standoff_cap = 1.5 - 0.60
	var settled: float = 0.90
	for _i: int in 600:
		settled = GoalieDepthSolver.solve(settled, DT, c)
	assert_almost_eq(settled, 0.90, 0.01,
			"the standoff, not the ceiling, decides depth against an in-tight threat")


func test_a_clean_1v0_is_still_challenged_aggressively() -> void:
	# Nothing binding — no receiver, no rush, threat far enough that the standoff
	# is slack — is a genuine 1v0, and challenging it hard is correct: there is no
	# lateral option to punish the depth.
	var c := _cfg()
	c.standoff_cap = 8.0 - 0.60
	var settled: float = 0.10
	for _i: int in 600:
		settled = GoalieDepthSolver.solve(settled, DT, c)
	assert_almost_eq(settled, c.ceiling_radius, 0.01,
			"with no lateral option live, depth solves to the ceiling")


func test_a_live_receiver_pulls_him_off_the_ceiling() -> void:
	# The same 1v0 geometry, but now a weak-side receiver makes the re-square race
	# bind. This is BPS "C" appearing without anyone authoring a C zone.
	var c := _cfg()
	c.standoff_cap = 8.0 - 0.60
	c.backdoor_cap = 0.85
	var settled: float = 0.10
	for _i: int in 600:
		settled = GoalieDepthSolver.solve(settled, DT, c)
	assert_almost_eq(settled, 0.85, 0.01,
			"a live lateral option caps the challenge — the C zone, emergent")


func test_settle_is_rate_capped() -> void:
	# A big gap would open faster than a real telescoping push; the cap holds it.
	var c := _cfg()
	c.ceiling_radius = 10.0
	var next: float = GoalieDepthSolver.solve(0.0, DT, c)
	assert_almost_eq(next, c.max_speed * DT, 0.0001,
			"a large depth change is limited to max_speed, not the raw lerp")


func test_approach_is_symmetric_in_and_out() -> void:
	var out_step: float = GoalieDepthSolver.approach(0.0, 10.0, DT, 4.0, 2.2) - 0.0
	var in_step: float = 0.0 - GoalieDepthSolver.approach(10.0, 0.0, DT, 4.0, 2.2) + 10.0
	assert_almost_eq(out_step, in_step, 0.0001,
			"the rate cap applies equally to challenging out and retreating in")


# ── Lateral tracking cap (the deke / walkout answer) ─────────────────────────

func test_lateral_tracking_cap_is_a_rate_constraint() -> void:
	# r <= push * d / v. A carrier 4 m out moving the puck across at exactly the
	# goalie's push speed means he can only hold 4 m — nothing binds in practice.
	assert_almost_eq(
			GoalieBehaviorRules.lateral_tracking_cap(4.0, 3.8, 3.8), 4.0, 0.001,
			"at v == push speed the cap equals the threat distance")
	# Twice his push speed halves the depth he can afford.
	assert_almost_eq(
			GoalieBehaviorRules.lateral_tracking_cap(4.0, 7.6, 3.8), 2.0, 0.001,
			"doubling the carrier's lateral speed halves the affordable depth")


func test_lateral_tracking_cap_tightens_as_the_carrier_closes() -> void:
	# The same lateral pace is far more dangerous in tight, because the ANGULAR
	# rate the goalie has to match scales with 1/distance. This is what stops him
	# challenging into a walkout.
	var far: float = GoalieBehaviorRules.lateral_tracking_cap(6.0, 5.0, 3.8)
	var near: float = GoalieBehaviorRules.lateral_tracking_cap(2.0, 5.0, 3.8)
	assert_gt(far, near, "the same deke pace caps him harder the closer it happens")


func test_a_stationary_carrier_does_not_bind() -> void:
	assert_eq(GoalieBehaviorRules.lateral_tracking_cap(4.0, 0.0, 3.8), INF,
			"a carrier not moving the puck across imposes no depth cost")

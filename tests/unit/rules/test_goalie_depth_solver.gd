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
	c.chart_radius = 1.30
	c.floor_radius = 0.10
	c.settle_speed = 4.0
	c.max_speed = 2.2
	return c


func test_unconstrained_settles_toward_the_chart() -> void:
	var c := _cfg()
	var next: float = GoalieDepthSolver.solve(0.10, DT, c)
	assert_gt(next, 0.10, "with nothing binding, depth advances toward the chart radius")
	assert_lt(next, c.chart_radius, "and it settles rather than snapping")


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


func test_settle_is_rate_capped() -> void:
	# A big gap would open faster than a real telescoping push; the cap holds it.
	var c := _cfg()
	c.chart_radius = 10.0
	var next: float = GoalieDepthSolver.solve(0.0, DT, c)
	assert_almost_eq(next, c.max_speed * DT, 0.0001,
			"a large depth change is limited to max_speed, not the raw lerp")


func test_approach_is_symmetric_in_and_out() -> void:
	var out_step: float = GoalieDepthSolver.approach(0.0, 10.0, DT, 4.0, 2.2) - 0.0
	var in_step: float = 0.0 - GoalieDepthSolver.approach(10.0, 0.0, DT, 4.0, 2.2) + 10.0
	assert_almost_eq(out_step, in_step, 0.0001,
			"the rate cap applies equally to challenging out and retreating in")

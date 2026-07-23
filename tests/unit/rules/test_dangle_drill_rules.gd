extends GutTest

# DangleDrillRules — the Dangle Gauntlet's fixed serpentine, the gate-crossing
# geometry, and the par/medal scoring. Engine-free, so the whole course and
# every clear/miss decision is pinned here headless; dangle_gauntlet_manager.gd
# owns only the staging and the live clock.


func test_course_is_ordered_and_inside_the_rink() -> void:
	var gates: Array = DangleDrillRules.build_course()
	assert_eq(gates.size(), DangleDrillRules.gate_count(),
			"build_course must yield one gate per centre")
	assert_gt(gates.size(), 1, "a weave needs more than one gate")
	for g: DangleDrillRules.Gate in gates:
		assert_lt(absf(g.center.x), GameRules.INNER_HALF_WIDTH,
				"gate %s is outside the boards laterally" % g.center)
		assert_lt(absf(g.center.y), GameRules.INNER_HALF_LENGTH,
				"gate %s is outside the boards lengthwise" % g.center)
		# Clear of both nets so no gate sits behind a goal line.
		assert_lt(absf(g.center.y), GameRules.GOAL_LINE_Z,
				"gate %s is beyond a goal line" % g.center)


func test_gate_axes_are_unit_length() -> void:
	for g: DangleDrillRules.Gate in DangleDrillRules.build_course():
		assert_almost_eq(g.axis.length(), 1.0, 0.0001, "gate axis must be normalized")
		# The lateral is perpendicular to the axis.
		assert_almost_eq(g.axis.dot(g.lateral()), 0.0, 0.0001,
				"lateral must be perpendicular to the through-axis")


# A straight run down the middle of a gate clears it: the puck moves from the
# near side to the far side through the centre.
func test_forward_crossing_through_the_gap_clears() -> void:
	var g := DangleDrillRules.Gate.new(Vector2(0.0, 0.0), Vector2(0.0, -1.0), 0.75)
	var prev := Vector2(0.0, 0.5)   # near side (+ along axis is -Z here → this is near)
	var cur := Vector2(0.0, -0.5)   # far side
	assert_true(DangleDrillRules.crossed_gate(prev, cur, g),
			"a straight run through the centre should clear")


# Crossing outside the gap (past the post) does not clear even though the plane
# was crossed forward.
func test_crossing_outside_the_gap_misses() -> void:
	var g := DangleDrillRules.Gate.new(Vector2(0.0, 0.0), Vector2(0.0, -1.0), 0.75)
	var prev := Vector2(2.0, 0.5)
	var cur := Vector2(2.0, -0.5)
	assert_false(DangleDrillRules.crossed_gate(prev, cur, g),
			"crossing wide of the posts must not clear")


# Going backward through the gate (wrong direction) does not clear — you can't
# reverse through a checkpoint to bank it again.
func test_backward_crossing_does_not_clear() -> void:
	var g := DangleDrillRules.Gate.new(Vector2(0.0, 0.0), Vector2(0.0, -1.0), 0.75)
	var prev := Vector2(0.0, -0.5)  # starting on the far side
	var cur := Vector2(0.0, 0.5)    # moving back to the near side
	assert_false(DangleDrillRules.crossed_gate(prev, cur, g),
			"a backward crossing must not clear the gate")


# A tick that stays on one side of the plane never clears, however close.
func test_no_crossing_when_both_points_on_same_side() -> void:
	var g := DangleDrillRules.Gate.new(Vector2(0.0, 0.0), Vector2(0.0, -1.0), 0.75)
	assert_false(DangleDrillRules.crossed_gate(Vector2(0.0, 1.0), Vector2(0.0, 0.1), g),
			"approaching but not reaching the plane must not clear")


# The crossing point is interpolated at the plane, so a diagonal segment that
# only slips inside the gap AT the plane still clears (no tunnelling, no false
# miss from reading only the endpoint).
func test_diagonal_crossing_uses_interpolated_point() -> void:
	var g := DangleDrillRules.Gate.new(Vector2(0.0, 0.0), Vector2(0.0, -1.0), 0.75)
	# Endpoints both sit at x = 0.6 (inside the 0.75 gap) but the segment crosses
	# the z = 0 plane exactly at x = 0.6, which is inside — should clear.
	assert_true(DangleDrillRules.crossed_gate(Vector2(0.6, 0.4), Vector2(0.6, -0.4), g))
	# Now a segment whose plane-crossing lands at x = 1.0 (outside) must miss even
	# though its far endpoint (x = 0.5) is inside the gap.
	assert_false(DangleDrillRules.crossed_gate(Vector2(1.5, 0.5), Vector2(0.5, -0.5), g),
			"the gap test must use the plane-crossing point, not the endpoint")


func test_course_length_and_par_are_positive() -> void:
	assert_gt(DangleDrillRules.course_length(), 0.0)
	assert_almost_eq(DangleDrillRules.par_time(),
			DangleDrillRules.course_length() / DangleDrillRules.REFERENCE_DANGLE_SPEED,
			0.0001, "par must be length ÷ reference pace")


# Medal windows are ordered and gated on a clean sweep.
func test_medal_tiers_track_par_windows() -> void:
	var par: float = DangleDrillRules.par_time()
	var n: int = DangleDrillRules.gate_count()
	assert_eq(DangleDrillRules.medal(par * 1.0, n, n), DangleDrillRules.Medal.GOLD,
			"a near-par clean run is gold")
	assert_eq(DangleDrillRules.medal(par * DangleDrillRules.SILVER_PAR_MULT, n, n),
			DangleDrillRules.Medal.SILVER)
	assert_eq(DangleDrillRules.medal(par * DangleDrillRules.BRONZE_PAR_MULT, n, n),
			DangleDrillRules.Medal.BRONZE)
	assert_eq(DangleDrillRules.medal(par * 5.0, n, n), DangleDrillRules.Medal.NONE,
			"a slow finish earns no medal")


func test_bailed_gate_never_medals() -> void:
	var n: int = DangleDrillRules.gate_count()
	assert_eq(DangleDrillRules.medal(0.01, n - 1, n), DangleDrillRules.Medal.NONE,
			"missing a gate forfeits the medal however fast the run")

extends GutTest

# PassingDrillRules — the Passing drill's scenario pool and its no-repeat random
# sequencing. Pins the staging invariants (spots stay in-bounds, lanes are real
# passes, the pool spans the advertised variety) so a later edit that pushes a
# scenario off-rink or collapses a lane fails here.


func test_pool_has_enough_scenarios_for_no_repeat() -> void:
	var pool: Array = PassingDrillRules.scenarios()
	assert_gt(pool.size(), 1, "pick_next's no-repeat needs at least two scenarios")


func test_all_spots_stay_inside_the_rink() -> void:
	for s: PassingDrillRules.PassScenario in PassingDrillRules.scenarios():
		for spot: Vector2 in [s.passer, s.receiver, s.receiver_target]:
			assert_lt(absf(spot.x), GameRules.INNER_HALF_WIDTH,
					"%s spot x=%.1f is outside the boards" % [s.title, spot.x])
			assert_lt(absf(spot.y), GameRules.INNER_HALF_LENGTH,
					"%s spot z=%.1f is outside the boards" % [s.title, spot.y])


func test_every_lane_is_a_real_pass() -> void:
	# The passer and the receiver's start must be far enough apart that the rep
	# is an actual pass, not a hand-off — and the passer always sits up-ice (+z)
	# of the receiver so the lane runs toward the attacked -Z net.
	for s: PassingDrillRules.PassScenario in PassingDrillRules.scenarios():
		var gap: float = s.passer.distance_to(s.receiver)
		assert_gt(gap, 4.0, "%s is too short to be a pass (%.1f m)" % [s.title, gap])
		assert_gt(s.passer.y, s.receiver.y,
				"%s passer should sit up-ice of the receiver" % s.title)


func test_pool_spans_the_advertised_variety() -> void:
	var pool: Array = PassingDrillRules.scenarios()
	var moving: int = 0
	var walls: int = 0
	var stationary: int = 0
	for s: PassingDrillRules.PassScenario in pool:
		if s.receiver_moves():
			moving += 1
		else:
			stationary += 1
		if s.wall:
			walls += 1
	assert_gt(moving, 0, "no moving-receiver scenarios — the lead-the-skater case is missing")
	assert_gt(stationary, 0, "no stationary-receiver scenarios")
	assert_gt(walls, 0, "no saucer-wall scenarios")
	# The wall is meant to be occasional, not the norm.
	assert_lt(walls, pool.size(), "every scenario has a wall — saucer should be occasional")


func test_moving_receiver_flag_matches_the_route() -> void:
	for s: PassingDrillRules.PassScenario in PassingDrillRules.scenarios():
		var same: bool = s.receiver.is_equal_approx(s.receiver_target)
		assert_eq(s.receiver_moves(), not same,
				"%s receiver_moves() disagrees with its route" % s.title)


func test_pick_next_first_pick_stays_in_range() -> void:
	var n: int = PassingDrillRules.scenarios().size()
	for roll: int in n * 2:
		assert_between(PassingDrillRules.pick_next(-1, roll, n), 0, n - 1)


func test_pick_next_never_repeats_previous() -> void:
	var n: int = PassingDrillRules.scenarios().size()
	for prev: int in n:
		for roll: int in (n - 1) * 2:
			var idx: int = PassingDrillRules.pick_next(prev, roll, n)
			assert_ne(idx, prev, "prev=%d roll=%d repeated" % [prev, roll])
			assert_between(idx, 0, n - 1)


func test_pick_next_reaches_every_other_scenario() -> void:
	var n: int = PassingDrillRules.scenarios().size()
	for prev: int in n:
		var seen: Dictionary = {}
		for roll: int in n - 1:
			seen[PassingDrillRules.pick_next(prev, roll, n)] = true
		assert_eq(seen.size(), n - 1,
				"rolls from prev=%d should cover all other scenarios" % prev)


func test_pick_next_handles_degenerate_counts() -> void:
	assert_eq(PassingDrillRules.pick_next(-1, 0, 1), 0, "single-scenario pool returns 0")
	assert_eq(PassingDrillRules.pick_next(0, 5, 1), 0, "single-scenario pool ignores previous")
	assert_eq(PassingDrillRules.pick_next(-1, 3, 0), 0, "empty guard returns 0")

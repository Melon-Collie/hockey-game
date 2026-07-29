extends GutTest

# AIPossessionShapeTally — the shape-occupancy debug instrument.

const DZONE: int = AIPossessionState.State.DZONE
const OZONE: int = AIPossessionState.State.OZONE
const NEUTRAL: int = AIPossessionState.State.NEUTRAL

var _t: AIPossessionShapeTally


func before_each() -> void:
	_t = AIPossessionShapeTally.new()


func test_shares_sum_to_one_over_sampled_play() -> void:
	_t.accumulate(0, DZONE, 3.0)
	_t.accumulate(0, OZONE, 1.0)
	assert_almost_eq(_t.share(0, DZONE), 0.75, 0.0001, "3 of 4 s in DZONE")
	assert_almost_eq(_t.share(0, OZONE), 0.25, 0.0001, "1 of 4 s in OZONE")
	assert_almost_eq(_t.total_seconds(0), 4.0, 0.0001, "denominator is live play")


func test_a_held_shape_counts_as_one_spell() -> void:
	for _i: int in 100:
		_t.accumulate(0, DZONE, 0.00833)
	assert_eq(_t.entries(0, DZONE), 1,
			"100 consecutive samples of one shape is a single spell")


func test_re_entering_a_shape_opens_a_new_spell() -> void:
	_t.accumulate(0, DZONE, 1.0)
	_t.accumulate(0, NEUTRAL, 1.0)
	_t.accumulate(0, DZONE, 1.0)
	assert_eq(_t.entries(0, DZONE), 2, "left and came back — two spells")
	assert_almost_eq(_t.mean_spell_s(0, DZONE), 1.0, 0.0001, "2 s over 2 spells")


func test_teams_are_tallied_independently() -> void:
	_t.accumulate(0, DZONE, 2.0)
	_t.accumulate(1, OZONE, 2.0)
	assert_almost_eq(_t.share(0, DZONE), 1.0, 0.0001, "team 0 was all DZONE")
	assert_almost_eq(_t.share(1, DZONE), 0.0, 0.0001, "team 1 never was")
	assert_almost_eq(_t.share(1, OZONE), 1.0, 0.0001, "team 1 was all OZONE")


func test_an_empty_tally_never_divides_by_zero() -> void:
	assert_eq(_t.share(0, DZONE), 0.0, "no samples yet")
	assert_eq(_t.mean_spell_s(0, DZONE), 0.0, "never entered")
	assert_eq(_t.downgrade_share(0), 0.0, "no live play sampled")


func test_out_of_range_input_is_ignored() -> void:
	_t.accumulate(7, DZONE, 1.0)
	_t.accumulate(0, 99, 1.0)
	_t.accumulate(0, DZONE, 0.0)
	_t.accumulate(0, DZONE, -1.0)
	assert_eq(_t.total_seconds(0), 0.0,
			"a bad team, a bad state and a non-positive dt all no-op")


func test_coverage_downgrade_is_counted_alongside_the_shape() -> void:
	# The downgrade rides on TRANS_OD samples — it is time the D-zone coverage
	# was suppressed, so it must be visible without being a shape of its own.
	_t.accumulate(0, AIPossessionState.State.TRANS_OD, 1.0, true)
	_t.accumulate(0, AIPossessionState.State.TRANS_OD, 3.0, false)
	assert_almost_eq(_t.share(0, AIPossessionState.State.TRANS_OD), 1.0, 0.0001,
			"all four seconds are still TRANS_OD occupancy")
	assert_almost_eq(_t.downgrade_seconds(0), 1.0, 0.0001,
			"only the flagged second was a suppressed DZONE")
	assert_almost_eq(_t.downgrade_share(0), 0.25, 0.0001, "1 of 4 s suppressed")


func test_reset_clears_everything() -> void:
	_t.accumulate(0, DZONE, 5.0, true)
	_t.reset()
	assert_eq(_t.total_seconds(0), 0.0, "seconds cleared")
	assert_eq(_t.entries(0, DZONE), 0, "spells cleared")
	assert_eq(_t.downgrade_seconds(0), 0.0, "downgrade cleared")
	_t.accumulate(0, DZONE, 1.0)
	assert_eq(_t.entries(0, DZONE), 1,
			"the post-reset sample opens a fresh spell, not a continuation")


func test_dict_export_omits_unvisited_shapes() -> void:
	_t.accumulate(0, DZONE, 2.0)
	var d: Dictionary = _t.to_dict()
	var shapes: Dictionary = d["team_0"]["shapes"]
	assert_true(shapes.has("DZONE"), "a visited shape is exported")
	assert_false(shapes.has("OZONE"), "an unvisited shape is not noise in the dump")
	assert_almost_eq(float(d["team_0"]["live_seconds"]), 2.0, 0.0001,
			"live seconds carried for the denominator")


func test_every_state_has_a_name() -> void:
	for state: int in AIPossessionShapeTally.STATE_COUNT:
		assert_ne(AIPossessionShapeTally.state_name(state), "?",
				"State %d needs a display name — STATE_COUNT and the enum must agree"
				% state)

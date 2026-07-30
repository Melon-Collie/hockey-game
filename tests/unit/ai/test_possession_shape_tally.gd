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


# ── Transitions ──────────────────────────────────────────────────────────────

func test_the_first_sample_is_an_entry_but_not_a_transition() -> void:
	_t.accumulate(0, DZONE, 1.0)
	assert_eq(_t.entries(0, DZONE), 1, "it is a spell")
	assert_eq(_t.top_transitions(0).size(), 0,
			"a fresh tally's first shape came FROM nothing — no phantom edge")


func test_transitions_are_directional() -> void:
	_t.accumulate(0, DZONE, 1.0)
	_t.accumulate(0, OZONE, 1.0)
	assert_eq(_t.transitions(0, DZONE, OZONE), 1, "one DZONE -> OZONE")
	assert_eq(_t.transitions(0, OZONE, DZONE), 0, "and none the other way")


func test_an_oscillating_pair_counts_both_directions() -> void:
	for _i: int in 5:
		_t.accumulate(0, DZONE, 0.5)
		_t.accumulate(0, AIPossessionState.State.RETRIEVAL, 0.5)
	assert_eq(_t.transitions(0, DZONE, AIPossessionState.State.RETRIEVAL), 5,
			"five flips out")
	assert_eq(_t.transitions(0, AIPossessionState.State.RETRIEVAL, DZONE), 4,
			"and four back — the last spell hasn't been left yet")


func test_top_transitions_ranks_by_count_and_respects_the_limit() -> void:
	for _i: int in 4:
		_t.accumulate(0, DZONE, 0.5)
		_t.accumulate(0, AIPossessionState.State.RETRIEVAL, 0.5)
	_t.accumulate(0, OZONE, 1.0)
	var top: Array[Vector3i] = _t.top_transitions(0, 2)
	assert_eq(top.size(), 2, "limit honored")
	assert_eq(top[0].z, 4, "the busiest pair leads")
	assert_eq(top[0].x, DZONE, "and it is DZONE -> ...")
	assert_eq(top[0].y, AIPossessionState.State.RETRIEVAL, "... -> RETRIEVAL")


func test_transitions_survive_a_reset() -> void:
	_t.accumulate(0, DZONE, 1.0)
	_t.accumulate(0, OZONE, 1.0)
	_t.reset()
	assert_eq(_t.top_transitions(0).size(), 0, "edges cleared")
	_t.accumulate(0, OZONE, 1.0)
	_t.accumulate(0, DZONE, 1.0)
	assert_eq(_t.transitions(0, DZONE, OZONE), 0,
			"the pre-reset edge is gone, not merely outweighed")
	assert_eq(_t.transitions(0, OZONE, DZONE), 1, "only the new edge counts")


func test_out_of_range_transition_queries_are_safe() -> void:
	assert_eq(_t.transitions(9, DZONE, OZONE), 0, "bad team")
	assert_eq(_t.transitions(0, 99, OZONE), 0, "bad from-state")
	assert_eq(_t.transitions(0, DZONE, 99), 0, "bad to-state")
	assert_eq(_t.top_transitions(9).size(), 0, "bad team yields no edges")

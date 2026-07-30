extends GutTest

# AIBreakoutEpisodeTracker — the live counterpart of the breakout harness.
# Team 0 defends +Z, so "deep in our zone" is large positive z.

const TEAM: int = 0
const OWN_GOAL_Z: float = GameRules.GOAL_LINE_Z
const DEEP: float = GameRules.BLUE_LINE_Z + 6.0      # established in our zone
const OUT: float = GameRules.BLUE_LINE_Z - 2.0       # out past our blue line
const DT: float = 1.0 / 120.0

var _t: AIBreakoutEpisodeTracker


func before_each() -> void:
	_t = AIBreakoutEpisodeTracker.new()


# `carrier` is a team_id, or -1 for loose. Runs `n` samples at `z`.
func _run(z: float, carrier: int, n: int = 1, retrieval: bool = false) -> void:
	for _i: int in n:
		_t.tick(TEAM, OWN_GOAL_Z, Vector3(0.0, 0.0, z), carrier, DT, retrieval)


func _count(outcome: int) -> int:
	return _t.count(TEAM, outcome)


# ── Arming ───────────────────────────────────────────────────────────────────

func test_an_opponent_carrying_in_does_not_arm_an_episode() -> void:
	# That's defense, not a breakout attempt — counting it would bury the metric
	# in cycle possessions we never had.
	_run(DEEP, 1, 60)
	_run(OUT, 1, 5)
	assert_eq(_t.total(TEAM), 0, "no episode was ever opened")


func test_a_puck_on_the_blue_line_does_not_arm() -> void:
	# Inside our zone but not ESTABLISHED — the hysteresis band that stops a puck
	# sitting on the line opening and closing episodes every tick.
	_run(GameRules.BLUE_LINE_Z + 0.5, -1, 60)
	assert_eq(_t.total(TEAM), 0, "not past the establishment margin")


func test_a_loose_puck_deep_in_our_zone_arms_the_race() -> void:
	_run(DEEP, -1, 10)
	_run(OUT, TEAM, 1)
	assert_eq(_count(AIBreakoutEpisodeTracker.Outcome.CLEAN_EXIT), 1,
			"the retrieval race is a breakout attempt")


# ── Outcomes ─────────────────────────────────────────────────────────────────

func test_our_carrier_over_the_line_is_a_clean_exit() -> void:
	_run(DEEP, TEAM, 30)
	_run(OUT, TEAM, 1)
	assert_eq(_count(AIBreakoutEpisodeTracker.Outcome.CLEAN_EXIT), 1)
	assert_eq(_t.total(TEAM), 1, "and the episode closed")


func test_an_uncontrolled_puck_over_the_line_is_a_clear_exit() -> void:
	# Never touched by us: a rim-out from the initial race we didn't win.
	_run(DEEP, -1, 30)
	_run(OUT, -1, 1)
	assert_eq(_count(AIBreakoutEpisodeTracker.Outcome.CLEAR_EXIT), 1)


func test_a_release_of_ours_still_in_flight_counts_as_controlled() -> void:
	# The harness credits a breakout PASS in flight as a clean exit; the live
	# tracker approximates it from carrier history over CONTROLLED_RELEASE_S.
	_run(DEEP, TEAM, 30)          # we had it
	_run(DEEP, -1, 12)            # released — 0.1 s of flight
	_run(OUT, -1, 1)
	assert_eq(_count(AIBreakoutEpisodeTracker.Outcome.CLEAN_EXIT), 1,
			"our pass crossing the line is a controlled exit")


func test_a_long_dead_puck_crossing_out_is_only_a_clear_exit() -> void:
	# Past the release window, an uncarried puck is no longer our controlled play.
	_run(DEEP, TEAM, 30)
	_run(DEEP, -1, int(AIBreakoutEpisodeTracker.CONTROLLED_RELEASE_S * 120.0) + 30)
	_run(OUT, -1, 1)
	assert_eq(_count(AIBreakoutEpisodeTracker.Outcome.CLEAR_EXIT), 1,
			"the credit expires with the flight window")


func test_an_opponent_taking_it_in_our_zone_is_a_cough_up() -> void:
	_run(DEEP, TEAM, 30)
	_run(DEEP, 1, 1)
	assert_eq(_count(AIBreakoutEpisodeTracker.Outcome.COUGH_UP), 1)


func test_losing_the_initial_race_is_a_cough_up() -> void:
	# The harness counts this explicitly; so must we, or the two disagree on the
	# most common failure.
	_run(DEEP, -1, 5)
	_run(DEEP, 1, 1)
	assert_eq(_count(AIBreakoutEpisodeTracker.Outcome.COUGH_UP), 1)


func test_bottled_in_past_the_limit_is_a_timeout() -> void:
	_run(DEEP, TEAM, int(AIBreakoutEpisodeTracker.LIMIT_S * 120.0) + 5)
	assert_eq(_count(AIBreakoutEpisodeTracker.Outcome.TIMEOUT), 1)


func test_a_whistle_resolves_as_stoppage_not_timeout() -> void:
	# Live play has whistles the harness has no concept of. Folding them into
	# TIMEOUT would inflate a failure bucket with plays that simply ended.
	_run(DEEP, TEAM, 30)
	_t.close_on_stoppage()
	assert_eq(_count(AIBreakoutEpisodeTracker.Outcome.STOPPAGE), 1)
	assert_eq(_count(AIBreakoutEpisodeTracker.Outcome.TIMEOUT), 0)


func test_exit_beats_a_same_tick_cough() -> void:
	# Matches the harness's loop order: a puck that crosses out on the step it
	# changes hands counts as having left.
	_run(DEEP, TEAM, 30)
	_run(OUT, 1, 1)
	assert_eq(_t.total(TEAM), 1, "exactly one outcome")
	assert_eq(_count(AIBreakoutEpisodeTracker.Outcome.COUGH_UP), 0,
			"the exit is scored, not the turnover")


# ── Re-arming ────────────────────────────────────────────────────────────────

func test_a_cough_up_re_arms_when_we_get_it_back() -> void:
	# One long zone entry can hold several failed attempts, and each is a
	# separate breakout we didn't complete.
	for _i: int in 3:
		_run(DEEP, TEAM, 20)
		_run(DEEP, 1, 5)      # they take it — cough, episode closes
		_run(DEEP, -1, 5)     # loose again — re-arms
	assert_eq(_count(AIBreakoutEpisodeTracker.Outcome.COUGH_UP), 3,
			"three distinct failed attempts inside one zone entry")


func test_shares_and_totals_agree() -> void:
	_run(DEEP, TEAM, 20)
	_run(OUT, TEAM, 1)
	_run(DEEP, TEAM, 20)
	_run(DEEP, 1, 1)
	assert_eq(_t.total(TEAM), 2)
	assert_almost_eq(_t.share(TEAM, AIBreakoutEpisodeTracker.Outcome.CLEAN_EXIT),
			0.5, 0.0001)
	assert_almost_eq(_t.share(TEAM, AIBreakoutEpisodeTracker.Outcome.COUGH_UP),
			0.5, 0.0001)


# ── Bookkeeping ──────────────────────────────────────────────────────────────

func test_retrieval_is_credited_per_episode_not_per_tick() -> void:
	_run(DEEP, TEAM, 30, true)
	_run(OUT, TEAM, 1)
	assert_eq(_t.retrieval_episodes(TEAM), 1,
			"30 ticks of RETRIEVAL is one episode that saw it")


func test_teams_are_independent() -> void:
	# Team 1 defends -Z, so the same world puck is in the OTHER end for it.
	_t.tick(1, -GameRules.GOAL_LINE_Z, Vector3(0.0, 0.0, DEEP), -1, DT, false)
	assert_eq(_t.total(1), 0, "a puck in team 0's end is not team 1's episode")


func test_reset_clears_open_and_closed_state() -> void:
	_run(DEEP, TEAM, 20)
	_run(OUT, TEAM, 1)
	_run(DEEP, TEAM, 20)      # leaves an episode OPEN
	_t.reset()
	assert_eq(_t.total(TEAM), 0, "closed counts cleared")
	_t.close_on_stoppage()
	assert_eq(_t.total(TEAM), 0,
			"and the open episode was dropped, not carried past the reset")


func test_out_of_range_input_is_ignored() -> void:
	_t.tick(9, OWN_GOAL_Z, Vector3(0.0, 0.0, DEEP), -1, DT, false)
	_t.tick(TEAM, OWN_GOAL_Z, Vector3(0.0, 0.0, DEEP), -1, 0.0, false)
	assert_eq(_t.total(TEAM), 0, "bad team and a zero dt both no-op")
	assert_eq(_t.total(9), 0)


func test_dict_export_labels_the_mode() -> void:
	_run(DEEP, TEAM, 20)
	_run(OUT, TEAM, 1)
	var d: Dictionary = _t.to_dict("retrieval_off")
	assert_eq(d["mode"], "retrieval_off",
			"an unlabelled A/B dump is useless for a comparison")
	assert_eq(int(d["team_0"]["episodes"]), 1)
	assert_eq(int(d["team_0"]["outcomes"]["clean-exit"]["count"]), 1)


func test_every_outcome_has_a_name() -> void:
	for outcome: int in AIBreakoutEpisodeTracker.OUTCOME_COUNT:
		assert_ne(AIBreakoutEpisodeTracker.outcome_name(outcome), "?",
				"Outcome %d needs a name — OUTCOME_COUNT and the enum must agree"
				% outcome)

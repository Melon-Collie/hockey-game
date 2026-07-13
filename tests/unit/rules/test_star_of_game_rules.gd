extends GutTest

# StarOfGameRules — pure end-of-game star selection. Pins the scoring weights,
# the margin-scaled GWG bonus, the no-star nothing-game case, the losing-team
# discount + first-star restriction, and the tie order (effective score, then
# winning team over losing team, then earliest index) that keeps selection
# deterministic across peers.


func _stats(goals: int, assists: int, sog: int, hits: int, blocked: int,
		gwg: int = 0, takeaways: int = 0, giveaways: int = 0) -> PlayerStats:
	var s := PlayerStats.new()
	s.goals = goals
	s.assists = assists
	s.shots_on_goal = sog
	s.hits = hits
	s.shots_blocked = blocked
	s.game_winning_goals = gwg
	s.takeaways = takeaways
	s.giveaways = giveaways
	return s


func _no_losers(count: int) -> Array[bool]:
	var flags: Array[bool] = []
	flags.resize(count)
	flags.fill(false)
	return flags


# ── score ─────────────────────────────────────────────────────────────────────

func test_score_weights() -> void:
	assert_almost_eq(StarOfGameRules.score(_stats(1, 0, 0, 0, 0)), 3.0, 0.0001, "goal = 3")
	assert_almost_eq(StarOfGameRules.score(_stats(0, 1, 0, 0, 0)), 2.0, 0.0001, "assist = 2")
	assert_almost_eq(StarOfGameRules.score(_stats(0, 0, 1, 0, 0)), 0.5, 0.0001, "SOG = 0.5")
	assert_almost_eq(StarOfGameRules.score(_stats(0, 0, 0, 1, 0)), 0.25, 0.0001, "hit = 0.25")
	assert_almost_eq(StarOfGameRules.score(_stats(0, 0, 0, 0, 1)), 0.5, 0.0001, "block = 0.5")

func test_score_weights_turnovers() -> void:
	assert_almost_eq(StarOfGameRules.score(_stats(0, 0, 0, 0, 0, 0, 1, 0)), 0.5, 0.0001,
			"takeaway = 0.5")
	assert_almost_eq(StarOfGameRules.score(_stats(1, 0, 0, 0, 0, 0, 0, 2)), 2.5, 0.0001,
			"giveaways dock -0.25 each")

func test_score_floors_at_zero() -> void:
	# A turnover-riddled nothing game must read as zero (never stars), not
	# negative — and must not distort ranking below the zero-stat cutoff.
	assert_almost_eq(StarOfGameRules.score(_stats(0, 0, 0, 1, 0, 0, 0, 4)), 0.0, 0.0001)

func test_score_composite() -> void:
	# 2G 1A 4SOG 2H 1B 1TKA 1GVA = 6 + 2 + 2 + 0.5 + 0.5 + 0.5 - 0.25 = 11.25
	assert_almost_eq(StarOfGameRules.score(_stats(2, 1, 4, 2, 1, 0, 1, 1)), 11.25, 0.0001)

func test_score_gwg_bonus_scales_with_margin() -> void:
	var gwg_goal := _stats(1, 0, 0, 0, 0, 1)
	assert_almost_eq(StarOfGameRules.score(gwg_goal, 1), 5.0, 0.0001,
			"one-goal game: goal (3) + full close bonus (2)")
	assert_almost_eq(StarOfGameRules.score(gwg_goal, 2), 4.0, 0.0001,
			"two-goal margin: bonus halves")
	assert_almost_eq(StarOfGameRules.score(gwg_goal, 4), 3.5, 0.0001,
			"blowout: bonus fades")

func test_score_no_gwg_flag_means_no_bonus() -> void:
	assert_almost_eq(StarOfGameRules.score(_stats(1, 0, 0, 0, 0), 1), 3.0, 0.0001)


# ── gwg_bonus / game_winning_goal_index ───────────────────────────────────────

func test_gwg_bonus_zero_for_non_win_margins() -> void:
	assert_almost_eq(StarOfGameRules.gwg_bonus(0), 0.0, 0.0001, "draw has no GWG")
	assert_almost_eq(StarOfGameRules.gwg_bonus(-1), 0.0, 0.0001)

func test_game_winning_goal_index_is_nhl_definition() -> void:
	# 4-2 final: the winner's third goal (index 2) put them past the loser's total.
	assert_eq(StarOfGameRules.game_winning_goal_index(4, 2), 2)
	assert_eq(StarOfGameRules.game_winning_goal_index(1, 0), 0, "1-0: the only goal")
	assert_eq(StarOfGameRules.game_winning_goal_index(3, 2), 2, "OT-style one-goal final")

func test_game_winning_goal_index_absent_without_a_win() -> void:
	assert_eq(StarOfGameRules.game_winning_goal_index(2, 2), -1, "draw")
	assert_eq(StarOfGameRules.game_winning_goal_index(1, 3), -1, "caller mixed up the order")


# ── goalie_score ──────────────────────────────────────────────────────────────

func test_goalie_average_night_scores_zero() -> void:
	# GA exactly at the baseline expectation nets nothing — by construction an
	# average Mitts goalie night never stars.
	var shots: int = 10
	var expected_ga: int = int(shots * (1.0 - StarOfGameRules.BASELINE_SAVE_PCT))
	assert_almost_eq(StarOfGameRules.goalie_score(shots, expected_ga), 0.0, 0.0001)

func test_goalie_score_is_gsaa_in_goal_currency() -> void:
	# Goals saved above expectation convert at GOAL_WEIGHT — an outlier night
	# reads like a scorer's night.
	var shots: int = 20
	var ga: int = 2
	var gsaa: float = shots * (1.0 - StarOfGameRules.BASELINE_SAVE_PCT) - ga
	assert_almost_eq(StarOfGameRules.goalie_score(shots, ga),
			gsaa * StarOfGameRules.GOAL_WEIGHT, 0.0001)

func test_goalie_bad_night_floors_at_zero() -> void:
	assert_almost_eq(StarOfGameRules.goalie_score(10, 9), 0.0, 0.0001,
			"worse than expected never goes negative")

func test_goalie_no_shots_faced_scores_zero() -> void:
	assert_almost_eq(StarOfGameRules.goalie_score(0, 0), 0.0, 0.0001,
			"an untested goalie did no goaltending")

func test_goalie_shutout_bonus_needs_real_work() -> void:
	var shots: int = StarOfGameRules.SHUTOUT_MIN_SHOTS
	var base: float = shots * (1.0 - StarOfGameRules.BASELINE_SAVE_PCT) \
			* StarOfGameRules.GOAL_WEIGHT
	assert_almost_eq(StarOfGameRules.goalie_score(shots, 0),
			base + StarOfGameRules.SHUTOUT_BONUS, 0.0001,
			"a worked shutout earns the narrative bonus")
	var few: int = StarOfGameRules.SHUTOUT_MIN_SHOTS - 1
	var few_base: float = few * (1.0 - StarOfGameRules.BASELINE_SAVE_PCT) \
			* StarOfGameRules.GOAL_WEIGHT
	assert_almost_eq(StarOfGameRules.goalie_score(few, 0), few_base, 0.0001,
			"blanking a team that barely shot earns no bonus")


# ── pick_star ─────────────────────────────────────────────────────────────────

func test_highest_score_wins() -> void:
	var scores: Array[float] = [2.0, 7.5, 3.0]
	assert_eq(StarOfGameRules.pick_star(scores, _no_losers(3)), 1)

func test_nothing_game_has_no_star() -> void:
	var scores: Array[float] = [0.0, 0.0, 0.0]
	assert_eq(StarOfGameRules.pick_star(scores, _no_losers(3)), -1)

func test_empty_candidates_has_no_star() -> void:
	var scores: Array[float] = []
	assert_eq(StarOfGameRules.pick_star(scores, _no_losers(0)), -1)

func test_zero_stat_player_never_stars_even_alone() -> void:
	var scores: Array[float] = [0.0]
	assert_eq(StarOfGameRules.pick_star(scores, _no_losers(1)), -1)

func test_tie_takes_earliest_index() -> void:
	# No human-over-bot tie-break anymore: everyone competes on equal footing,
	# so a same-team tie resolves purely by candidate order (sorted peer id).
	var scores: Array[float] = [4.0, 4.0, 4.0]
	assert_eq(StarOfGameRules.pick_star(scores, _no_losers(3)), 0)


# ── pick_stars ────────────────────────────────────────────────────────────────

func test_stars_ranked_best_first() -> void:
	var scores: Array[float] = [2.0, 7.5, 3.0, 1.0]
	assert_eq(StarOfGameRules.pick_stars(scores, _no_losers(4)), [1, 2, 0] as Array[int])

func test_stars_skip_zero_stat_players() -> void:
	# Only two players registered a stat — the third star seat stays empty.
	var scores: Array[float] = [0.0, 5.0, 0.0, 2.0]
	assert_eq(StarOfGameRules.pick_stars(scores, _no_losers(4)), [1, 3] as Array[int])

func test_stars_nothing_game_is_empty() -> void:
	var scores: Array[float] = [0.0, 0.0]
	assert_eq(StarOfGameRules.pick_stars(scores, _no_losers(2)), [] as Array[int])

func test_stars_respects_max_count() -> void:
	var scores: Array[float] = [5.0, 4.0, 3.0, 2.0]
	assert_eq(StarOfGameRules.pick_stars(scores, _no_losers(4), 2), [0, 1] as Array[int])

func test_pick_star_matches_first_of_pick_stars() -> void:
	var scores: Array[float] = [2.0, 7.5, 3.0]
	assert_eq(StarOfGameRules.pick_star(scores, _no_losers(3)),
			StarOfGameRules.pick_stars(scores, _no_losers(3))[0])


# ── losing-team rules ─────────────────────────────────────────────────────────

func test_top_scoring_loser_cannot_take_first_star() -> void:
	# The loser's 8.0 discounts to 4.8 — still the best line, but the first
	# star must come from the winning team; the loser slots in second.
	var scores: Array[float] = [8.0, 4.0, 3.0]
	var losing: Array[bool] = [true, false, false]
	assert_eq(StarOfGameRules.pick_stars(scores, losing), [1, 0, 2] as Array[int])

func test_dominant_loser_outranks_a_winner_for_second_star() -> void:
	# 8.0 * 0.6 = 4.8 beats the second winner's 4.0.
	var scores: Array[float] = [5.0, 4.0, 8.0]
	var losing: Array[bool] = [false, false, true]
	assert_eq(StarOfGameRules.pick_stars(scores, losing), [0, 2, 1] as Array[int])

func test_modest_loser_is_discounted_below_winners() -> void:
	# 5.0 * 0.6 = 3.0 loses to both winners despite the higher raw line.
	var scores: Array[float] = [4.0, 3.5, 5.0]
	var losing: Array[bool] = [false, false, true]
	assert_eq(StarOfGameRules.pick_stars(scores, losing), [0, 1, 2] as Array[int])

func test_effective_tie_goes_to_the_winning_team() -> void:
	# At the second seat the loser's raw 5.0 discounts to exactly the winner's
	# 3.0: the winner takes it even from the later index — index order only
	# breaks same-team ties.
	var scores: Array[float] = [6.0, 5.0, 3.0]
	var losing: Array[bool] = [false, true, false]
	assert_eq(StarOfGameRules.pick_stars(scores, losing), [0, 2, 1] as Array[int])

func test_losers_take_the_podium_when_no_winner_has_a_stat() -> void:
	# Own-goal-only win: nobody on the winning team registered a stat, so the
	# first-star restriction relaxes rather than showing an empty podium.
	var scores: Array[float] = [0.0, 6.0, 2.0]
	var losing: Array[bool] = [false, true, true]
	assert_eq(StarOfGameRules.pick_stars(scores, losing), [1, 2] as Array[int])

func test_draw_disables_team_rules() -> void:
	# A draw passes all-false flags: no discount, no first-star restriction.
	var scores: Array[float] = [3.0, 5.0]
	assert_eq(StarOfGameRules.pick_stars(scores, _no_losers(2)), [1, 0] as Array[int])

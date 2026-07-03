extends GutTest

# StarOfGameRules — pure end-of-game star selection. Pins the scoring weights,
# the no-star nothing-game case, and the tie order (score, then human over
# bot, then earliest index) that keeps selection deterministic across peers.


func _stats(goals: int, assists: int, sog: int, hits: int, blocked: int) -> PlayerStats:
	var s := PlayerStats.new()
	s.goals = goals
	s.assists = assists
	s.shots_on_goal = sog
	s.hits = hits
	s.shots_blocked = blocked
	return s


# ── score ─────────────────────────────────────────────────────────────────────

func test_score_weights() -> void:
	assert_almost_eq(StarOfGameRules.score(_stats(1, 0, 0, 0, 0)), 3.0, 0.0001, "goal = 3")
	assert_almost_eq(StarOfGameRules.score(_stats(0, 1, 0, 0, 0)), 2.0, 0.0001, "assist = 2")
	assert_almost_eq(StarOfGameRules.score(_stats(0, 0, 1, 0, 0)), 0.5, 0.0001, "SOG = 0.5")
	assert_almost_eq(StarOfGameRules.score(_stats(0, 0, 0, 1, 0)), 0.25, 0.0001, "hit = 0.25")
	assert_almost_eq(StarOfGameRules.score(_stats(0, 0, 0, 0, 1)), 0.5, 0.0001, "block = 0.5")

func test_score_composite() -> void:
	# 2G 1A 4SOG 2H 1B = 6 + 2 + 2 + 0.5 + 0.5 = 11
	assert_almost_eq(StarOfGameRules.score(_stats(2, 1, 4, 2, 1)), 11.0, 0.0001)


# ── pick_star ─────────────────────────────────────────────────────────────────

func test_highest_score_wins() -> void:
	var scores: Array[float] = [2.0, 7.5, 3.0]
	var humans: Array[bool] = [true, true, true]
	assert_eq(StarOfGameRules.pick_star(scores, humans), 1)

func test_nothing_game_has_no_star() -> void:
	var scores: Array[float] = [0.0, 0.0, 0.0]
	var humans: Array[bool] = [true, true, true]
	assert_eq(StarOfGameRules.pick_star(scores, humans), -1)

func test_empty_candidates_has_no_star() -> void:
	var scores: Array[float] = []
	var humans: Array[bool] = []
	assert_eq(StarOfGameRules.pick_star(scores, humans), -1)

func test_zero_stat_player_never_stars_even_alone() -> void:
	var scores: Array[float] = [0.0]
	var humans: Array[bool] = [true]
	assert_eq(StarOfGameRules.pick_star(scores, humans), -1)

func test_human_beats_bot_on_tie() -> void:
	var scores: Array[float] = [5.0, 5.0]
	var humans: Array[bool] = [false, true]
	assert_eq(StarOfGameRules.pick_star(scores, humans), 1, "tied bot loses to human")

func test_bot_wins_outright_over_human() -> void:
	var scores: Array[float] = [3.0, 5.0]
	var humans: Array[bool] = [true, false]
	assert_eq(StarOfGameRules.pick_star(scores, humans), 1, "a clearly better bot still stars")

func test_tie_between_humans_takes_earliest_index() -> void:
	var scores: Array[float] = [4.0, 4.0, 4.0]
	var humans: Array[bool] = [true, true, true]
	assert_eq(StarOfGameRules.pick_star(scores, humans), 0)

func test_tie_between_bots_takes_earliest_index() -> void:
	var scores: Array[float] = [4.0, 4.0]
	var humans: Array[bool] = [false, false]
	assert_eq(StarOfGameRules.pick_star(scores, humans), 0)

func test_human_tiebreak_does_not_demote_existing_human() -> void:
	# A later bot tying a human leader must not steal the star.
	var scores: Array[float] = [4.0, 4.0]
	var humans: Array[bool] = [true, false]
	assert_eq(StarOfGameRules.pick_star(scores, humans), 0)

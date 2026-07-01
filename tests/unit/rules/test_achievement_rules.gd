extends GutTest

# AchievementRules — pure evaluation of the Achievements registry against a
# finished game's stats and a player's lifetime totals. Idempotent unlocking
# means callers may re-report earned ids, so these only assert membership.

func _stats(goals: int, assists: int, sog: int, hits: int, blocks: int) -> PlayerStats:
	var s := PlayerStats.new()
	s.goals = goals
	s.assists = assists
	s.shots_on_goal = sog
	s.hits = hits
	s.shots_blocked = blocks
	return s


func _ctx(outcome: String, gf: int, ga: int) -> Dictionary:
	return {"outcome": outcome, "goals_for": gf, "goals_against": ga}


# ── game_dict ────────────────────────────────────────────────────────────────
func test_game_dict_derives_points() -> void:
	var d := AchievementRules.game_dict(_stats(2, 3, 5, 1, 0))
	assert_eq(d["points"], 5)
	assert_eq(d["goals"], 2)
	assert_eq(d["assists"], 3)


# ── single-game thresholds ───────────────────────────────────────────────────
func test_hat_trick_unlocks_at_three_goals() -> void:
	var ids := AchievementRules.earned_game(
			AchievementRules.game_dict(_stats(3, 0, 4, 0, 0)), _ctx("win", 4, 2))
	assert_has(ids, Achievements.HAT_TRICK)


func test_two_goals_is_no_hat_trick() -> void:
	var ids := AchievementRules.earned_game(
			AchievementRules.game_dict(_stats(2, 0, 4, 0, 0)), _ctx("win", 4, 2))
	assert_does_not_have(ids, Achievements.HAT_TRICK)


func test_playmaker_unlocks_at_three_assists() -> void:
	var ids := AchievementRules.earned_game(
			AchievementRules.game_dict(_stats(0, 3, 0, 0, 0)), _ctx("draw", 3, 3))
	assert_has(ids, Achievements.PLAYMAKER)


func test_big_night_counts_goals_plus_assists() -> void:
	# 3 + 2 = 5 points trips Big Night without tripping Hat Trick's 3-goal bar
	# only on goals — 3 goals here also trips Hat Trick, so assert both fire.
	var ids := AchievementRules.earned_game(
			AchievementRules.game_dict(_stats(3, 2, 6, 0, 0)), _ctx("win", 5, 1))
	assert_has(ids, Achievements.BIG_NIGHT)
	assert_has(ids, Achievements.HAT_TRICK)


func test_big_night_from_mixed_line_without_hat_trick() -> void:
	var ids := AchievementRules.earned_game(
			AchievementRules.game_dict(_stats(2, 3, 4, 0, 0)), _ctx("win", 5, 1))
	assert_has(ids, Achievements.BIG_NIGHT)
	assert_does_not_have(ids, Achievements.HAT_TRICK)


func test_brick_wall_unlocks_at_five_blocks() -> void:
	var ids := AchievementRules.earned_game(
			AchievementRules.game_dict(_stats(0, 0, 0, 0, 5)), _ctx("loss", 1, 3))
	assert_has(ids, Achievements.BRICK_WALL)


func test_first_goal_unlocks_on_scoring_any_game() -> void:
	# Onboarding: single-game, so it fires the first game you score in (any mode).
	var ids := AchievementRules.earned_game(
			AchievementRules.game_dict(_stats(1, 0, 2, 0, 0)), _ctx("loss", 1, 3))
	assert_has(ids, Achievements.FIRST_GOAL)


func test_first_goal_not_awarded_without_a_goal() -> void:
	var ids := AchievementRules.earned_game(
			AchievementRules.game_dict(_stats(0, 2, 3, 1, 1)), _ctx("loss", 0, 2))
	assert_does_not_have(ids, Achievements.FIRST_GOAL)


# ── compound (special) ───────────────────────────────────────────────────────
func test_shutout_requires_win_and_zero_against() -> void:
	var ids := AchievementRules.earned_game(
			AchievementRules.game_dict(_stats(1, 0, 3, 0, 0)), _ctx("win", 2, 0))
	assert_has(ids, Achievements.SHUTOUT)


func test_first_win_unlocks_on_any_win() -> void:
	var ids := AchievementRules.earned_game(
			AchievementRules.game_dict(_stats(0, 0, 1, 0, 0)), _ctx("win", 1, 0))
	assert_has(ids, Achievements.FIRST_WIN)


func test_first_win_not_awarded_on_loss_or_draw() -> void:
	var loss := AchievementRules.earned_game(
			AchievementRules.game_dict(_stats(0, 0, 1, 0, 0)), _ctx("loss", 0, 1))
	assert_does_not_have(loss, Achievements.FIRST_WIN)
	var draw := AchievementRules.earned_game(
			AchievementRules.game_dict(_stats(0, 0, 1, 0, 0)), _ctx("draw", 1, 1))
	assert_does_not_have(draw, Achievements.FIRST_WIN)


func test_shutout_not_awarded_on_a_win_that_conceded() -> void:
	var ids := AchievementRules.earned_game(
			AchievementRules.game_dict(_stats(1, 0, 3, 0, 0)), _ctx("win", 3, 1))
	assert_does_not_have(ids, Achievements.SHUTOUT)


func test_shutout_not_awarded_on_a_scoreless_draw() -> void:
	# 0-0 is a draw, not a win, so no shutout even with 0 against.
	var ids := AchievementRules.earned_game(
			AchievementRules.game_dict(_stats(0, 0, 2, 0, 0)), _ctx("draw", 0, 0))
	assert_does_not_have(ids, Achievements.SHUTOUT)


# ── nothing earned ───────────────────────────────────────────────────────────
func test_quiet_game_earns_nothing() -> void:
	# No goal, no win — so no Lamp Lighter / W either.
	var ids := AchievementRules.earned_game(
			AchievementRules.game_dict(_stats(0, 1, 2, 1, 1)), _ctx("loss", 1, 4))
	assert_eq(ids.size(), 0)


# ── career thresholds ────────────────────────────────────────────────────────
func test_first_goal_is_not_a_career_achievement() -> void:
	# Reclassified to single-game onboarding — a lone career goal must NOT grant it
	# via the career path (it fires from the game instead).
	var ids := AchievementRules.earned_career({"goals": 1, "wins": 1, "games_played": 1})
	assert_does_not_have(ids, Achievements.FIRST_GOAL)
	assert_does_not_have(ids, Achievements.FIRST_WIN)


func test_sniper_unlocks_at_fifty_career_goals() -> void:
	var ids := AchievementRules.earned_career({"goals": 50})
	assert_has(ids, Achievements.SNIPER)


func test_veteran_unlocks_at_twenty_five_games() -> void:
	var ids := AchievementRules.earned_career({"games_played": 25})
	assert_has(ids, Achievements.VETERAN)


func test_missing_career_columns_count_as_zero() -> void:
	# A partial fetch (no goals column) must not crash or false-unlock.
	var ids := AchievementRules.earned_career({"games_played": 1})
	assert_does_not_have(ids, Achievements.VETERAN)
	assert_does_not_have(ids, Achievements.SNIPER)


func test_empty_career_earns_nothing() -> void:
	assert_eq(AchievementRules.earned_career({}).size(), 0)


# ── registry / event lookups ─────────────────────────────────────────────────
func test_event_threshold_and_id_for_big_hit() -> void:
	assert_eq(Achievements.event_id("big_hit"), Achievements.FREIGHT_TRAIN)
	assert_gt(Achievements.event_threshold("big_hit"), 0.0)


func test_unknown_event_fails_closed() -> void:
	assert_eq(Achievements.event_id("nope"), "")
	assert_eq(Achievements.event_threshold("nope"), -1.0)


func test_all_ids_are_unique() -> void:
	var seen: Dictionary = {}
	for entry in Achievements.ALL:
		var id: String = entry["id"]
		assert_false(seen.has(id), "duplicate achievement id: %s" % id)
		seen[id] = true

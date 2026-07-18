extends GutTest

# TurnoverRules — pure classification of a possession change into
# takeaway / giveaway / nothing.

func test_same_team_recovery_is_nothing() -> void:
	assert_eq(TurnoverRules.classify(0, 0, false, false), TurnoverRules.NONE)


func test_no_prior_owner_is_nothing() -> void:
	assert_eq(TurnoverRules.classify(-1, 1, false, false), TurnoverRules.NONE)


func test_opponent_recovers_a_fumble_is_a_giveaway() -> void:
	assert_eq(TurnoverRules.classify(0, 1, false, false), TurnoverRules.GIVEAWAY)


func test_opponent_recovers_after_a_strip_is_a_takeaway() -> void:
	assert_eq(TurnoverRules.classify(0, 1, true, false), TurnoverRules.TAKEAWAY)


func test_shot_takes_precedence_over_strip() -> void:
	# If both flags are set, the shot wins — recovering a shot is always a
	# rebound (no turnover), never a takeaway, even if a graze also registered.
	assert_eq(TurnoverRules.classify(0, 1, true, true), TurnoverRules.NONE)


func test_opponent_recovers_a_rebound_is_nothing() -> void:
	# A shot (saved or missed) recovered by the other team is a rebound, neither
	# a giveaway to the shooter nor a takeaway to the recoverer.
	assert_eq(TurnoverRules.classify(0, 1, false, true), TurnoverRules.NONE)

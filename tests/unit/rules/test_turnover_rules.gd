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


func test_strip_takes_precedence_over_shot() -> void:
	# If both flags are set, the active strip wins — it's a takeaway, not a wash.
	assert_eq(TurnoverRules.classify(0, 1, true, true), TurnoverRules.TAKEAWAY)


func test_opponent_recovers_a_rebound_is_nothing() -> void:
	# Shot on goal recovered by the other team is a rebound, not a giveaway.
	assert_eq(TurnoverRules.classify(0, 1, false, true), TurnoverRules.NONE)

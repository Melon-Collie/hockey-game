extends GutTest

# PossessionRules — pure establishment test: a touch becomes possession by
# holding the puck, or instantly by making a deliberate play with it.

func test_short_hold_is_not_established() -> void:
	assert_false(PossessionRules.is_established(
			PossessionRules.ESTABLISH_HOLD_S - 0.1, false))


func test_hold_at_threshold_is_established() -> void:
	assert_true(PossessionRules.is_established(
			PossessionRules.ESTABLISH_HOLD_S, false))


func test_deliberate_play_establishes_instantly() -> void:
	# A one-touch pass proves control regardless of hold time.
	assert_true(PossessionRules.is_established(0.0, true))


func test_zero_hold_without_play_is_a_touch() -> void:
	assert_false(PossessionRules.is_established(0.0, false))

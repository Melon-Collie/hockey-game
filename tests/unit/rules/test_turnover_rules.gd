extends GutTest

# TurnoverRules — pure classification of a possession change into
# takeaway / giveaway / nothing, plus the dump/pass release geometry.

func test_same_team_recovery_is_nothing() -> void:
	assert_eq(TurnoverRules.classify(0, 0, false, false, false), TurnoverRules.NONE)


func test_no_prior_owner_is_nothing() -> void:
	assert_eq(TurnoverRules.classify(-1, 1, false, false, false), TurnoverRules.NONE)


func test_opponent_recovers_a_fumble_is_a_giveaway() -> void:
	assert_eq(TurnoverRules.classify(0, 1, false, false, false), TurnoverRules.GIVEAWAY)


func test_opponent_recovers_after_a_strip_is_a_takeaway() -> void:
	assert_eq(TurnoverRules.classify(0, 1, true, false, false), TurnoverRules.TAKEAWAY)


func test_shot_takes_precedence_over_strip() -> void:
	# If both flags are set, the shot wins — recovering a shot is always a
	# rebound (no turnover), never a takeaway, even if a graze also registered.
	assert_eq(TurnoverRules.classify(0, 1, true, true, false), TurnoverRules.NONE)


func test_opponent_recovers_a_rebound_is_nothing() -> void:
	# A shot (saved or missed) recovered by the other team is a rebound, neither
	# a giveaway to the shooter nor a takeaway to the recoverer.
	assert_eq(TurnoverRules.classify(0, 1, false, true, false), TurnoverRules.NONE)


func test_opponent_recovers_a_dump_is_nothing() -> void:
	# A dump/clear/rim retrieved by the other team is a deliberate surrender to
	# open ice, not a giveaway to the dumper.
	assert_eq(TurnoverRules.classify(0, 1, false, false, true), TurnoverRules.NONE)


func test_dump_takes_precedence_over_strip() -> void:
	# A deliberate surrender outranks a coincident graze, same as a shot.
	assert_eq(TurnoverRules.classify(0, 1, true, false, true), TurnoverRules.NONE)


# ── Dump vs pass geometry (is_dump_release) ──────────────────────────────────

func test_release_with_no_teammate_ahead_is_a_dump() -> void:
	# Fired up-ice into open space, teammates all behind the puck → a clear.
	var teammates: Array[Vector2] = [Vector2(0, -5), Vector2(4, -8)]
	assert_true(TurnoverRules.is_dump_release(
			Vector2(0, 0), Vector2(0, 20), teammates))


func test_release_aimed_at_a_teammate_is_a_pass() -> void:
	# A teammate sits in the flight corridor ahead — this is a pass (giveaway-
	# eligible if picked off), not a dump.
	var teammates: Array[Vector2] = [Vector2(0.5, 10)]
	assert_false(TurnoverRules.is_dump_release(
			Vector2(0, 0), Vector2(0, 20), teammates))


func test_teammate_off_the_flight_line_is_still_a_dump() -> void:
	# A teammate ahead but well wide of the launch line is not a target.
	var teammates: Array[Vector2] = [Vector2(8, 10)]
	assert_true(TurnoverRules.is_dump_release(
			Vector2(0, 0), Vector2(0, 20), teammates))


func test_teammate_beyond_max_pass_distance_is_a_dump() -> void:
	# On-line but past any plausible pass reach → a dump, not a stretch pass.
	var teammates: Array[Vector2] = [Vector2(0, 40)]
	assert_true(TurnoverRules.is_dump_release(
			Vector2(0, 0), Vector2(0, 20), teammates))


func test_zero_launch_is_not_a_dump() -> void:
	# A whistle drop / no meaningful launch is never classified as a dump.
	var teammates: Array[Vector2] = [Vector2(0, 10)]
	assert_false(TurnoverRules.is_dump_release(
			Vector2(0, 0), Vector2.ZERO, teammates))

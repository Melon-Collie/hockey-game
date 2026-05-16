extends GutTest

# ColorVoteRules — vote tallying and team-color resolution from per-player votes.
# Color identity is an integer slot index into TeamColorRegistry.

const _ALL_SLOTS: Array[int] = [0, 1, 2, 3, 4, 5, 6, 7]
const _DEFAULT_HOME: int = 0  # "blueberry"
const _DEFAULT_AWAY: int = 1  # "pomegranate"

func _rng(seed: int = 1) -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = seed
	return r


# ── tally_votes ──────────────────────────────────────────────────────────────

func test_tally_empty_votes_returns_empty_dict() -> void:
	var t: Dictionary = ColorVoteRules.tally_votes([] as Array[int])
	assert_true(t.is_empty())

func test_tally_counts_each_color() -> void:
	var votes: Array[int] = [2, 2, 7]  # lemon, lemon, lime
	var t: Dictionary = ColorVoteRules.tally_votes(votes)
	assert_eq(int(t[2]), 2)
	assert_eq(int(t[7]), 1)


# ── pick_winner ──────────────────────────────────────────────────────────────

func test_pick_winner_empty_tally_returns_neg_one() -> void:
	assert_eq(ColorVoteRules.pick_winner({}, _rng()), -1)

func test_pick_winner_clear_majority() -> void:
	var t: Dictionary = ColorVoteRules.tally_votes([2, 2, 7] as Array[int])
	assert_eq(ColorVoteRules.pick_winner(t, _rng()), 2)

func test_pick_winner_three_way_tie_picks_one_of_them() -> void:
	var t: Dictionary = ColorVoteRules.tally_votes([2, 7, 6] as Array[int])
	var winner: int = ColorVoteRules.pick_winner(t, _rng(42))
	assert_true(winner == 2 or winner == 7 or winner == 6,
			"random tiebreak must return one of the tied slots, got %d" % winner)


# ── resolve_team_colors ──────────────────────────────────────────────────────

func test_resolve_empty_votes_falls_back_to_defaults() -> void:
	var result: Array[int] = ColorVoteRules.resolve_team_colors(
			[] as Array[int], [] as Array[int], _ALL_SLOTS,
			_DEFAULT_HOME, _DEFAULT_AWAY, _rng())
	assert_eq(result[0], _DEFAULT_HOME)
	assert_eq(result[1], _DEFAULT_AWAY)

func test_resolve_majority_wins_per_team() -> void:
	var home: Array[int] = [2, 2, 7]  # lemon, lemon, lime
	var away: Array[int] = [6, 4, 6]  # fig, papaya, fig
	var result: Array[int] = ColorVoteRules.resolve_team_colors(
			home, away, _ALL_SLOTS, _DEFAULT_HOME, _DEFAULT_AWAY, _rng())
	assert_eq(result[0], 2)
	assert_eq(result[1], 6)

func test_resolve_three_way_tie_picks_random_voted_color() -> void:
	var votes: Array[int] = [2, 7, 6]
	var result: Array[int] = ColorVoteRules.resolve_team_colors(
			votes, [] as Array[int], _ALL_SLOTS,
			_DEFAULT_HOME, _DEFAULT_AWAY, _rng(7))
	assert_true(result[0] == 2 or result[0] == 7 or result[0] == 6,
			"home should resolve to one of the three tied slots, got %d" % result[0])

func test_resolve_clash_away_rerolls_from_remaining_votes() -> void:
	# Home wins lemon (2v1). Away also wins lemon (2v1) but has fig as a
	# fallback in its tally, so away should land on fig.
	var home: Array[int] = [2, 2, 7]
	var away: Array[int] = [2, 2, 6]
	var result: Array[int] = ColorVoteRules.resolve_team_colors(
			home, away, _ALL_SLOTS, _DEFAULT_HOME, _DEFAULT_AWAY, _rng())
	assert_eq(result[0], 2)
	assert_eq(result[1], 6, "away clash should re-roll to remaining vote")

func test_resolve_clash_with_no_alt_votes_picks_from_palette() -> void:
	# Both teams unanimously vote lemon. Away has no other voted slot, so it
	# must pick uniformly from the palette excluding lemon.
	var home: Array[int] = [2, 2, 2]
	var away: Array[int] = [2, 2, 2]
	var result: Array[int] = ColorVoteRules.resolve_team_colors(
			home, away, _ALL_SLOTS, _DEFAULT_HOME, _DEFAULT_AWAY, _rng(3))
	assert_eq(result[0], 2)
	assert_ne(result[1], 2, "away must differ when forced to re-roll")
	assert_true(_ALL_SLOTS.has(result[1]), "away pick must be a valid palette slot")

func test_resolve_default_clash_when_no_votes_uses_distinct_defaults() -> void:
	# No votes at all → defaults are used. Defaults are already distinct,
	# so no re-roll is needed.
	var result: Array[int] = ColorVoteRules.resolve_team_colors(
			[] as Array[int], [] as Array[int], _ALL_SLOTS,
			_DEFAULT_HOME, _DEFAULT_AWAY, _rng())
	assert_eq(result[0], _DEFAULT_HOME)
	assert_eq(result[1], _DEFAULT_AWAY)

func test_resolve_default_clash_forces_away_reroll() -> void:
	# Defaults are the same and no votes exist — away must re-roll from the
	# palette since no away tally exists at all.
	var result: Array[int] = ColorVoteRules.resolve_team_colors(
			[] as Array[int], [] as Array[int], _ALL_SLOTS,
			_DEFAULT_HOME, _DEFAULT_HOME, _rng(11))
	assert_eq(result[0], _DEFAULT_HOME)
	assert_ne(result[1], _DEFAULT_HOME)


# ── sticky resolution ───────────────────────────────────────────────────────

func test_pick_winner_sticky_keeps_previous_when_still_tied() -> void:
	var t: Dictionary = ColorVoteRules.tally_votes([2, 7, 6] as Array[int])
	# Three-way tie: 2, 7, 6. Sticky on 7 should keep 7 regardless of rng seed.
	for seed: int in [1, 2, 3, 4, 5]:
		var winner: int = ColorVoteRules.pick_winner_sticky(t, 7, _rng(seed))
		assert_eq(winner, 7, "sticky should hold previous on seed %d" % seed)

func test_pick_winner_sticky_rerolls_when_previous_no_longer_tied() -> void:
	# 2 now has 2 votes, 7/6 only 1. Previous 7 is no longer a leader.
	var t: Dictionary = ColorVoteRules.tally_votes([2, 2, 7, 6] as Array[int])
	assert_eq(ColorVoteRules.pick_winner_sticky(t, 7, _rng()), 2)

func test_pick_winner_sticky_ignores_unknown_previous() -> void:
	var t: Dictionary = ColorVoteRules.tally_votes([2, 2, 7] as Array[int])
	# Previous was a slot nobody voted for — should fall through to majority.
	assert_eq(ColorVoteRules.pick_winner_sticky(t, 4, _rng()), 2)

func test_resolve_sticky_holds_home_winner_through_unrelated_vote_change() -> void:
	# Three-way tie on home. Pick once, then change ONE away vote. Home's
	# winner must remain identical because its tied set didn't change.
	var home: Array[int] = [2, 7, 6]
	var first: Array[int] = ColorVoteRules.resolve_team_colors(
			home, [4] as Array[int], _ALL_SLOTS,
			_DEFAULT_HOME, _DEFAULT_AWAY, _rng(7))
	var second: Array[int] = ColorVoteRules.resolve_team_colors(
			home, [5] as Array[int], _ALL_SLOTS,
			_DEFAULT_HOME, _DEFAULT_AWAY, _rng(99),
			first[0], first[1])
	assert_eq(second[0], first[0], "sticky home should not re-roll on unrelated change")

func test_resolve_sticky_clash_drops_previous_when_it_collides_with_home() -> void:
	# Both teams unanimously vote 2. Previous away was 2 (now equal to home),
	# so sticky must NOT keep it — must re-roll to a different slot.
	var votes: Array[int] = [2, 2, 2]
	var result: Array[int] = ColorVoteRules.resolve_team_colors(
			votes, votes, _ALL_SLOTS,
			_DEFAULT_HOME, _DEFAULT_AWAY, _rng(5),
			2, 2)
	assert_eq(result[0], 2)
	assert_ne(result[1], 2)

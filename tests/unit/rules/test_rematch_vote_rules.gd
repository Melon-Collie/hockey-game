extends GutTest

# RematchVoteRules — the end-of-game "play again" vote. One pool, two flavors:
# REMATCH and LOBBY both count toward unanimity; any LOBBY vote escalates the
# resolved destination to the lobby.

const NONE := RematchVoteRules.Choice.NONE
const REMATCH := RematchVoteRules.Choice.REMATCH
const LOBBY := RematchVoteRules.Choice.LOBBY


func _votes(entries: Dictionary) -> Dictionary[int, int]:
	var typed: Dictionary[int, int] = {}
	for k: int in entries:
		typed[k] = entries[k]
	return typed


# ── count_voted ──────────────────────────────────────────────────────────────

func test_count_ignores_withdrawn_votes() -> void:
	var votes := _votes({1: REMATCH, 2: NONE, 3: LOBBY})
	assert_eq(RematchVoteRules.count_voted(votes), 2)

func test_count_empty_pool_is_zero() -> void:
	assert_eq(RematchVoteRules.count_voted(_votes({})), 0)


# ── resolve ──────────────────────────────────────────────────────────────────

func test_resolve_waits_for_unanimity() -> void:
	var votes := _votes({1: REMATCH, 2: REMATCH})
	assert_eq(RematchVoteRules.resolve(votes, 3), NONE)

func test_resolve_all_rematch_is_rematch() -> void:
	var votes := _votes({1: REMATCH, 2: REMATCH, 3: REMATCH})
	assert_eq(RematchVoteRules.resolve(votes, 3), REMATCH)

func test_resolve_any_lobby_vote_escalates_to_lobby() -> void:
	var votes := _votes({1: REMATCH, 2: LOBBY, 3: REMATCH})
	assert_eq(RematchVoteRules.resolve(votes, 3), LOBBY)

func test_resolve_all_lobby_is_lobby() -> void:
	var votes := _votes({1: LOBBY, 2: LOBBY})
	assert_eq(RematchVoteRules.resolve(votes, 2), LOBBY)

func test_resolve_withdrawn_vote_blocks_unanimity() -> void:
	# A NONE entry (voted, then unvoted) must not count toward the bar.
	var votes := _votes({1: REMATCH, 2: NONE, 3: LOBBY})
	assert_eq(RematchVoteRules.resolve(votes, 3), NONE)

func test_resolve_zero_voters_never_resolves() -> void:
	# Degenerate pool (e.g. everyone is a spectator) must not fire a rematch.
	assert_eq(RematchVoteRules.resolve(_votes({}), 0), NONE)

func test_resolve_solo_voter_is_instant() -> void:
	# Offline / single-human room: one vote is unanimity — the button acts
	# immediately, matching the old host-only instant behavior.
	assert_eq(RematchVoteRules.resolve(_votes({1: LOBBY}), 1), LOBBY)
	assert_eq(RematchVoteRules.resolve(_votes({1: REMATCH}), 1), REMATCH)

func test_resolve_extra_votes_beyond_total_still_resolve() -> void:
	# A vote landing in the same frame a spectator swap shrinks the pool
	# (count > total) still resolves rather than deadlocking.
	var votes := _votes({1: REMATCH, 2: REMATCH, 3: REMATCH})
	assert_eq(RematchVoteRules.resolve(votes, 2), REMATCH)

class_name RematchVoteRules

# Pure rule layer: resolves the end-of-game "play again" vote. No engine APIs.
#
# There is ONE vote pool with two flavors: REMATCH ("run it back right here")
# and LOBBY ("play again, but through the lobby so we can reshuffle first").
# Both count toward the same unanimity bar — the group is agreeing to keep
# playing together, the flavor only picks the route. Splitting them into two
# separate unanimous polls would deadlock any mixed room (3 rematch + 2 lobby
# reaches neither bar); merging them can't, and the lobby is the safe superset
# outcome (the host can immediately relaunch the same matchup from it), so a
# single LOBBY voice escalates the destination for everyone.

enum Choice {
	NONE,     # no vote cast (or vote withdrawn)
	REMATCH,  # instant reset, same teams/settings
	LOBBY,    # back to the shared lobby to reconfigure first
}


# Number of live (non-NONE) votes in the pool — the tally the HUD displays.
static func count_voted(votes: Dictionary[int, int]) -> int:
	var count: int = 0
	for v: int in votes.values():
		if v != Choice.NONE:
			count += 1
	return count


static func has_lobby_vote(votes: Dictionary[int, int]) -> bool:
	for v: int in votes.values():
		if v == Choice.LOBBY:
			return true
	return false


# The vote's outcome: NONE until every eligible voter has cast a live vote,
# then LOBBY if anyone asked for the lobby, else REMATCH. `total_voters` is
# the eligible pool size (connected players minus spectators), supplied by
# the caller — a total of 0 never resolves.
static func resolve(votes: Dictionary[int, int], total_voters: int) -> Choice:
	if total_voters <= 0 or count_voted(votes) < total_voters:
		return Choice.NONE
	return Choice.LOBBY if has_lobby_vote(votes) else Choice.REMATCH

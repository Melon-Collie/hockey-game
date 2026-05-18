class_name ColorVoteRules

# Pure rule layer: resolves per-player color votes into a final color pair for
# home and away teams. No engine APIs; deterministic given a seeded RNG so it
# is fully unit-testable.
#
# Votes are integer color slots (TeamColorRegistry index). Tiebreaks can be
# sticky: if the caller passes a `previous_*` slot and it is still tied for
# the lead, it wins again. Keeps the live lobby UI from flickering on every
# unrelated vote change.

const _NO_PREVIOUS: int = -1


# Counts how many times each color slot appears in `votes`.
static func tally_votes(votes: Array[int]) -> Dictionary:
	var tally: Dictionary = {}
	for v: int in votes:
		tally[v] = int(tally.get(v, 0)) + 1
	return tally


# Picks the slot with the most votes. Ties are broken uniformly at random
# via `rng`. Returns -1 if the tally is empty so callers can substitute a
# default.
static func pick_winner(tally: Dictionary, rng: RandomNumberGenerator) -> int:
	return pick_winner_sticky(tally, _NO_PREVIOUS, rng)


# Sticky variant of pick_winner. If `previous` is non-negative AND it is
# still tied for the lead, returns `previous` (no random roll). Otherwise
# behaves like pick_winner: clear majority wins; ties picked uniformly at
# random.
static func pick_winner_sticky(tally: Dictionary, previous: int,
		rng: RandomNumberGenerator) -> int:
	if tally.is_empty():
		return _NO_PREVIOUS
	var best: int = 0
	for v: int in tally.values():
		if v > best:
			best = v
	var leaders: Array[int] = []
	for k: int in tally.keys():
		if int(tally[k]) == best:
			leaders.append(k)
	if previous != _NO_PREVIOUS and leaders.has(previous):
		return previous
	if leaders.size() == 1:
		return leaders[0]
	return leaders[rng.randi_range(0, leaders.size() - 1)]


# Resolves both teams' colors from their vote pools. Returns [home_slot, away_slot].
#
# Rules:
#   • Tally each team's votes; the most-voted slot wins. Ties broken randomly,
#     unless the previous winner is still in the tied set (then it stays).
#   • Empty pool → fall back to the supplied default for that team.
#   • If home and away both resolve to the same slot, the AWAY team re-rolls
#     by re-running pick_winner over its tally with the home pick excluded.
#     If no away votes remain after exclusion, away is picked uniformly from
#     `all_color_slots` minus home's pick (preferring `previous_away` when it
#     is still a valid choice).
static func resolve_team_colors(
		home_votes: Array[int],
		away_votes: Array[int],
		all_color_slots: Array[int],
		default_home_slot: int,
		default_away_slot: int,
		rng: RandomNumberGenerator,
		previous_home: int = _NO_PREVIOUS,
		previous_away: int = _NO_PREVIOUS) -> Array[int]:
	var home_tally: Dictionary = tally_votes(home_votes)
	var away_tally: Dictionary = tally_votes(away_votes)

	var home_slot: int = pick_winner_sticky(home_tally, previous_home, rng)
	if home_slot == _NO_PREVIOUS:
		home_slot = default_home_slot

	var away_slot: int = pick_winner_sticky(away_tally, previous_away, rng)
	if away_slot == _NO_PREVIOUS:
		away_slot = default_away_slot

	if away_slot == home_slot:
		var filtered: Dictionary = {}
		for k: int in away_tally.keys():
			if k != home_slot:
				filtered[k] = away_tally[k]
		# Don't keep a previous away that just collided with home.
		var sticky_for_reroll: int = _NO_PREVIOUS if previous_away == home_slot else previous_away
		away_slot = pick_winner_sticky(filtered, sticky_for_reroll, rng)
		if away_slot == _NO_PREVIOUS:
			var pool: Array[int] = []
			for c: int in all_color_slots:
				if c != home_slot:
					pool.append(c)
			if pool.is_empty():
				away_slot = home_slot
			elif sticky_for_reroll != _NO_PREVIOUS and pool.has(sticky_for_reroll):
				away_slot = sticky_for_reroll
			else:
				away_slot = pool[rng.randi_range(0, pool.size() - 1)]

	var result: Array[int] = [home_slot, away_slot]
	return result

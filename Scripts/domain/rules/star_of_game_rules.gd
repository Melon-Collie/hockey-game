class_name StarOfGameRules

# Pure selection math for the end-of-game Three Stars. No engine deps.
#
# Every machine computes the stars locally from the replicated stat counters,
# so selection must be deterministic: callers pass candidates in a stable
# order (sorted peer id) and ties resolve by explicit rules, never iteration
# accident. Up to three stars, arena-style; a zero-stat player never stars,
# so a quiet game legitimately produces fewer than three — scarcity is what
# keeps a star meaning something at 3v3.
#
# Scoring weights goals over assists over the volume stats; hits and blocks
# keep a defensive grinder in the running during a low-scoring game.
const GOAL_WEIGHT: float = 3.0
const ASSIST_WEIGHT: float = 2.0
const SOG_WEIGHT: float = 0.5
const BLOCK_WEIGHT: float = 0.5
const HIT_WEIGHT: float = 0.25
# Scores within this margin count as tied (weights are clean fractions, so
# genuine ties are exact — the epsilon just guards float summation order).
const TIE_EPSILON: float = 0.001


static func score(stats: PlayerStats) -> float:
	return stats.goals * GOAL_WEIGHT \
			+ stats.assists * ASSIST_WEIGHT \
			+ stats.shots_on_goal * SOG_WEIGHT \
			+ stats.shots_blocked * BLOCK_WEIGHT \
			+ stats.hits * HIT_WEIGHT


# Returns the index of the first star, or -1 when nobody registered a
# single counting stat (a nothing game has no star). Kept as the single-star
# entry point (tests pin it); ranking rules live in pick_stars.
static func pick_star(scores: Array[float], is_human: Array[bool]) -> int:
	var stars: Array[int] = pick_stars(scores, is_human, 1)
	return stars[0] if not stars.is_empty() else -1


# Ranked star indices, best first, up to max_count entries. Zero-stat players
# never star, so the result can be shorter than max_count (or empty for a
# nothing game). Tie order at each rank: higher score, then human over bot
# (a bot only outranks a human when it outright outplayed them), then earliest
# index (callers pass sorted-peer-id order, so this is stable across machines).
static func pick_stars(scores: Array[float], is_human: Array[bool],
		max_count: int = 3) -> Array[int]:
	var picked: Array[int] = []
	while picked.size() < max_count:
		var best_idx: int = -1
		var best_score: float = 0.0
		var best_human: bool = false
		for i: int in scores.size():
			if picked.has(i):
				continue
			var s: float = scores[i]
			if s <= TIE_EPSILON:
				continue  # zero-stat players never star
			var wins: bool = false
			if best_idx == -1 or s > best_score + TIE_EPSILON:
				wins = true
			elif absf(s - best_score) <= TIE_EPSILON and is_human[i] and not best_human:
				wins = true
			if wins:
				best_idx = i
				best_score = s
				best_human = is_human[i]
		if best_idx == -1:
			break
		picked.append(best_idx)
	return picked

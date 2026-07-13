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
# Approximates how the real vote behaves:
#   - Stat line first: goals over assists over the volume stats; hits and
#     blocks keep a defensive grinder in the running in a low-scoring game.
#   - The game-winning goal is worth extra, and worth the most when the game
#     was close — an OT/one-goal winner is the story of the night, a blowout
#     GWG is trivia (gwg_bonus decays with the final margin).
#   - Stars go to the winners: losing-team stat lines are discounted at
#     selection (LOSING_TEAM_MULT), so only a genuinely dominant performance
#     in a loss cracks the podium — and even then never as the first star.
#   - Humans and bots compete on equal footing; there is no human tie-break.
const GOAL_WEIGHT: float = 3.0
const ASSIST_WEIGHT: float = 2.0
const SOG_WEIGHT: float = 0.5
const BLOCK_WEIGHT: float = 0.5
const HIT_WEIGHT: float = 0.25
# Game-winning-goal bonus in a one-goal game; the effective bonus is
# GWG_CLOSE_BONUS / margin, so it halves at two goals and fades in blowouts.
const GWG_CLOSE_BONUS: float = 2.0
# Selection-time discount on a losing-team stat line ("you still lost"). A
# loser must outscore a winning-team candidate by 1/LOSING_TEAM_MULT to take
# a star seat off them, which is the "did really well" bar — and it makes two
# losing-team stars in one game naturally rare rather than hard-capped.
const LOSING_TEAM_MULT: float = 0.6
# Scores within this margin count as tied (weights are clean fractions, so
# genuine ties are exact — the epsilon just guards float summation order).
const TIE_EPSILON: float = 0.001


static func score(stats: PlayerStats, goal_margin: int = 0) -> float:
	return stats.goals * GOAL_WEIGHT \
			+ stats.assists * ASSIST_WEIGHT \
			+ stats.shots_on_goal * SOG_WEIGHT \
			+ stats.shots_blocked * BLOCK_WEIGHT \
			+ stats.hits * HIT_WEIGHT \
			+ stats.game_winning_goals * gwg_bonus(goal_margin)


# Extra credit for scoring the game-winner, scaled by how close the game
# ended: full bonus at a one-goal margin (OT winners are always margin 1),
# decaying hyperbolically as the margin opens up. Margin <= 0 (a draw, or a
# caller with no margin to report) means no GWG existed.
static func gwg_bonus(goal_margin: int) -> float:
	if goal_margin <= 0:
		return 0.0
	return GWG_CLOSE_BONUS / float(goal_margin)


# Index into the winning team's goals (in scoring order) of the game-winning
# goal — NHL definition: the goal that put the winner one past the loser's
# final total, i.e. their (losing_score + 1)th. Returns -1 for a non-win.
static func game_winning_goal_index(winning_score: int, losing_score: int) -> int:
	if winning_score <= losing_score:
		return -1
	return losing_score


# Returns the index of the first star, or -1 when nobody registered a
# single counting stat (a nothing game has no star). Kept as the single-star
# entry point (tests pin it); ranking rules live in pick_stars.
static func pick_star(scores: Array[float], on_losing_team: Array[bool]) -> int:
	var stars: Array[int] = pick_stars(scores, on_losing_team, 1)
	return stars[0] if not stars.is_empty() else -1


# Ranked star indices, best first, up to max_count entries. Zero-stat players
# never star, so the result can be shorter than max_count (or empty for a
# nothing game). Losing-team candidates compete at their discounted score and
# are barred from the first star (unless no winning-team player registered a
# stat at all — an own-goal-only win — where an empty podium would be worse).
# A draw passes all-false flags, which disables both team rules. Tie order at
# each rank: higher effective score, then winning team over losing team, then
# earliest index (callers pass sorted-peer-id order, so this is stable across
# machines).
static func pick_stars(scores: Array[float], on_losing_team: Array[bool],
		max_count: int = 3) -> Array[int]:
	var picked: Array[int] = []
	while picked.size() < max_count:
		var losers_allowed: bool = not picked.is_empty()
		var best_idx: int = _best_remaining(scores, on_losing_team, picked, losers_allowed)
		if best_idx == -1 and not losers_allowed:
			best_idx = _best_remaining(scores, on_losing_team, picked, true)
		if best_idx == -1:
			break
		picked.append(best_idx)
	return picked


static func _best_remaining(scores: Array[float], on_losing_team: Array[bool],
		picked: Array[int], losers_allowed: bool) -> int:
	var best_idx: int = -1
	var best_score: float = 0.0
	var best_losing: bool = false
	for i: int in scores.size():
		if picked.has(i):
			continue
		if scores[i] <= TIE_EPSILON:
			continue  # zero-stat players never star
		if on_losing_team[i] and not losers_allowed:
			continue
		var s: float = scores[i] * (LOSING_TEAM_MULT if on_losing_team[i] else 1.0)
		var wins: bool = false
		if best_idx == -1 or s > best_score + TIE_EPSILON:
			wins = true
		elif absf(s - best_score) <= TIE_EPSILON and best_losing and not on_losing_team[i]:
			wins = true
		if wins:
			best_idx = i
			best_score = s
			best_losing = on_losing_team[i]
	return best_idx

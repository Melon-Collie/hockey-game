class_name AchievementService extends RefCounted
## Application-layer glue between the achievement domain (Achievements /
## AchievementRules) and Steam (via SteamManager). Owned by GameManager:
## evaluated at game-over and poked from a couple of live gameplay hooks. The
## domain decides *what* is earned; this decides *when* to ask Steam, and
## de-dupes so the same unlock isn't re-issued.

# Ids unlocked this session, so a re-evaluation (every game-over) doesn't
# re-issue setAchievement/storeStats for one already done. Steam tolerates the
# repeat, but storeStats hits the network — skip it. Persists across games in a
# session by design (the service outlives a single match).
var _unlocked_this_session: Dictionary = {}


# Single-game + compound achievements, evaluated the moment a game ends. Reads
# only this game's stats, so it runs in any mode (including offline vs bots) —
# Steam availability is enforced downstream in SteamManager.
func evaluate_single_game(stats: PlayerStats, outcome: String,
		goals_for: int, goals_against: int) -> void:
	if stats == null:
		return
	var game: Dictionary = AchievementRules.game_dict(stats)
	var ctx: Dictionary = {
		"outcome": outcome, "goals_for": goals_for, "goals_against": goals_against,
	}
	for id in AchievementRules.earned_game(game, ctx):
		unlock(id)


# Career-threshold achievements. Lifetime totals live in Supabase, so fetch them
# (async) and evaluate on the callback. Call only from the online, shared-stats
# game-over path. `this_game` is merged into the fetched totals so crossing a
# threshold unlocks on the game you cross it — the row CareerStatsReporter just
# posted hasn't aggregated into career_totals yet.
func evaluate_career(reporter: CareerStatsReporter, this_game: PlayerStats,
		outcome: String) -> void:
	if reporter == null or this_game == null or not SteamManager.is_available:
		return
	reporter.fetch_totals(func(totals: Dictionary) -> void:
		var merged: Dictionary = _merge_game_into_career(totals, this_game, outcome)
		for id in AchievementRules.earned_career(merged):
			unlock(id)
	)


# Live hook: the local player just landed a body check of `impulse` magnitude
# (the same units SkaterVFX / body_check_rules use). Fires the "big hit"
# achievement the instant it happens rather than waiting for game-over.
func on_local_hit(impulse: float) -> void:
	var threshold: float = Achievements.event_threshold("big_hit")
	if threshold >= 0.0 and impulse >= threshold:
		unlock(Achievements.event_id("big_hit"))


# Issue an unlock, skipping work for anything already earned this session or in a
# prior session (Steam remembers across launches).
func unlock(id: String) -> void:
	if id.is_empty() or _unlocked_this_session.has(id):
		return
	_unlocked_this_session[id] = true
	if SteamManager.is_achievement_unlocked(id):
		return
	SteamManager.unlock_achievement(id)


# Adds this game's contribution to the fetched lifetime totals. Only the columns
# a career condition can target are summed; missing columns start at 0.
func _merge_game_into_career(totals: Dictionary, this_game: PlayerStats,
		outcome: String) -> Dictionary:
	var merged: Dictionary = totals.duplicate()
	merged["goals"] = int(totals.get("goals", 0)) + this_game.goals
	merged["assists"] = int(totals.get("assists", 0)) + this_game.assists
	merged["points"] = int(totals.get("points", 0)) + this_game.goals + this_game.assists
	merged["shots_on_goal"] = int(totals.get("shots_on_goal", 0)) + this_game.shots_on_goal
	merged["hits"] = int(totals.get("hits", 0)) + this_game.hits
	merged["shots_blocked"] = int(totals.get("shots_blocked", 0)) + this_game.shots_blocked
	merged["games_played"] = int(totals.get("games_played", 0)) + 1
	if outcome == "win":
		merged["wins"] = int(totals.get("wins", 0)) + 1
	return merged

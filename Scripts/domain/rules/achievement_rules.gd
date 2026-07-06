class_name AchievementRules
## Pure evaluation of the Achievements registry — given a finished game's stats
## (and, separately, a player's lifetime totals), returns the ids that should be
## unlocked. No engine, no Steam, no state: fully unit-testable. Unlocking is
## idempotent on Steam's side, so callers may re-report an already-earned id
## without harm; that lets these run every game-over without bookkeeping.

# Builds the canonical single-game stat dict the "game" conditions read. Keeps
# the field names that Achievements.cond.field refers to in one place, and
# derives `points` (goals + assists) so a condition can target it directly.
static func game_dict(stats: PlayerStats) -> Dictionary:
	return {
		"goals": stats.goals,
		"assists": stats.assists,
		"points": stats.goals + stats.assists,
		"shots_on_goal": stats.shots_on_goal,
		"hits": stats.hits,
		"shots_blocked": stats.shots_blocked,
		"hits_taken": stats.hits_taken,
		"takeaways": stats.takeaways,
		"giveaways": stats.giveaways,
		"faceoff_wins": stats.faceoff_wins,
	}


# Ids earned from this single game. `game` is game_dict(); `ctx` carries the
# game-level outcome fields the "special" conditions need:
#   { "outcome": "win"/"loss"/"draw", "goals_for": int, "goals_against": int }
static func earned_game(game: Dictionary, ctx: Dictionary) -> Array[String]:
	var out: Array[String] = []
	for entry in Achievements.ALL:
		var cond: Dictionary = entry["cond"]
		var kind: String = cond.get("kind", "")
		if kind == "game":
			if int(game.get(cond["field"], 0)) >= int(cond["min"]):
				out.append(String(entry["id"]))
		elif kind == "special":
			if _special_met(String(cond["key"]), game, ctx):
				out.append(String(entry["id"]))
	return out


# Ids earned from lifetime totals. `career` is a career_totals row (Supabase) as
# a Dictionary of column -> value; missing columns count as 0 so a partial fetch
# simply under-reports (delays an unlock) rather than crashing.
static func earned_career(career: Dictionary) -> Array[String]:
	var out: Array[String] = []
	for entry in Achievements.ALL:
		var cond: Dictionary = entry["cond"]
		if cond.get("kind", "") != "career":
			continue
		if int(career.get(cond["field"], 0)) >= int(cond["min"]):
			out.append(String(entry["id"]))
	return out


# Compound game-over predicates. Add a branch here only when a new achievement
# uses cond.kind == "special".
static func _special_met(key: String, _game: Dictionary, ctx: Dictionary) -> bool:
	match key:
		"win":
			return String(ctx.get("outcome", "")) == "win"
		"shutout":
			return String(ctx.get("outcome", "")) == "win" \
					and int(ctx.get("goals_against", 1)) == 0
	return false

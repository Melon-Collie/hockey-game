class_name SteamStatRecorder extends RefCounted
## Mirrors a finished game's stats into Steam User Stats (the SteamStats registry)
## and reads the running career totals back out. Owned by GameManager, called at
## game-over for online games. The increment math is pure + static (testable
## without Steam); the read-modify-write and totals read go through SteamManager,
## which no-ops when Steam is unavailable.

# Per-game deltas to apply, { stat_id: amount }. Pure — derived from this game's
# PlayerStats and outcome, no Steam access — so it unit-tests directly.
static func increments(stats: PlayerStats, outcome: String) -> Dictionary:
	var out: Dictionary = {}
	if stats == null:
		return out
	var game: Dictionary = AchievementRules.game_dict(stats)
	for entry in SteamStats.ALL:
		var inc: Dictionary = entry["inc"]
		var delta: int = 0
		match String(inc.get("kind", "")):
			"stat":
				delta = int(game.get(inc["field"], 0))
			"win":
				delta = 1 if outcome == "win" else 0
			"game":
				delta = 1
		out[String(entry["id"])] = delta
	return out


# Add this game's deltas to the stored Steam stats and flush. No-op without Steam.
func record_game(stats: PlayerStats, outcome: String) -> void:
	if not SteamManager.is_available or stats == null:
		return
	var deltas: Dictionary = increments(stats, outcome)
	for id: String in deltas:
		var delta: int = deltas[id]
		if delta == 0:
			continue
		SteamManager.set_stat_int(id, SteamManager.get_stat_int(id) + delta)
	SteamManager.store_stats()


# Current career totals from Steam, keyed by career-totals column name (goals,
# assists, hits, wins, games_played, …) — the shape AchievementRules.earned_career
# expects. `points` is derived for parity with the Supabase view. Empty without
# Steam (caller then unlocks nothing, which is correct).
func totals() -> Dictionary:
	var out: Dictionary = {}
	if not SteamManager.is_available:
		return out
	for entry in SteamStats.ALL:
		out[String(entry["key"])] = SteamManager.get_stat_int(String(entry["id"]))
	out["points"] = int(out.get("goals", 0)) + int(out.get("assists", 0))
	return out

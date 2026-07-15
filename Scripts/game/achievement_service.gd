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


# Career-threshold achievements, evaluated against current lifetime totals.
# `career_totals` comes from Steam User Stats (SteamStatRecorder.totals), already
# updated with this game — so crossing a threshold unlocks on the game you cross
# it, with no backend round-trip and no merge guesswork. Empty totals (Steam
# unavailable) unlock nothing, which is correct.
func evaluate_career(career_totals: Dictionary) -> void:
	for id in AchievementRules.earned_career(career_totals):
		unlock(id)


# Live hook: the local player just landed a body check of `impulse` magnitude
# (the same units SkaterVFX / body_check_rules use). Fires the "big hit"
# achievement the instant it happens rather than waiting for game-over.
func on_local_hit(impulse: float) -> void:
	var threshold: float = Achievements.event_threshold("big_hit")
	if threshold >= 0.0 and impulse >= threshold:
		unlock(Achievements.event_id("big_hit"))


# Live hook: the player just finished the whole tutorial course (every
# TutorialRegistry entry complete — GameManager checks that before calling).
# A meta-progression event, so it intentionally bypasses the game-over sweep and
# its free-play/drill gate: the course is played in tutorial mode.
func on_tutorials_complete() -> void:
	unlock(Achievements.event_id("tutorials_done"))


# Live hook: the player applied a custom build in the free-play picker
# (NetworkManager.local_attributes_changed). Also outside the game-over sweep —
# build edits happen in free play, where the achievement gate is closed.
func on_build_edited() -> void:
	unlock(Achievements.event_id("build_edited"))


# Issue an unlock, skipping work for anything already earned this session or in a
# prior session (Steam remembers across launches).
func unlock(id: String) -> void:
	if id.is_empty() or _unlocked_this_session.has(id):
		return
	_unlocked_this_session[id] = true
	if SteamManager.is_achievement_unlocked(id):
		return
	SteamManager.unlock_achievement(id)

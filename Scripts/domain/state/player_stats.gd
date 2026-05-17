class_name PlayerStats

var goals: int = 0
var assists: int = 0
var shots_on_goal: int = 0
var hits: int = 0
var shots_blocked: int = 0
# Tracked locally on every peer (game_manager._physics_process) rather than
# host-authoritative + broadcast like the counters above. Each peer's own
# value is what ships to Supabase, since report() runs per-peer at game-over.
# Intentionally absent from to_array/from_array — would only carry stale
# zeros across the wire and isn't shown on the live scoreboard.
var toi_seconds: float = 0.0

func to_array() -> Array:
	return [goals, assists, shots_on_goal, hits, shots_blocked]

static func from_array(a: Array) -> PlayerStats:
	var s := PlayerStats.new()
	s.goals = a[0]
	s.assists = a[1]
	s.shots_on_goal = a[2]
	s.hits = a[3]
	s.shots_blocked = a[4]
	return s

func to_dict() -> Dictionary:
	return {
		"goals": goals,
		"assists": assists,
		"shots_on_goal": shots_on_goal,
		"hits": hits,
		"shots_blocked": shots_blocked,
		"toi_seconds": roundi(toi_seconds),
	}

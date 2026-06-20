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
	s.update_from_array(a)
	return s

# In-place update from the wire array, PRESERVING toi_seconds. Time-on-ice is
# tracked locally per-peer (see the field doc above) and never crosses the wire,
# so reassigning record.stats to a fresh from_array() object on every stats
# packet would wipe a client's accumulated TOI to zero. Clients route through
# this instead so the local count survives each decode.
func update_from_array(a: Array) -> void:
	goals = a[0]
	assists = a[1]
	shots_on_goal = a[2]
	hits = a[3]
	shots_blocked = a[4]

func to_dict() -> Dictionary:
	return {
		"goals": goals,
		"assists": assists,
		"shots_on_goal": shots_on_goal,
		"hits": hits,
		"shots_blocked": shots_blocked,
		"toi_seconds": roundi(toi_seconds),
	}

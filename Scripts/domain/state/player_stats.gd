class_name PlayerStats

var goals: int = 0
var assists: int = 0
var shots_on_goal: int = 0
var hits: int = 0
var shots_blocked: int = 0
# Extended per-player stats (host-authoritative, broadcast like the counters
# above). NHL-derived definitions, made deterministic for Mitts (see
# GameManager stat detection):
#   hits_taken   — body checks absorbed (mirror of `hits`).
#   takeaways    — puck actively stripped from an opponent (poke / stick-lift).
#   giveaways    — self-inflicted turnover: lost the puck to the other team in
#                  open play WITHOUT being stripped/hit (fumble / bad pass).
#   faceoff_wins — credited to a team's centre (slot 0) when that team wins the
#                  draw (first to recover the puck off the drop).
var hits_taken: int = 0
var takeaways: int = 0
var giveaways: int = 0
var faceoff_wins: int = 0
# Tracked locally on every peer (game_manager._physics_process) rather than
# host-authoritative + broadcast like the counters above. Each peer's own
# value is what ships to Supabase, since report() runs per-peer at game-over.
# Intentionally absent from to_array/from_array — would only carry stale
# zeros across the wire and isn't shown on the live scoreboard.
var toi_seconds: float = 0.0

# Wire order is append-only: new fields go at the END so an index never shifts.
# STATS_PLAYER_RECORD_SIZE (WorldStateCodec) = 1 (peer_id) + this array's size,
# and PROTOCOL_VERSION is bumped whenever this grows.
func to_array() -> Array:
	return [goals, assists, shots_on_goal, hits, shots_blocked,
			hits_taken, takeaways, giveaways, faceoff_wins]

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
	hits_taken = a[5]
	takeaways = a[6]
	giveaways = a[7]
	faceoff_wins = a[8]

func to_dict() -> Dictionary:
	return {
		"goals": goals,
		"assists": assists,
		"shots_on_goal": shots_on_goal,
		"hits": hits,
		"shots_blocked": shots_blocked,
		"hits_taken": hits_taken,
		"takeaways": takeaways,
		"giveaways": giveaways,
		"faceoff_wins": faceoff_wins,
		"toi_seconds": roundi(toi_seconds),
	}

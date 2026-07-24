class_name ShotEvent extends RefCounted
## One resolved shot attempt (analytics plan B1) — the record behind the shot map,
## the xG-flow chart, and the career heatmap. Assembled host-side by
## ShotOnGoalTracker when a shot resolves and buffered by AdvancedStatsTracker.
## Pure data; RefCounted (allocated a few times per minute at shot resolution, not
## a hot path). Position is the release point in rink coordinates; the outcome and
## type are the shot map's categorical channels.

enum Outcome { GOAL, SAVED, MISSED, BLOCKED }
# Coarse type: what the tracker can tell for free. WRIST/SLAP aren't separable at
# the release signal (both collapse to the same puck_release_requested), so an
# ordinary shot is SHOT; the meaningful tags a shot map wants — one-timers and
# redirects — are ONE_TIMER and TIP.
enum ShotType { SHOT, ONE_TIMER, TIP }

const _OUTCOME_KEY: Array[String] = ["goal", "saved", "missed", "blocked"]
const _TYPE_KEY: Array[String] = ["shot", "one_timer", "tip"]

var shooter_peer: int = -1
var team_id: int = -1
var x: float = 0.0          # release position, rink coordinates
var z: float = 0.0
var xg: float = 0.0         # the geometric xG (stored even when blocked, for the map)
var outcome: int = Outcome.MISSED
var shot_type: int = ShotType.SHOT
var on_net: bool = false
var period: int = 1
var clock_s: float = 0.0    # period time remaining at the shot (for the xG-flow x-axis)


static func make(shooter_peer: int, team_id: int, pos: Vector3, xg: float,
		outcome: int, shot_type: int, on_net: bool, period: int, clock_s: float) -> ShotEvent:
	var e := ShotEvent.new()
	e.shooter_peer = shooter_peer
	e.team_id = team_id
	e.x = pos.x
	e.z = pos.z
	e.xg = xg
	e.outcome = outcome
	e.shot_type = shot_type
	e.on_net = on_net
	e.period = period
	e.clock_s = clock_s
	return e


func outcome_key() -> String:
	return _OUTCOME_KEY[outcome] if outcome >= 0 and outcome < _OUTCOME_KEY.size() else "missed"


func type_key() -> String:
	return _TYPE_KEY[shot_type] if shot_type >= 0 and shot_type < _TYPE_KEY.size() else "shot"


# Supabase row (shot_events table). steam_id + game_id are stamped by the poster
# (GameManager maps shooter_peer → steam at game-over); everything else is here.
func to_dict() -> Dictionary:
	return {
		"team_id": team_id,
		"x": snappedf(x, 0.01),
		"z": snappedf(z, 0.01),
		"xg": snappedf(xg, 0.001),
		"outcome": outcome_key(),
		"shot_type": type_key(),
		"on_net": on_net,
		"period": period,
		"clock_s": snappedf(clock_s, 0.1),
	}

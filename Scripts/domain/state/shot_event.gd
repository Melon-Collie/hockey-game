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


# Params carry the p_ prefix so they don't shadow the fields they assign (the
# engine analyser flags that; gdlint doesn't see it).
static func make(p_shooter_peer: int, p_team_id: int, pos: Vector3, p_xg: float,
		p_outcome: int, p_shot_type: int, p_on_net: bool, p_period: int,
		p_clock_s: float) -> ShotEvent:
	var e := ShotEvent.new()
	e.shooter_peer = p_shooter_peer
	e.team_id = p_team_id
	e.x = pos.x
	e.z = pos.z
	e.xg = p_xg
	e.outcome = p_outcome
	e.shot_type = p_shot_type
	e.on_net = p_on_net
	e.period = p_period
	e.clock_s = p_clock_s
	return e


# ── Wire format ───────────────────────────────────────────────────────────────
# The host holds the authoritative per-game shot log; it ships the whole list to
# clients at game-over so every peer can render its own post-game shot map. Flat
# fixed-size arrays (one per event) — the payload is a few dozen events once per
# match, so compactness matters less than being obviously correct.

const WIRE_SIZE: int = 10


func to_array() -> Array:
	return [shooter_peer, team_id, x, z, xg, outcome, shot_type, on_net,
			period, clock_s]


# Returns null on a malformed record (version skew / forged payload) so the
# batch decoder can skip it rather than script-error mid-walk.
static func from_array(a: Array) -> ShotEvent:
	if a.size() != WIRE_SIZE:
		return null
	var e := ShotEvent.new()
	e.shooter_peer = a[0]
	e.team_id = a[1]
	e.x = a[2]
	e.z = a[3]
	e.xg = a[4]
	e.outcome = a[5]
	e.shot_type = a[6]
	e.on_net = a[7]
	e.period = a[8]
	e.clock_s = a[9]
	return e


# Rebuild from a stored row — the Supabase `shot_events` shape (to_dict's keys,
# where outcome/type are text) rather than the wire array. Used to regenerate the
# analytics views for a past game. Unknown keys default rather than erroring, so
# a row written by an older build still renders.
static func from_row(row: Dictionary) -> ShotEvent:
	var e := ShotEvent.new()
	e.team_id = int(row.get("team_id", 0))
	e.x = float(row.get("x", 0.0))
	e.z = float(row.get("z", 0.0))
	e.xg = float(row.get("xg", 0.0))
	e.outcome = maxi(_OUTCOME_KEY.find(String(row.get("outcome", "missed"))), 0)
	e.shot_type = maxi(_TYPE_KEY.find(String(row.get("shot_type", "shot"))), 0)
	e.on_net = bool(row.get("on_net", false))
	e.period = int(row.get("period", 1))
	e.clock_s = float(row.get("clock_s", 0.0))
	return e


static func decode_rows(rows: Array) -> Array[ShotEvent]:
	var out: Array[ShotEvent] = []
	for r: Variant in rows:
		if r is Dictionary:
			out.append(ShotEvent.from_row(r as Dictionary))
	return out


static func encode_list(events: Array[ShotEvent]) -> Array:
	var out: Array = []
	for e: ShotEvent in events:
		out.append(e.to_array())
	return out


# Skips malformed records; never returns nulls.
static func decode_list(data: Array) -> Array[ShotEvent]:
	var out: Array[ShotEvent] = []
	for row: Variant in data:
		if row is Array:
			var e: ShotEvent = ShotEvent.from_array(row as Array)
			if e != null:
				out.append(e)
	return out


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

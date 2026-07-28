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

# ── Release CONTEXT (the goalie's situation, sampled at the release tick) ─────
# Location alone cannot be compared to a public xG model, because a fitted model
# has the context baked INTO its location term: an NHL shot from 3 m is mostly
# rebounds and scrambles, so "3 m" silently carries "chaos". Stripping that out
# and comparing the residue measures nothing. These columns put it back, so an
# empirical model can be fitted from our own play and the comparison becomes
# like-for-like by construction.
#
# All of it is already computed at release for the goalie's own read; this only
# stops throwing it away. Defaults are the "no goalie resolved" case (drills,
# empty net), which reads as a set, unscreened keeper — deliberately the neutral
# assumption rather than a missing-data sentinel a query would have to know about.
var goalie_stance: int = -1        # GoalieStateMachine.State, -1 when unresolved
var goalie_unset: float = 0.0      # 0 square and stopped … 1 fully in motion
var goalie_radius: float = 0.0     # challenge radius from goal centre (m)
var goalie_x: float = 0.0          # lateral position (rink coords)
var screen_delay: float = 0.0      # s the shot was hidden from him, 0 = clear sight
var shooter_speed: float = 0.0     # m/s at release — a stationary shot is rare in play
var since_last_save_s: float = -1.0  # s since this goalie's last save, -1 = none yet
var puck_lateral_speed: float = 0.0  # |vx| of the release — deke / cross-seam finish


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

const WIRE_SIZE: int = 18


func to_array() -> Array:
	return [shooter_peer, team_id, x, z, xg, outcome, shot_type, on_net,
			period, clock_s, goalie_stance, goalie_unset, goalie_radius, goalie_x,
			screen_delay, shooter_speed, since_last_save_s, puck_lateral_speed]


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
	e.goalie_stance = a[10]
	e.goalie_unset = a[11]
	e.goalie_radius = a[12]
	e.goalie_x = a[13]
	e.screen_delay = a[14]
	e.shooter_speed = a[15]
	e.since_last_save_s = a[16]
	e.puck_lateral_speed = a[17]
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
	e.goalie_stance = int(row.get("goalie_stance", -1))
	e.goalie_unset = float(row.get("goalie_unset", 0.0))
	e.goalie_radius = float(row.get("goalie_radius", 0.0))
	e.goalie_x = float(row.get("goalie_x", 0.0))
	e.screen_delay = float(row.get("screen_delay", 0.0))
	e.shooter_speed = float(row.get("shooter_speed", 0.0))
	e.since_last_save_s = float(row.get("since_last_save_s", -1.0))
	e.puck_lateral_speed = float(row.get("puck_lateral_speed", 0.0))
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
		"goalie_stance": goalie_stance,
		"goalie_unset": snappedf(goalie_unset, 0.01),
		"goalie_radius": snappedf(goalie_radius, 0.01),
		"goalie_x": snappedf(goalie_x, 0.01),
		"screen_delay": snappedf(screen_delay, 0.001),
		"shooter_speed": snappedf(shooter_speed, 0.01),
		"since_last_save_s": snappedf(since_last_save_s, 0.01),
		"puck_lateral_speed": snappedf(puck_lateral_speed, 0.01),
	}

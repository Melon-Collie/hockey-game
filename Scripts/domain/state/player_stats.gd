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
#   faceoff_wins   — credited to a team's centre (slot 0) when that team wins
#                    the draw (first to recover the puck off the drop).
#   faceoff_losses — credited to the OPPOSING centre on the same draw, so
#                    faceoff win % has a real denominator.
var hits_taken: int = 0
var takeaways: int = 0
var giveaways: int = 0
var faceoff_wins: int = 0
var faceoff_losses: int = 0
# Stamped once by the host at the final horn (PhaseCoordinator's goal log →
# the goal that put the winner past the loser's final total, NHL-style) and
# broadcast like the counters above, so every peer's Three Stars selection
# reads the same flag. Deliberately absent from to_dict(): the career_stats
# table has no column for it, and PostgREST rejects rows with unknown keys —
# adding it there means a schema migration first.
var game_winning_goals: int = 0
# Host-authoritative goal-flavor counters, broadcast like the counters above so
# a client scorer's own copy reflects them at game-over (where the single-game
# achievements read them). Like game_winning_goals, absent from to_dict(): the
# career_stats table has no column for them.
#   one_timer_goals — goals scored off a one-timer (shot from the shooting zone
#                     without possessing the puck; PhaseCoordinator reads
#                     ShotOnGoalTracker.pending_is_one_timer at goal time).
#   tip_goals       — goals scored by redirecting a teammate's in-flight shot
#                     (the scorer was the last, deflecting toucher, not the shooter).
#   ot_goals        — goals scored in sudden-death overtime (always the winner).
var one_timer_goals: int = 0
var tip_goals: int = 0
var ot_goals: int = 0
# Advanced-stat shot-attempt counters (analytics plan A1), host-authoritative and
# broadcast like the counters above. Individual Corsi/Fenwick; team CF%/FF% and
# PDO derive from these + the existing goals/SOG at display time.
#   shot_attempts         — individual Corsi (iCF): every shot RELEASE this player
#                           took (on goal, missed, or blocked). Off ShotOnGoalTracker's
#                           shot_attempted, so one per release (rebound re-shots and
#                           mid-flight tips don't re-count in v1).
#   shot_attempts_blocked — of those attempts, the ones a defender blocked, so
#                           Fenwick (iFF) = shot_attempts − shot_attempts_blocked.
#                           Off ShotOnGoalTracker's shot_attempt_blocked, which fires
#                           on the same on-net-blocked set as the shots_blocked stat
#                           (v1: a blocked-off-net shot isn't counted as a block).
var shot_attempts: int = 0
var shot_attempts_blocked: int = 0
# Individual expected goals (ixG, analytics plan A2) — the summed xG of the shot
# attempts this player took (AIActionScoring.expected_goals, evaluated at release
# from the real goalie geometry). Host-authoritative and broadcast like the
# counters above; a float, unlike the integer counters. Blocked attempts are
# excluded (xG is on unblocked/Fenwick shots). Goals − xg_for is finishing.
var xg_for: float = 0.0
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
			hits_taken, takeaways, giveaways, faceoff_wins, faceoff_losses,
			game_winning_goals, one_timer_goals, tip_goals, ot_goals,
			shot_attempts, shot_attempts_blocked, xg_for]

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
	faceoff_losses = a[9]
	game_winning_goals = a[10]
	one_timer_goals = a[11]
	tip_goals = a[12]
	ot_goals = a[13]
	shot_attempts = a[14]
	shot_attempts_blocked = a[15]
	xg_for = a[16]

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
		"faceoff_losses": faceoff_losses,
		"shot_attempts": shot_attempts,
		"shot_attempts_blocked": shot_attempts_blocked,
		"xg_for": snappedf(xg_for, 0.001),
		"toi_seconds": roundi(toi_seconds),
	}

class_name GoalieWorldView
extends RefCounted

# The goalie's per-tick view of the other skaters — one scan, shared by every read
# that needs one. First half of the perception/decision split (#519, plan doc §6.2).
#
# ── Why this exists ──────────────────────────────────────────────────────────
# GoalieController was running SIX independent full skater scans per tick, each
# re-walking the same array for a slightly different question: nearest opponent to
# the puck, nearest teammate to the puck, opposing positions for the sweep-lane
# model, "is any shooter near the puck", the backdoor depth cap, and the screen
# occlusion set. At 120 Hz x 2 goalies that is 12 walks of the registry per frame
# to answer questions that one walk answers. This is the "memoize at the seam"
# pattern CLAUDE.md asks for, and it is also the shape the eventual
# GoaliePerception takes: read the world ONCE into plain data, then decide against
# the data rather than against live nodes.
#
# Frame-stamped and rebuilt lazily, so it is correct both from the physics tick and
# from the puck_released SIGNAL handler (which fires outside _physics_process and
# would otherwise read a stale or unbuilt view).
#
# Pure data out. The arrays are reused across rebuilds (PackedVector3Array.clear()
# keeps capacity), so a steady-state tick allocates nothing.

# Non-ghost OPPOSING skater positions — the sweep-lane model and the behind-net
# trip's pressure scan.
var opponents: PackedVector3Array = PackedVector3Array()
# Non-ghost opposing positions EXCLUDING the puck carrier — the backdoor depth cap
# asks about the weak-side one-timer threat, which by definition is not the passer.
var off_puck_opponents: PackedVector3Array = PackedVector3Array()
# EVERY non-ghost skater, both teams — a defenceman screens his own goalie just as
# effectively as an opponent does.
var screeners: PackedVector3Array = PackedVector3Array()

# Distance from the puck to the nearest non-ghost OPPOSING skater, INF if none.
var nearest_opponent_dist: float = INF
# Same, but INCLUDING ghosted players.
#
# ⚠️ BEHAVIOUR QUIRK, PRESERVED DELIBERATELY. Five of the six original scans
# excluded ghosts; `_compute_opposing_shooter_near_puck` did not. So a ghosted
# (offside / icing) player currently counts as "a shooter is near the puck" for the
# slide trigger, the active-blade intent, the standing / paddle sweep and the
# lunge — but not for crease jams, sweep lanes, screens or the backdoor cap. A
# ghosted player cannot legally play the puck, so sealing the back door for one
# looks wrong; this is kept bit-identical here so the extraction is behaviour-
# neutral, and flagged for a separate decision rather than silently changed.
var nearest_opponent_dist_any: float = INF
# Distance from the puck to the nearest non-ghost TEAMMATE, INF if none. Answers
# "is the carrier contested?" for the crease-jam seal.
var nearest_teammate_dist: float = INF

# Physics frame this view was built for; -1 = never built.
var _frame: int = -1


func invalidate() -> void:
	_frame = -1


# Rebuild if this frame has not been scanned yet. `carrier` may be null.
# `team_id` of -1 means "no team assigned", in which case nobody is a teammate and
# every skater is treated as an opponent — matching the original per-scan checks.
func ensure(frame: int, skaters: Array, team_id: int, puck_pos: Vector3,
		carrier: Skater) -> void:
	if frame == _frame:
		return
	_frame = frame
	opponents.clear()
	off_puck_opponents.clear()
	screeners.clear()
	nearest_opponent_dist = INF
	nearest_opponent_dist_any = INF
	nearest_teammate_dist = INF
	for skater: Skater in skaters:
		if skater == null:
			continue
		var opposing: bool = team_id == -1 or skater.get_team_id() != team_id
		var dist: float = skater.global_position.distance_to(puck_pos)
		if opposing:
			nearest_opponent_dist_any = minf(nearest_opponent_dist_any, dist)
		if skater.is_ghost:
			continue   # ghosted players can't play the puck
		screeners.append(skater.global_position)
		if opposing:
			opponents.append(skater.global_position)
			if skater != carrier:
				off_puck_opponents.append(skater.global_position)
			nearest_opponent_dist = minf(nearest_opponent_dist, dist)
		else:
			nearest_teammate_dist = minf(nearest_teammate_dist, dist)

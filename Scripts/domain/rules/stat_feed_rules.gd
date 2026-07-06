class_name StatFeedRules

# Pure mapping of one player's stat-counter changes onto HUD ticker events —
# the "JONES · BLOCKED SHOT" toast feed. No engine deps.
#
# Every peer sees the same replicated PlayerStats counters (host mutates them
# directly, clients decode the stats broadcast), so the HUD derives the feed by
# diffing consecutive snapshots per player instead of listening to a new RPC —
# one code path for host, client, and offline.
#
# Deliberate exclusions:
#   goals / assists — the goal banner + chyron already own that moment; a toast
#                     would double-announce it. A goal also suppresses the
#                     shot-on-goal event from the same diff (the SOG counter
#                     increments alongside the goal).
#   giveaways       — a shame counter; box-score material, not ticker material.
#   hits_taken      — mirror of the deliverer's `hits`, would double-toast.

const EVENT_SHOT_ON_GOAL := &"shot_on_goal"
const EVENT_BLOCKED_SHOT := &"blocked_shot"
const EVENT_HIT := &"hit"
const EVENT_TAKEAWAY := &"takeaway"
const EVENT_FACEOFF_WIN := &"faceoff_win"


# Events for the change prev → now. Any counter DECREASING means the snapshots
# straddle a reset (rematch, rejoin resync) — nothing was "recorded", so the
# answer is no events and the caller just re-baselines.
static func feed_events(prev: PlayerStats, now: PlayerStats) -> Array[StringName]:
	var events: Array[StringName] = []
	if _any_decreased(prev, now):
		return events
	if now.shots_on_goal > prev.shots_on_goal and now.goals == prev.goals:
		events.append(EVENT_SHOT_ON_GOAL)
	if now.shots_blocked > prev.shots_blocked:
		events.append(EVENT_BLOCKED_SHOT)
	if now.hits > prev.hits:
		events.append(EVENT_HIT)
	if now.takeaways > prev.takeaways:
		events.append(EVENT_TAKEAWAY)
	if now.faceoff_wins > prev.faceoff_wins:
		events.append(EVENT_FACEOFF_WIN)
	return events


static func _any_decreased(prev: PlayerStats, now: PlayerStats) -> bool:
	var before: Array = prev.to_array()
	var after: Array = now.to_array()
	for i: int in before.size():
		if (after[i] as int) < (before[i] as int):
			return true
	return false

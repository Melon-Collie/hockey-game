class_name HudStatFeed
extends RefCounted

# Ticker toast per recorded counting stat ("JONES · BLOCKED SHOT"), derived by
# diffing each player's replicated stat counters against the last snapshot —
# the same numbers on every peer, so host and clients see identical toasts
# with no extra RPC. Goals/assists are excluded (the goal banner + chyron own
# that moment); see StatFeedRules for the full exclusion rationale.

signal feed_event(subject: String, detail: String, color: Color)

const _LABELS: Dictionary[StringName, String] = {
	StatFeedRules.EVENT_SHOT_ON_GOAL: "SHOT ON GOAL",
	StatFeedRules.EVENT_BLOCKED_SHOT: "BLOCKED SHOT",
	StatFeedRules.EVENT_HIT: "HIT",
	StatFeedRules.EVENT_TAKEAWAY: "TAKEAWAY",
	StatFeedRules.EVENT_FACEOFF_WIN: "FACEOFF WON",
}

# peer_id -> PlayerStats snapshot from the previous stats_updated.
var _baseline: Dictionary[int, PlayerStats] = {}

func poll() -> void:
	var players: Dictionary = GameManager.get_players()
	for pid: int in players:
		var record: PlayerRecord = players[pid] as PlayerRecord
		if record == null or record.stats == null:
			continue
		var snapshot: PlayerStats = PlayerStats.from_array(record.stats.to_array())
		var prev: PlayerStats = _baseline.get(pid)
		# First sight of a player just establishes the baseline — joining
		# mid-game must not replay their whole stat line as toasts.
		if prev != null:
			for event: StringName in StatFeedRules.feed_events(prev, snapshot):
				feed_event.emit(record.display_name(),
						"· %s" % _LABELS[event], _color_for(record))
		_baseline[pid] = snapshot
	# Drop baselines for departed players so a reused peer id starts fresh.
	for pid: int in _baseline.keys():
		if not players.has(pid):
			_baseline.erase(pid)

# Same color the join/leave toasts use for this player's team.
func _color_for(record: PlayerRecord) -> Color:
	if record.team == null:
		return MenuStyle.BROADCAST_CREAM
	return TeamColorRegistry.get_colors(
			record.team.color_slot, record.team.team_id).primary

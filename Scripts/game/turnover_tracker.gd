class_name TurnoverTracker extends RefCounted
## Host-only attribution of takeaways / giveaways / faceoff wins from possession
## changes. GameManager feeds it three authoritative hooks — a possession gain
## (puck picked up), a strip (puck_stripped_from), and a shot on goal — and it
## mutates the affected players' PlayerStats. The pure decision lives in
## TurnoverRules; this holds the short-lived context (last owner + recent
## strip/shot) needed to classify each gain. No-op when the registry is absent.
##
## Only ever constructed/called on the host (like HitTracker), so the stats it
## writes are authoritative and ride the normal stats broadcast to every peer.

# A recovery within this of a strip counts as a takeaway; within this of a shot
# on goal counts as a rebound (not a giveaway). Generous windows — possession
# often bounces loose for a moment between the event and the recovery.
const STRIP_WINDOW_S: float = 1.5
const SHOT_WINDOW_S: float = 2.0

var _registry: PlayerRegistry = null
var _last_carrier_peer: int = -1
var _last_carrier_team: int = -1
var _strip_time: float = -INF
var _strip_victim_team: int = -1
var _shot_time: float = -INF
var _shot_team: int = -1


func setup(registry: PlayerRegistry) -> void:
	_registry = registry


# Possession gained by `peer_id`. `was_faceoff` = this pickup ended a faceoff
# (won the draw), which is credited to the winning team's centre and never
# counts as a turnover. Returns true when a stat was credited, so the caller
# knows to broadcast the stats now rather than on the next unrelated event.
func on_carrier_gained(peer_id: int, was_faceoff: bool) -> bool:
	if _registry == null:
		return false
	var rec: PlayerRecord = _registry.get_record(peer_id)
	if rec == null or rec.team == null:
		return false
	var new_team: int = rec.team.team_id
	if was_faceoff:
		var credited: bool = _credit_faceoff_win(new_team)
		# A faceoff is a fresh start — clear stale turnover context.
		_last_carrier_peer = peer_id
		_last_carrier_team = new_team
		_strip_time = -INF
		_shot_time = -INF
		return credited
	var now: float = _now()
	var recent_strip: bool = _strip_time + STRIP_WINDOW_S > now \
			and _strip_victim_team == _last_carrier_team
	var recent_shot: bool = _shot_time + SHOT_WINDOW_S > now \
			and _shot_team == _last_carrier_team
	var stat_credited: bool = false
	match TurnoverRules.classify(_last_carrier_team, new_team, recent_strip, recent_shot):
		TurnoverRules.TAKEAWAY:
			if rec.stats != null:
				rec.stats.takeaways += 1
				stat_credited = true
		TurnoverRules.GIVEAWAY:
			var prev: PlayerRecord = _registry.get_record(_last_carrier_peer)
			if prev != null and prev.stats != null:
				prev.stats.giveaways += 1
				stat_credited = true
	_last_carrier_peer = peer_id
	_last_carrier_team = new_team
	return stat_credited


# A poke / stick-lift stripped the puck from `victim_peer_id`.
func note_strip(victim_peer_id: int) -> void:
	_strip_time = _now()
	_strip_victim_team = _team_of(victim_peer_id)


# `shooter_peer_id` put a shot on goal.
func note_shot_on_goal(shooter_peer_id: int) -> void:
	_shot_time = _now()
	_shot_team = _team_of(shooter_peer_id)


# Clear all context (new game / post-goal faceoff reset).
func reset() -> void:
	_last_carrier_peer = -1
	_last_carrier_team = -1
	_strip_time = -INF
	_strip_victim_team = -1
	_shot_time = -INF
	_shot_team = -1


func _credit_faceoff_win(winning_team: int) -> bool:
	# The centre (team_slot 0) takes the draw, so the win is theirs regardless of
	# which linemate actually corralled the loose puck.
	for pid: int in _registry.all():
		var r: PlayerRecord = _registry.get_record(pid)
		if r != null and r.team != null and r.team.team_id == winning_team \
				and r.team_slot == 0 and r.stats != null:
			r.stats.faceoff_wins += 1
			return true
	return false


func _team_of(peer_id: int) -> int:
	if _registry == null:
		return -1
	var r: PlayerRecord = _registry.get_record(peer_id)
	return r.team.team_id if r != null and r.team != null else -1


func _now() -> float:
	return Time.get_ticks_msec() / 1000.0

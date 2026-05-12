class_name HitTracker
extends RefCounted

# Host-only tracker for hit crediting. Validates that a hit is against an
# opposing player before incrementing the hitter's stat.
#
# Flow:
#   on_hit(hitter_peer_id, victim_peer_id, victim_team_id) → credits hit if cross-team, emits hit_credited
#
# Dedup: a 0.5s per-pair cooldown prevents double-counting when both host
# physics and the lag-compensated claim path fire for the same contact.

signal hit_credited

const HIT_COOLDOWN_S: float = 1.5

var _registry: PlayerRegistry = null
var _last_hit_time: Dictionary = {}  # "hitter:victim" -> float host_time


func setup(registry: PlayerRegistry) -> void:
	_registry = registry


func on_hit(hitter_peer_id: int, victim_peer_id: int, victim_team_id: int) -> void:
	var record: PlayerRecord = _registry.get_record(hitter_peer_id)
	if record == null:
		return
	if record.team.team_id == victim_team_id:
		return  # no credit for hitting a teammate
	var key: String = "%d:%d" % [hitter_peer_id, victim_peer_id]
	var now: float = Time.get_ticks_msec() / 1000.0
	if _last_hit_time.get(key, 0.0) + HIT_COOLDOWN_S > now:
		return  # already credited this contact
	_last_hit_time[key] = now
	record.stats.hits += 1
	hit_credited.emit()

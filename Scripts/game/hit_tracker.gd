class_name HitTracker
extends RefCounted

# Host-only tracker for hit crediting. Validates that a hit is against an
# opposing player before incrementing the hitter's stat.
#
# Flow:
#   on_hit(hitter_peer_id, victim_peer_id, victim_team_id, force, hit_dir) →
#     credits hit if cross-team, emits hit_credited (carrying the victim + impact
#     payload so GameManager can broadcast the authoritative impact event, Lever A)
#
# Dedup: a per-pair cooldown (HIT_COOLDOWN_S) prevents double-counting when both
# host physics and the lag-compensated claim path fire for the same contact. The
# hit_credited payload is therefore emitted at most once per pair per cooldown,
# which is exactly the cadence the impact broadcast wants.

signal hit_credited(victim_peer_id: int, force: float, hit_dir: Vector3)

const HIT_COOLDOWN_S: float = 1.5

var _registry: PlayerRegistry = null
var _last_hit_time: Dictionary = {}  # "hitter:victim" -> float host_time


func setup(registry: PlayerRegistry) -> void:
	_registry = registry


func on_hit(hitter_peer_id: int, victim_peer_id: int, victim_team_id: int,
		force: float = 0.0, hit_dir: Vector3 = Vector3.ZERO) -> void:
	var record: PlayerRecord = _registry.get_record(hitter_peer_id)
	if record == null:
		return
	if record.team.team_id == victim_team_id:
		return  # no credit for hitting a teammate
	var key: String = "%d:%d" % [hitter_peer_id, victim_peer_id]
	var now: float = Time.get_ticks_msec() / 1000.0
	# -INF so a never-seen pair's first hit never trips the cooldown — defaulting
	# to 0.0 would gate every hit in the first HIT_COOLDOWN_S seconds after
	# engine boot (caught as flaky CI on test_hit_tracker).
	if _last_hit_time.get(key, -INF) + HIT_COOLDOWN_S > now:
		return  # already credited this contact
	_last_hit_time[key] = now
	record.stats.hits += 1
	hit_credited.emit(victim_peer_id, force, hit_dir)

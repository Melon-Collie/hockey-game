class_name HitTracker
extends RefCounted

# Host-only tracker for hit crediting, mirroring the NHL definition (see
# HitRules): the victim must be in possession of the puck, and the stat lands
# only when the contact costs them possession. GameManager feeds it
# authoritative contacts (direct host physics or the lag-comp claim path) plus
# the possession-change hooks it already observes.
#
# Flow:
#   on_contact(hitter, victim, victim_team, force, dir,
#              attacker_has_puck, victim_is_carrier)
#     → cross-team + per-pair cooldown gates, then HitRules.classify_contact:
#       CREDIT         → stat lands now (victim just lost the puck — a
#                        finished check)
#       CREDIT_PENDING → impact fires now; the stat waits for the victim to
#                        lose possession within POSSESSION_LOSS_WINDOW_S
#       REJECT         → nothing
#   note_possession_lost(peer_id)   → credits any pending hits on that victim
#                                     and starts their just-released grace
#   note_possession_gained(peer_id) → clears the victim's just-released grace
#   tick(delta)                     → ages grace timers, expires pendings
#
# Signals: `impact_landed` fires at CONTACT time for any credited-or-pending
# contact and drives the authoritative impact broadcast (Lever A) — the burst /
# sound can't wait on the possession-loss verdict. `hit_credited` fires when
# the stat actually lands (possibly up to POSSESSION_LOSS_WINDOW_S later) and
# drives the stats sync.
#
# Dedup: a per-pair cooldown (HIT_COOLDOWN_S) prevents double-counting when
# both host physics and the lag-compensated claim path fire for the same
# contact, and coalesces sustained-contact re-fires. It arms at contact time,
# so an expired pending still consumed the pair's window.

signal impact_landed(victim_peer_id: int, force: float, hit_dir: Vector3)
signal hit_credited(victim_peer_id: int, force: float, hit_dir: Vector3)

const HIT_COOLDOWN_S: float = 1.5


class PendingHit:
	var hitter_peer_id: int
	var victim_peer_id: int
	var force: float
	var hit_dir: Vector3
	var remaining: float


var _registry: PlayerRegistry = null
var _last_hit_time: Dictionary = {}  # "hitter:victim" -> float host_time
var _pending: Array[PendingHit] = []
# Seconds since each peer last lost/released the puck; advanced by tick(),
# erased when they regain possession. Bounded by roster size.
var _possession_lost_ago: Dictionary[int, float] = {}


func setup(registry: PlayerRegistry) -> void:
	_registry = registry


func on_contact(hitter_peer_id: int, victim_peer_id: int, victim_team_id: int,
		force: float, hit_dir: Vector3,
		attacker_has_puck: bool, victim_is_carrier: bool) -> void:
	var record: PlayerRecord = _registry.get_record(hitter_peer_id)
	if record == null:
		return
	if record.team.team_id == victim_team_id:
		return  # no credit for hitting a teammate
	var since_loss: float = _possession_lost_ago.get(victim_peer_id, INF)
	var verdict: HitRules.Verdict = HitRules.classify_contact(
			force, attacker_has_puck, victim_is_carrier, since_loss)
	if verdict == HitRules.Verdict.REJECT:
		return
	var key: String = "%d:%d" % [hitter_peer_id, victim_peer_id]
	var now: float = Time.get_ticks_msec() / 1000.0
	# -INF so a never-seen pair's first hit never trips the cooldown — defaulting
	# to 0.0 would gate every hit in the first HIT_COOLDOWN_S seconds after
	# engine boot (caught as flaky CI on test_hit_tracker).
	if _last_hit_time.get(key, -INF) + HIT_COOLDOWN_S > now:
		return  # already fired for this contact
	_last_hit_time[key] = now
	impact_landed.emit(victim_peer_id, force, hit_dir)
	if verdict == HitRules.Verdict.CREDIT:
		_credit(hitter_peer_id, victim_peer_id, force, hit_dir)
		return
	var pending := PendingHit.new()
	pending.hitter_peer_id = hitter_peer_id
	pending.victim_peer_id = victim_peer_id
	pending.force = force
	pending.hit_dir = hit_dir
	pending.remaining = HitRules.POSSESSION_LOSS_WINDOW_S
	_pending.append(pending)


# The puck left `victim_peer_id` (strip, knock-loose, or release) — any pending
# hit on them was a check that cost them possession, so it credits now.
func note_possession_lost(victim_peer_id: int) -> void:
	_possession_lost_ago[victim_peer_id] = 0.0
	var i: int = _pending.size() - 1
	while i >= 0:
		var pending: PendingHit = _pending[i]
		if pending.victim_peer_id == victim_peer_id:
			_pending.remove_at(i)
			_credit(pending.hitter_peer_id, pending.victim_peer_id,
					pending.force, pending.hit_dir)
		i -= 1


func note_possession_gained(peer_id: int) -> void:
	_possession_lost_ago.erase(peer_id)


func tick(delta: float) -> void:
	for pid: int in _possession_lost_ago:
		_possession_lost_ago[pid] += delta
	var i: int = _pending.size() - 1
	while i >= 0:
		_pending[i].remaining -= delta
		if _pending[i].remaining <= 0.0:
			_pending.remove_at(i)  # carrier absorbed the check — no hit
		i -= 1


func _credit(hitter_peer_id: int, victim_peer_id: int,
		force: float, hit_dir: Vector3) -> void:
	var record: PlayerRecord = _registry.get_record(hitter_peer_id)
	if record == null or record.stats == null:
		return
	record.stats.hits += 1
	# Mirror onto the victim: a "hit taken" for every credited check. Same
	# cross-team + per-pair cooldown gate as the delivered hit (we're inside both).
	var victim: PlayerRecord = _registry.get_record(victim_peer_id)
	if victim != null and victim.stats != null:
		victim.stats.hits_taken += 1
	hit_credited.emit(victim_peer_id, force, hit_dir)

class_name HitClaimResolver
extends RefCounted

# Validates body-check claims with lag compensation. Has both client (send) and
# host (receive) sides because body-check physics is local-authoritative — only
# the local skater's body fires `body_checked_player`. The host can't directly
# observe the contact, so it accepts a claim from the client and rewinds state
# to validate range before crediting via HitTracker.
#
# Flow:
#   notify_local_hit(hitter_peer_id, victim)
#     host  : credits HitTracker.on_hit directly
#     client: throttles per (hitter,victim) and sends NetworkManager.send_hit_claim
#   receive_claim(hitter, victim, host_ts, rtt) [host]
#     → reject if claim stale, peers unknown, or rewound positions out of range
#     → otherwise credit via HitTracker.on_hit
#
# Throttle: body_checked_player fires every 240Hz tick during sustained contact;
# unthrottled claim RPCs flood the host. The throttle window matches
# HitTracker.HIT_COOLDOWN_S so claims can't outrun crediting.
#
# `receive_claim` is host-only by contract — caller gates on NetworkManager.is_host.
# `notify_local_hit` does its own host/client branch since that's the whole point.
# Emits no signals; HitTracker.hit_credited fires when credit lands.

const MAX_CLAIM_AGE_S: float = 0.2
const MAX_RANGE_M: float = 2.0

var _registry: PlayerRegistry = null
var _state_buffer: StateBufferManager = null
var _hit_tracker: HitTracker = null

var _last_claim_sent: Dictionary[String, float] = {}  # client only: "hitter:victim" -> time


func setup(
		registry: PlayerRegistry,
		state_buffer: StateBufferManager,
		hit_tracker: HitTracker) -> void:
	_registry = registry
	_state_buffer = state_buffer
	_hit_tracker = hit_tracker


# Drops the throttle dict on rematch so the first body-check after reset
# isn't suppressed by a stale entry from the previous game.
func reset_throttle() -> void:
	_last_claim_sent.clear()


func notify_local_hit(hitter_peer_id: int, victim: Skater) -> void:
	if NetworkManager.is_host:
		_hit_tracker.on_hit(hitter_peer_id, _registry.resolve_peer_id(victim), _registry.resolve_team_id(victim))
		return
	var victim_peer_id: int = _registry.resolve_peer_id(victim)
	if victim_peer_id == -1:
		return
	var key: String = "%d:%d" % [hitter_peer_id, victim_peer_id]
	var now: float = Time.get_ticks_msec() / 1000.0
	if _last_claim_sent.get(key, 0.0) + HitTracker.HIT_COOLDOWN_S > now:
		return
	_last_claim_sent[key] = now
	NetworkManager.send_hit_claim(
			victim_peer_id,
			NetworkManager.estimated_host_time(),
			NetworkManager.get_latest_rtt_ms())


func receive_claim(hitter_peer_id: int, victim_peer_id: int, host_timestamp: float, rtt_ms: float) -> void:
	if _state_buffer == null or not _state_buffer.is_ready():
		return
	var now: float = Time.get_ticks_msec() / 1000.0
	if now - host_timestamp > MAX_CLAIM_AGE_S:
		return
	var hitter_rec: PlayerRecord = _registry.get_record(hitter_peer_id)
	var victim_rec: PlayerRecord = _registry.get_record(victim_peer_id)
	if hitter_rec == null or victim_rec == null:
		return
	var rewind_rtt: float = clampf(rtt_ms, 10.0, 200.0)
	var rewind_time: float = host_timestamp - rewind_rtt / 2000.0
	var snapshot: WorldSnapshot = _state_buffer.get_state_at(rewind_time)
	var hitter_snap: SkaterNetworkState = snapshot.get_skater_state(hitter_peer_id)
	var victim_snap: SkaterNetworkState = snapshot.get_skater_state(victim_peer_id)
	if hitter_snap == null or victim_snap == null:
		return
	if hitter_snap.position.distance_to(victim_snap.position) > MAX_RANGE_M:
		return
	_hit_tracker.on_hit(hitter_peer_id, victim_peer_id, victim_rec.team.team_id)

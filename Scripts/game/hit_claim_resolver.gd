class_name HitClaimResolver
extends RefCounted

# Validates body-check claims with lag compensation. Has both client (send) and
# host (receive) sides because body-check physics is local-authoritative — only
# the local skater's body fires `body_checked_player`. The host can't directly
# observe the contact, so it accepts a claim from the client and rewinds state
# to validate the gates (impulse threshold, attacker-doesn't-have-puck,
# victim-is-puck-relevant) before crediting via HitTracker.
#
# Flow:
#   notify_local_hit(hitter_peer_id, victim, impulse_magnitude)
#     host  : runs HitRules.is_valid_hit against live state, credits directly
#     client: pre-filters (impulse, local-carry), throttles per (hitter,victim),
#             sends NetworkManager.send_hit_claim. The host re-validates the
#             rule gates from rewound snapshots on receipt.
#   receive_claim(hitter, victim, host_ts, rtt, interp_delay_ms) [host]
#     → reject if claim stale, peers unknown, or rewound positions out of range
#     → rewind hitter to host_ts + INPUT_LEAD_SEC (their own predicted body)
#       and victim to host_ts - interp_delay (the remote body they saw)
#     → re-derive impulse from rewound velocities along hitter→victim normal
#     → reject if HitRules.is_valid_hit fails
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
var _puck_getter: Callable = Callable()             # () -> Puck
var _puck_controller_getter: Callable = Callable()  # () -> PuckController

var _last_claim_sent: Dictionary[String, float] = {}  # client only: "hitter:victim" -> time


func setup(
		registry: PlayerRegistry,
		state_buffer: StateBufferManager,
		hit_tracker: HitTracker,
		puck_getter: Callable,
		puck_controller_getter: Callable) -> void:
	_registry = registry
	_state_buffer = state_buffer
	_hit_tracker = hit_tracker
	_puck_getter = puck_getter
	_puck_controller_getter = puck_controller_getter


# Drops the throttle dict on rematch so the first body-check after reset
# isn't suppressed by a stale entry from the previous game.
func reset_throttle() -> void:
	_last_claim_sent.clear()


func notify_local_hit(hitter_peer_id: int, victim: Skater, impulse_magnitude: float) -> void:
	var victim_peer_id: int = _registry.resolve_peer_id(victim)
	if victim_peer_id == -1:
		return
	if NetworkManager.is_host:
		if not _puck_getter.is_valid() or not _puck_controller_getter.is_valid():
			return
		var puck: Puck = _puck_getter.call() as Puck
		var puck_ctrl: PuckController = _puck_controller_getter.call() as PuckController
		if puck == null or puck_ctrl == null:
			return
		var puck_carrier: int = puck_ctrl.get_carrier_peer_id()
		var attacker_has_puck: bool = (puck_carrier == hitter_peer_id)
		var victim_relevant: bool = HitRules.is_victim_puck_relevant(
				victim_peer_id, puck_carrier, victim.global_position, puck.global_position)
		if not HitRules.is_valid_hit(impulse_magnitude, attacker_has_puck, victim_relevant):
			return
		_hit_tracker.on_hit(hitter_peer_id, victim_peer_id, _registry.resolve_team_id(victim))
		return
	# Client: pre-filter on impulse and local puck state so we don't spam the
	# host with claims for trivial bumps or while the local player is carrying
	# the puck. The host re-validates all gates from rewound snapshots.
	if impulse_magnitude < HitRules.MIN_HIT_IMPULSE:
		return
	if not _puck_controller_getter.is_valid():
		return
	var pc: PuckController = _puck_controller_getter.call() as PuckController
	if pc == null or pc.get_carrier_peer_id() == hitter_peer_id:
		return
	var key: String = "%d:%d" % [hitter_peer_id, victim_peer_id]
	var now: float = NetworkManager.local_time()
	if _last_claim_sent.get(key, 0.0) + HitTracker.HIT_COOLDOWN_S > now:
		return
	_last_claim_sent[key] = now
	NetworkManager.send_hit_claim(
			victim_peer_id,
			NetworkManager.estimated_host_time(),
			NetworkManager.get_latest_rtt_ms(),
			NetworkManager.get_target_interpolation_delay() * 1000.0)


func receive_claim(hitter_peer_id: int, victim_peer_id: int, host_timestamp: float, _rtt_ms: float, interp_delay_ms: float) -> void:
	if _state_buffer == null or not _state_buffer.is_ready():
		return
	var now: float = NetworkManager.local_time()
	if now - host_timestamp > MAX_CLAIM_AGE_S:
		return
	var hitter_rec: PlayerRecord = _registry.get_record(hitter_peer_id)
	var victim_rec: PlayerRecord = _registry.get_record(victim_peer_id)
	if hitter_rec == null or victim_rec == null:
		return
	# Two rewinds because the attacker viewed the two bodies at different times:
	# their own body via local prediction (SELF view) and the victim via
	# interpolation (REMOTE view). Using one rewind for both (as the prior
	# `host_timestamp - rtt/2` did) compares hitter-from-one-time against
	# victim-from-another-time. See LagCompRewind for the derivation.
	var hitter_rewind_time: float = LagCompRewind.self_view_time(host_timestamp)
	var victim_rewind_time: float = LagCompRewind.remote_view_time(host_timestamp, interp_delay_ms)
	var hitter_snapshot: WorldSnapshot = _state_buffer.get_state_at(hitter_rewind_time)
	var victim_snapshot: WorldSnapshot = _state_buffer.get_state_at(victim_rewind_time)
	var hitter_snap: SkaterNetworkState = hitter_snapshot.get_skater_state(hitter_peer_id)
	var victim_snap: SkaterNetworkState = victim_snapshot.get_skater_state(victim_peer_id)
	if hitter_snap == null or victim_snap == null:
		return
	if hitter_snap.position.distance_to(victim_snap.position) > MAX_RANGE_M:
		return
	# Puck pulled from the victim's rewind snapshot — when the attacker isn't
	# the carrier, the puck they saw was interpolated at host_time - interp_delay
	# alongside the victim. When the attacker IS the carrier (which the
	# is_valid_hit gate rejects anyway), the puck would be at their blade in
	# the hitter snapshot, but the rejection comes from the carrier_peer_id
	# check that doesn't depend on the puck's position, so either snapshot works.
	var puck_snap: PuckNetworkState = victim_snapshot.puck_state
	if puck_snap == null:
		return
	# Re-derive impulse from rewound velocities along the hitter→victim normal.
	# Each velocity is read from its own rewound snapshot so the closing speed
	# reflects what the attacker actually saw, not a single mid-time slice.
	# Skater weight is uniform (1.0) so impulse ≈ approach.
	var to_victim: Vector3 = victim_snap.position - hitter_snap.position
	to_victim.y = 0.0
	if to_victim.length_squared() < 0.0001:
		return
	var normal: Vector3 = to_victim.normalized()
	var rel_vel: Vector3 = hitter_snap.velocity - victim_snap.velocity
	rel_vel.y = 0.0
	var impulse: float = rel_vel.dot(normal)
	var attacker_has_puck: bool = (puck_snap.carrier_peer_id == hitter_peer_id)
	var victim_relevant: bool = HitRules.is_victim_puck_relevant(
			victim_peer_id, puck_snap.carrier_peer_id,
			victim_snap.position, puck_snap.position)
	if not HitRules.is_valid_hit(impulse, attacker_has_puck, victim_relevant):
		return
	_hit_tracker.on_hit(hitter_peer_id, victim_peer_id, victim_rec.team.team_id)

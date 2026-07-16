class_name HitClaimResolver
extends RefCounted

# Validates body-check claims with lag compensation. Has both client (send) and
# host (receive) sides because body-check physics is local-authoritative — only
# the local skater's body fires `body_checked_player`. The host can't directly
# observe the contact, so it accepts a claim from the client and rewinds state
# to gather the contact facts (impulse, who carried the puck) before routing to
# HitTracker.on_contact, which owns the crediting rules (HitRules).
#
# Flow:
#   notify_local_hit(hitter_peer_id, victim, impulse_magnitude)
#     host  : reads live carrier state, routes to HitTracker.on_contact
#     client: pre-filters (impulse, local-carry), throttles per (hitter,victim),
#             sends NetworkManager.send_hit_claim. The host re-derives the
#             contact facts from rewound snapshots on receipt.
#   receive_claim(hitter, victim, host_ts, interp_delay_ms) [host]
#     → reject if claim stale, peers unknown, or rewound positions out of range
#     → rewind hitter to host_ts + INPUT_LEAD_SEC (their own predicted body)
#       and victim to host_ts - interp_delay (the remote body they saw)
#     → re-derive impulse from rewound velocities along hitter→victim normal,
#       scaled by the hitter's weight (the same magnitude the host-observed
#       path validates)
#     → route to HitTracker.on_contact (HitRules classifies + credits)
#
# Throttle: body_checked_player fires every physics tick during sustained contact;
# unthrottled claim RPCs flood the host. The throttle window matches
# HitTracker.HIT_COOLDOWN_S so claims can't outrun crediting.
#
# `receive_claim` is host-only by contract — caller gates on NetworkManager.is_host.
# `notify_local_hit` does its own host/client branch since that's the whole point.
# Emits no signals; HitTracker.impact_landed / hit_credited fire when the
# contact / stat land.

const MAX_CLAIM_AGE_S: float = 0.2
const MAX_RANGE_M: float = 2.0

var _registry: PlayerRegistry = null
var _state_buffer: StateBufferManager = null
var _hit_tracker: HitTracker = null
var _puck_controller_getter: Callable = Callable()  # () -> PuckController

var _last_claim_sent: Dictionary[String, float] = {}  # client only: "hitter:victim" -> time


func setup(
		registry: PlayerRegistry,
		state_buffer: StateBufferManager,
		hit_tracker: HitTracker,
		puck_controller_getter: Callable) -> void:
	_registry = registry
	_state_buffer = state_buffer
	_hit_tracker = hit_tracker
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
		if not _puck_controller_getter.is_valid():
			return
		var puck_ctrl: PuckController = _puck_controller_getter.call() as PuckController
		if puck_ctrl == null:
			return
		var puck_carrier: int = puck_ctrl.get_carrier_peer_id()
		# Direction for the impact burst — hitter → victim on the horizontal plane,
		# the same vector the lag-comp claim path derives from rewound positions.
		var hitter_rec: PlayerRecord = _registry.get_record(hitter_peer_id)
		var hit_dir: Vector3 = Vector3.ZERO
		if hitter_rec != null and hitter_rec.skater != null:
			hit_dir = victim.global_position - hitter_rec.skater.global_position
			hit_dir.y = 0.0
			hit_dir = hit_dir.normalized()
		var hitter_committed: bool = hitter_rec != null and hitter_rec.skater != null \
				and hitter_rec.skater.hit_committed
		_hit_tracker.on_contact(hitter_peer_id, victim_peer_id,
				_registry.resolve_team_id(victim), impulse_magnitude, hit_dir,
				puck_carrier == hitter_peer_id, puck_carrier == victim_peer_id,
				hitter_committed)
		return
	# Client: pre-filter on impulse, commit, and local puck state so we don't spam
	# the host with claims for trivial bumps, uncommitted contact, or while the
	# local player is carrying. The host re-validates all gates from rewound
	# snapshots (including the rewound hit_committed), so this is purely an RPC saver.
	if impulse_magnitude < HitRules.MIN_HIT_IMPULSE:
		return
	var local_hitter: PlayerRecord = _registry.get_record(hitter_peer_id)
	if local_hitter == null or local_hitter.skater == null or not local_hitter.skater.hit_committed:
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
	# Adapted interp delay (get_interpolation_delay), the value that actually
	# positioned the rendered victim this frame — matched by remote_view_time on
	# the host. Not the target (which can lead it mid-jitter); see the pickup
	# claim send in local_controller for the full rationale.
	NetworkManager.send_hit_claim(
			victim_peer_id,
			NetworkManager.estimated_host_time(),
			NetworkManager.get_interpolation_delay() * 1000.0)


func receive_claim(hitter_peer_id: int, victim_peer_id: int, host_timestamp: float, interp_delay_ms: float) -> void:
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
	# Puck carrier read from the victim's rewind snapshot — that's the world the
	# attacker saw when they committed to the check. The tracker's grace path
	# (HitRules.classify_contact) covers the skew: if the host already saw the
	# victim lose the puck by the time this claim arrives, the live possession
	# loss wins over the snapshot's stale carrier flag.
	var puck_snap: PuckNetworkState = victim_snapshot.puck_state
	if puck_snap == null:
		return
	# Re-derive impulse from rewound velocities along the hitter→victim normal.
	# Each velocity is read from its own rewound snapshot so the closing speed
	# reflects what the attacker actually saw, not a single mid-time slice.
	var to_victim: Vector3 = victim_snap.position - hitter_snap.position
	to_victim.y = 0.0
	if to_victim.length_squared() < 0.0001:
		return
	var normal: Vector3 = to_victim.normalized()
	var rel_vel: Vector3 = hitter_snap.velocity - victim_snap.velocity
	rel_vel.y = 0.0
	var impulse: float = rel_vel.dot(normal)
	# Scale by the hitter's weight BEFORE the tracker validates so the claim
	# path meets the same weight-scaled bar as the host-observed path
	# (body_checked_player carries weight × approach) — validating the raw
	# closing speed here made remote hitters need more closing speed than
	# hosted ones. Weight spreads ±18% with Size. `normal` is the
	# hitter → victim direction for the burst.
	var hit_force: float = impulse * (hitter_rec.skater.weight if hitter_rec.skater != null else 1.0)
	# Commit read from the hitter's own rewind snapshot (their predicted body at
	# the instant they committed) — the same replicated hit_committed the live
	# resolver gates the physics on, so the credit meets the same bar.
	_hit_tracker.on_contact(hitter_peer_id, victim_peer_id, victim_rec.team.team_id,
			hit_force, normal,
			puck_snap.carrier_peer_id == hitter_peer_id,
			puck_snap.carrier_peer_id == victim_peer_id,
			hitter_snap.hit_committed)

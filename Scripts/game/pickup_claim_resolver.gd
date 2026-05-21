class_name PickupClaimResolver
extends RefCounted

# Host-only resolver for client-initiated pickup claims with lag compensation.
# Pulled out of GameManager so the validation flow (age check, blade/puck
# rewind, contest-window arbitration) lives in one testable place.
#
# Flow:
#   receive_claim(peer_id, host_ts, rtt, interp_delay)
#     → reject if puck locked, claim stale, skater missing/ghost, on cooldown
#     → rewind blade to host_ts + rtt/2; rewind puck to host_ts - interp_delay
#     → reject if PuckInteractionRules.check_pickup fails
#     → if a prior claim is pending, resolve via apply_contested_pickup
#     → otherwise arm pending and wait CONTEST_WINDOW_S for a contender
#   tick(delta) [each host physics frame]
#     → after CONTEST_WINDOW_S with no contender, apply_lag_comp_pickup and clear
#   clear() [when puck is granted authoritatively]
#     → drop any pending claim
#
# Host-only by contract — caller gates on NetworkManager.is_host. Emits no
# signals: every effect is a method call on the injected puck controller.

const MAX_CLAIM_AGE_S: float = 0.2
const CONTEST_WINDOW_S: float = 0.05

var _registry: PlayerRegistry = null
var _state_buffer: StateBufferManager = null
var _puck_getter: Callable = Callable()             # () -> Puck
var _puck_controller_getter: Callable = Callable()  # () -> PuckController

var _pending_peer_id: int = -1
var _pending_timer: float = 0.0


func setup(
		registry: PlayerRegistry,
		state_buffer: StateBufferManager,
		puck_getter: Callable,
		puck_controller_getter: Callable) -> void:
	_registry = registry
	_state_buffer = state_buffer
	_puck_getter = puck_getter
	_puck_controller_getter = puck_controller_getter


func tick(delta: float) -> void:
	if _pending_peer_id == -1:
		return
	_pending_timer += delta
	if _pending_timer < CONTEST_WINDOW_S:
		return
	# Resolve at use time so a peer that disconnected / demoted during the
	# contest window doesn't dereference a freed skater.
	var record: PlayerRecord = _registry.get_record(_pending_peer_id)
	if record != null and record.skater != null and _puck_controller_getter.is_valid():
		var pc: PuckController = _puck_controller_getter.call() as PuckController
		if pc != null:
			pc.apply_lag_comp_pickup(record.skater)
	_pending_peer_id = -1
	_pending_timer = 0.0


func clear() -> void:
	_pending_peer_id = -1
	_pending_timer = 0.0


func receive_claim(peer_id: int, host_timestamp: float, rtt_ms: float, interp_delay_ms: float) -> void:
	if not _puck_getter.is_valid() or not _puck_controller_getter.is_valid():
		return
	var puck: Puck = _puck_getter.call() as Puck
	var pc: PuckController = _puck_controller_getter.call() as PuckController
	if puck == null or pc == null:
		return
	if puck.carrier != null or puck.pickup_locked:
		return
	# Use session-relative game time so the age check matches host_timestamp's
	# time base (the client stamped it with estimated_host_time).
	# Time.get_ticks_msec() is OS uptime and would diverge by however long the
	# host was alive before the game started.
	var now: float = NetworkManager.local_time()
	if now - host_timestamp > MAX_CLAIM_AGE_S:
		return
	var record: PlayerRecord = _registry.get_record(peer_id)
	if record == null or record.skater == null:
		return
	# is_ghost is checked from the rewound snapshot below (skater_snap), not
	# present-time, so a player who became ghost in the last RTT/2 isn't
	# wrongly denied a claim that was legal at send time, and a player who
	# just cleared ghost isn't wrongly granted one that was illegal then.
	if puck.is_on_cooldown(record.skater):
		return
	if _state_buffer == null or not _state_buffer.is_ready():
		return
	var rewind_rtt: float = clampf(rtt_ms, 10.0, 200.0)
	# Blade: client's blade state from T_client = claim send time arrives in the
	# state buffer at host time = host_timestamp + rtt/2 (one-way transit).
	var blade_rewind_time: float = host_timestamp + rewind_rtt / 2000.0
	# Puck: client's interpolated puck is delayed by interp_delay behind host
	# time. Rewind to the timestamp the client was actually looking at.
	var puck_rewind_time: float = host_timestamp - clampf(interp_delay_ms, 0.0, 200.0) / 1000.0
	var puck_snap: WorldSnapshot = _state_buffer.get_state_at(puck_rewind_time)
	if puck_snap.puck_state == null or puck_snap.puck_state.carrier_peer_id != -1:
		return
	var puck_pos: Vector3 = puck_snap.puck_state.position
	var puck_prev_snap: WorldSnapshot = _state_buffer.get_state_at(puck_rewind_time - 1.0 / 240.0)
	var puck_prev: Vector3 = puck_prev_snap.puck_state.position if puck_prev_snap.puck_state != null else puck_pos
	var blade_snap: WorldSnapshot = _state_buffer.get_state_at(blade_rewind_time)
	var blade_prev_snap: WorldSnapshot = _state_buffer.get_state_at(blade_rewind_time - 1.0 / 240.0)
	var skater_snap: SkaterNetworkState = blade_snap.get_skater_state(peer_id)
	var skater_prev_snap: SkaterNetworkState = blade_prev_snap.get_skater_state(peer_id)
	if skater_snap == null or skater_prev_snap == null:
		return
	if skater_snap.is_ghost:
		return
	var blade_curr: Vector3 = skater_snap.blade_contact_world
	var blade_prev: Vector3 = skater_prev_snap.blade_contact_world
	if not PuckInteractionRules.check_pickup(puck_prev, puck_pos, blade_prev, blade_curr, PuckController.PICKUP_RADIUS):
		return
	if _pending_peer_id != -1:
		# Resolve the prior claimant at contest time. If they've disconnected
		# or demoted in the contest window, treat the new claim as uncontested.
		var prior_record: PlayerRecord = _registry.get_record(_pending_peer_id)
		if prior_record != null and prior_record.skater != null:
			pc.apply_contested_pickup(record.skater, prior_record.skater)
			_pending_peer_id = -1
			_pending_timer = 0.0
		else:
			_pending_peer_id = peer_id
			_pending_timer = 0.0
	else:
		_pending_timer = 0.0
		_pending_peer_id = peer_id

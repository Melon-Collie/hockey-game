class_name PokeClaimResolver
extends RefCounted

# Host-only resolver for client-initiated poke check claims with lag compensation.
# Mirrors PickupClaimResolver but with no contest window — first valid claim
# wins, the carrier loses the puck either way. Two attackers claiming within
# microseconds of each other are arbitrated by RPC arrival order; the second
# claim sees carrier == null from the first's apply_poke_check and skips.
#
# Flow:
#   receive_claim(peer_id, host_ts, rtt, interp_delay, expected_carrier_peer_id)
#     → reject if puck locked, no carrier, carrier changed, claim stale,
#       skater missing/ghost, attempting to poke self or teammate
#     → rewind blade to host_ts + rtt/2; rewind puck to host_ts - interp_delay
#     → reject if PuckInteractionRules.check_poke fails against rewound state
#     → apply_lag_comp_poke (idempotent — re-checks carrier on apply path
#       so a concurrent host-side _check_interactions detection that already
#       cleared the carrier doesn't get double-applied).

const MAX_CLAIM_AGE_S: float = 0.2

var _registry: PlayerRegistry = null
var _state_buffer: StateBufferManager = null
var _puck_getter: Callable = Callable()             # () -> Puck
var _puck_controller_getter: Callable = Callable()  # () -> PuckController


func setup(
		registry: PlayerRegistry,
		state_buffer: StateBufferManager,
		puck_getter: Callable,
		puck_controller_getter: Callable) -> void:
	_registry = registry
	_state_buffer = state_buffer
	_puck_getter = puck_getter
	_puck_controller_getter = puck_controller_getter


func receive_claim(peer_id: int, host_timestamp: float, rtt_ms: float,
		interp_delay_ms: float, expected_carrier_peer_id: int) -> void:
	if not _puck_getter.is_valid() or not _puck_controller_getter.is_valid():
		return
	var puck: Puck = _puck_getter.call() as Puck
	var pc: PuckController = _puck_controller_getter.call() as PuckController
	if puck == null or pc == null:
		return
	if puck.carrier == null or puck.pickup_locked:
		return
	# Same age check as pickup — `host_timestamp` is in the `estimated_host_time`
	# time base, matched against session-relative `local_time`.
	var now: float = NetworkManager.local_time()
	if now - host_timestamp > MAX_CLAIM_AGE_S:
		return
	var record: PlayerRecord = _registry.get_record(peer_id)
	if record == null or record.skater == null or record.skater.is_ghost:
		return
	# Defense in depth — client-side gate already excludes these, but a
	# malformed RPC shouldn't be able to bypass the rules.
	if record.skater == puck.carrier:
		return
	var carrier_team: int = _registry.team_id_by_skater.get(puck.carrier, -1)
	var checker_team: int = _registry.team_id_by_skater.get(record.skater, -1)
	if not PuckCollisionRules.can_poke_check(carrier_team, checker_team):
		return
	if _state_buffer == null or not _state_buffer.is_ready():
		return
	var rewind_rtt: float = clampf(rtt_ms, 10.0, 200.0)
	# Blade rewind: client's blade state at claim-send time arrives in the host's
	# state buffer at host_timestamp + rtt/2 (one-way transit).
	var blade_rewind_time: float = host_timestamp + rewind_rtt / 2000.0
	# Puck rewind: client's interpolated remote carrier was rendered at
	# host_time - interp_delay. Rewind to the timestamp the client was looking at.
	var puck_rewind_time: float = host_timestamp - clampf(interp_delay_ms, 0.0, 200.0) / 1000.0
	var puck_snap: WorldSnapshot = _state_buffer.get_state_at(puck_rewind_time)
	if puck_snap.puck_state == null:
		return
	# Validate the carrier was the player the claimant was attacking. If the
	# carrier had already changed by the claimant's view-time (someone else
	# stripped first, or the carrier released the puck), the claim is stale.
	if puck_snap.puck_state.carrier_peer_id != expected_carrier_peer_id:
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
	var blade_curr: Vector3 = skater_snap.blade_contact_world
	var blade_prev: Vector3 = skater_prev_snap.blade_contact_world
	if not PuckInteractionRules.check_poke(puck_prev, puck_pos, blade_prev, blade_curr, PuckController.POKE_RADIUS):
		return
	# Pass the intended victim through so apply guards against the carrier
	# having changed (X → Z) between claim send and apply. Looked up from the
	# claimant's expected target, not from the current `puck.carrier`.
	var expected_record: PlayerRecord = _registry.get_record(expected_carrier_peer_id)
	if expected_record == null or expected_record.skater == null:
		return
	pc.apply_lag_comp_poke(record.skater, expected_record.skater)

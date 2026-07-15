class_name StickLiftClaimResolver
extends RefCounted

# Host-only resolver for client-initiated stick-lift claims with lag compensation.
# Mirrors PokeClaimResolver: the attacker (claimant) holds Q with their blade
# lifted and hooks it under an opposing carrier's stick shaft to pop it up and
# dislodge the puck. Like poke, there's no contest window — first valid claim
# wins, the carrier loses the puck either way.
#
# Flow:
#   receive_claim(peer_id, host_ts, interp_delay, expected_carrier_peer_id)
#     → reject if puck locked, no carrier, carrier changed, claim stale,
#       skater missing/ghost, attempting to lift self or a teammate
#     → rewind the attacker's blade to LagCompRewind.self_view_time(host_ts)
#       and the carrier's stick shaft to remote_view_time(host_ts, interp_delay)
#       — never rtt/2 (see LagCompRewind / Networking Invariants)
#     → reject if PuckInteractionRules.check_blade_under_stick fails against the
#       rewound geometry (attacker's blade within radius of the shaft AND below it)
#     → apply_lag_comp_stick_lift (idempotent — re-checks carrier on apply so a
#       concurrent host-side detection that already stripped doesn't double-apply).
#
# Geometry is an instantaneous point-vs-segment test (the attacker's blade vs.
# the victim's hand→blade shaft), so — unlike poke's swept test — it needs no
# previous-tick snapshot.

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


func receive_claim(peer_id: int, host_timestamp: float,
		interp_delay_ms: float, expected_carrier_peer_id: int) -> void:
	if not _puck_getter.is_valid() or not _puck_controller_getter.is_valid():
		return
	var puck: Puck = _puck_getter.call() as Puck
	var pc: PuckController = _puck_controller_getter.call() as PuckController
	if puck == null or pc == null:
		return
	if puck.carrier == null or puck.pickup_locked:
		return
	# Same age check as pickup/poke — `host_timestamp` is in the
	# `estimated_host_time` base, matched against session-relative `local_time`.
	var now: float = NetworkManager.local_time()
	if now - host_timestamp > MAX_CLAIM_AGE_S:
		return
	var record: PlayerRecord = _registry.get_record(peer_id)
	if record == null or record.skater == null:
		return
	# is_ghost is judged from the rewound attacker snapshot below, not present-time
	# — matching PickupClaimResolver / PokeClaimResolver: an attacker legal at their
	# view-time but ghosted (offside) in the last RTT/2 isn't wrongly denied, and one
	# who just tagged up isn't wrongly granted a lift that was illegal then.
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
	# Attacker's blade is SELF-view (they render their own body via prediction);
	# the carrier's stick shaft is REMOTE-view (rendered via interpolation).
	var blade_rewind_time: float = LagCompRewind.self_view_time(host_timestamp)
	var shaft_rewind_time: float = LagCompRewind.remote_view_time(host_timestamp, interp_delay_ms)
	var shaft_snap: WorldSnapshot = _state_buffer.get_state_at(shaft_rewind_time)
	if shaft_snap.puck_state == null:
		return
	# The carrier the claimant was attacking must still have been carrying at
	# their view-time; otherwise someone else stripped first or the carrier
	# released and the claim is stale.
	if shaft_snap.puck_state.carrier_peer_id != expected_carrier_peer_id:
		return
	var victim_snap: SkaterNetworkState = shaft_snap.get_skater_state(expected_carrier_peer_id)
	if victim_snap == null:
		return
	var blade_snap: WorldSnapshot = _state_buffer.get_state_at(blade_rewind_time)
	var attacker_snap: SkaterNetworkState = blade_snap.get_skater_state(peer_id)
	if attacker_snap == null:
		return
	if attacker_snap.is_ghost:
		return
	if not PuckInteractionRules.check_blade_under_stick(
			attacker_snap.blade_contact_world,
			victim_snap.top_hand_world, victim_snap.blade_contact_world,
			PuckController.STICK_LIFT_RADIUS, PuckController.STICK_LIFT_UNDER_MARGIN):
		return
	# Pass the intended victim through so apply guards against the carrier having
	# changed (X → Z) between claim send and apply.
	var expected_record: PlayerRecord = _registry.get_record(expected_carrier_peer_id)
	if expected_record == null or expected_record.skater == null:
		return
	pc.apply_lag_comp_stick_lift(record.skater, expected_record.skater)

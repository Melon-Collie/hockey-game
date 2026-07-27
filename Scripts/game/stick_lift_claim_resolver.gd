class_name StickLiftClaimResolver
extends RefCounted

# Host-only resolver for client-initiated stick-lift claims with lag compensation.
# Mirrors PokeClaimResolver: the attacker (claimant) holds Q with their blade
# lifted and hooks it under an opposing carrier's stick shaft to pop it up and
# dislodge the puck. Like poke, there's no contest window — first valid claim
# wins, the carrier loses the puck either way.
#
# Flow:
#   receive_claim(peer_id, host_ts, interp_delay, expected_carrier_peer_id,
#                 client_blade_curr)
#     → reject if puck locked, no carrier, carrier changed, claim stale,
#       skater missing/ghost, attempting to lift self or a teammate
#     → rewind the carrier's stick shaft to remote_view_time(host_ts, interp_delay)
#       and the attacker's body to self_view_time(host_ts); stage-3: shift the
#       shaft by the carrier's forward-predicted displacement
#       (LagCompRewind.forward_predict_skater — the claimant rendered the
#       carrier intent-integrated toward present, and the shaft rides the
#       carrier's body); reach-clamp the CLIENT-sent attacker blade to that body
#     → reject if PuckInteractionRules.check_blade_under_stick fails against that
#       geometry (attacker's blade within radius of the shaft AND below it)
#     → apply_lag_comp_stick_lift (idempotent)
#
# The shared claim-resolver contract is in Scripts/game/CLAUDE.md.
#
# Geometry is an instantaneous point-vs-segment test (the attacker's blade vs.
# the victim's hand→blade shaft), so — unlike poke's swept test — it needs no
# previous-tick snapshot.

const MAX_CLAIM_AGE_S: float = 0.2

var _registry: PlayerRegistry = null
var _state_buffer: StateBufferManager = null
var _puck_getter: Callable = Callable()             # () -> Puck
var _puck_controller_getter: Callable = Callable()  # () -> PuckController
# Stage-3 forward-prediction scratch (reused; receive_claim is host-only).
var _fp_result := SkaterMovementRules.ForwardResult.new()


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
		interp_delay_ms: float, input_lead_ms: float, expected_carrier_peer_id: int,
		client_blade_curr: Vector3) -> void:
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
	# Anti-cheat: bound the self-reported render delay against the measured link
	# before any rewind / forward-predict depth reads it (see LagCompRewind).
	interp_delay_ms = LagCompRewind.plausible_interp_delay_ms(
			interp_delay_ms, float(NetworkManager.get_peer_ping_ms(peer_id)))
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
	var blade_rewind_time: float = LagCompRewind.self_view_time(host_timestamp, input_lead_ms)
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
	# Looked up here (rather than at apply time) because the stage-3 carrier
	# reconstruction below needs the carrier's controller.
	var expected_record: PlayerRecord = _registry.get_record(expected_carrier_peer_id)
	if expected_record == null or expected_record.skater == null:
		return
	# Stage-3: the claimant rendered the CARRIER forward-predicted toward
	# host-present, and the stick shaft rides the carrier's upper body — so the
	# shaft the attacker hooked under sits at the rewound shaft position PLUS the
	# carrier's forward-predicted displacement (rigid translation: the render
	# holds the body-relative shaft pose and advances the body). No-op at
	# fraction 0 — exact legacy render == rewind.
	var shaft_top: Vector3 = victim_snap.top_hand_world
	var shaft_blade: Vector3 = victim_snap.blade_contact_world
	if LagCompRewind.forward_predict_skater(victim_snap,
			expected_record.controller as SkaterController, interp_delay_ms, _fp_result):
		var carrier_delta: Vector3 = _fp_result.position - victim_snap.position
		shaft_top += carrier_delta
		shaft_blade += carrier_delta
	var blade_snap: WorldSnapshot = _state_buffer.get_state_at(blade_rewind_time)
	var attacker_snap: SkaterNetworkState = blade_snap.get_skater_state(peer_id)
	if attacker_snap == null:
		return
	if attacker_snap.is_ghost:
		return
	# Client-authoritative attacker blade ("aim") — the claim carries the blade the
	# client hooked under the shaft with, reach-clamped to the attacker's
	# server-authoritative body so a modified client can't teleport it. The victim's
	# shaft stays REMOTE-view (host-reconstructed, as before). See
	# PickupClaimResolver / LagCompRewind.clamp_client_blade.
	var max_reach: float = 0.0
	var blade_speed: float = 0.0
	if _registry != null:
		var caps: AISkaterCaps = _registry.caps_by_peer.get(peer_id)
		if caps != null:
			max_reach = caps.max_blade_reach
			blade_speed = caps.blade_speed
	var attacker_blade: Vector3 = LagCompRewind.clamp_client_blade(
			client_blade_curr, attacker_snap.position, max_reach)
	# Tighter continuity bound toward the host's own blade reconstruction — see
	# PickupClaimResolver / LagCompRewind.continuity_clamp. No-ops when the host
	# has no reconstruction for the attacker at the rewind instant.
	attacker_blade = LagCompRewind.continuity_clamp(attacker_blade,
			attacker_snap.blade_contact_world,
			LagCompRewind.blade_continuity_tolerance(blade_speed))
	# Host-only claim-outcome telemetry (no-op off the host): the claim reached the
	# rewound geometry test; a check_blade_under_stick fail is the lag-comp
	# "reached for it, didn't get it" signal. See NetworkTelemetry / network_sessions.
	NetworkTelemetry.record_stick_lift_claim()
	if not PuckInteractionRules.check_blade_under_stick(
			attacker_blade,
			shaft_top, shaft_blade,
			PuckController.STICK_LIFT_RADIUS, PuckController.STICK_LIFT_UNDER_MARGIN):
		NetworkTelemetry.record_stick_lift_claim_miss()
		return
	# Pass the intended victim through so apply guards against the carrier having
	# changed (X → Z) between claim send and apply. Looked up above.
	pc.apply_lag_comp_stick_lift(record.skater, expected_record.skater)
